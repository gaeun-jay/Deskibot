#!/usr/bin/env python3
"""
Deskibot Voice Pipeline
ESP32(µ-law) → STT (CLOVA) → Claude (Tool Use) → TTS (Google) → ESP32

STT는 2026-08-19 실측으로 CLOVA를 채택했다(근거는 STT_ENGINE 선언부 주석).
CLOVA 호출이 실패하면 Google로 자동 대체하므로 두 자격증명이 모두 필요하다.
TTS는 Google 그대로다.

응답 바이너리 포맷:
  [4B] STT 텍스트 길이 (little-endian uint32)
  [N]  STT 텍스트 (UTF-8)
  [4B] 명령 JSON 길이
  [M]  명령 JSON (UTF-8)
        {"action":"none"}
        {"action":"add_todo","done":true,"content":"..."}
        {"action":"complete_todo","done":true,"content":"..."}
        {"action":"delete_todo","done":true,"content":"..."}
  [...]  PCM 오디오 (16-bit mono, 16 kHz, little-endian)
"""

import hashlib, struct, time, os, json, wave, io
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from uuid import UUID
from zoneinfo import ZoneInfo

from app.todo_add import (
    normalize_content,
    parse_date,
    parse_deadline,
    resolve_category,
    resolve_notify,
)
from app.todo_matching import select_todo_candidate
from app.voice_prompt import TOOLS, build_system_prompt
from app.audio_codec import ulaw_to_pcm16

# .env 는 패키지 밖(server/hw/)에 있다. 실행 위치에 기대지 않도록 명시한다 —
# uvicorn 을 어디서 띄우든 같은 파일을 읽는다. sw 서버와 같은 방식이다.
BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

from google.cloud import speech
from google.cloud import texttospeech
from google.api_core.client_options import ClientOptions
import anthropic
import requests

claude = anthropic.Anthropic()

# ─── 설정 ─────────────────────────────────────────────────────────────────────
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY", "")
DB_HOST        = os.environ.get("DB_HOST", "")
DB_PORT        = os.environ.get("DB_PORT", "")
DB_NAME        = os.environ.get("DB_NAME", "")
DB_USER        = os.environ.get("DB_USER", "")
DB_PASSWORD    = os.environ.get("DB_PASSWORD", "")

SAMPLE_RATE  = 16000

# STT 벤치마크용 원본 오디오 덤프. 실기기 마이크·거리·게인이 그대로 담긴
# 녹음이라야 벤치 결과가 현장 성능과 맞는다. 평소에는 꺼 둔다.
DEBUG_DUMP_AUDIO = os.environ.get("DEBUG_DUMP_AUDIO", "") == "1"
DUMP_DIR         = os.environ.get("DUMP_DIR", "bench/audio")
# 녹음만 하고 STT/LLM/TTS를 건너뛴다. 벤치 데이터셋을 모을 때 쓴다.
# 이걸 안 켜면 "삭제해줘", "완료" 같은 발화가 실제 DB를 바꿔 버린다.
DUMP_ONLY        = os.environ.get("DUMP_ONLY", "") == "1"
CLAUDE_MODEL = "claude-haiku-4-5-20251001"
TTS_VOICE    = "ko-KR-Neural2-A"
KST          = ZoneInfo("Asia/Seoul")

# 한 번의 발화로 무한정 할 일이 쌓이지 않게 막는다.
MAX_ADDS_PER_REQUEST = 3

# 완료·삭제도 한 요청에 여러 건 처리한다("영어 숙제랑 헬스 지워줘").
# 다만 추가와 달리 되돌릴 수 없어서 상한은 남긴다 — STT가 한 번 크게 잘못
# 들었을 때 피해가 번지지 않게 하는 장치다.
MAX_MUTATIONS_PER_REQUEST = 3

# STT 힌트. "데스키봇"이 "JS 키보드"로 들리는 등 고유명사·도메인 어휘가 계속
# 어긋나서 넣는다. boost는 0~20이고 과하면 엉뚱한 말도 이 단어로 끌어당긴다.
STT_PHRASE_HINTS = [
    "데스키봇",
    "뽀모도로", "집중", "타이머", "스톱워치",
    "할 일", "일정", "마감", "알림",
    "추가", "삭제", "완료",
]
STT_PHRASE_BOOST = 15.0

# ─── 클라이언트 싱글톤 ────────────────────────────────────────────────────────
_google_opts = ClientOptions(api_key=GOOGLE_API_KEY)
_stt_client  = speech.SpeechClient(client_options=_google_opts)
_tts_client  = texttospeech.TextToSpeechClient(client_options=_google_opts)

