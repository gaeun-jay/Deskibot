import asyncio
import hmac
import logging
import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import PlainTextResponse
from starlette.concurrency import run_in_threadpool

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")
# 로컬 개발용 덮어쓰기. 서버에는 이 파일이 없으므로 아무 일도 하지 않는다.
load_dotenv(BASE_DIR / ".env.local", override=True)

from app.analysis_api import router as analysis_router
from app.auth_api import router as auth_router
from app.auth_service import AuthError, verify_token
from app.category_api import router as category_router
from app.focus_history_api import router as focus_history_router
from app.stats_api import router as stats_router
from app.todo_api import router as todo_router
from app.db import check_database
from app.device_service import authenticate_device
from app.focus_service import (
    FocusCommandError,
    end_focus_session,
    get_active_focus_session,
    pause_focus_session,
    resume_focus_session,
    start_focus_session,
)
from app.event_service import (
    end_detection_event,
    start_detection_event,
)
from app.realtime import manager

logger = logging.getLogger(__name__)

app = FastAPI(
    title="Deskibot SW API",
    version="1.0.0",
)

app.include_router(auth_router)
app.include_router(category_router)
app.include_router(todo_router)
app.include_router(focus_history_router)
app.include_router(stats_router)
app.include_router(analysis_router)


@app.get("/api/health", response_class=PlainTextResponse)
def health():
    try:
        if not check_database():
            return PlainTextResponse(
                "database unavailable",
                status_code=503,
            )
    except Exception:
        return PlainTextResponse(
            "database unavailable",
            status_code=503,
        )

    return "ok"


async def process_focus_command(
    websocket: WebSocket,
    user_id: str,
    source: str,
    message: dict,
):
    message_type = message.get("type")

    try:
        if message_type == "detection_start":
            if source != "robot":
                raise FocusCommandError(
                    "robot_only",
                    "detection events can be sent only by a robot",
                )

            event = await run_in_threadpool(
                start_detection_event,
                user_id,
                message.get("kind"),
            )

            await manager.broadcast(
                user_id,
                {
                    "type": "detection_event",
                    "action": "detection_start",
                    "changed_by": source,
                    "event": event,
                },
            )
            return

        elif message_type == "detection_end":
            if source != "robot":
                raise FocusCommandError(
                    "robot_only",
                    "detection events can be sent only by a robot",
                )

            event = await run_in_threadpool(
                end_detection_event,
                user_id,
                message.get("kind"),
            )

            await manager.broadcast(
                user_id,
                {
                    "type": "detection_event",
                    "action": "detection_end",
                    "changed_by": source,
                    "event": event,
                },
            )
            return

        elif message_type == "focus_start":
            session = await run_in_threadpool(
                start_focus_session,
                user_id,
                source,
                message.get("mode"),
                message.get("planned_duration_sec"),
                message.get("title"),
            )

        elif message_type == "focus_pause":
            session = await run_in_threadpool(
                pause_focus_session,
                user_id,
                source,
                message.get("session_id"),
                message.get("revision"),
            )

        elif message_type == "focus_resume":
            session = await run_in_threadpool(
                resume_focus_session,
                user_id,
                source,
                message.get("session_id"),
                message.get("revision"),
            )

        elif message_type == "focus_end":
            session = await run_in_threadpool(
                end_focus_session,
                user_id,
                source,
                message.get("session_id"),
                message.get("revision"),
                message.get("outcome", "completed"),
            )

        else:
            await websocket.send_json(
                {
                    "type": "error",
                    "code": "unsupported_message",
                    "message": "unsupported message type",
                }
            )
            return

        await manager.broadcast(
            user_id,
            {
                "type": "focus_state",
                "action": message_type,
                "changed_by": source,
                "session": session,
            },
        )

    except FocusCommandError as error:
        await websocket.send_json(
            {
                "type": "error",
                "command": message_type,
                "code": error.code,
                "message": error.message,
            }
        )

    except Exception:
        logger.exception(
            "Unexpected focus command error: %s",
            message_type,
        )

        await websocket.send_json(
            {
                "type": "error",
                "command": message_type,
                "code": "internal_error",
                "message": "an internal server error occurred",
            }
        )


@app.websocket("/ws/focus")
async def focus_websocket(websocket: WebSocket):
    await websocket.accept()

    user_id = None
    source = None
    connected = False

    try:
        auth_message = await asyncio.wait_for(
            websocket.receive_json(),
            timeout=10,
        )

        if auth_message.get("type") != "auth":
            await websocket.close(
                code=4401,
                reason="authentication required",
            )
            return

        provided_token = str(auth_message.get("token", ""))
        source = str(auth_message.get("source", ""))
        device_uid = None

        if source not in {"app", "robot"}:
            await websocket.close(
                code=4400,
                reason="invalid source",
            )
            return

        if source == "app":
            # 로그인 토큰(JWT)으로 실제 사용자를 식별한다.
            try:
                user_id = str(verify_token(provided_token))
            except AuthError:
                user_id = None

            # 전환 기간용 뒷문. 예전 테스트 스크립트가 쓰던 고정 문자열
            # 방식으로, 모든 접속이 TEST_USER_ID 한 사람으로 잡힌다.
            # .env 에서 WS_TEST_TOKEN 을 지우면 이 경로는 닫힌다.
            if user_id is None:
                legacy_token = os.environ.get("WS_TEST_TOKEN", "")
                test_user_id = os.environ.get("TEST_USER_ID", "")

                if (
                    legacy_token
                    and test_user_id
                    and hmac.compare_digest(provided_token, legacy_token)
                ):
                    logger.warning(
                        "WS 접속이 WS_TEST_TOKEN 으로 인증됨 "
                        "(전환 기간용, JWT 로 옮길 것)"
                    )
                    user_id = test_user_id

            if user_id is None:
                await websocket.close(
                    code=4401,
                    reason="invalid app token",
                )
                return

        else:
            device = await run_in_threadpool(
                authenticate_device,
                provided_token,
            )

            if device is None:
                await websocket.close(
                    code=4401,
                    reason="invalid robot token",
                )
                return

            user_id = device["user_id"]
            device_uid = device["device_uid"]
        await manager.connect(user_id, websocket)
        connected = True

        auth_response = {
            "type": "auth_ok",
            "source": source,
            "user_id": user_id,
        }

        if device_uid is not None:
            auth_response["device_uid"] = device_uid

        await websocket.send_json(auth_response)

        active_session = await run_in_threadpool(
            get_active_focus_session,
            user_id,
        )

        await websocket.send_json(
            {
                "type": "focus_state",
                "session": active_session,
            }
        )

        await manager.broadcast(
            user_id,
            {
                "type": "presence",
                "source": source,
                "status": "connected",
            },
            exclude=websocket,
        )

        while True:
            message = await websocket.receive_json()

            if message.get("type") == "ping":
                await websocket.send_json(
                    {
                        "type": "pong",
                    }
                )
                continue

            await process_focus_command(
                websocket,
                user_id,
                source,
                message,
            )

    except asyncio.TimeoutError:
        await websocket.close(
            code=4401,
            reason="authentication timeout",
        )

    except WebSocketDisconnect:
        pass

    finally:
        if connected and user_id:
            manager.disconnect(user_id, websocket)

            await manager.broadcast(
                user_id,
                {
                    "type": "presence",
                    "source": source,
                    "status": "disconnected",
                },
            )