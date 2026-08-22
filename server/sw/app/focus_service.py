from datetime import timezone
from uuid import UUID, uuid4

from psycopg.errors import UniqueViolation

from app.db import get_db_connection


FINAL_STATUSES = {
    "completed",
    "incomplete",
    "interrupted",
}


class FocusCommandError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def serialize_focus_session(row):
    if row is None:
        return None

    return {
        "session_id": str(row["id"]),
        "user_id": str(row["user_id"]),
        "mode": row["type"],
        "status": row["status"],
        "runtime_state": row["runtime_state"],
        "title": row["title"],
        "started_at": row["started_at"].isoformat(),
        "ended_at": (
            row["ended_at"].isoformat()
            if row["ended_at"]
            else None
        ),
        "paused_at": (
            row["paused_at"].isoformat()
            if row["paused_at"]
            else None
        ),
        "planned_duration_sec": row["planned_duration_sec"],
        "actual_duration_sec": row["actual_duration_sec"],
        "total_pause_duration_sec": (
            row["total_pause_duration_sec"]
        ),
        "revision": row["state_version"],
        "state_updated_at": row["state_updated_at"].isoformat(),
        "initiated_by": row["initiated_by"],
        "last_changed_by": row["last_changed_by"],
    }


def _select_active_session(
    conn,
    user_id: UUID,
    *,
    for_update: bool = False,
):
    query = """
        SELECT
            id,
            user_id,
            type,
            status,
            runtime_state,
            title,
            started_at,
            ended_at,
            paused_at,
            planned_duration_sec,
            actual_duration_sec,
            total_pause_duration_sec,
            state_version,
            state_updated_at,
            initiated_by,
            last_changed_by
        FROM focus_sessions
        WHERE
            user_id = %s
            AND status = 'in_progress'
        LIMIT 1
    """

    if for_update:
        query += " FOR UPDATE"

    return conn.execute(
        query,
        (user_id,),
    ).fetchone()


def get_active_focus_session(user_id: str):
    with get_db_connection() as conn:
        row = _select_active_session(
            conn,
            UUID(user_id),
        )

    return serialize_focus_session(row)


def _validate_source(source: str):
    if source not in {"app", "robot"}:
        raise FocusCommandError(
            "invalid_source",
            "source must be app or robot",
        )


def _validate_target(
    row,
    session_id: str,
    revision,
):
    if row is None:
        raise FocusCommandError(
            "no_active_session",
            "there is no active focus session",
        )

    try:
        requested_session_id = UUID(str(session_id))
    except (TypeError, ValueError):
        raise FocusCommandError(
            "invalid_session_id",
            "session_id is invalid",
        )

    if row["id"] != requested_session_id:
        raise FocusCommandError(
            "session_mismatch",
            "the active session has changed",
        )

    if (
        isinstance(revision, bool)
        or not isinstance(revision, int)
        or revision < 0
    ):
        raise FocusCommandError(
            "invalid_revision",
            "revision must be a non-negative integer",
        )

    if row["state_version"] != revision:
        raise FocusCommandError(
            "revision_conflict",
            "the session state has already changed",
        )


def start_focus_session(
    user_id: str,
    source: str,
    mode: str,
    planned_duration_sec=None,
    title=None,
):
    _validate_source(source)

    if mode not in {"pomodoro", "stopwatch"}:
        raise FocusCommandError(
            "invalid_mode",
            "mode must be pomodoro or stopwatch",
        )

    if title is not None:
        title = str(title).strip()

        if not title:
            title = None

    if mode == "pomodoro":
        if (
            isinstance(planned_duration_sec, bool)
            or not isinstance(planned_duration_sec, int)
            or planned_duration_sec <= 0
        ):
            raise FocusCommandError(
                "invalid_duration",
                "pomodoro requires a positive planned_duration_sec",
            )
    else:
        if planned_duration_sec is not None:
            raise FocusCommandError(
                "invalid_duration",
                "stopwatch must not have planned_duration_sec",
            )

    try:
        with get_db_connection() as conn:
            existing = _select_active_session(
                conn,
                UUID(user_id),
                for_update=True,
            )

            if existing is not None:
                raise FocusCommandError(
                    "active_session_exists",
                    "a focus session is already in progress",
                )

            row = conn.execute(
                """
                INSERT INTO focus_sessions (
                    id,
                    user_id,
                    type,
                    status,
                    title,
                    started_at,
                    planned_duration_sec,
                    total_pause_duration_sec,
                    runtime_state,
                    paused_at,
                    state_version,
                    state_updated_at,
                    initiated_by,
                    last_changed_by
                )
                VALUES (
                    %s,
                    %s,
                    %s,
                    'in_progress',
                    %s,
                    NOW(),
                    %s,
                    0,
                    'running',
                    NULL,
                    0,
                    NOW(),
                    %s,
                    %s
                )
                RETURNING *
                """,
                (
                    uuid4(),
                    UUID(user_id),
                    mode,
                    title,
                    planned_duration_sec,
                    source,
                    source,
                ),
            ).fetchone()

        return serialize_focus_session(row)

    except UniqueViolation:
        raise FocusCommandError(
            "active_session_exists",
            "a focus session is already in progress",
        )


