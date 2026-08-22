"""할 일 CRUD.

앱 lib/services/todo_service.dart 를 대체한다.

주의: todos 테이블은 HW 음성 서버와 공유한다. HW가 음성 명령으로 완료 처리
(UPDATE is_done)와 삭제(DELETE, 소프트 삭제 아님)를 하므로, 여기서 읽은 행이
다음 순간 사라져 있을 수 있다. 갱신·삭제가 0행이면 404로 처리한다.
"""

from datetime import date as date_type, datetime, time as time_type
from uuid import UUID
from zoneinfo import ZoneInfo

from psycopg.errors import CheckViolation, ForeignKeyViolation

from app.db import get_db_connection


KST = ZoneInfo("Asia/Seoul")

# 부분 수정에서 "안 보냄"과 "명시적 null"을 구분하기 위한 표식
UNSET = object()

PATCHABLE = (
    "content",
    "category_id",
    "date",
    "deadline_time",
    "notify",
    "notify_before_min",
    "is_done",
)


class TodoError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def today_kst() -> date_type:
    return datetime.now(KST).date()


def serialize_todo(row):
    if row is None:
        return None

    deadline = row["deadline_time"]

    return {
        # 앱 TodoModel.id 는 String 이므로 클라이언트에서 문자열로 다룰 것
        "id": row["id"],
        "content": row["content"],
        "category_id": str(row["category_id"]),
        "date": row["date"].isoformat(),
        "deadline_time": deadline.strftime("%H:%M") if deadline else None,
        "notify": row["notify"],
        "notify_before_min": row["notify_before_min"],
        "is_done": row["is_done"],
    }


# ─── 검증 ────────────────────────────────────────────────────────────────────

def _clean_content(content) -> str:
    content = (content or "").strip()

    if not content:
        raise TodoError("invalid_content", "content must not be empty")

    return content


def _validate_notify(notify, deadline_time, notify_before_min):
    """todos 의 CHECK 제약을 그대로 옮긴 것.

    DB가 거부하기 전에 여기서 잡아야 원인을 알 수 있는 메시지를 줄 수 있다.
    """
    if notify:
        if deadline_time is None:
            raise TodoError(
                "invalid_notify",
                "notify requires deadline_time",
            )

        if not isinstance(notify_before_min, int) or notify_before_min < 0:
            raise TodoError(
                "invalid_notify",
                "notify requires notify_before_min to be 0 or greater",
            )
    else:
        if notify_before_min is not None:
            raise TodoError(
                "invalid_notify",
                "notify_before_min must be null when notify is false",
            )


def _resolve_category_id(conn, user_id: UUID, category_id):
    """category_id 가 NOT NULL 이라 없으면 사용자의 첫 카테고리로 채운다.

    앱 TodoModel 의 categoryId 는 nullable 이므로 이 보정이 없으면
    카테고리를 고르지 않은 할 일 생성이 전부 실패한다.
    """
    if category_id is not None:
        row = conn.execute(
            """
            SELECT id FROM categories
            WHERE id = %s AND user_id = %s
            """,
            (category_id, user_id),
        ).fetchone()

        if row is None:
            raise TodoError(
                "category_not_found",
                "that category does not exist for this user",
            )

        return row["id"]

    row = conn.execute(
        """
        SELECT id FROM categories
        WHERE user_id = %s
        ORDER BY sort_order, name
        LIMIT 1
        """,
        (user_id,),
    ).fetchone()

    if row is None:
        raise TodoError(
            "no_category",
            "create a category before adding a todo",
        )

    return row["id"]


# ─── 조회 ────────────────────────────────────────────────────────────────────

def list_todos(user_id: UUID, on_date: date_type | None = None):
    on_date = on_date or today_kst()

    with get_db_connection() as conn:
        rows = conn.execute(
            """
            SELECT
                id, content, category_id, date,
                deadline_time, notify, notify_before_min, is_done
            FROM todos
            WHERE user_id = %s AND date = %s
            ORDER BY deadline_time NULLS LAST, id
            """,
            (user_id, on_date),
        ).fetchall()

    return {
        "date": on_date.isoformat(),
        "todos": [serialize_todo(r) for r in rows],
    }


