"""음성 Todo 명령의 보수적인 후보 선택 로직."""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from typing import Any


def normalize_todo_text(value: str) -> str:
    """대소문자와 연속 공백만 정규화한다. 임의의 유사도 추측은 하지 않는다."""
    return re.sub(r"\s+", " ", value.strip()).casefold()


def select_todo_candidate(
    todos: Iterable[Mapping[str, Any]], content_hint: str
) -> tuple[Mapping[str, Any] | None, str]:
    """정확 일치 또는 유일한 포함 일치만 선택한다.

    반환 reason은 ``matched``, ``not_found``, ``ambiguous`` 중 하나다.
    """
    hint = normalize_todo_text(content_hint)
    if not hint:
        return None, "not_found"

    candidates = list(todos)
    exact = [row for row in candidates if normalize_todo_text(str(row["content"])) == hint]
    if len(exact) == 1:
        return exact[0], "matched"
    if len(exact) > 1:
        return None, "ambiguous"

    contained = []
    for row in candidates:
        content = normalize_todo_text(str(row["content"]))
        if hint in content or content in hint:
            contained.append(row)

    if len(contained) == 1:
        return contained[0], "matched"
    if len(contained) > 1:
        return None, "ambiguous"
    return None, "not_found"
