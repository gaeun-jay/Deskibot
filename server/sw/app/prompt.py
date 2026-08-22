"""누적 분석용 Claude 프롬프트 빌더.

기존 Node 서버(server/src/prompt.js)의 포팅.
일자별 데이터는 분(minute) 단위로 정규화된 dict를 받는다.
(PostgreSQL은 초 단위로 저장하므로 analysis_service에서 변환한 뒤 넘긴다.)
"""

WEEKDAY_KO = ["월", "화", "수", "목", "금", "토", "일"]

SLOT_NAMES = {
    "dawn": "새벽",
    "morning": "오전",
    "afternoon": "오후",
    "night": "저녁",
}


JSON_RULES = """규칙:
- summary: 데이터에서 가장 두드러진 취약점을 한 문장으로, 구체적인 수치 포함 권장 (40자 이내)
- patterns 최대 3개, 실제 데이터에서 관찰된 패턴만 포함
  - type은 focus, distraction, todo 중 하나
  - title은 15자 이내, body는 60자 이내
- routine 최대 3개, 데이터 기반 구체적인 시간대와 행동
  - time은 HH:MM 형식, label은 15자 이내, body는 50자 이내
- patterns.body와 routine.body는 "-다", "-입니다", "-해보는 건 어떨까요" 같은 제안형·서술형 말투로 작성
- 단어 나열식이나 명사형 종결(-함, -됨)은 피할 것
- 한국어로 작성"""


def _weekday_ko(date_str: str) -> str:
    from datetime import date

    year, month, day = (int(part) for part in date_str.split("-"))
    return WEEKDAY_KO[date(year, month, day).weekday()]


def format_slot(slot) -> str:
    if not slot:
        return "활동 없음"

    parts = []

    if slot.get("focus_duration", 0) > 0:
        parts.append(f"집중 {slot['focus_duration']}분")

    if slot.get("drowsy_count", 0) > 0:
        parts.append(f"졸음 {slot['drowsy_count']}회")

    if slot.get("phone_count", 0) > 0:
        parts.append(f"폰 {slot['phone_count']}회")

    return " / ".join(parts) if parts else "활동 없음"


def user_context(user_type) -> str:
    if not user_type:
        return ""

    return f"사용자 유형: {user_type}\n"


def _day_block(day) -> str:
    date_str = day["date"]
    stats = day.get("stats")
    advice = day.get("advice")
    weekday = _weekday_ko(date_str)

    if not stats:
        return f"[{date_str} ({weekday})]\n  데이터 없음"

    pomodoro = stats.get("pomodoro_duration", 0)
    stopwatch = stats.get("stopwatch_duration", 0)
    focus_min = pomodoro + stopwatch
    slots = stats.get("time_slots") or {}

    slot_line = " | ".join(
        f"{label}: {format_slot(slots.get(key))}"
        for key, label in SLOT_NAMES.items()
    )

    lines = [
        f"[{date_str} ({weekday})]",
        (
            f"  집중: {focus_min}분"
            f" (뽀모도로 {pomodoro}분 / 스톱워치 {stopwatch}분)"
        ),
        (
            f"  졸음: {stats.get('drowsy_count', 0)}회"
            f" {stats.get('drowsy_duration', 0)}분"
            f" | 스마트폰: {stats.get('phone_count', 0)}회"
            f" {stats.get('phone_duration', 0)}분"
        ),
        (
            f"  할 일: {stats.get('todo_done', 0)}"
            f"/{stats.get('todo_total', 0)} 완료"
        ),
        f"  시간대 | {slot_line}",
    ]

    if advice:
        lines.append(f'  당일 AI 평가: "{advice}"')

    return "\n".join(lines)


def _sum_focus(days) -> int:
    total = 0

    for day in days:
        stats = day.get("stats")

        if not stats:
            continue

        total += stats.get("pomodoro_duration", 0)
        total += stats.get("stopwatch_duration", 0)

    return total


def _sum_field(days, field: str) -> int:
    return sum(
        (day.get("stats") or {}).get(field, 0)
        for day in days
    )