def get_todo(user_id: UUID, todo_id: int):
    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT
                id, content, category_id, date,
                deadline_time, notify, notify_before_min, is_done
            FROM todos
            WHERE id = %s AND user_id = %s
            """,
            (todo_id, user_id),
        ).fetchone()

    if row is None:
        raise TodoError("todo_not_found", "that todo does not exist")

    return serialize_todo(row)


# ─── 생성 ────────────────────────────────────────────────────────────────────

def create_todo(
    user_id: UUID,
    content: str,
    on_date: date_type | None = None,
    category_id: UUID | None = None,
    deadline_time: time_type | None = None,
    notify: bool = False,
    notify_before_min: int | None = None,
):
    content = _clean_content(content)
    on_date = on_date or today_kst()
    _validate_notify(notify, deadline_time, notify_before_min)

    try:
        with get_db_connection() as conn:
            resolved_category = _resolve_category_id(
                conn, user_id, category_id
            )

            row = conn.execute(
                """
                INSERT INTO todos (
                    user_id, category_id, content, date,
                    deadline_time, notify, notify_before_min, is_done
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, false)
                RETURNING
                    id, content, category_id, date,
                    deadline_time, notify, notify_before_min, is_done
                """,
                (
                    user_id,
                    resolved_category,
                    content,
                    on_date,
                    deadline_time,
                    notify,
                    notify_before_min,
                ),
            ).fetchone()

    except ForeignKeyViolation:
        raise TodoError(
            "category_not_found",
            "that category does not exist for this user",
        )
    except CheckViolation:
        raise TodoError(
            "invalid_todo",
            "the todo violates a database constraint",
        )

    return serialize_todo(row)


# ─── 수정 ────────────────────────────────────────────────────────────────────

def update_todo(user_id: UUID, todo_id: int, changes: dict):
    """부분 수정. changes 에 담긴 키만 바꾼다.

    notify 관련 CHECK 가 세 컬럼에 걸쳐 있어서, 기존 행과 병합한 뒤
    검증해야 한다. HW 가 동시에 건드릴 수 있으므로 FOR UPDATE 로 잠근다.
    """
    unknown = set(changes) - set(PATCHABLE)

    if unknown:
        raise TodoError(
            "invalid_field",
            f"cannot update: {', '.join(sorted(unknown))}",
        )

    if not changes:
        return get_todo(user_id, todo_id)

    try:
        with get_db_connection() as conn:
            current = conn.execute(
                """
                SELECT
                    id, content, category_id, date,
                    deadline_time, notify, notify_before_min, is_done
                FROM todos
                WHERE id = %s AND user_id = %s
                FOR UPDATE
                """,
                (todo_id, user_id),
            ).fetchone()

            # HW 음성 명령으로 이미 삭제됐을 수 있다.
            if current is None:
                raise TodoError("todo_not_found", "that todo does not exist")

            merged = {key: current[key] for key in PATCHABLE}
            merged.update(changes)

            if "content" in changes:
                merged["content"] = _clean_content(merged["content"])

            if "category_id" in changes:
                merged["category_id"] = _resolve_category_id(
                    conn, user_id, merged["category_id"]
                )

            _validate_notify(
                merged["notify"],
                merged["deadline_time"],
                merged["notify_before_min"],
            )

            row = conn.execute(
                """
                UPDATE todos SET
                    content           = %(content)s,
                    category_id       = %(category_id)s,
                    date              = %(date)s,
                    deadline_time     = %(deadline_time)s,
                    notify            = %(notify)s,
                    notify_before_min = %(notify_before_min)s,
                    is_done           = %(is_done)s
                WHERE id = %(id)s AND user_id = %(user_id)s
                RETURNING
                    id, content, category_id, date,
                    deadline_time, notify, notify_before_min, is_done
                """,
                {**merged, "id": todo_id, "user_id": user_id},
            ).fetchone()

    except ForeignKeyViolation:
        raise TodoError(
            "category_not_found",
            "that category does not exist for this user",
        )
    except CheckViolation:
        raise TodoError(
            "invalid_todo",
            "the todo violates a database constraint",
        )

    return serialize_todo(row)


# ─── 삭제 ────────────────────────────────────────────────────────────────────

def delete_todo(user_id: UUID, todo_id: int):
    with get_db_connection() as conn:
        row = conn.execute(
            """
            DELETE FROM todos
            WHERE id = %s AND user_id = %s
            RETURNING id
            """,
            (todo_id, user_id),
        ).fetchone()

    # 이미 HW 가 지웠거나 남의 할 일이거나.
    if row is None:
        raise TodoError("todo_not_found", "that todo does not exist")
