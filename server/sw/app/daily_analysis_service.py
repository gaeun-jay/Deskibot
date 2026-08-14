"""일간 분석(오늘의 공부일지) 생성 및 조회.

앱 lib/services/daily_service.dart 의 getTodayAnalysis() 를 대체한다.
원래 개발 PC 에서 돌리던 FastAPI(/daily-analysis/generate)가 하던 일인데,
그 코드가 유실돼 새로 만든다.

스키마 제약: analysis_daily 에는 advice 컬럼 하나뿐이다. 앱은 title/subtitle
도 읽지만 저장할 자리가 없어서 null 로 내려보낸다. 앱 화면에 title 이 없을
때의 대체 분기가 이미 있어서 표시는 정상적으로 된다.
"""

import json
import os
from datetime import date as date_type
from uuid import UUID

import anthropic

from app.analysis_service import (
    AnalysisError,
    _anthropic_client,
    build_output_config,
    resolve_model,
    to_analysis_error,
)
from app.db import get_db_connection
from app.stats_service import rebuild_daily_stats, today_kst


DEFAULT_MODEL = "claude-opus-5"

ADVICE_SCHEMA = {
    "type": "object",
    "properties": {
        "advice": {
            "type": "string",
            "description": "오늘 하루에 대한 코칭 한두 문장",
        },
    },
    "required": ["advice"],
    "additionalProperties": False,
}

SLOT_NAMES = {
    "dawn": "새벽",
    "morning": "오전",
    "afternoon": "오후",
    "night": "저녁",
}


def _minutes(seconds) -> int:
    return round((seconds or 0) / 60)


def _build_prompt(on_date: date_type, totals, slots, sessions, user_type):
    focus_min = _minutes(
        totals["pomodoro_duration_sec"] + totals["stopwatch_duration_sec"]
    )

    slot_lines = []
    for key, label in SLOT_NAMES.items():
        v = slots.get(key) or {}
        parts = []

        if v.get("focus_duration_sec"):
            parts.append(f"집중 {_minutes(v['focus_duration_sec'])}분")
        if v.get("drowsy_count"):
            parts.append(f"졸음 {v['drowsy_count']}회")
        if v.get("phone_count"):
            parts.append(f"폰 {v['phone_count']}회")

        slot_lines.append(f"{label}: {' / '.join(parts) if parts else '활동 없음'}")

    session_lines = []
    for s in sessions[:10]:
        kind = "뽀모도로" if s["type"] == "pomodoro" else "스톱워치"
        session_lines.append(
            f"  - {kind} {_minutes(s['actual_duration_sec'])}분"
            f" ({s['status']})"
        )

    user_line = f"사용자 유형: {user_type}\n" if user_type else ""

    return f"""당신은 학습 습관 코치입니다. 아래는 사용자의 {on_date.isoformat()} 하루 집중 공부 데이터입니다.
{user_line}
총 집중: {focus_min}분 (뽀모도로 {_minutes(totals['pomodoro_duration_sec'])}분 / 스톱워치 {_minutes(totals['stopwatch_duration_sec'])}분)
세션 수: 뽀모도로 {totals['pomodoro_count']}회, 스톱워치 {totals['stopwatch_count']}회
졸음: {totals['drowsy_count']}회 {_minutes(totals['drowsy_duration_sec'])}분
스마트폰: {totals['phone_count']}회 {_minutes(totals['phone_duration_sec'])}분
할 일: {totals['todo_done']}/{totals['todo_total']} 완료
시간대 | {' | '.join(slot_lines)}
{chr(10).join(session_lines) if session_lines else ''}

위 하루 데이터를 보고 사용자에게 건넬 조언을 작성하세요.

규칙:
- 두 문장 이내, 100자 이내
- 구체적인 수치를 하나 이상 언급할 것
- "-다", "-네요", "-해보는 건 어떨까요" 같은 서술형·제안형 말투
- 단정적인 훈계나 비난은 피하고, 관찰한 사실에서 출발할 것
- 한국어로 작성"""


def _fetch_day(conn, user_id: UUID, on_date: date_type):
    totals, slots = rebuild_daily_stats(conn, user_id, on_date)

    sessions = conn.execute(
        """
        SELECT type, status, actual_duration_sec
        FROM focus_sessions
        WHERE user_id = %s AND session_date = %s AND status <> 'in_progress'
        ORDER BY started_at
        """,
        (user_id, on_date),
    ).fetchall()

    user = conn.execute(
        "SELECT user_type FROM users WHERE id = %s",
        (user_id,),
    ).fetchone()

    if user is None:
        raise AnalysisError("user_not_found", "the user does not exist")

    return totals, slots, sessions, user["user_type"]


def serialize_daily(row):
    if row is None:
        return None

    return {
        "date": row["date"].isoformat(),
        "advice": row["advice"],
        # analysis_daily 에 저장할 컬럼이 없다. 앱은 값이 없으면
        # 대체 화면을 그리도록 이미 만들어져 있다.
        "title": None,
        "subtitle": None,
        "generated_at": row["generated_at"].isoformat(),
    }


def get_daily_analysis(user_id: str, on_date: date_type | None = None):
    on_date = on_date or today_kst()
    parsed = _parse_user_id(user_id)

    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT date, advice, generated_at
            FROM analysis_daily
            WHERE user_id = %s AND date = %s
            """,
            (parsed, on_date),
        ).fetchone()

    return serialize_daily(row)


def generate_daily_analysis(user_id: str, on_date: date_type | None = None):
    on_date = on_date or today_kst()
    parsed = _parse_user_id(user_id)

    with get_db_connection() as conn:
        totals, slots, sessions, user_type = _fetch_day(conn, parsed, on_date)

        has_activity = any(
            totals[k]
            for k in (
                "pomodoro_count",
                "stopwatch_count",
                "drowsy_count",
                "phone_count",
                "todo_total",
            )
        )

        if not has_activity:
            raise AnalysisError(
                "no_data",
                "there is no activity on this date",
            )

    prompt = _build_prompt(on_date, totals, slots, sessions, user_type)
    advice = _call_claude(prompt)

    with get_db_connection() as conn:
        row = conn.execute(
            """
            INSERT INTO analysis_daily (user_id, date, advice, generated_at)
            VALUES (%s, %s, %s, NOW())
            ON CONFLICT (user_id, date) DO UPDATE SET
                advice = EXCLUDED.advice,
                generated_at = EXCLUDED.generated_at
            RETURNING date, advice, generated_at
            """,
            (parsed, on_date, advice),
        ).fetchone()

    return serialize_daily(row)


def _call_claude(prompt: str) -> str:
    client = _anthropic_client()

    try:
        response = client.beta.messages.create(
            model=resolve_model(),
            max_tokens=4000,
            output_config=build_output_config(ADVICE_SCHEMA, "low"),
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
        raise AnalysisError("model_truncated", "the model response was truncated")

    text = next(
        (b.text for b in response.content if b.type == "text"),
        None,
    )

    if not text:
        raise AnalysisError(
            "empty_model_response",
            "the model returned no text content",
        )

    try:
        advice = (json.loads(text).get("advice") or "").strip()
    except ValueError:
        raise AnalysisError(
            "invalid_model_response",
            "the model response was not valid JSON",
        )

    # analysis_daily.advice 에 CHECK (btrim(advice) <> '') 가 걸려 있다.
    if not advice:
        raise AnalysisError("empty_advice", "the model returned empty advice")

    return advice


def _parse_user_id(user_id) -> UUID:
    try:
        return UUID(str(user_id))
    except (TypeError, ValueError):
        raise AnalysisError("invalid_user_id", "user_id is invalid")
