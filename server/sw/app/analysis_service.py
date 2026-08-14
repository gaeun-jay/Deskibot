"""누적 분석(주간/월간/분기/반기/연간) 생성 및 조회.

기존 Node 서버(server/src/firestore.js + analyze.js)의 포팅.
Firestore 문서 조회를 PostgreSQL 범위 쿼리로, Claude 응답의 정규식 JSON 파싱을
structured outputs로 대체했다.
"""

import json
import os
from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

import anthropic
from psycopg.types.json import Json

from app.db import get_db_connection
from app.stats_service import rebuild_active_dates
from app.prompt import (
    build_half_yearly_prompt,
    build_monthly_prompt,
    build_quarterly_prompt,
    build_weekly_prompt,
    build_yearly_prompt,
)


KST = ZoneInfo("Asia/Seoul")

# period_type은 analysis_cumulative의 CHECK 제약과 일치해야 한다.
# ('6monthly'가 아니라 'half_yearly')
PERIOD_SPECS = {
    "weekly": (7, build_weekly_prompt),
    "monthly": (30, build_monthly_prompt),
    "quarterly": (90, build_quarterly_prompt),
    "half_yearly": (180, build_half_yearly_prompt),
    "yearly": (365, build_yearly_prompt),
}

MAX_PATTERNS = 3
MAX_ROUTINE = 3

DEFAULT_MODEL = "claude-opus-5"

# effort 파라미터를 받지 않는 모델들. CLAUDE_MODEL 로 이런 모델을 지정하면
# effort 를 빼고 보낸다. 넣어서 보내면 400 "does not support the effort
# parameter" 로 실패한다.
EFFORT_UNSUPPORTED = ("haiku-4-5", "sonnet-4-5", "claude-3")


def resolve_model() -> str:
    return os.environ.get("CLAUDE_MODEL") or DEFAULT_MODEL


def build_output_config(schema: dict, effort: str) -> dict:
    """모델이 받아주는 형태로 output_config 를 만든다."""
    config = {"format": {"type": "json_schema", "schema": schema}}
    model = resolve_model()

    if not any(token in model for token in EFFORT_UNSUPPORTED):
        config["effort"] = effort

    return config


def to_analysis_error(error: Exception) -> "AnalysisError":
    """Anthropic SDK 예외를 원인이 보이는 AnalysisError 로 바꾼다.

    이게 없으면 모델·파라미터 조합이 안 맞을 때 그냥 500 internal_error 가
    나서 로그를 뒤져야만 원인을 알 수 있다.
    """
    status = getattr(error, "status_code", None)
    message = str(getattr(error, "message", "") or error)

    if status == 401:
        return AnalysisError("model_auth_failed", "the Anthropic API key was rejected")
    if status == 429:
        return AnalysisError("model_rate_limited", "the Anthropic API is rate limiting")
    if status == 400:
        return AnalysisError("model_request_invalid", message)

    return AnalysisError("model_unavailable", message)

ANALYSIS_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {
            "type": "string",
            "description": "사용자의 핵심 취약점을 한 문장으로 요약",
        },
        "patterns": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "enum": ["focus", "distraction", "todo"],
                    },
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["type", "title", "body"],
                "additionalProperties": False,
            },
        },
        "routine": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "time": {
                        "type": "string",
                        "description": "HH:MM 형식",
                    },
                    "label": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["time", "label", "body"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["summary", "patterns", "routine"],
    "additionalProperties": False,
}


class AnalysisError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


_client = None


def _anthropic_client():
    global _client

    if _client is None:
        if not os.environ.get("ANTHROPIC_API_KEY"):
            raise AnalysisError(
                "missing_api_key",
                "ANTHROPIC_API_KEY is not configured",
            )

        _client = anthropic.Anthropic(timeout=120.0)

    return _client


def _to_minutes(seconds) -> int:
    return round((seconds or 0) / 60)


def _today_kst() -> date:
    return datetime.now(KST).date()