_db_env = {
    "host": DB_HOST,
    "port": DB_PORT,
    "dbname": DB_NAME,
    "user": DB_USER,
    "password": DB_PASSWORD,
}
_missing_db_env = [name for name, value in _db_env.items() if not value]
if _missing_db_env:
    raise RuntimeError("missing PostgreSQL settings: " + ", ".join(_missing_db_env))
try:
    _db_env["port"] = int(DB_PORT)
except ValueError as exc:
    raise RuntimeError("DB_PORT must be an integer") from exc
_db_env["row_factory"] = dict_row

# check: 빌려주기 전에 커넥션이 살아있는지 확인한다. 로봇이 몇 시간 조용하면
# 놀던 커넥션이 죽는데, 이게 없으면 침묵 뒤 첫 요청만 503으로 실패하고
# 그 다음부터 정상이 된다. 시연에서 첫 호출이 튕기는 형태로 나타난다.
# max_idle: 애초에 죽을 때까지 방치하지 않도록 5분마다 재활용한다.
db_pool = ConnectionPool(
    conninfo="",
    kwargs=_db_env,
    min_size=1,
    max_size=5,
    open=True,
    check=ConnectionPool.check_connection,
    max_idle=300,
)
print("[PostgreSQL] ✅ device 인증 풀 연결 완료", flush=True)

# ─── HW device 인증 ───────────────────────────────────────────────────────────
def authenticate_device(token: str) -> UUID | None:
    """device token 을 검증하고 연결된 user_id 를 반환한다.

    HTTP 계층에서 헤더를 꺼내 넘긴다. 이 함수가 request 를 직접 보지 않으므로
    웹 프레임워크와 무관하고, 나중에 server/common/ 으로 그대로 옮길 수 있다.
    """
    if not token or len(token) > 127:
        return None

    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    with db_pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE devices
                   SET last_seen_at = NOW()
                 WHERE token_hash = %s
                   AND user_id IS NOT NULL
                RETURNING user_id
                """,
                (token_hash,),
            )
            row = cur.fetchone()
    return row["user_id"] if row else None

# ─── PostgreSQL Todo 헬퍼 ─────────────────────────────────────────────────────
def postgres_get_schedule(user_id: UUID) -> str:
    """오늘 남은 할 일을 마감이 지난 것과 아직 남은 것으로 나눠 돌려준다.

    마감이 이미 지난 항목을 "9시까지 있어요"라고 미래형으로 읽으면 어색하다.
    여기서는 분류만 해주고, 실제 말투는 Claude가 시스템 프롬프트 규칙에 따라 만든다.
    """
    now = datetime.now(KST)
    today = now.date()
    with db_pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, content, deadline_time
                  FROM todos
                 WHERE user_id = %s
                   AND date = %s
                   AND is_done = false
                 ORDER BY deadline_time NULLS LAST, id
                """,
                (user_id, today),
            )
            rows = cur.fetchall()

    if not rows:
        return "오늘 완료하지 않은 할 일이 없습니다."

    now_minutes = now.hour * 60 + now.minute
    overdue, remaining = [], []
    for row in rows:
        deadline = row["deadline_time"]
        if deadline is None:
            remaining.append(row["content"])
            continue
        label = f"{row['content']}({deadline.strftime('%H시 %M분')} 마감)"
        if deadline.hour * 60 + deadline.minute < now_minutes:
            overdue.append(label)
        else:
            remaining.append(label)

    # 마감이 지난 쪽을 먼저 말한다. 확인이 필요한 항목이라 더 급하다.
    max_spoken = 4
    parts, spoken = [], 0
    if overdue:
        shown = overdue[:max_spoken]
        spoken += len(shown)
        parts.append("마감이 이미 지난 할 일: " + ", ".join(shown))
    if remaining and spoken < max_spoken:
        shown = remaining[: max_spoken - spoken]
        spoken += len(shown)
        parts.append("아직 마감 전인 할 일: " + ", ".join(shown))

    result = " / ".join(parts)
    left = len(rows) - spoken
    if left > 0:
        result += f" / 그 외 {left}개"
    return result


