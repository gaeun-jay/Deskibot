"""Deskibot HW 음성 서버 — HTTP 계층.

라우트와 요청·응답 변환만 담당한다. STT·Claude·TTS·DB 는 전부
app/voice_service.py 에 있고 이 파일은 그것을 부르기만 한다.

sw 서버와 같은 모양이다 (FastAPI + uvicorn, app/ 패키지, HTTP 층과 로직 층 분리).
프로세스·포트·systemd 유닛은 계속 따로다 — 나중에 hw 를 별도 인스턴스로
옮길 때 코드를 고치지 않기 위해서다.

nginx 가 외부 /hw/ 를 내부 / 로 넘기므로(끝 슬래시) 두 경로를 모두 등록한다.
"""

import json
import time
import traceback
from datetime import datetime

from fastapi import FastAPI, Header, Request
from fastapi.responses import PlainTextResponse, Response
from starlette.concurrency import run_in_threadpool

from app.voice_service import (
    DEBUG_DUMP_AUDIO,
    DUMP_ONLY,
    KST,
    _confirm_beep,
    _dump_pcm,
    authenticate_device,
    db_pool,
    pack_response,
    run_llm,
    run_stt,
    run_tts,
)
from app.audio_codec import ulaw_to_pcm16

app = FastAPI(title="Deskibot HW Voice Server", version="1.0.0")

OCTET = "application/octet-stream"


def _auth(device_key: str | None):
    """인증 결과를 (user_id, 오류응답) 으로 돌려준다.

    DB 가 죽었을 때의 503 과 토큰이 틀렸을 때의 401 을 구분한다. 로봇은 전자면
    잠시 뒤 재시도하고 후자면 토큰을 다시 넣어야 하므로, 같은 코드로 뭉뚱그리면
    현장에서 원인을 못 가린다.
    """
    try:
        user_id = authenticate_device(device_key or "")
    except Exception:
        print("[PostgreSQL] device 인증 조회 실패", flush=True)
        return None, PlainTextResponse("service unavailable", status_code=503)
    if not user_id:
        return None, PlainTextResponse("unauthorized", status_code=401)
    return user_id, None


def _process_audio(user_id, pcm_in: bytes) -> Response:
    """STT → Claude → TTS. 블로킹이라 스레드풀에서 돈다."""
    total_start = time.time()

    if DEBUG_DUMP_AUDIO:
        _dump_pcm(pcm_in)

    if DUMP_ONLY:
        print("[DUMP] 녹음 전용 모드 — STT/LLM/TTS 건너뜀", flush=True)
        return Response(
            content=pack_response(
                "녹음 저장됨", json.dumps({"action": "none"}), _confirm_beep()
            ),
            media_type=OCTET,
        )

    print(f"\n{'='*60}", flush=True)
    print(f"[SERVER] 수신: {len(pcm_in):,} bytes", flush=True)

    try:
        transcript = run_stt(pcm_in)
        if not transcript:
            msg = "음성이 인식되지 않았습니다. 다시 시도해 주세요."
            body = pack_response("", json.dumps({"action": "none"}), run_tts(msg))
            return Response(
                content=body,
                media_type=OCTET,
                headers={"X-Server-Time": f"{time.time()-total_start:.3f}"},
            )

        t_stt = time.time() - total_start
        cmd_json, tts_text = run_llm(user_id, transcript)
        t_llm = time.time() - total_start - t_stt
        audio_pcm = run_tts(tts_text)
        body = pack_response(transcript, cmd_json, audio_pcm)
        elapsed = time.time() - total_start

        print(f"[SERVER] ✅ {elapsed:.2f}s | {len(body):,} bytes", flush=True)
        print(f"{'='*60}", flush=True)
        # 기기가 '왕복 총시간 − 서버 처리시간 = 네트워크 시간'을 계산할 수 있게
        # 단계별 소요를 헤더로 실어 보낸다. 본문 형식은 건드리지 않는다.
        return Response(
            content=body,
            media_type=OCTET,
            headers={
                "X-Server-Time": f"{elapsed:.3f}",
                "X-Stage-Times": f"stt={t_stt:.3f},llm={t_llm:.3f},"
                                 f"tts={elapsed - t_stt - t_llm:.3f}",
            },
        )
    except Exception as e:
        print(f"[SERVER] ❌ {e}", flush=True)
        traceback.print_exc()
        return PlainTextResponse("internal server error", status_code=500)


@app.post("/process")
@app.post("/hw/process")
async def process(
    request: Request,
    x_device_key: str | None = Header(None),
    x_audio_encoding: str | None = Header(None),
):
    user_id, err = _auth(x_device_key)
    if err:
        return err

    raw = await request.body()
    if not raw:
        return PlainTextResponse("no audio", status_code=400)

    # 기기가 업로드를 절반으로 줄이려고 µ-law로 보낼 수 있다. 헤더가 없으면
    # 기존처럼 16-bit PCM으로 취급하므로 구형 펌웨어와 그대로 호환된다.
    # 이후 파이프라인(덤프·STT)은 항상 PCM16만 본다.
    encoding = (x_audio_encoding or "pcm16").lower()
    if encoding == "mulaw":
        pcm_in = ulaw_to_pcm16(raw)
        print(f"[SERVER] µ-law {len(raw):,} bytes → PCM {len(pcm_in):,} bytes", flush=True)
    elif encoding == "pcm16":
        pcm_in = raw
    else:
        print(f"[SERVER] ❌ 알 수 없는 인코딩: {encoding}", flush=True)
        return PlainTextResponse("unsupported audio encoding", status_code=400)

    return await run_in_threadpool(_process_audio, user_id, pcm_in)


def _fetch_todos(user_id):
    today = datetime.now(KST).date()
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
    return today, items


@app.get("/todos")
@app.get("/hw/todos")
async def todos(x_device_key: str | None = Header(None)):
    """로봇이 오늘 할 일과 마감 알림 대상을 읽어간다.

    인증된 user_id로만 조회하므로 시리얼 `token` 명령으로 사용자를 바꾸면
    할 일도 함께 바뀐다.
    """
    user_id, err = _auth(x_device_key)
    if err:
        return err

    try:
        today, items = await run_in_threadpool(_fetch_todos, user_id)
    except Exception:
        print("[PostgreSQL] todos 조회 실패", flush=True)
        return PlainTextResponse("service unavailable", status_code=503)

    print(f"[TODOS] {len(items)}건 응답", flush=True)
    return Response(
        content=json.dumps(
            {"date": today.isoformat(), "todos": items}, ensure_ascii=False
        ),
        media_type="application/json; charset=utf-8",
    )


@app.get("/health", response_class=PlainTextResponse)
@app.get("/hw/health", response_class=PlainTextResponse)
def health():
    return "ok"
