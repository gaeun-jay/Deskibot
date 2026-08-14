#!/usr/bin/env python3
"""
Deskibot Voice Pipeline
ESP32 → STT (Google) → Claude (Tool Use) → TTS (Google) → ESP32

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

import hashlib, struct, time, os, json
from datetime import datetime
from flask import Flask, request, Response
from dotenv import load_dotenv
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from uuid import UUID
from zoneinfo import ZoneInfo

from todo_add import (
    normalize_content,
    parse_date,
    parse_deadline,
    resolve_category,
    resolve_notify,
)
from todo_matching import select_todo_candidate

load_dotenv()

from google.cloud import speech
from google.cloud import texttospeech
from google.api_core.client_options import ClientOptions
import anthropic

app    = Flask(__name__)
claude = anthropic.Anthropic()

# ─── 설정 ─────────────────────────────────────────────────────────────────────
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY", "")
DB_HOST        = os.environ.get("DB_HOST", "")
DB_PORT        = os.environ.get("DB_PORT", "")
DB_NAME        = os.environ.get("DB_NAME", "")
DB_USER        = os.environ.get("DB_USER", "")
DB_PASSWORD    = os.environ.get("DB_PASSWORD", "")

SAMPLE_RATE  = 16000
CLAUDE_MODEL = "claude-haiku-4-5-20251001"
TTS_VOICE    = "ko-KR-Neural2-A"
KST          = ZoneInfo("Asia/Seoul")

# 한 번의 발화로 무한정 할 일이 쌓이지 않게 막는다.
MAX_ADDS_PER_REQUEST = 3

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

db_pool = ConnectionPool(conninfo="", kwargs=_db_env, min_size=1, max_size=5, open=True)
print("[PostgreSQL] ✅ device 인증 풀 연결 완료", flush=True)

# ─── HW device 인증 ───────────────────────────────────────────────────────────
def _authenticate_device() -> UUID | None:
    """X-Device-Key를 검증하고 연결된 user_id를 반환한다."""
    token = request.headers.get("X-Device-Key", "")
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

# ─── Claude Tool 정의 ─────────────────────────────────────────────────────────
TOOLS = [
    {
        "name": "get_schedule",
        "description": (
            "오늘의 할 일 목록을 조회합니다. "
            "'과제', '일정', '오늘 뭐 해야 해', '할 일' 등 조회 관련 질문에 사용하세요."
        ),
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "add_todo",
        "description": (
            "새 할 일을 추가합니다. "
            "'~해야 해', '~있어', '~추가해줘', '~기억해줘' 처럼 앞으로 할 일을 "
            "이야기할 때 사용합니다. 되묻지 말고 들은 내용만으로 바로 추가하세요."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "할 일 제목. 조사·군더더기를 뺀 짧은 명사구 (예: '영어 숙제')",
                },
                "category": {
                    "type": "string",
                    "description": "카테고리 목록 중 제목과 가장 잘 맞는 이름. 애매하면 '기타'",
                },
                "date": {
                    "type": "string",
                    "description": "날짜 YYYY-MM-DD. 언급이 없으면 오늘",
                },
                "deadline_time": {
                    "type": ["string", "null"],
                    "description": (
                        "마감 시각 HH:MM (24시간제). "
                        "사용자가 구체적인 시각을 말했을 때만 넣고, 아니면 null"
                    ),
                },
                "notify_before_min": {
                    "type": ["integer", "null"],
                    "description": (
                        "마감 몇 분 전에 알릴지. 30 또는 60만 가능. "
                        "사용자가 '30분 전'이라고 콕 집어 말했을 때만 30, "
                        "그 외에는 null(마감이 있으면 서버가 60으로 설정)"
                    ),
                },
            },
            "required": ["content", "category", "date"],
        },
    },
    {
        "name": "complete_todo",
        "description": (
            "할 일을 완료 처리합니다. "
            "'끝냈어', '완료', '체크', '다했어' 등의 표현에 사용합니다."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content_hint": {"type": "string", "description": "완료할 할 일 이름/힌트"},
            },
            "required": ["content_hint"],
        },
    },
    {
        "name": "delete_todo",
        "description": (
            "할 일을 목록에서 완전히 삭제합니다. "
            "'삭제', '지워줘', '없애줘', '취소' 등의 표현에 사용합니다. "
            "완료 처리(complete_todo)와 달리 기록 자체가 사라집니다."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content_hint": {"type": "string", "description": "삭제할 할 일 이름/힌트"},
            },
            "required": ["content_hint"],
        },
    },
]

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


# ─── STT ─────────────────────────────────────────────────────────────────────
def run_stt(pcm: bytes) -> str:
    dur = len(pcm) / SAMPLE_RATE / 2
    print(f"\n[STT] 입력: {len(pcm):,} bytes ({dur:.1f}초)", flush=True)
    t0 = time.time()

    audio  = speech.RecognitionAudio(content=pcm)
    config = speech.RecognitionConfig(
        encoding=speech.RecognitionConfig.AudioEncoding.LINEAR16,
        sample_rate_hertz=SAMPLE_RATE,
        language_code="ko-KR",
        enable_automatic_punctuation=True,
        speech_contexts=[
            speech.SpeechContext(phrases=STT_PHRASE_HINTS, boost=STT_PHRASE_BOOST)
        ],
    )
    resp       = _stt_client.recognize(config=config, audio=audio)
    transcript = "".join(r.alternatives[0].transcript for r in resp.results)

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

    system = (
        "당신은 Deskibot(데스키봇)입니다. 음성으로 대화하는 친근한 스마트 데스크 기기입니다. "
        "'데스키봇'은 당신을 부르는 호출어이지 사용자의 이름이 아닙니다. "
        "사용자 말 앞에 '데스키봇'이 붙어 있어도 그건 당신을 부른 것이니, "
        "답변에서 사용자를 '데스키봇'이라고 부르거나 문장 앞에 '데스키봇'을 붙이지 마세요. "
        "('데스키봇 고양이 밥 삭제했어요' ← 이렇게 말하면 안 됩니다. "
        "'고양이 밥 삭제했어요'라고 하세요.) "
        "사용자를 부를 일이 있으면 호칭 없이 말하거나 '사용자님'을 쓰세요. "
        "사용자의 요청에 필요한 도구를 사용해 응답하세요. "
        "답변은 구어체 한국어로 자연스럽게 말하고, 짧은 응원 한 마디를 덧붙여 주세요. "
        "마크다운(**, ##, 목록 기호 등)은 절대 사용하지 마세요 — TTS가 기호를 그대로 읽습니다. "
        "전체 답변은 TTS로 읽었을 때 10초를 넘지 않게 간결하게 유지하세요.\n\n"
        f"오늘 날짜: {today} (현재 시각 {now.strftime('%H:%M')}, 한국 시간)\n"
        f"사용자 카테고리 목록: {cat_list}\n\n"
        "지원하는 할 일 기능은 조회, 추가, 완료 처리, 삭제입니다.\n"
        "'오늘 뭐 해야 해', '할 일 알려줘' 같은 요청은 get_schedule을 사용하세요.\n"
        "get_schedule 결과를 읽을 때는 마감이 지났는지에 따라 말투를 바꾸세요.\n"
        "- 아직 마감 전: '9시까지 알고리즘 과제가 있어요' 처럼 현재형으로\n"
        "- 마감이 이미 지남: '알고리즘 과제는 9시까지였는데 다 하셨나요?' 처럼 "
        "과거형으로 말하고 완료했는지 물어보세요. 지난 일을 남은 일처럼 말하지 마세요.\n"
        "'끝냈어', '완료', '체크', '다했어' 등의 표현은 complete_todo 사용\n"
        "'삭제', '지워줘', '없애줘', '취소' 등의 표현은 delete_todo 사용\n"
        "앞으로 해야 할 일을 이야기하면 add_todo 사용. 예: '나 오늘 영어 숙제 있어',\n"
        "'내일까지 보고서 써야 해', '운동 하기 추가해줘'\n\n"
        "할 일 추가 규칙:\n"
        "- content는 조사와 군더더기를 뺀 짧은 명사구로 만드세요. "
        "'나 오늘 영어 숙제 있어' → '영어 숙제'\n"
        "- category는 위 카테고리 목록 중 content와 가장 잘 맞는 이름을 그대로 쓰세요. "
        "마땅한 게 없으면 '기타'라고 쓰면 됩니다.\n"
        "- date는 언급이 없으면 오늘. '내일', '모레', '다음 주 월요일' 같은 표현은 "
        "오늘 날짜를 기준으로 계산해서 YYYY-MM-DD로 넣으세요.\n"
        "- deadline_time은 사용자가 '오후 9시까지', '3시에' 처럼 구체적인 시각을 "
        "말했을 때만 넣습니다. 언급이 없으면 반드시 null로 두세요. "
        "'오늘 안에', '빨리' 같은 막연한 표현은 시각이 아니므로 null입니다.\n"
        "- notify_before_min은 사용자가 '30분 전에 알려줘'라고 명시했을 때만 30을 넣고, "
        "그 외에는 null로 두세요(마감이 있으면 서버가 1시간 전 알림을 자동으로 켭니다).\n"
        "- 정보가 부족해도 되묻지 말고 들은 내용만으로 바로 추가하세요.\n"
    )

    messages = [{"role": "user", "content": text}]
    cmd_json = json.dumps({"action": "none"})
    mutation_used = False   # complete/delete는 한 요청에 한 번만
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
                if b.name in {"complete_todo", "delete_todo"} and mutation_used:
                    tool_result = "한 요청에서는 할 일을 하나만 변경할 수 있습니다."
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
                        mutation_used = True
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
@app.route("/process", methods=["POST"])
@app.route("/hw/process", methods=["POST"])
def process():
    try:
        user_id = _authenticate_device()
    except Exception:
        print("[PostgreSQL] device 인증 조회 실패", flush=True)
        return "service unavailable", 503
    if not user_id:
        return "unauthorized", 401

    pcm_in = request.data
    if not pcm_in:
        return "no audio", 400

    total_start = time.time()
    print(f"\n{'='*60}", flush=True)
    print(f"[SERVER] 수신: {len(pcm_in):,} bytes", flush=True)

    try:
        transcript = run_stt(pcm_in)
        if not transcript:
            msg  = "음성이 인식되지 않았습니다. 다시 시도해 주세요."
            body = pack_response("", json.dumps({"action": "none"}), run_tts(msg))
            return Response(body, content_type="application/octet-stream")

        cmd_json, tts_text = run_llm(user_id, transcript)
        audio_pcm          = run_tts(tts_text)
        body               = pack_response(transcript, cmd_json, audio_pcm)

        print(f"[SERVER] ✅ {time.time()-total_start:.2f}s | {len(body):,} bytes", flush=True)
        print(f"{'='*60}", flush=True)
        return Response(body, content_type="application/octet-stream")

    except Exception as e:
        import traceback
        print(f"[SERVER] ❌ {e}", flush=True)
        traceback.print_exc()
        return "internal server error", 500


@app.route("/todos", methods=["GET"])
@app.route("/hw/todos", methods=["GET"])
def todos():
    """로봇이 오늘 할 일과 마감 알림 대상을 읽어간다(Firestore 폴링 대체).

    인증된 user_id로만 조회하므로 시리얼 `token` 명령으로 사용자를 바꾸면
    할 일도 함께 바뀐다. 기존 ESP는 FS_USER_ID가 컴파일 상수라 토큰을 바꿔도
    남의 할 일을 계속 보여줄 수 있었다.
    """
    try:
        user_id = _authenticate_device()
    except Exception:
        print("[PostgreSQL] device 인증 조회 실패", flush=True)
        return "service unavailable", 503
    if not user_id:
        return "unauthorized", 401

    today = datetime.now(KST).date()
    try:
        with db_pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT content, deadline_time, notify, notify_before_min
                      FROM todos
                     WHERE user_id = %s
                       AND date = %s
                       AND is_done = false
                     ORDER BY deadline_time NULLS LAST, id
                     LIMIT 20
                    """,
                    (user_id, today),
                )
                rows = cur.fetchall()
    except Exception:
        print("[PostgreSQL] todos 조회 실패", flush=True)
        return "service unavailable", 503

    # ESP 힙이 빠듯하므로 필요한 필드만 담는다. 알림 관련 필드는 notify가 켜져
    # 있고 마감/사전알림이 모두 있는 항목에만 넣는다(ESP가 그 조합만 사용).
    items = []
    for row in rows:
        item = {"content": row["content"]}
        if row["notify"] and row["deadline_time"] is not None \
                and row["notify_before_min"] is not None:
            item["deadline_time"] = row["deadline_time"].strftime("%H:%M")
            item["notify_before_min"] = int(row["notify_before_min"])
        items.append(item)

    print(f"[TODOS] {len(items)}건 응답", flush=True)
    return Response(
        json.dumps({"date": today.isoformat(), "todos": items}, ensure_ascii=False),
        content_type="application/json; charset=utf-8",
    )


@app.route("/health", methods=["GET"])
def health():
    return "ok"


if __name__ == "__main__":
    print(f"[SERVER] Deskibot Voice Pipeline")
    print(f"[SERVER]   STT  : Google Cloud Speech (ko-KR)")
    print(f"[SERVER]   LLM  : Claude {CLAUDE_MODEL} + Tool Use")
    print(f"[SERVER]   TTS  : Google Cloud TTS ({TTS_VOICE})")
    print("[SERVER]   Auth : PostgreSQL devices.token_hash")
    print(f"{'='*60}")
    app.run(host="0.0.0.0", port=8000, debug=False)