def resolve_period(period_type: str):
    spec = PERIOD_SPECS.get(period_type)

    if spec is None:
        raise AnalysisError(
            "invalid_period_type",
            "period_type must be one of: "
            + ", ".join(PERIOD_SPECS),
        )

    days, build_prompt = spec
    period_end = _today_kst()
    period_start = period_end - timedelta(days=days - 1)

    return period_start, period_end, build_prompt


# ─── 데이터 조회 ──────────────────────────────────────────────────────────────

def fetch_daily_data(user_id: UUID, period_start: date, period_end: date):
    """기간 내 일자별 통계/시간대/당일 조언을 한 번에 읽어 날짜순으로 정렬한다."""

    with get_db_connection() as conn:
        # stats_daily 는 파생 테이블이라 원천과 어긋나 있을 수 있다.
        # 활동이 있었던 날만 골라 먼저 다시 계산한다.
        rebuild_active_dates(conn, user_id, period_start, period_end)

        stats_rows = conn.execute(
            """
            SELECT
                date,
                pomodoro_duration_sec,
                stopwatch_duration_sec,
                drowsy_count,
                drowsy_duration_sec,
                phone_count,
                phone_duration_sec,
                todo_total,
                todo_done
            FROM stats_daily
            WHERE
                user_id = %s
                AND date BETWEEN %s AND %s
            """,
            (user_id, period_start, period_end),
        ).fetchall()

        slot_rows = conn.execute(
            """
            SELECT
                date,
                slot,
                focus_duration_sec,
                drowsy_count,
                phone_count
            FROM stats_daily_timeslot
            WHERE
                user_id = %s
                AND date BETWEEN %s AND %s
            """,
            (user_id, period_start, period_end),
        ).fetchall()

        advice_rows = conn.execute(
            """
            SELECT date, advice
            FROM analysis_daily
            WHERE
                user_id = %s
                AND date BETWEEN %s AND %s
            """,
            (user_id, period_start, period_end),
        ).fetchall()

        user_row = conn.execute(
            "SELECT user_type FROM users WHERE id = %s",
            (user_id,),
        ).fetchone()

    if user_row is None:
        raise AnalysisError("user_not_found", "the user does not exist")

    stats_by_date = {}

    for row in stats_rows:
        stats_by_date[row["date"]] = {
            "pomodoro_duration": _to_minutes(row["pomodoro_duration_sec"]),
            "stopwatch_duration": _to_minutes(row["stopwatch_duration_sec"]),
            "drowsy_count": row["drowsy_count"],
            "drowsy_duration": _to_minutes(row["drowsy_duration_sec"]),
            "phone_count": row["phone_count"],
            "phone_duration": _to_minutes(row["phone_duration_sec"]),
            "todo_total": row["todo_total"],
            "todo_done": row["todo_done"],
            "time_slots": {},
        }

    for row in slot_rows:
        stats = stats_by_date.get(row["date"])

        # 시간대 행만 있고 일별 집계가 없는 경우는 집계 누락이므로 건너뛴다.
        if stats is None:
            continue

        stats["time_slots"][row["slot"]] = {
            "focus_duration": _to_minutes(row["focus_duration_sec"]),
            "drowsy_count": row["drowsy_count"],
            "phone_count": row["phone_count"],
        }

    advice_by_date = {row["date"]: row["advice"] for row in advice_rows}

    days = []
    cursor = period_start

    while cursor <= period_end:
        days.append(
            {
                "date": cursor.isoformat(),
                "stats": stats_by_date.get(cursor),
                "advice": advice_by_date.get(cursor),
            }
        )
        cursor += timedelta(days=1)

    return days, user_row["user_type"]


# ─── Claude 호출 ─────────────────────────────────────────────────────────────