def pause_focus_session(
    user_id: str,
    source: str,
    session_id: str,
    revision,
):
    _validate_source(source)

    with get_db_connection() as conn:
        row = _select_active_session(
            conn,
            UUID(user_id),
            for_update=True,
        )
        _validate_target(row, session_id, revision)

        if row["type"] != "stopwatch":
            raise FocusCommandError(
                "pause_not_allowed",
                "pomodoro cannot be paused",
            )

        if row["runtime_state"] != "running":
            raise FocusCommandError(
                "invalid_state",
                "the stopwatch is not running",
            )

        updated = conn.execute(
            """
            UPDATE focus_sessions
            SET
                runtime_state = 'paused',
                paused_at = NOW(),
                state_version = state_version + 1,
                state_updated_at = NOW(),
                last_changed_by = %s
            WHERE id = %s
            RETURNING *
            """,
            (
                source,
                row["id"],
            ),
        ).fetchone()

    return serialize_focus_session(updated)


def resume_focus_session(
    user_id: str,
    source: str,
    session_id: str,
    revision,
):
    _validate_source(source)

    with get_db_connection() as conn:
        row = _select_active_session(
            conn,
            UUID(user_id),
            for_update=True,
        )
        _validate_target(row, session_id, revision)

        if row["type"] != "stopwatch":
            raise FocusCommandError(
                "resume_not_allowed",
                "pomodoro cannot be resumed",
            )

        if (
            row["runtime_state"] != "paused"
            or row["paused_at"] is None
        ):
            raise FocusCommandError(
                "invalid_state",
                "the stopwatch is not paused",
            )

        conn.execute(
            """
            INSERT INTO focus_session_events (
                session_id,
                kind,
                started_at,
                ended_at
            )
            VALUES (
                %s,
                'pause',
                %s,
                NOW()
            )
            """,
            (
                row["id"],
                row["paused_at"],
            ),
        )

        updated = conn.execute(
            """
            UPDATE focus_sessions
            SET
                total_pause_duration_sec =
                    total_pause_duration_sec
                    + GREATEST(
                        0,
                        FLOOR(
                            EXTRACT(
                                EPOCH FROM (NOW() - paused_at)
                            )
                        )::integer
                    ),
                runtime_state = 'running',
                paused_at = NULL,
                state_version = state_version + 1,
                state_updated_at = NOW(),
                last_changed_by = %s
            WHERE id = %s
            RETURNING *
            """,
            (
                source,
                row["id"],
            ),
        ).fetchone()

    return serialize_focus_session(updated)


def end_focus_session(
    user_id: str,
    source: str,
    session_id: str,
    revision,
    outcome: str = "completed",
):
    _validate_source(source)

    if outcome not in FINAL_STATUSES:
        raise FocusCommandError(
            "invalid_outcome",
            "outcome must be completed, incomplete, or interrupted",
        )

    with get_db_connection() as conn:
        row = _select_active_session(
            conn,
            UUID(user_id),
            for_update=True,
        )
        _validate_target(row, session_id, revision)

        current_time = conn.execute(
            "SELECT clock_timestamp() AS current_time"
        ).fetchone()["current_time"]

        total_pause_duration_sec = row[
            "total_pause_duration_sec"
        ]

        if (
            row["type"] == "stopwatch"
            and row["runtime_state"] == "paused"
            and row["paused_at"] is not None
        ):
            paused_seconds = int(
                (
                    current_time.astimezone(timezone.utc)
                    - row["paused_at"].astimezone(timezone.utc)
                ).total_seconds()
            )

            total_pause_duration_sec += max(
                0,
                paused_seconds,
            )

            conn.execute(
                """
                INSERT INTO focus_session_events (
                    session_id,
                    kind,
                    started_at,
                    ended_at
                )
                VALUES (
                    %s,
                    'pause',
                    %s,
                    %s
                )
                """,
                (
                    row["id"],
                    row["paused_at"],
                    current_time,
                ),
            )

        elapsed_seconds = int(
            (
                current_time.astimezone(timezone.utc)
                - row["started_at"].astimezone(timezone.utc)
            ).total_seconds()
        )

        actual_duration_sec = max(
            0,
            elapsed_seconds - total_pause_duration_sec,
        )
        # 집중 세션 종료 시 열려 있는 졸음 및 휴대폰 감지도 함께 종료
        conn.execute(
            """
            UPDATE focus_session_events
            SET ended_at = %s
            WHERE
                session_id = %s
                AND ended_at IS NULL
                AND kind IN ('drowsy', 'phone')
            """,
            (
                current_time,
                row["id"],
            ),
        )
        
        updated = conn.execute(
            """
            UPDATE focus_sessions
            SET
                status = %s,
                ended_at = %s,
                actual_duration_sec = %s,
                total_pause_duration_sec = %s,
                runtime_state = NULL,
                paused_at = NULL,
                state_version = state_version + 1,
                state_updated_at = %s,
                last_changed_by = %s
            WHERE id = %s
            RETURNING *
            """,
            (
                outcome,
                current_time,
                actual_duration_sec,
                total_pause_duration_sec,
                current_time,
                source,
                row["id"],
            ),
        ).fetchone()

    return serialize_focus_session(updated)