def postgres_get_categories(user_id: UUID) -> list[dict]:
    """사용자가 앱에서 만들어 둔 카테고리를 표시 순서대로 읽는다."""
    with db_pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, name
                  FROM categories
                 WHERE user_id = %s
                 ORDER BY sort_order, name
                """,
                (user_id,),
            )
            return cur.fetchall()


def postgres_add_todo(user_id: UUID, args: dict) -> tuple[str, str]:
    """음성으로 받은 할 일을 todos에 추가한다.

    제목만 정하고 마감은 사용자가 말했을 때만 넣는다. 마감이 있으면 마감 알림을
    함께 켠다(앱과 동일하게 30분 전/1시간 전 둘 중 하나, 기본 1시간 전).
    """
    content = normalize_content(args.get("content"))
    if not content:
        return "할 일 제목을 알아듣지 못했습니다.", json.dumps(
            {"action": "add_todo", "done": False, "reason": "empty_content"},
            ensure_ascii=False,
        )

    now = datetime.now(KST)
    todo_date = parse_date(args.get("date"), now.date())
    deadline = parse_deadline(args.get("deadline_time"))
    notify, notify_before_min = resolve_notify(
        todo_date, deadline, args.get("notify_before_min"), now
    )

    categories = postgres_get_categories(user_id)
    category = resolve_category(categories, args.get("category"))
    if category is None:
        return (
            "앱에서 카테고리를 먼저 만들어 주세요.",
            json.dumps(
                {"action": "add_todo", "done": False, "reason": "no_category"},
                ensure_ascii=False,
            ),
        )

    with db_pool.connection() as conn:
        with conn.cursor() as cur:
            # 음성 인식이 한 번에 두 번 도는 경우가 있어 같은 날 같은 제목의
            # 미완료 할 일은 다시 만들지 않는다.
            cur.execute(
                """
                SELECT id
                  FROM todos
                 WHERE user_id = %s
                   AND date = %s
                   AND is_done = false
                   AND btrim(lower(content)) = btrim(lower(%s))
                 LIMIT 1
                """,
                (user_id, todo_date, content),
            )
            if cur.fetchone() is not None:
                return (
                    f"{content}, 이미 등록되어 있습니다.",
                    json.dumps(
                        {"action": "add_todo", "done": False, "reason": "duplicate"},
                        ensure_ascii=False,
                    ),
                )

            cur.execute(
                """
                INSERT INTO todos
                    (user_id, category_id, content, date,
                     deadline_time, notify, notify_before_min, is_done)
                VALUES (%s, %s, %s, %s, %s, %s, %s, false)
                """,
                (
                    user_id,
                    category["id"],
                    content,
                    todo_date,
                    deadline,
                    notify,
                    notify_before_min,
                ),
            )

    detail = f"카테고리 {category['name']}"
    if deadline is not None:
        detail += f", 마감 {deadline.strftime('%H시 %M분')}"
        if notify:
            detail += f", 마감 {notify_before_min}분 전 알림"
        else:
            detail += ", 알림 시각이 이미 지나 알림은 끔"
    else:
        detail += ", 마감 없음"
    print(f"[PostgreSQL] ✅ todo 추가: {content} ({detail})", flush=True)

    return f"{content} 추가 완료 ({detail})", json.dumps(
        {"action": "add_todo", "done": True, "content": content},
        ensure_ascii=False,
    )


def _mutate_open_todo(user_id: UUID, content_hint: str, action: str) -> tuple[str, str]:
    """인증 사용자의 미완료 Todo를 보수적으로 찾아 삭제 또는 완료 처리한다."""
    if action not in {"delete_todo", "complete_todo"}:
        raise ValueError("unsupported Todo action")
    with db_pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, content
                  FROM todos
                 WHERE user_id = %s
                   AND is_done = false
                 ORDER BY date, deadline_time NULLS LAST, id
                """,
                (user_id,),
            )
            candidate, reason = select_todo_candidate(cur.fetchall(), content_hint)
            if candidate is None:
                message = (
                    "비슷한 할 일이 여러 개라 처리하지 않았습니다. 더 정확히 말해 주세요."
                    if reason == "ambiguous"
                    else "해당 할 일을 찾지 못했습니다."
                )
                return message, json.dumps(
                    {"action": action, "done": False, "reason": reason},
                    ensure_ascii=False,
                )

            if action == "delete_todo":
                cur.execute(
                    """
                    DELETE FROM todos
                     WHERE id = %s
                       AND user_id = %s
                       AND is_done = false
                    RETURNING content
                    """,
                    (candidate["id"], user_id),
                )
                success_text = "삭제했습니다."
            else:
                cur.execute(
                    """
                    UPDATE todos
                       SET is_done = true
                     WHERE id = %s
                       AND user_id = %s
                       AND is_done = false
                    RETURNING content
                    """,
                    (candidate["id"], user_id),
                )
                success_text = "완료 처리했습니다."

            changed = cur.fetchone()
            if changed is None:
                return "이미 변경된 할 일입니다.", json.dumps(
                    {"action": action, "done": False, "reason": "conflict"},
                    ensure_ascii=False,
                )

            content = changed["content"]
            return f"{content}, {success_text}", json.dumps(
                {"action": action, "done": True, "content": content},
                ensure_ascii=False,
            )