def _call_claude(prompt: str) -> dict:
    client = _anthropic_client()

    try:
        response = client.beta.messages.create(
            model=resolve_model(),
            # 사고 토큰과 응답이 max_tokens를 공유하므로 넉넉히 잡는다.
            max_tokens=8000,
            output_config=build_output_config(ANALYSIS_SCHEMA, "medium"),
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            messages=[{"role": "user", "content": prompt}],
        )
    except anthropic.APIStatusError as error:
        raise to_analysis_error(error)

    if response.stop_reason == "refusal":
        raise AnalysisError(
            "model_refusal",
            "the model declined to generate this analysis",
        )

    if response.stop_reason == "max_tokens":
        raise AnalysisError(
            "model_truncated",
            "the model response was truncated",
        )

    text = next(
        (
            block.text
            for block in response.content
            if block.type == "text"
        ),
        None,
    )

    if not text:
        raise AnalysisError(
            "empty_model_response",
            "the model returned no text content",
        )

    try:
        return json.loads(text)
    except ValueError:
        raise AnalysisError(
            "invalid_model_response",
            "the model response was not valid JSON",
        )


# ─── 저장 / 조회 ─────────────────────────────────────────────────────────────

def serialize_cumulative(row):
    if row is None:
        return None

    return {
        "id": row["id"],
        "user_id": str(row["user_id"]),
        "period_type": row["period_type"],
        "period_start": row["period_start"].isoformat(),
        "period_end": row["period_end"].isoformat(),
        "summary": row["summary"],
        "patterns": row["patterns"],
        "routine": row["routine"],
        "generated_at": row["generated_at"].isoformat(),
    }


def _upsert_cumulative(
    user_id: UUID,
    period_type: str,
    period_start: date,
    period_end: date,
    result: dict,
):
    summary = (result.get("summary") or "").strip()

    if not summary:
        raise AnalysisError(
            "empty_summary",
            "the model returned an empty summary",
        )

    patterns = (result.get("patterns") or [])[:MAX_PATTERNS]
    routine = (result.get("routine") or [])[:MAX_ROUTINE]

    with get_db_connection() as conn:
        row = conn.execute(
            """
            INSERT INTO analysis_cumulative (
                user_id,
                period_type,
                period_start,
                period_end,
                summary,
                patterns,
                routine,
                generated_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())
            ON CONFLICT (user_id, period_type, period_start)
            DO UPDATE SET
                period_end = EXCLUDED.period_end,
                summary = EXCLUDED.summary,
                patterns = EXCLUDED.patterns,
                routine = EXCLUDED.routine,
                generated_at = EXCLUDED.generated_at
            RETURNING *
            """,
            (
                user_id,
                period_type,
                period_start,
                period_end,
                summary,
                Json(patterns),
                Json(routine),
            ),
        ).fetchone()

    return serialize_cumulative(row)


def generate_cumulative_analysis(user_id: str, period_type: str):
    """기간 데이터를 모아 Claude로 분석하고 analysis_cumulative에 upsert한다."""

    parsed_user_id = _parse_user_id(user_id)
    period_start, period_end, build_prompt = resolve_period(period_type)

    days, user_type = fetch_daily_data(
        parsed_user_id,
        period_start,
        period_end,
    )

    if not any(day["stats"] for day in days):
        raise AnalysisError(
            "no_data",
            "there is no activity data in this period",
        )

    result = _call_claude(build_prompt(days, user_type))

    return _upsert_cumulative(
        parsed_user_id,
        period_type,
        period_start,
        period_end,
        result,
    )


def get_latest_cumulative_analysis(user_id: str, period_type: str):
    parsed_user_id = _parse_user_id(user_id)

    if period_type not in PERIOD_SPECS:
        raise AnalysisError(
            "invalid_period_type",
            "period_type must be one of: " + ", ".join(PERIOD_SPECS),
        )

    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT *
            FROM analysis_cumulative
            WHERE
                user_id = %s
                AND period_type = %s
            ORDER BY period_start DESC
            LIMIT 1
            """,
            (parsed_user_id, period_type),
        ).fetchone()

    return serialize_cumulative(row)


def _parse_user_id(user_id: str) -> UUID:
    try:
        return UUID(str(user_id))
    except (TypeError, ValueError):
        raise AnalysisError("invalid_user_id", "user_id is invalid")
