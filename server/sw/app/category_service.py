"""카테고리 CRUD.

앱 lib/services/user_service.dart 와 timetable_service.getCategories() 를 대체한다.

Firestore 에서는 users 문서 안의 배열이었지만 PostgreSQL 에서는 별도 테이블이고,
앱에 없던 제약이 셋 붙어 있다.

  * 유저당 최대 5개  (trg_category_limit 트리거)
  * 이름 중복 불가   (UNIQUE (user_id, name))
  * 색상은 #RRGGBB  (CHECK)

또 todos 가 (category_id, user_id) 복합 FK 로 ON DELETE RESTRICT 를 걸고 있어서,
할 일이 딸린 카테고리는 지울 수 없다.
"""

import re
from uuid import UUID

from psycopg.errors import (
    CheckViolation,
    ForeignKeyViolation,
    RaiseException,
    UniqueViolation,
)

from app.db import get_db_connection


MAX_CATEGORIES = 5
COLOR_PATTERN = re.compile(r"^#[0-9A-Fa-f]{6}$")


class CategoryError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def serialize_category(row):
    if row is None:
        return None

    return {
        "id": str(row["id"]),
        "name": row["name"],
        "color": row["color"],
        "sort_order": row["sort_order"],
    }


def _clean_name(name) -> str:
    name = (name or "").strip()

    if not name:
        raise CategoryError("invalid_name", "name must not be empty")

    return name


def _clean_color(color) -> str:
    color = (color or "").strip()

    if not COLOR_PATTERN.match(color):
        raise CategoryError(
            "invalid_color",
            "color must look like #RRGGBB",
        )

    return color.upper() if color.startswith("#") else color


def list_categories(user_id: UUID):
    with get_db_connection() as conn:
        rows = conn.execute(
            """
            SELECT id, name, color, sort_order
            FROM categories
            WHERE user_id = %s
            ORDER BY sort_order, name
            """,
            (user_id,),
        ).fetchall()

    return {"categories": [serialize_category(r) for r in rows]}


def create_category(
    user_id: UUID,
    name: str,
    color: str,
    sort_order: int | None = None,
):
    name = _clean_name(name)
    color = _clean_color(color)

    try:
        with get_db_connection() as conn:
            if sort_order is None:
                row = conn.execute(
                    """
                    SELECT COALESCE(MAX(sort_order) + 1, 0) AS next
                    FROM categories WHERE user_id = %s
                    """,
                    (user_id,),
                ).fetchone()
                sort_order = row["next"]

            created = conn.execute(
                """
                INSERT INTO categories (user_id, name, color, sort_order)
                VALUES (%s, %s, %s, %s)
                RETURNING id, name, color, sort_order
                """,
                (user_id, name, color, sort_order),
            ).fetchone()

    except UniqueViolation:
        raise CategoryError(
            "name_taken",
            "a category with that name already exists",
        )
    except RaiseException:
        # trg_category_limit 트리거가 던지는 예외
        raise CategoryError(
            "category_limit",
            f"you can have at most {MAX_CATEGORIES} categories",
        )
    except CheckViolation:
        raise CategoryError(
            "invalid_category",
            "the category violates a database constraint",
        )

    return serialize_category(created)


def update_category(user_id: UUID, category_id: UUID, changes: dict):
    allowed = {"name", "color", "sort_order"}
    unknown = set(changes) - allowed

    if unknown:
        raise CategoryError(
            "invalid_field",
            f"cannot update: {', '.join(sorted(unknown))}",
        )

    if not changes:
        raise CategoryError("no_changes", "nothing to update")

    if "name" in changes:
        changes["name"] = _clean_name(changes["name"])

    if "color" in changes:
        changes["color"] = _clean_color(changes["color"])

    try:
        with get_db_connection() as conn:
            current = conn.execute(
                """
                SELECT id, name, color, sort_order
                FROM categories
                WHERE id = %s AND user_id = %s
                FOR UPDATE
                """,
                (category_id, user_id),
            ).fetchone()

            if current is None:
                raise CategoryError(
                    "category_not_found",
                    "that category does not exist",
                )

            merged = {
                "name": current["name"],
                "color": current["color"],
                "sort_order": current["sort_order"],
            }
            merged.update(changes)

            updated = conn.execute(
                """
                UPDATE categories SET
                    name = %(name)s,
                    color = %(color)s,
                    sort_order = %(sort_order)s
                WHERE id = %(id)s AND user_id = %(user_id)s
                RETURNING id, name, color, sort_order
                """,
                {**merged, "id": category_id, "user_id": user_id},
            ).fetchone()

    except UniqueViolation:
        raise CategoryError(
            "name_taken",
            "a category with that name already exists",
        )
    except CheckViolation:
        raise CategoryError(
            "invalid_category",
            "the category violates a database constraint",
        )

    return serialize_category(updated)


def delete_category(user_id: UUID, category_id: UUID):
    try:
        with get_db_connection() as conn:
            row = conn.execute(
                """
                DELETE FROM categories
                WHERE id = %s AND user_id = %s
                RETURNING id
                """,
                (category_id, user_id),
            ).fetchone()

    except ForeignKeyViolation:
        # todos 가 ON DELETE RESTRICT 로 붙잡고 있다.
        raise CategoryError(
            "category_in_use",
            "move or delete the todos in this category first",
        )

    if row is None:
        raise CategoryError(
            "category_not_found",
            "that category does not exist",
        )
