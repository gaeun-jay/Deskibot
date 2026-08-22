"""일간 분석(오늘의 공부일지) 생성 및 조회.

앱 lib/services/daily_service.dart 의 getTodayAnalysis() 를 대체한다.
원래 개발 PC 에서 돌리던 FastAPI(/daily-analysis/generate)가 하던 일인데,
그 코드가 유실돼 새로 만든다.

title/subtitle/advice 세 필드를 한 번의 Claude 호출로 같이 생성해
analysis_daily 에 저장한다. 마이그레이션 전에 생성된 기존 행은
title/subtitle 이 NULL 일 수 있다 — 앱은 그 경우 대체 화면을 그린다.
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
        "title": {
            "type": "string",
            "description": (
                "오늘의 집중/방해 패턴을 감성적으로 요약한 한 문장. "
                '예: "오전엔 잘 됐는데 오후가 아쉬웠던 하루."'
            ),
        },
        "subtitle": {
            "type": "string",
            "description": (
                "title을 보완하는 핵심 패턴 한 줄 요약. "
                '예: "오전 루틴은 지켜졌지만, 점심 후 전환이 아직 어려워요."'
            ),
        },
        "advice": {
            "type": "string",
            "description": (
                "시간대별 집중 패턴과 방해 요소, 투두 데이터를 바탕으로 한 "
                "내일을 위한 조언. 최대한 간략하게 1~2문장. "
                '예: "내일은 오후 시간대에 수면 부족을 보충하고, 정해진 '
                '투두 완료 시간을 명확히 설정하여 집중력을 높여보세요."'
            ),
        },
    },
    "required": ["title", "subtitle", "advice"],
    "additionalProperties": False,
}

# 그날 활동이 전혀 없을 때 쓰는 고정 문구. Claude 를 부르지 않는다.
NO_ACTIVITY_TITLE = "기록이 없는 하루였어요"
NO_ACTIVITY_SUBTITLE = "어제는 앱도 로봇도 사용하지 않은 것 같아요"
NO_ACTIVITY_ADVICE = "오늘은 짧게라도 집중 세션 하나만 시작해보는 건 어떨까요?"

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
            f" ({s['end_reason']})"
        )

    user_line = f"사용자 유형: {user_type}\n" if user_type else ""

    return f"""당신은 오늘 날짜에 해당하는 사용자의 집중 세션, 하루 통계, 투두 데이터를 모두 분석하여 사용자에게 따뜻하고 공감되는 하루 레포트를 작성하는 AI입니다.

아래는 사용자의 {on_date.isoformat()} 하루 학습 데이터입니다.
{user_line}
총 집중: {focus_min}분 (뽀모도로 {_minutes(totals['pomodoro_duration_sec'])}분 / 스톱워치 {_minutes(totals['stopwatch_duration_sec'])}분)
세션 수: 뽀모도로 {totals['pomodoro_count']}회, 스톱워치 {totals['stopwatch_count']}회
졸음: {totals['drowsy_count']}회 {_minutes(totals['drowsy_duration_sec'])}분
스마트폰: {totals['phone_count']}회 {_minutes(totals['phone_duration_sec'])}분
할 일: {totals['todo_done']}/{totals['todo_total']} 완료
시간대 | {' | '.join(slot_lines)}
{chr(10).join(session_lines) if session_lines else ''}

위 데이터를 분석해서 title, subtitle, advice 를 작성하세요.

작성 기준:
- title: 오늘의 집중/방해 패턴을 감성적으로 요약한 한 문장
  (예: "오전엔 잘 됐는데 오후가 아쉬웠던 하루.")
- subtitle: title을 보완하는 핵심 패턴 한 줄 요약
  (예: "오전 루틴은 지켜졌지만, 점심 후 전환이 아직 어려워요.")
- advice: 시간대별 집중 패턴과 방해 요소, 투두 데이터를 바탕으로 한 내일을 위한 조언.
  최대한 간략하게 1~2문장
  (예: "내일은 오후 시간대에 수면 부족을 보충하고, 정해진 투두 완료 시간을 명확히 설정하여 집중력을 높여보세요.")

공통 규칙:
- 모두 한국어로, 따뜻하고 공감되는 어조로 작성할 것
- 구체적인 수치를 하나 이상 언급할 것
- 단정적인 훈계나 비난은 피하고, 관찰한 사실에서 출발할 것
- 세 필드 모두 서로 다른 표현을 쓸 것 (같은 문장 반복 금지)"""


def _fetch_day(conn, user_id: UUID, on_date: date_type):
    totals, slots = rebuild_daily_stats(conn, user_id, on_date)

    sessions = conn.execute(
        """
        SELECT type, end_reason, actual_duration_sec
        FROM focus_session_outcomes
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
        "title": row["title"],
        "subtitle": row["subtitle"],
        "advice": row["advice"],
        "generated_at": row["generated_at"].isoformat(),
    }


def get_daily_analysis(user_id: str, on_date: date_type | None = None):
    on_date = on_date or today_kst()
    parsed = _parse_user_id(user_id)

    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT date, title, subtitle, advice, generated_at
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

    if has_activity:
        prompt = _build_prompt(on_date, totals, slots, sessions, user_type)
        title, subtitle, advice = _call_claude(prompt)
    else:
        # 그날 활동이 전혀 없으면 Claude 를 호출하지 않고 고정 문구를 쓴다.
        # (비용 절감 + "리포트 없음"보다 자연스러운 빈 하루 안내)
        title = NO_ACTIVITY_TITLE
        subtitle = NO_ACTIVITY_SUBTITLE
        advice = NO_ACTIVITY_ADVICE

    with get_db_connection() as conn:
        row = conn.execute(
            """
            INSERT INTO analysis_daily (user_id, date, title, subtitle, advice, generated_at)
            VALUES (%s, %s, %s, %s, %s, NOW())
            ON CONFLICT (user_id, date) DO UPDATE SET
                title = EXCLUDED.title,
                subtitle = EXCLUDED.subtitle,
                advice = EXCLUDED.advice,
                generated_at = EXCLUDED.generated_at
            RETURNING date, title, subtitle, advice, generated_at
            """,
            (parsed, on_date, title, subtitle, advice),
        ).fetchone()

    return serialize_daily(row)


def _call_claude(prompt: str) -> tuple[str, str, str]:
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
        parsed = json.loads(text)
        title = (parsed.get("title") or "").strip()
        subtitle = (parsed.get("subtitle") or "").strip()
        advice = (parsed.get("advice") or "").strip()
    except ValueError:
        raise AnalysisError(
            "invalid_model_response",
            "the model response was not valid JSON",
        )

    # analysis_daily 의 title/subtitle/advice 모두 NOT NULL + 빈 문자열 금지 CHECK 가 걸려 있다.
    if not title:
        raise AnalysisError("empty_title", "the model returned empty title")
    if not subtitle:
        raise AnalysisError("empty_subtitle", "the model returned empty subtitle")
    if not advice:
        raise AnalysisError("empty_advice", "the model returned empty advice")

    return title, subtitle, advice


def _parse_user_id(user_id) -> UUID:
    try:
        return UUID(str(user_id))
    except (TypeError, ValueError):
        raise AnalysisError("invalid_user_id", "user_id is invalid")
