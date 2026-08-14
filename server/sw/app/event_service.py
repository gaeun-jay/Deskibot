from uuid import UUID

from app.db import get_db_connection
from app.focus_service import FocusCommandError


DETECTION_KINDS = {
    "drowsy",
    "phone",
}


def serialize_detection_event(row):
    if row is None:
        return None

    return {
        "event_id": row["id"],
        "session_id": str(row["session_id"]),
        "kind": row["kind"],
        "started_at": row["started_at"].isoformat(),
        "ended_at": (
            row["ended_at"].isoformat()
            if row["ended_at"]
            else None
        ),
        "duration_sec": row["duration_sec"],
        "active": row["ended_at"] is None,
    }


def _validate_detection_kind(kind: str):
    if kind not in DETECTION_KINDS:
        raise FocusCommandError(
            "invalid_detection_kind",
            "kind must be drowsy or phone",
        )


def start_detection_event(
    user_id: str,
    kind: str,
):
    _validate_detection_kind(kind)

    with get_db_connection() as conn:
        session = conn.execute(
            """
            SELECT
                id,
                type,
                status,
                runtime_state
            FROM focus_sessions
            WHERE
                user_id = %s
                AND status = 'in_progress'
            LIMIT 1
            FOR UPDATE
            """,
            (UUID(user_id),),
        ).fetchone()

        if session is None:
            raise FocusCommandError(
                "no_active_session",
                "there is no active focus session",
            )

        if (
            session["type"] != "pomodoro"
            or session["runtime_state"] != "running"
        ):
            raise FocusCommandError(
                "detection_not_allowed",
                "detections are recorded only during pomodoro",
            )

        existing = conn.execute(
            """
            SELECT
                id,
                session_id,
                kind,
                started_at,
                ended_at,
                duration_sec
            FROM focus_session_events
            WHERE
                session_id = %s
                AND kind = %s
                AND ended_at IS NULL
            LIMIT 1
            """,
            (
                session["id"],
                kind,
            ),
        ).fetchone()

        # 같은 시작 신호가 반복되어도 이벤트를 중복 생성하지 않음
        if existing is not None:
            return serialize_detection_event(existing)

        event = conn.execute(
            """
            INSERT INTO focus_session_events (
                session_id,
                kind,
                started_at,
                ended_at
            )
            VALUES (
                %s,
                %s,
                NOW() - INTERVAL '10 seconds',
                NULL
            )
            RETURNING
                id,
                session_id,
                kind,
                started_at,
                ended_at,
                duration_sec
            """,
            (
                session["id"],
                kind,
            ),
        ).fetchone()

    return serialize_detection_event(event)


def end_detection_event(
    user_id: str,
    kind: str,
):
    _validate_detection_kind(kind)

    with get_db_connection() as conn:
        event = conn.execute(
            """
            SELECT
                e.id,
                e.session_id,
                e.kind,
                e.started_at,
                e.ended_at,
                e.duration_sec
            FROM focus_session_events AS e
            JOIN focus_sessions AS s
                ON s.id = e.session_id
            WHERE
                s.user_id = %s
                AND e.kind = %s
                AND e.ended_at IS NULL
            ORDER BY e.id DESC
            LIMIT 1
            FOR UPDATE OF e
            """,
            (
                UUID(user_id),
                kind,
            ),
        ).fetchone()

        # 이미 종료된 신호가 반복되어도 오류로 처리하지 않음
        if event is None:
            return None

        updated = conn.execute(
            """
            UPDATE focus_session_events
            SET ended_at = NOW() - INTERVAL '2 seconds'
            WHERE id = %s
            RETURNING
                id,
                session_id,
                kind,
                started_at,
                ended_at,
                duration_sec
            """,
            (event["id"],),
        ).fetchone()

    return serialize_detection_event(updated)