# ─── Tool 실행 ────────────────────────────────────────────────────────────────
def _run_tool(user_id: UUID, name: str, args: dict) -> tuple[str, str]:
    """Returns (tool_result_for_claude, cmd_json_for_esp)"""

    if name == "get_schedule":
        return postgres_get_schedule(user_id), json.dumps({"action": "none"})

    elif name == "add_todo":
        return postgres_add_todo(user_id, args)

    elif name == "complete_todo":
        return _mutate_open_todo(user_id, args.get("content_hint", ""), name)

    elif name == "delete_todo":
        return _mutate_open_todo(user_id, args.get("content_hint", ""), name)

    return "알 수 없는 도구", json.dumps({"action": "none"})


# ─── 오디오 덤프 (벤치마크용) ─────────────────────────────────────────────────
def _dump_pcm(pcm: bytes) -> None:
    """수신 PCM을 wav로 저장한다. 실패해도 음성 처리는 계속되어야 한다."""
    try:
        os.makedirs(DUMP_DIR, exist_ok=True)
        name = f"{datetime.now(KST).strftime('%Y%m%d-%H%M%S')}-{hashlib.sha1(pcm).hexdigest()[:8]}.wav"
        path = os.path.join(DUMP_DIR, name)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(pcm)
        print(f"[DUMP] {path} ({len(pcm)/SAMPLE_RATE/2:.1f}초)", flush=True)
    except Exception as e:
        print(f"[DUMP] ⚠️ 저장 실패: {e}", flush=True)


def _confirm_beep(ms: int = 150, hz: int = 880) -> bytes:
    """녹음 확인용 짧은 톤. ESP는 오디오 길이가 0이면 에러로 처리한다
    (src/screens/voice.h:441). TTS를 부르지 않으니 API 비용도 들지 않는다."""
    import math
    n = int(SAMPLE_RATE * ms / 1000)
    out = bytearray()
    for i in range(n):
        # 앞뒤를 페이드해서 팝 노이즈를 없앤다.
        fade = min(1.0, i / 240, (n - i) / 240)
        v = int(9000 * fade * math.sin(2 * math.pi * hz * i / SAMPLE_RATE))
        out += struct.pack("<h", v)
    return bytes(out)


# ─── 호출어 보정 ──────────────────────────────────────────────────────────────
# CLOVA CSR에는 키워드 부스팅이 없다(Google의 phrase hints에 해당하는 기능이
# CLOVA Speech 장문 API에만 있다). 그래서 후처리로 보완한다.
#
# 실측 90발화에서 CLOVA의 호출어 오인식은 "데 스키보드" 계열로 뭉쳐 있었다
# (15건 중 10건). 문장 머리 1~3어절을 붙여 "데스키봇"과 편집거리를 재고,
# 길이 대비 0.5 이하면 되돌린다.
#
# 문턱은 기존 데이터셋으로 정했다. 0.5에서 복원 12/15, 오탐 0건이다.
# (0.75로 올리면 복원 14건이지만 호출어 없는 발화 9건에 잘못 끼워넣는다.)
_WAKE_WORD = "데스키봇"
_WAKE_MAX_DIST_RATIO = 0.5


