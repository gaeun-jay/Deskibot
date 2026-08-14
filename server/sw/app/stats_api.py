"""통계 REST 엔드포인트.

    GET /api/stats/daily?date=YYYY-MM-DD
    GET /api/stats/range?start=YYYY-MM-DD&end=YYYY-MM-DD

두 엔드포인트 모두 읽기 전에 원천에서 다시 계산해 stats_daily 에 반영한다.
"""

import logging
from datetime import date as date_type
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from starlette.concurrency import run_in_threadpool

from app.auth_api import current_user_id
from app.stats_service import StatsError, get_daily_stats, get_stats_range

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/stats", tags=["stats"])

STATUS_BY_CODE = {
    "invalid_range": 400,
    "range_too_long": 400,
}


def _http_error(error: StatsError) -> HTTPException:
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


@router.get("/daily")
async def daily(
    user_id: UUID = Depends(current_user_id),
    date: date_type | None = Query(default=None),
):
    try:
        return await run_in_threadpool(get_daily_stats, user_id, date)
    except StatsError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected daily stats error")
        raise _internal()


@router.get("/range")
async def date_range(
    user_id: UUID = Depends(current_user_id),
    start: date_type = Query(...),
    end: date_type = Query(...),
):
    try:
        return await run_in_threadpool(get_stats_range, user_id, start, end)
    except StatsError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected stats range error")
        raise _internal()
