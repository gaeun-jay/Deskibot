"""집중 세션 조회 REST 엔드포인트.

    GET   /api/focus-sessions?date=YYYY-MM-DD
    GET   /api/focus-sessions/{session_id}
    PATCH /api/focus-sessions/{session_id}    (제목만)

세션 시작·일시정지·종료는 /ws/focus WebSocket 이 담당한다. 여기는 조회 전용.
"""

import logging
from datetime import date as date_type
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict
from starlette.concurrency import run_in_threadpool

from app.auth_api import current_user_id
from app.focus_history_service import (
    FocusHistoryError,
    get_session,
    list_sessions,
    update_session_title,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/focus-sessions", tags=["focus-sessions"])

STATUS_BY_CODE = {"session_not_found": 404}


def _http_error(error: FocusHistoryError) -> HTTPException:
    return HTTPException(
        status_code=STATUS_BY_CODE.get(error.code, 400),
        detail={"code": error.code, "message": error.message},
    )


def _internal() -> HTTPException:
    return HTTPException(
        status_code=500,
        detail={
            "code": "internal_error",
            "message": "an internal server error occurred",
        },
    )


class UpdateSessionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None


@router.get("")
async def get_sessions(
    user_id: UUID = Depends(current_user_id),
    date: date_type | None = Query(default=None),
):
    try:
        return await run_in_threadpool(list_sessions, user_id, date)
    except FocusHistoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected focus session list error")
        raise _internal()


@router.get("/{session_id}")
async def get_one_session(
    session_id: UUID,
    user_id: UUID = Depends(current_user_id),
):
    try:
        return await run_in_threadpool(get_session, user_id, session_id)
    except FocusHistoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected focus session fetch error")
        raise _internal()


@router.patch("/{session_id}")
async def patch_session(
    session_id: UUID,
    body: UpdateSessionRequest,
    user_id: UUID = Depends(current_user_id),
):
    try:
        return await run_in_threadpool(
            update_session_title, user_id, session_id, body.title
        )
    except FocusHistoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected focus session update error")
        raise _internal()
