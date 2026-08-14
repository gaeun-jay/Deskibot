"""카테고리 REST 엔드포인트.

    GET    /api/categories
    POST   /api/categories
    PATCH  /api/categories/{category_id}
    DELETE /api/categories/{category_id}
"""

import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from app.auth_api import current_user_id
from app.category_service import (
    CategoryError,
    create_category,
    delete_category,
    list_categories,
    update_category,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/categories", tags=["categories"])

STATUS_BY_CODE = {
    "invalid_name": 400,
    "invalid_color": 400,
    "invalid_field": 400,
    "invalid_category": 400,
    "no_changes": 400,
    "category_not_found": 404,
    "name_taken": 409,
    "category_limit": 409,
    "category_in_use": 409,
}


def _http_error(error: CategoryError) -> HTTPException:
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


class CreateCategoryRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    color: str
    sort_order: int | None = Field(default=None, ge=0)


class UpdateCategoryRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str | None = None
    color: str | None = None
    sort_order: int | None = Field(default=None, ge=0)


@router.get("")
async def get_categories(user_id: UUID = Depends(current_user_id)):
    try:
        return await run_in_threadpool(list_categories, user_id)
    except CategoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected category list error")
        raise _internal()


@router.post("", status_code=201)
async def post_category(
    body: CreateCategoryRequest,
    user_id: UUID = Depends(current_user_id),
):
    try:
        return await run_in_threadpool(
            create_category, user_id, body.name, body.color, body.sort_order
        )
    except CategoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected category create error")
        raise _internal()


@router.patch("/{category_id}")
async def patch_category(
    category_id: UUID,
    body: UpdateCategoryRequest,
    user_id: UUID = Depends(current_user_id),
):
    changes = body.model_dump(include=body.model_fields_set)

    try:
        return await run_in_threadpool(
            update_category, user_id, category_id, changes
        )
    except CategoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected category update error")
        raise _internal()


@router.delete("/{category_id}", status_code=204)
async def remove_category(
    category_id: UUID,
    user_id: UUID = Depends(current_user_id),
):
    try:
        await run_in_threadpool(delete_category, user_id, category_id)
    except CategoryError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected category delete error")
        raise _internal()

    return Response(status_code=204)
