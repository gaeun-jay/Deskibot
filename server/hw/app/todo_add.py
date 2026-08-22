"""음성 Todo 추가 명령의 순수 정규화 로직.

DB/네트워크에 의존하지 않으므로 단위 테스트로 검증한다.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from datetime import date as date_cls
from datetime import datetime
from datetime import time as time_cls
from typing import Any

from app.todo_matching import normalize_todo_text

# 앱이 제공하는 마감 알림 선택지는 "마감 30분 전"과 "마감 1시간 전" 둘뿐이다.
NOTIFY_BEFORE_CHOICES = (30, 60)
DEFAULT_NOTIFY_BEFORE = 60

# ESP의 알림 버퍼가 content[128]바이트라 한글 42자쯤에서 잘린다. 잘린 제목으로
# 알림 중복 판정(strcmp)이 흔들리므로 서버에서 미리 짧게 자른다.
MAX_CONTENT_LEN = 40

# 카테고리를 특정하지 못했을 때 우선적으로 찾아볼 이름.
FALLBACK_CATEGORY_NAME = "기타"


def normalize_content(value: Any) -> str:
    """할 일 제목을 공백 정규화하고 길이를 제한한다. 빈 문자열이면 ''."""
    text = " ".join(str(value or "").split())
    return text[:MAX_CONTENT_LEN]


def parse_date(value: Any, today: date_cls) -> date_cls:
    """YYYY-MM-DD를 파싱한다. 값이 없거나 형식이 틀리면 오늘로 둔다."""
    if not value:
        return today
    try:
        return datetime.strptime(str(value).strip(), "%Y-%m-%d").date()
    except ValueError:
        return today


def parse_deadline(value: Any) -> time_cls | None:
    """HH:MM(또는 HH:MM:SS)을 파싱한다. 값이 없거나 형식이 틀리면 None."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    for fmt in ("%H:%M", "%H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).time().replace(second=0, microsecond=0)
        except ValueError:
            continue
    return None


def resolve_category(
    categories: Iterable[Mapping[str, Any]], hint: Any
) -> Mapping[str, Any] | None:
    """사용자 카테고리 중 hint와 가장 가까운 것을 고른다.

    정확 일치 → 포함 일치 → '기타' → 첫 카테고리(sort_order 최소) 순.
    카테고리가 하나도 없으면 None (todos.category_id가 NOT NULL이라 추가 불가).
    """
    rows = list(categories)
    if not rows:
        return None

    norm_hint = normalize_todo_text(str(hint or ""))
    if norm_hint:
        for row in rows:
            if normalize_todo_text(str(row["name"])) == norm_hint:
                return row
        contained = [
            row
            for row in rows
            if norm_hint in normalize_todo_text(str(row["name"]))
            or normalize_todo_text(str(row["name"])) in norm_hint
        ]
        if len(contained) == 1:
            return contained[0]

    for row in rows:
        if normalize_todo_text(str(row["name"])) == FALLBACK_CATEGORY_NAME:
            return row
    return rows[0]


def resolve_notify(
    todo_date: date_cls,
    deadline: time_cls | None,
    requested_before: Any,
    now: datetime,
) -> tuple[bool, int | None]:
    """마감 알림 여부와 사전 알림 분을 정한다.

    - 마감이 없으면 알림도 없다(사용자가 마감을 말하지 않은 기본 경우).
    - 마감이 있으면 기본으로 1시간 전 알림을 켠다.
    - 사용자가 30/60분 전을 명시하면 그 값을 쓰고, 다른 값은 30/60 중 가까운 쪽으로 맞춘다.
    - 알림 시각이 이미 지났으면(오늘 마감이 임박했거나 지난 날짜면) 울릴 수 없으므로 끈다.
      단 자동 선택한 1시간 전만 지났고 30분 전이 남아 있으면 30분 전으로 낮춘다.
    """
    if deadline is None:
        return False, None

    explicit = None
    if requested_before is not None:
        try:
            explicit = min(NOTIFY_BEFORE_CHOICES, key=lambda c: abs(c - int(requested_before)))
        except (TypeError, ValueError):
            explicit = None

    before = explicit if explicit is not None else DEFAULT_NOTIFY_BEFORE

    if todo_date < now.date():
        return False, None
    if todo_date == now.date():
        now_min = now.hour * 60 + now.minute
        deadline_min = deadline.hour * 60 + deadline.minute
        if deadline_min - before <= now_min:
            if explicit is None and before == 60 and deadline_min - 30 > now_min:
                before = 30
            else:
                return False, None

    return True, before
