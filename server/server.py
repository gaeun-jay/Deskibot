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
        {"action":"add_todo","done":true}
        {"action":"ask_todo_details","content":"...","date":"..."}
        {"action":"complete_todo","done":true,"content":"..."}
  [...]  PCM 오디오 (16-bit mono, 16 kHz, little-endian)
"""

import struct, time, os, json
from datetime import datetime, timezone, timedelta
from flask import Flask, request, Response
from dotenv import load_dotenv

load_dotenv()

from google.cloud import speech
from google.cloud import texttospeech
from google.api_core.client_options import ClientOptions
import anthropic
import firebase_admin
from firebase_admin import credentials, firestore

app    = Flask(__name__)
claude = anthropic.Anthropic()

# ─── 설정 ─────────────────────────────────────────────────────────────────────
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY", "")
FIREBASE_KEY   = os.environ.get("FIREBASE_KEY_PATH", "")
FS_USER_ID     = os.environ.get("FS_USER_ID", "")

SAMPLE_RATE  = 16000
CLAUDE_MODEL = "claude-haiku-4-5-20251001"
TTS_VOICE    = "ko-KR-Neural2-A"
KST          = timezone(timedelta(hours=9))

# ─── 클라이언트 싱글톤 ────────────────────────────────────────────────────────
_google_opts = ClientOptions(api_key=GOOGLE_API_KEY)
_stt_client  = speech.SpeechClient(client_options=_google_opts)
_tts_client  = texttospeech.TextToSpeechClient(client_options=_google_opts)

_key_path = os.path.join(os.path.dirname(__file__), FIREBASE_KEY)
cred = credentials.Certificate(_key_path)
firebase_admin.initialize_app(cred)
fs_client = firestore.client()
print("[Firebase] ✅ Firestore 연결 완료", flush=True)

# ─── Firestore 헬퍼 ───────────────────────────────────────────────────────────
def _user_ref():
    return fs_client.collection("users").document(FS_USER_ID)

def _get_user_data() -> dict:
    return _user_ref().get().to_dict() or {}

def _get_categories() -> list:
    return _get_user_data().get("settings", {}).get("categories", [])

def _find_todo_by_hint(todos: dict, hint: str) -> str | None:
    """미완료 todo 중 hint와 가장 유사한 항목의 ID 반환"""
    best_id, best_score = None, 0
    for tid, t in todos.items():
        if t.get("is_done", False):
            continue
        content = t.get("content", "")
        # 포함 관계 우선
        if hint in content or content in hint:
            score = min(len(hint), len(content))
            if score > best_score:
                best_score, best_id = score, tid
        # 문자 겹침 (포함 관계 없을 때 fallback)
        else:
            overlap = sum(1 for c in hint if c in content)
            if overlap > best_score and overlap >= len(hint) * 0.5:
                best_score, best_id = overlap, tid
    return best_id

def firebase_get_schedule() -> str:
    data  = _get_user_data()
    today = datetime.now(KST).strftime("%Y-%m-%d")
    todos = data.get("todos", {})
    today_items = [t["content"] for t in todos.values()
                   if t.get("date") == today and not t.get("is_done", False)]
    if not today_items:
        return "오늘 할 일이 없습니다."
    return "오늘 할 일: " + ", ".join(today_items)

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
            "새 할 일을 Firestore에 추가합니다. "
            "날짜·시간·알림 정보를 충분히 파악했을 때만 사용하세요. "
            "시간/알림 정보가 없으면 ask_todo_details를 먼저 사용하세요."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content":       {"type": "string",           "description": "할 일 내용"},
                "category_id":   {"type": "string",           "description": "카테고리 ID (카테고리 목록 참조)"},
                "date":          {"type": "string",           "description": "날짜 YYYY-MM-DD"},
                "start_time":    {"type": ["string", "null"], "description": "시작 시각 HH:mm"},
                "end_time":      {"type": ["string", "null"], "description": "종료 시각 HH:mm"},
                "notify":        {"type": "boolean",          "description": "알림 여부"},
                "deadline_time": {"type": ["string", "null"], "description": "마감 시각 HH:mm. start_time이 있으면 end_time과 동일하게."},
                "notify_before": {
                    "type": ["integer", "null"],
                    "description": (
                        "마감 N분 전에 알림. "
                        "30분 전 = 30, "
                        "당일 아침 9시 = (deadline_time의 HH×60 + MM) - 540"
                    ),
                },
            },
            "required": ["content", "category_id", "date"],
        },
    },
    {
        "name": "ask_todo_details",
        "description": (
            "사용자가 할 일 이름만 말하고 시작/종료 시간·알림을 말하지 않았을 때 사용합니다. "
            "ESP가 역질문을 하도록 신호를 보냅니다."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content": {"type": "string", "description": "파악된 할 일 내용"},
                "date":    {"type": "string", "description": "파악된 날짜 YYYY-MM-DD"},
            },
            "required": ["content", "date"],
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
def _run_tool(name: str, args: dict) -> tuple[str, str]:
    """Returns (tool_result_for_claude, cmd_json_for_esp)"""

    if name == "get_schedule":
        return firebase_get_schedule(), json.dumps({"action": "none"})

    elif name == "add_todo":
        todo_id  = f"todo_{int(time.time())}"
        end_time = args.get("end_time")
        deadline = args.get("deadline_time") or end_time  # start_time 있으면 end_time과 동일
        todo_data = {
            "content":       args.get("content", ""),
            "category_id":   args.get("category_id", "cat_01"),
            "date":          args.get("date", datetime.now(KST).strftime("%Y-%m-%d")),
            "start_time":    args.get("start_time"),
            "end_time":      end_time,
            "notify":        bool(args.get("notify", False)),
            "deadline_time": deadline or "",
            "notify_before": args.get("notify_before"),
            "is_done":       False,
        }
        _user_ref().update({f"todos.{todo_id}": todo_data})
        print(f"[Firestore] ✅ todo 추가: {todo_data['content']}", flush=True)
        return (
            f"'{todo_data['content']}' 추가 완료",
            json.dumps({"action": "add_todo", "done": True}),
        )

    elif name == "ask_todo_details":
        content = args.get("content", "")
        date    = args.get("date", "")
        return (
            "역질문 대기",
            json.dumps({"action": "ask_todo_details", "content": content, "date": date}),
        )

    elif name == "complete_todo":
        hint  = args.get("content_hint", "")
        todos = _get_user_data().get("todos", {})
        tid   = _find_todo_by_hint(todos, hint)
        if tid:
            _user_ref().update({f"todos.{tid}.is_done": True})
            done_content = todos[tid].get("content", hint)
            print(f"[Firestore] ✅ todo 완료: {done_content}", flush=True)
            return (
                f"'{done_content}' 완료 처리",
                json.dumps({"action": "complete_todo", "done": True, "content": done_content}),
            )
        else:
            print(f"[Firestore] ⚠️ todo 찾지 못함: '{hint}'", flush=True)
            return (
                f"'{hint}' 할 일을 찾지 못했습니다.",
                json.dumps({"action": "complete_todo", "done": False}),
            )

    elif name == "delete_todo":
        hint  = args.get("content_hint", "")
        todos = _get_user_data().get("todos", {})
        tid   = _find_todo_by_hint(todos, hint)
        if tid:
            del_content = todos[tid].get("content", hint)
            _user_ref().update({f"todos.{tid}": firestore.DELETE_FIELD})
            print(f"[Firestore] 🗑️ todo 삭제: {del_content}", flush=True)
            return (
                f"'{del_content}' 삭제 완료",
                json.dumps({"action": "delete_todo", "done": True, "content": del_content}),
            )
        else:
            print(f"[Firestore] ⚠️ todo 찾지 못함: '{hint}'", flush=True)
            return (
                f"'{hint}' 할 일을 찾지 못했습니다.",
                json.dumps({"action": "delete_todo", "done": False}),
            )

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
def run_llm(text: str, pending_content: str = "", pending_date: str = "") -> tuple[str, str]:
    """Returns (cmd_json, tts_text)"""
    print(f"[LLM] 입력: \"{text}\"", flush=True)
    t0 = time.time()

    categories = _get_categories()
    today      = datetime.now(KST).strftime("%Y-%m-%d")
    cat_list   = ", ".join(f"{c['id']}={c['name']}" for c in categories) if categories else "없음"

    system = (
        "당신은 Deskibot입니다. 음성으로 대화하는 친근한 스마트 데스크 기기입니다. "
        "사용자의 요청에 필요한 도구를 사용해 응답하세요. "
        "답변은 구어체 한국어로 자연스럽게 말하고, 짧은 응원 한 마디를 덧붙여 주세요. "
        "마크다운(**, ##, 목록 기호 등)은 절대 사용하지 마세요 — TTS가 기호를 그대로 읽습니다. "
        "전체 답변은 TTS로 읽었을 때 10초를 넘지 않게 간결하게 유지하세요.\n\n"
        f"오늘 날짜: {today}\n"
        f"카테고리 목록: {cat_list}\n\n"
        "할 일 추가 규칙:\n"
        "- 날짜 미지정 시 오늘로 설정\n"
        "- category_id는 카테고리 목록에서 content와 가장 유사한 것 선택. 없으면 첫 번째 ID 사용\n"
        "- start_time이 있으면 deadline_time = end_time으로 설정\n"
        "- start_time이 없으면 사용자가 말한 마감 시각을 deadline_time으로 설정\n"
        "- notify_before: 30분 전 알림이면 30, 당일 아침 9시 알림이면 (deadline HH×60+MM - 540)\n"
        "- 시간/알림 정보가 없으면 반드시 ask_todo_details 사용\n"
        "'끝냈어', '완료', '체크', '다했어' 등의 표현은 complete_todo 사용\n"
        "'삭제', '지워줘', '없애줘', '취소' 등의 표현은 delete_todo 사용\n"
    )

    if pending_content and pending_date:
        system += (
            f"\n현재 추가 대기 중인 할 일: '{pending_content}' (날짜: {pending_date}). "
            "사용자가 시간/알림을 말하면 해당 정보를 포함해 add_todo를 호출하세요. "
            "'필요없어', '그냥 넣어줘' 등이면 시간·알림 없이 add_todo를 호출하세요."
        )

    messages = [{"role": "user", "content": text}]
    cmd_json = json.dumps({"action": "none"})

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
                print(f"[LLM] 🔧 {b.name}({b.input})", flush=True)
                tool_result, tool_cmd = _run_tool(b.name, b.input if isinstance(b.input, dict) else {})
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
def process():
    pcm_in = request.data
    if not pcm_in:
        return "no audio", 400

    # 역질문 후 follow-up 컨텍스트 (ESP가 헤더로 전달)
    pending_content = request.headers.get("X-Pending-Content", "")
    pending_date    = request.headers.get("X-Pending-Date", "")

    total_start = time.time()
    print(f"\n{'='*60}", flush=True)
    print(f"[SERVER] 수신: {len(pcm_in):,} bytes | pending={pending_content or '없음'}", flush=True)

    try:
        transcript = run_stt(pcm_in)
        if not transcript:
            msg  = "음성이 인식되지 않았습니다. 다시 시도해 주세요."
            body = pack_response("", json.dumps({"action": "none"}), run_tts(msg))
            return Response(body, content_type="application/octet-stream")

        cmd_json, tts_text = run_llm(transcript, pending_content, pending_date)
        audio_pcm          = run_tts(tts_text)
        body               = pack_response(transcript, cmd_json, audio_pcm)

        print(f"[SERVER] ✅ {time.time()-total_start:.2f}s | {len(body):,} bytes", flush=True)
        print(f"{'='*60}", flush=True)
        return Response(body, content_type="application/octet-stream")

    except Exception as e:
        import traceback
        print(f"[SERVER] ❌ {e}", flush=True)
        traceback.print_exc()
        return str(e), 500


@app.route("/health", methods=["GET"])
def health():
    return "ok"


if __name__ == "__main__":
    print(f"[SERVER] Deskibot Voice Pipeline")
    print(f"[SERVER]   STT  : Google Cloud Speech (ko-KR)")
    print(f"[SERVER]   LLM  : Claude {CLAUDE_MODEL} + Tool Use")
    print(f"[SERVER]   TTS  : Google Cloud TTS ({TTS_VOICE})")
    print(f"[SERVER]   User : {FS_USER_ID}")
    print(f"{'='*60}")
    app.run(host="0.0.0.0", port=8000, debug=False)
