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
    today = datetime.now(KST).date()
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

    max_spoken = 4
    spoken = []
    for row in rows[:max_spoken]:
        item = row["content"]
        if row["deadline_time"] is not None:
            item += f" {row['deadline_time'].strftime('%H시 %M분')}까지"
        spoken.append(item)
    result = "오늘 할 일은 " + ", ".join(spoken)
    if len(rows) > max_spoken:
        result += f", 그 외 {len(rows) - max_spoken}개"
    return result + "입니다."


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

    today = datetime.now(KST).strftime("%Y-%m-%d")

    system = (
        "당신은 Deskibot입니다. 음성으로 대화하는 친근한 스마트 데스크 기기입니다. "
        "사용자의 요청에 필요한 도구를 사용해 응답하세요. "
        "답변은 구어체 한국어로 자연스럽게 말하고, 짧은 응원 한 마디를 덧붙여 주세요. "
        "마크다운(**, ##, 목록 기호 등)은 절대 사용하지 마세요 — TTS가 기호를 그대로 읽습니다. "
        "전체 답변은 TTS로 읽었을 때 10초를 넘지 않게 간결하게 유지하세요.\n\n"
        f"오늘 날짜: {today}\n\n"
        "지원하는 할 일 기능은 오늘 일정 조회, 완료 처리, 삭제뿐입니다.\n"
        "'오늘 뭐 해야 해', '할 일 알려줘' 같은 요청은 get_schedule을 사용하세요.\n"
        "'끝냈어', '완료', '체크', '다했어' 등의 표현은 complete_todo 사용\n"
        "'삭제', '지워줘', '없애줘', '취소' 등의 표현은 delete_todo 사용\n"
        "할 일 추가, 수정, 알림 설정 요청은 현재 지원하지 않는다고 짧게 안내하세요.\n"
    )

    messages = [{"role": "user", "content": text}]
    cmd_json = json.dumps({"action": "none"})
    mutation_used = False

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
                else:
                    tool_result, tool_cmd = _run_tool(
                        user_id, b.name, b.input if isinstance(b.input, dict) else {}
                    )
                    if b.name in {"complete_todo", "delete_todo"}:
                        mutation_used = True
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