def _edit_distance(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def fix_wake_word(text: str) -> str:
    """문장 머리의 호출어 오인식만 되돌린다. 나머지 구간은 건드리지 않는다."""
    if not text or _WAKE_WORD in text:
        return text
    toks = text.split()
    for n in (3, 2, 1):                    # "데 스키 보드"처럼 띄어 나오는 경우까지
        if len(toks) < n:
            continue
        head = "".join(toks[:n])
        if not (2 <= len(head) <= 7):
            continue
        if _edit_distance(head, _WAKE_WORD) / len(_WAKE_WORD) <= _WAKE_MAX_DIST_RATIO:
            print(f"[STT] 호출어 보정: \"{' '.join(toks[:n])}\" -> \"{_WAKE_WORD}\"", flush=True)
            return " ".join([_WAKE_WORD] + toks[n:])
    return text


# ─── STT ─────────────────────────────────────────────────────────────────────
# 엔진은 환경변수로 고른다. 문제가 생기면 재배포 없이 .env만 바꿔 되돌릴 수 있다.
#
# 2026-08-19 실측(ESP32 실기기 90발화, 힌트 없이 맨몸 비교)으로 CLOVA를 채택했다.
# 지연 단축이 최우선 목표이고, 통계적으로 유의한 차이가 난 지표가 레이턴시뿐이다.
#   CER      0.077 vs 0.090   (유의차 없음, CI [-0.002, +0.027])
#   intent   92.2% vs 86.7%   (유의차 없음, McNemar p=0.180)
#   p95      1.18s vs 1.54s   (유의함, CI [+0.127, +0.192])  ← 채택 근거
#   복합발화 90% vs 73%        (한 문장에 두 요청)
# 자세한 내용은 bench/report.md.
#
# 알아둘 점: CLOVA CSR에는 키워드 부스팅이 없다. Google의 phrase hints로 호출어
# "데스키봇"을 보정하던 수단이 사라진다(맨몸에서는 두 엔진 다 못 알아듣는다).
STT_ENGINE = os.environ.get("STT_ENGINE", "clova").lower()

_CLOVA_URL    = "https://naveropenapi.apigw.ntruss.com/recog/v1/stt"
_CLOVA_ID     = os.environ.get("NAVER_CLIENT_ID") or os.environ.get("NAVER_CLLIENT_ID", "")
_CLOVA_SECRET = os.environ.get("NAVER_API_KEY", "")


def _pcm_to_wav(pcm: bytes) -> bytes:
    """CLOVA CSR은 컨테이너가 있는 오디오를 받는다."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def _stt_google(pcm: bytes) -> str:
    config = speech.RecognitionConfig(
        encoding=speech.RecognitionConfig.AudioEncoding.LINEAR16,
        sample_rate_hertz=SAMPLE_RATE,
        language_code="ko-KR",
        enable_automatic_punctuation=True,
        speech_contexts=[
            speech.SpeechContext(phrases=STT_PHRASE_HINTS, boost=STT_PHRASE_BOOST)
        ],
    )
    resp = _stt_client.recognize(config=config, audio=speech.RecognitionAudio(content=pcm))
    return "".join(r.alternatives[0].transcript for r in resp.results)


def _stt_clova(pcm: bytes) -> str:
    r = requests.post(
        _CLOVA_URL,
        params={"lang": "Kor"},
        headers={
            "X-NCP-APIGW-API-KEY-ID": _CLOVA_ID,
            "X-NCP-APIGW-API-KEY": _CLOVA_SECRET,
            "Content-Type": "application/octet-stream",
        },
        data=_pcm_to_wav(pcm),
        timeout=15,
    )
    r.raise_for_status()
    return r.json().get("text", "")


def run_stt(pcm: bytes) -> str:
    dur = len(pcm) / SAMPLE_RATE / 2
    print(f"\n[STT] 입력: {len(pcm):,} bytes ({dur:.1f}초) engine={STT_ENGINE}", flush=True)
    t0 = time.time()

    try:
        transcript = _stt_clova(pcm) if STT_ENGINE == "clova" else _stt_google(pcm)
    except Exception as e:
        # 한쪽이 죽어도 음성 기능 전체가 멈추지는 않게 다른 엔진으로 한 번 넘긴다.
        other = "google" if STT_ENGINE == "clova" else "clova"
        print(f"[STT] ⚠️ {STT_ENGINE} 실패({type(e).__name__}) — {other}로 대체 시도", flush=True)
        try:
            transcript = _stt_google(pcm) if other == "google" else _stt_clova(pcm)
        except Exception as e2:
            print(f"[STT] ❌ 양쪽 모두 실패: {e2}", flush=True)
            return ""

    transcript = fix_wake_word(transcript)
    status = "✅" if transcript else "⚠️ (빈 결과)"
    print(f"[STT] {status} ({time.time()-t0:.2f}s): \"{transcript}\"", flush=True)
    return transcript


# ─── LLM ─────────────────────────────────────────────────────────────────────
def run_llm(user_id: UUID, text: str) -> tuple[str, str]:
    """Returns (cmd_json, tts_text)"""
    print(f"[LLM] 입력: \"{text}\"", flush=True)
    t0 = time.time()

    now   = datetime.now(KST)
    today = now.strftime("%Y-%m-%d")
    # 카테고리 조회가 실패해도 대화 자체는 되게 둔다(add_todo만 못 쓴다).
    try:
        cat_list = ", ".join(str(c["name"]) for c in postgres_get_categories(user_id)) or "없음"
    except Exception:
        print("[PostgreSQL] 카테고리 조회 실패 — 목록 없이 진행", flush=True)
        cat_list = "없음"

    system = build_system_prompt(today, now.strftime("%H:%M"), cat_list)

    messages = [{"role": "user", "content": text}]
    cmd_json = json.dumps({"action": "none"})
    mutation_count = 0      # complete/delete 건수 — 되돌리기 어려워 상한을 둔다
    add_count     = 0       # 추가는 되돌리기 쉬우니 몇 건까지 허용

    while True:
        resp = claude.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=300,
            system=system,
            tools=TOOLS,
            messages=messages,
        )

        if resp.stop_reason == "tool_use":
            assistant_content = []
            for b in resp.content:
                if b.type == "text":
                    assistant_content.append({"type": "text", "text": b.text})
                elif b.type == "tool_use":
                    assistant_content.append({
                        "type": "tool_use", "id": b.id, "name": b.name,
                        "input": b.input if isinstance(b.input, dict) else {},
                    })
            messages.append({"role": "assistant", "content": assistant_content})

            tool_results = []
            for b in resp.content:
                if b.type != "tool_use":
                    continue
                print(f"[LLM] 🔧 tool={b.name}", flush=True)
                if (b.name in {"complete_todo", "delete_todo"}
                        and mutation_count >= MAX_MUTATIONS_PER_REQUEST):
                    tool_result = (
                        f"한 요청에서는 할 일을 {MAX_MUTATIONS_PER_REQUEST}개까지만 "
                        "변경할 수 있습니다."
                    )
                    tool_cmd = json.dumps({"action": "none"})
                elif b.name == "add_todo" and add_count >= MAX_ADDS_PER_REQUEST:
                    tool_result = (
                        f"한 요청에서는 할 일을 {MAX_ADDS_PER_REQUEST}개까지만 추가할 수 있습니다."
                    )
                    tool_cmd = json.dumps({"action": "none"})
                else:
                    tool_result, tool_cmd = _run_tool(
                        user_id, b.name, b.input if isinstance(b.input, dict) else {}
                    )
                    if b.name in {"complete_todo", "delete_todo"}:
                        mutation_count += 1
                    elif b.name == "add_todo":
                        add_count += 1
                if json.loads(tool_cmd).get("action") != "none":
                    cmd_json = tool_cmd
                tool_results.append({"type": "tool_result", "tool_use_id": b.id, "content": tool_result})
            messages.append({"role": "user", "content": tool_results})

        else:
            tts_text = next((b.text for b in resp.content if b.type == "text"), "")
            print(f"[LLM] ✅ ({time.time()-t0:.2f}s) cmd={cmd_json[:80]} | tts=\"{tts_text[:40]}\"", flush=True)
            return cmd_json, tts_text


# ─── TTS ─────────────────────────────────────────────────────────────────────
def run_tts(text: str) -> bytes:
    preview = text[:60] + ("..." if len(text) > 60 else "")
    print(f"[TTS] \"{preview}\"", flush=True)
    t0   = time.time()
    resp = _tts_client.synthesize_speech(
        input=texttospeech.SynthesisInput(text=text),
        voice=texttospeech.VoiceSelectionParams(language_code="ko-KR", name=TTS_VOICE),
        audio_config=texttospeech.AudioConfig(
            audio_encoding=texttospeech.AudioEncoding.LINEAR16,
            sample_rate_hertz=SAMPLE_RATE,
        ),
    )
    wav = resp.audio_content
    idx = wav.find(b"data")
    if idx >= 0:
        data_size = struct.unpack_from("<I", wav, idx + 4)[0]
        pcm = wav[idx + 8 : idx + 8 + data_size]
    else:
        pcm = wav[44:]
    print(f"[TTS] ✅ ({time.time()-t0:.2f}s): {len(pcm):,} bytes", flush=True)
    return pcm


# ─── 직렬화 ──────────────────────────────────────────────────────────────────
def pack_response(transcript: str, cmd_json: str, audio: bytes) -> bytes:
    t = transcript.encode("utf-8")
    c = cmd_json.encode("utf-8")
    return struct.pack("<I", len(t)) + t + struct.pack("<I", len(c)) + c + audio


# ─── 엔드포인트 ───────────────────────────────────────────────────────────────
