"""할 일 REST 엔드포인트.

    GET    /api/todos?date=YYYY-MM-DD    (date 생략 시 KST 오늘)
    POST   /api/todos
    PATCH  /api/todos/{todo_id}
    DELETE /api/todos/{todo_id}

user_id 는 요청 본문이 아니라 Bearer 토큰에서 나온다.
"""

import logging
from datetime import date as date_type, time as time_type
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from app.auth_api import current_user_id
from app.todo_service import (
    TodoError,
    create_todo,
    delete_todo,
    list_todos,
    update_todo,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/todos", tags=["todos"])

STATUS_BY_CODE = {
    "invalid_content": 400,
    "invalid_notify": 400,
    "invalid_field": 400,
    "invalid_todo": 400,
    "no_category": 409,
    "category_not_found": 404,
    "todo_not_found": 404,
}


def _http_error(error: TodoError) -> HTTPException:
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


class CreateTodoRequest(BaseModel):
    # 모르는 필드는 조용히 버리지 말고 거부한다. 앱이 옛 필드명
    # (notify_before 등)을 보냈을 때 무시되는 대신 422로 드러나게 한다.
    model_config = ConfigDict(extra="forbid")

    content: str
    date: date_type | None = None
    category_id: UUID | None = None
    deadline_time: time_type | None = None
    notify: bool = False
    notify_before_min: int | None = Field(default=None, ge=0)


class UpdateTodoRequest(BaseModel):
    """모든 필드가 선택적. 실제로 보낸 것만 반영한다.

    model_fields_set 으로 "안 보냄"과 "명시적 null"을 구분한다.
    """

    model_config = ConfigDict(extra="forbid")

    content: str | None = None
    category_id: UUID | None = None
    date: date_type | None = None
    deadline_time: time_type | None = None
    notify: bool | None = None
    notify_before_min: int | None = Field(default=None, ge=0)
    is_done: bool | None = None


@router.get("")
async def get_todos(
    user_id: UUID = Depends(current_user_id),
    date: date_type | None = Query(default=None),
):
    try:
        return await run_in_threadpool(list_todos, user_id, date)
    except TodoError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected todo list error")
        raise _internal()


@router.post("", status_code=201)
async def post_todo(
    body: CreateTodoRequest,
    user_id: UUID = Depends(current_user_id),
):
    try:
        return await run_in_threadpool(
            create_todo,
            user_id,
            body.content,
            body.date,
            body.category_id,
            body.deadline_time,
            body.notify,
            body.notify_before_min,
        )
    except TodoError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected todo create error")
        raise _internal()


@router.patch("/{todo_id}")
async def patch_todo(
    todo_id: int,
    body: UpdateTodoRequest,
    user_id: UUID = Depends(current_user_id),
):
    # 보내지 않은 필드는 건드리지 않는다.
    changes = body.model_dump(include=body.model_fields_set)

    try:
        return await run_in_threadpool(
            update_todo, user_id, todo_id, changes
        )
    except TodoError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected todo update error")
        raise _internal()


@router.delete("/{todo_id}", status_code=204)
async def remove_todo(
    todo_id: int,
    user_id: UUID = Depends(current_user_id),
):
    try:
        await run_in_threadpool(delete_todo, user_id, todo_id)
    except TodoError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected todo delete error")
        raise _internal()

    return Response(status_code=204)
