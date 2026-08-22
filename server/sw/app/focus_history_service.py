"""집중 세션 조회(과거 기록).

앱 lib/services/focus_session_service.dart 와 timetable_service 의
getFocusBlocksForDate / updateFocusLabel 을 대체한다.

실시간 세션 제어는 focus_service.py(WebSocket)가 담당하고, 여기서는 이미
기록된 세션을 읽기만 한다.

Firestore 는 세션 문서 안에 drowsy_events[] / phone_events[] 배열을 들고
있어서 앱이 직접 개수와 합을 계산했다. PostgreSQL 은 focus_session_events
테이블의 행이므로 여기서 집계해 내려준다.
"""

from datetime import date as date_type, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from app.db import get_db_connection


KST = ZoneInfo("Asia/Seoul")

DETECTION_KINDS = ("drowsy", "phone")


class FocusHistoryError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def today_kst() -> date_type:
    return datetime.now(KST).date()


def _hhmm(value):
    """timestamptz 를 KST 기준 'HH:MM' 로. 앱이 타임테이블에 쓰는 형식."""
    if value is None:
        return None
    return value.astimezone(KST).strftime("%H:%M")


def _empty_stat():
    return {
        "count": 0,
        "duration_sec": 0,
        "latest_at": None,
        "latest_duration_sec": 0,
    }


def _serialize_session(row, events):
    """세션 한 건 + 그 세션의 이벤트 목록을 앱이 쓰기 좋은 모양으로."""
    stats = {kind: _empty_stat() for kind in DETECTION_KINDS}
    pause_count = 0

    for event in events:
        kind = event["kind"]

        if kind == "pause":
            pause_count += 1
            continue

        if kind not in stats:
            continue

        stat = stats[kind]
        stat["count"] += 1
        stat["duration_sec"] += event["duration_sec"] or 0

        # 이벤트는 started_at 오름차순으로 들어오므로 마지막이 최신이다.
        stat["latest_at"] = _hhmm(event["started_at"])
        stat["latest_duration_sec"] = event["duration_sec"] or 0

    return {
        "session_id": str(row["id"]),
        "type": row["type"],
        "status": row["status"],
        "title": row["title"],
        "date": row["session_date"].isoformat() if row["session_date"] else None,
        "started_at": row["started_at"].isoformat(),
        "ended_at": row["ended_at"].isoformat() if row["ended_at"] else None,
        # 앱 타임테이블이 "HH:MM" 문자열을 기대한다. 기기 타임존에 흔들리지
        # 않도록 서버에서 KST 로 변환해 함께 내려준다.
        "start_time": _hhmm(row["started_at"]),
        "end_time": _hhmm(row["ended_at"]),
        "planned_duration_sec": row["planned_duration_sec"],
        "actual_duration_sec": row["actual_duration_sec"] or 0,
        "total_pause_duration_sec": row["total_pause_duration_sec"],
        "pause_count": pause_count,
        "runtime_state": row["runtime_state"],
        "revision": row["state_version"],
        "drowsy": stats["drowsy"],
        "phone": stats["phone"],
    }


_SESSION_COLUMNS = """
    id, user_id, type, status, title, session_date,
    started_at, ended_at,
    planned_duration_sec, actual_duration_sec, total_pause_duration_sec,
    runtime_state, state_version
"""


def list_sessions(user_id: UUID, on_date: date_type | None = None):
    on_date = on_date or today_kst()

    with get_db_connection() as conn:
        sessions = conn.execute(
            f"""
            SELECT {_SESSION_COLUMNS}
            FROM focus_sessions
            WHERE user_id = %s AND session_date = %s
            ORDER BY started_at
            """,
            (user_id, on_date),
        ).fetchall()

        events_by_session = {}

        if sessions:
            rows = conn.execute(
                """
                SELECT session_id, kind, started_at, ended_at, duration_sec
                FROM focus_session_events
                WHERE session_id = ANY(%s)
                ORDER BY started_at, id
                """,
                ([s["id"] for s in sessions],),
            ).fetchall()

            for row in rows:
                events_by_session.setdefault(row["session_id"], []).append(row)

    return {
        "date": on_date.isoformat(),
        "sessions": [
            _serialize_session(s, events_by_session.get(s["id"], []))
            for s in sessions
        ],
    }


def get_session(user_id: UUID, session_id: UUID):
    with get_db_connection() as conn:
        row = conn.execute(
            f"""
            SELECT {_SESSION_COLUMNS}
            FROM focus_sessions
            WHERE id = %s AND user_id = %s
            """,
            (session_id, user_id),
        ).fetchone()

        if row is None:
            raise FocusHistoryError(
                "session_not_found",
                "that focus session does not exist",
            )

        events = conn.execute(
            """
            SELECT session_id, kind, started_at, ended_at, duration_sec
            FROM focus_session_events
            WHERE session_id = %s
            ORDER BY started_at, id
            """,
            (session_id,),
        ).fetchall()

    return _serialize_session(row, events)


def update_session_title(user_id: UUID, session_id: UUID, title):
    """앱 타임테이블에서 세션 제목을 바꾸는 기능.

    스키마가 빈 문자열을 거부하므로(CHECK btrim(title) <> '') 공백만 들어오면
    NULL 로 저장한다.
    """
    if title is not None:
        title = str(title).strip() or None

    with get_db_connection() as conn:
        row = conn.execute(
            f"""
            UPDATE focus_sessions
            SET title = %s
            WHERE id = %s AND user_id = %s
            RETURNING {_SESSION_COLUMNS}
            """,
            (title, session_id, user_id),
        ).fetchone()

        if row is None:
            raise FocusHistoryError(
                "session_not_found",
                "that focus session does not exist",
            )

        events = conn.execute(
            """
            SELECT session_id, kind, started_at, ended_at, duration_sec
            FROM focus_session_events
            WHERE session_id = %s
            ORDER BY started_at, id
            """,
            (session_id,),
        ).fetchall()

    return _serialize_session(row, events)