def build_weekly_prompt(days, user_type) -> str:
    day_section = "\n\n".join(_day_block(day) for day in days)

    return f"""당신은 학습 습관 코치입니다. 아래는 사용자의 최근 7일 집중 공부 데이터입니다.
{user_context(user_type)}
{day_section}

위 데이터를 분석하여 취약점 요약, 반복 패턴, 루틴 제안을 작성하세요.

{JSON_RULES}"""


def build_monthly_prompt(days, user_type) -> str:
    weeks = [[], [], [], []]

    for index, day in enumerate(days):
        weeks[min(index // 7, 3)].append(day)

    sections = []

    for week_index, week_days in enumerate(weeks):
        if not week_days:
            continue

        start = week_days[0]["date"]
        end = week_days[-1]["date"]

        sections.append(
            f"[{week_index + 1}주차 {start}~{end}]\n"
            f"  집중: {_sum_focus(week_days)}분"
            f" | 졸음: {_sum_field(week_days, 'drowsy_count')}회"
            f" | 스마트폰: {_sum_field(week_days, 'phone_count')}회"
            f" | 할일: {_sum_field(week_days, 'todo_done')}"
            f"/{_sum_field(week_days, 'todo_total')} 완료"
        )

    week_section = "\n\n".join(sections)

    return f"""당신은 학습 습관 코치입니다. 아래는 사용자의 최근 4주(30일) 집중 공부 요약 데이터입니다.
{user_context(user_type)}
{week_section}

위 4주 데이터를 분석하여 반복 패턴과 루틴 제안을 작성하세요.

{JSON_RULES}"""


def aggregate_by_month(days):
    months = {}

    for day in days:
        stats = day.get("stats")

        if not stats:
            continue

        key = day["date"][:7]

        month = months.setdefault(
            key,
            {
                "month": key,
                "total_focus": 0,
                "drowsy_count": 0,
                "phone_count": 0,
                "todo_done": 0,
                "todo_total": 0,
                "active_days": 0,
            },
        )

        focus = (
            stats.get("pomodoro_duration", 0)
            + stats.get("stopwatch_duration", 0)
        )

        month["total_focus"] += focus
        month["drowsy_count"] += stats.get("drowsy_count", 0)
        month["phone_count"] += stats.get("phone_count", 0)
        month["todo_done"] += stats.get("todo_done", 0)
        month["todo_total"] += stats.get("todo_total", 0)

        if focus > 0:
            month["active_days"] += 1

    return sorted(months.values(), key=lambda m: m["month"])


def month_section(month_data) -> str:
    return "\n".join(
        f"[{month['month']}] 집중: {month['total_focus']}분"
        f" (활동일 {month['active_days']}일)"
        f" | 졸음: {month['drowsy_count']}회"
        f" | 스마트폰: {month['phone_count']}회"
        f" | 할일: {month['todo_done']}/{month['todo_total']} 완료"
        for month in month_data
    )


def _monthly_summary_prompt(days, user_type, span_label: str, ask: str) -> str:
    section = month_section(aggregate_by_month(days))

    return f"""당신은 학습 습관 코치입니다. 아래는 사용자의 최근 {span_label} 집중 공부 요약 데이터입니다.
{user_context(user_type)}
{section}

{ask}

{JSON_RULES}"""


def build_quarterly_prompt(days, user_type) -> str:
    return _monthly_summary_prompt(
        days,
        user_type,
        "3개월",
        "위 3개월 데이터를 분석하여 분기별 반복 패턴과 루틴 제안을 작성하세요.",
    )


def build_half_yearly_prompt(days, user_type) -> str:
    return _monthly_summary_prompt(
        days,
        user_type,
        "6개월",
        "위 6개월 데이터를 분석하여 반기별 장기 패턴과 루틴 제안을 작성하세요.",
    )


def build_yearly_prompt(days, user_type) -> str:
    return _monthly_summary_prompt(
        days,
        user_type,
        "1년(12개월)",
        (
            "위 연간 데이터를 분석하여 계절별 학습 패턴, 취약 시기,"
            " 연간 루틴 제안을 작성하세요."
        ),
    )
