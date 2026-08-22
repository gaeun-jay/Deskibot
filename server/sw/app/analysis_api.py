"""분석 REST 엔드포인트.

일간
    GET  /api/analysis/daily?date=YYYY-MM-DD
    POST /api/analysis/daily/generate?date=YYYY-MM-DD

누적 (기존 Node 서버 /analyze/* 를 대체)
    POST /api/analysis/cumulative/{period_type}
    GET  /api/analysis/cumulative/{period_type}/latest

    weekly | monthly | quarterly | half_yearly | yearly
    (Node 의 '6monthly' 는 스키마 CHECK 에 맞춰 'half_yearly' 로 바뀌었다)

user_id 는 요청 본문이 아니라 Bearer 토큰에서 나온다.
"""

import logging
from datetime import date as date_type
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from starlette.concurrency import run_in_threadpool

from app.analysis_service import (
    AnalysisError,
    generate_cumulative_analysis,
    get_latest_cumulative_analysis,
)
from app.auth_api import current_user_id
from app.daily_analysis_service import (
    generate_daily_analysis,
    get_daily_analysis,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/analysis", tags=["analysis"])

# 클라이언트 잘못 → 4xx, 모델·외부 문제 → 502, 서버 설정 → 500
STATUS_BY_CODE = {
    "invalid_user_id": 400,
    "invalid_period_type": 400,
    "user_not_found": 404,
    "analysis_not_found": 404,
    "no_data": 409,
    # 그 기간을 통째로 겪지 않은 유저 (첫 일간 분석이 기간 시작보다 늦다)
    "period_not_covered": 409,
    "missing_api_key": 500,
    # 모델 쪽 문제는 502 로 (클라이언트가 고칠 수 있는 게 아니다)
    "model_request_invalid": 502,
    "model_auth_failed": 502,
    "model_rate_limited": 503,
    "model_unavailable": 502,
}


def _http_error(error: AnalysisError) -> HTTPException:
    if error.code == "missing_api_key":
        logger.error("ANTHROPIC_API_KEY is not configured")
        return HTTPException(
            status_code=500,
            detail={
                "code": "server_misconfigured",
                "message": "an internal server error occurred",
            },
        )

    return HTTPException(
        status_code=STATUS_BY_CODE.get(error.code, 502),
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


# ─── 일간 ────────────────────────────────────────────────────────────────────

@router.get("/daily")
async def daily(
    user_id: UUID = Depends(current_user_id),
    date: date_type | None = Query(default=None),
):
    try:
        result = await run_in_threadpool(get_daily_analysis, str(user_id), date)
    except AnalysisError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected daily analysis fetch error")
        raise _internal()

    if result is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "analysis_not_found",
                "message": "no analysis has been generated for this date",
            },
        )

    return result


@router.post("/daily/generate")
async def generate_daily(
    user_id: UUID = Depends(current_user_id),
    date: date_type | None = Query(default=None),
):
    try:
        return await run_in_threadpool(
            generate_daily_analysis, str(user_id), date
        )
    except AnalysisError as error:
        raise _http_error(error)
    except Exception:
        logger.exception("Unexpected daily analysis generate error")
        raise _internal()


# ─── 누적 ────────────────────────────────────────────────────────────────────

@router.post("/cumulative/{period_type}")
async def generate_cumulative(
    period_type: str,
    user_id: UUID = Depends(current_user_id),
):
    try:
        return await run_in_threadpool(
            generate_cumulative_analysis, str(user_id), period_type
        )
    except AnalysisError as error:
        raise _http_error(error)
    except Exception:
        logger.exception(
            "Unexpected cumulative analysis error: %s", period_type
        )
        raise _internal()


@router.get("/cumulative/{period_type}/latest")
async def latest_cumulative(
    period_type: str,
    user_id: UUID = Depends(current_user_id),
):
    try:
        analysis = await run_in_threadpool(
            get_latest_cumulative_analysis, str(user_id), period_type
        )
    except AnalysisError as error:
        raise _http_error(error)
    except Exception:
        logger.exception(
            "Unexpected cumulative analysis lookup error: %s", period_type
        )
        raise _internal()

    if analysis is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "analysis_not_found",
                "message": "no analysis has been generated yet",
            },
        )

    return analysis
