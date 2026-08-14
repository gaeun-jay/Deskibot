"""일간 통계 집계.

focus_sessions / focus_session_events / todos 를 원천으로
stats_daily 와 stats_daily_timeslot 을 만들어낸다.

지금까지 이 로직이 서버 어디에도 없어서 두 테이블은 시드 데이터만 들어 있었다.
누적 분석(analysis_service)이 stats_daily 를 읽으므로 이게 먼저 있어야 한다.

전략은 '읽을 때 다시 계산해서 저장'이다. 스케줄러나 트리거 없이도 항상
원천과 일치하고, 동시에 테이블이 채워져 분석 기능이 쓸 수 있게 된다.
데이터 규모가 작아서(하루 수십 행) 비용도 무시할 만하다.

시간대 구분은 스키마 주석을 따른다.
  dawn 00-06 / morning 06-12 / afternoon 12-18 / night 18-24
  세션과 이벤트는 '시작 시각'(KST)이 속한 슬롯 하나에만 잡힌다.
"""

from datetime import date as date_type, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from app.db import get_db_connection


KST = ZoneInfo("Asia/Seoul")

SLOTS = ("dawn", "morning", "afternoon", "night")

# started_at 을 KST 로 바꿔 슬롯 이름으로 만드는 식. 여러 쿼리에서 재사용한다.
_SLOT_EXPR = """
    CASE
        WHEN EXTRACT(HOUR FROM {col} AT TIME ZONE 'Asia/Seoul') < 6  THEN 'dawn'
        WHEN EXTRACT(HOUR FROM {col} AT TIME ZONE 'Asia/Seoul') < 12 THEN 'morning'
        WHEN EXTRACT(HOUR FROM {col} AT TIME ZONE 'Asia/Seoul') < 18 THEN 'afternoon'
        ELSE 'night'
    END
"""


class StatsError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def today_kst() -> date_type:
    return datetime.now(KST).date()


def _empty_daily():
    return {
        "pomodoro_count": 0,
        "pomodoro_duration_sec": 0,
        "stopwatch_count": 0,
        "stopwatch_duration_sec": 0,
        "drowsy_count": 0,
        "drowsy_duration_sec": 0,
        "phone_count": 0,
        "phone_duration_sec": 0,
        "todo_total": 0,
        "todo_done": 0,
    }


def _compute(conn, user_id: UUID, on_date: date_type):
    """원천 테이블에서 하루치 수치를 계산한다. 쓰지는 않는다."""
    totals = _empty_daily()

    # 세션 — 끝난 것만 센다. 진행 중인 세션은 actual_duration_sec 가 없다.
    row = conn.execute(
        """
        SELECT
            count(*) FILTER (WHERE type = 'pomodoro')  AS p_cnt,
            COALESCE(sum(actual_duration_sec)
                     FILTER (WHERE type = 'pomodoro'), 0) AS p_dur,
            count(*) FILTER (WHERE type = 'stopwatch') AS s_cnt,
            COALESCE(sum(actual_duration_sec)
                     FILTER (WHERE type = 'stopwatch'), 0) AS s_dur
        FROM focus_sessions
        WHERE user_id = %s
          AND session_date = %s
          AND status <> 'in_progress'
        """,
        (user_id, on_date),
    ).fetchone()

    totals["pomodoro_count"] = row["p_cnt"]
    totals["pomodoro_duration_sec"] = int(row["p_dur"])
    totals["stopwatch_count"] = row["s_cnt"]
    totals["stopwatch_duration_sec"] = int(row["s_dur"])

    # 감지 이벤트 — 아직 안 끝난 이벤트는 duration_sec 가 NULL 이므로 0으로 본다.
    row = conn.execute(
        """
        SELECT
            count(*) FILTER (WHERE e.kind = 'drowsy') AS d_cnt,
            COALESCE(sum(e.duration_sec)
                     FILTER (WHERE e.kind = 'drowsy'), 0) AS d_dur,
            count(*) FILTER (WHERE e.kind = 'phone')  AS ph_cnt,
            COALESCE(sum(e.duration_sec)
                     FILTER (WHERE e.kind = 'phone'), 0)  AS ph_dur
        FROM focus_session_events e
        JOIN focus_sessions s ON s.id = e.session_id
        WHERE s.user_id = %s AND s.session_date = %s
        """,
        (user_id, on_date),
    ).fetchone()

    totals["drowsy_count"] = row["d_cnt"]
    totals["drowsy_duration_sec"] = int(row["d_dur"])
    totals["phone_count"] = row["ph_cnt"]
    totals["phone_duration_sec"] = int(row["ph_dur"])

    # 할 일
    row = conn.execute(
        """
        SELECT count(*) AS total,
               count(*) FILTER (WHERE is_done) AS done
        FROM todos
        WHERE user_id = %s AND date = %s
        """,
        (user_id, on_date),
    ).fetchone()

    totals["todo_total"] = row["total"]
    totals["todo_done"] = row["done"]

    # 시간대별
    slots = {
        s: {"focus_duration_sec": 0, "drowsy_count": 0, "phone_count": 0}
        for s in SLOTS
    }

    for row in conn.execute(
        f"""
        SELECT {_SLOT_EXPR.format(col='started_at')} AS slot,
               COALESCE(sum(actual_duration_sec), 0) AS dur
        FROM focus_sessions
        WHERE user_id = %s
          AND session_date = %s
          AND status <> 'in_progress'
        GROUP BY 1
        """,
        (user_id, on_date),
    ).fetchall():
        slots[row["slot"]]["focus_duration_sec"] = int(row["dur"])

    for row in conn.execute(
        f"""
        SELECT {_SLOT_EXPR.format(col='e.started_at')} AS slot,
               count(*) FILTER (WHERE e.kind = 'drowsy') AS d_cnt,
               count(*) FILTER (WHERE e.kind = 'phone')  AS ph_cnt
        FROM focus_session_events e
        JOIN focus_sessions s ON s.id = e.session_id
        WHERE s.user_id = %s AND s.session_date = %s
        GROUP BY 1
        """,
        (user_id, on_date),
    ).fetchall():
        slots[row["slot"]]["drowsy_count"] = row["d_cnt"]
        slots[row["slot"]]["phone_count"] = row["ph_cnt"]

    return totals, slots


def rebuild_daily_stats(conn, user_id: UUID, on_date: date_type):
    """하루치를 다시 계산해 stats_daily / stats_daily_timeslot 에 반영한다.

    호출자가 트랜잭션(conn)을 넘긴다. 여러 날짜를 한 번에 돌릴 때
    커넥션을 재사용하기 위해서다.
    """
    totals, slots = _compute(conn, user_id, on_date)

    conn.execute(
        """
        INSERT INTO stats_daily (
            user_id, date,
            pomodoro_count, pomodoro_duration_sec,
            stopwatch_count, stopwatch_duration_sec,
            drowsy_count, drowsy_duration_sec,
            phone_count, phone_duration_sec,
            todo_total, todo_done
        )
        VALUES (
            %(user_id)s, %(date)s,
            %(pomodoro_count)s, %(pomodoro_duration_sec)s,
            %(stopwatch_count)s, %(stopwatch_duration_sec)s,
            %(drowsy_count)s, %(drowsy_duration_sec)s,
            %(phone_count)s, %(phone_duration_sec)s,
            %(todo_total)s, %(todo_done)s
        )
        ON CONFLICT (user_id, date) DO UPDATE SET
            pomodoro_count         = EXCLUDED.pomodoro_count,
            pomodoro_duration_sec  = EXCLUDED.pomodoro_duration_sec,
            stopwatch_count        = EXCLUDED.stopwatch_count,
            stopwatch_duration_sec = EXCLUDED.stopwatch_duration_sec,
            drowsy_count           = EXCLUDED.drowsy_count,
            drowsy_duration_sec    = EXCLUDED.drowsy_duration_sec,
            phone_count            = EXCLUDED.phone_count,
            phone_duration_sec     = EXCLUDED.phone_duration_sec,
            todo_total             = EXCLUDED.todo_total,
            todo_done              = EXCLUDED.todo_done
        """,
        {"user_id": user_id, "date": on_date, **totals},
    )

    # 값이 전부 0인 슬롯은 행을 두지 않는다. 이전 계산에서 남았을 수 있으니
    # 먼저 지우고 필요한 것만 다시 넣는다.
    conn.execute(
        "DELETE FROM stats_daily_timeslot WHERE user_id = %s AND date = %s",
        (user_id, on_date),
    )

    for slot, values in slots.items():
        if not any(values.values()):
            continue

        conn.execute(
            """
            INSERT INTO stats_daily_timeslot (
                user_id, date, slot,
                focus_duration_sec, drowsy_count, phone_count
            )
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (
                user_id,
                on_date,
                slot,
                values["focus_duration_sec"],
                values["drowsy_count"],
                values["phone_count"],
            ),
        )

    return totals, slots


def rebuild_active_dates(conn, user_id: UUID, start: date_type, end: date_type):
    """기간 안에서 '활동이 있었던 날짜'만 골라 다시 계산한다.

    누적 분석은 최대 365일을 훑는데 대부분은 빈 날이다. 전부 재계산하면
    쿼리가 수천 번 나가므로, 세션이나 할 일이 실제로 있는 날만 손본다.
    """
    rows = conn.execute(
        """
        SELECT DISTINCT d FROM (
            SELECT session_date AS d FROM focus_sessions
             WHERE user_id = %(uid)s AND session_date BETWEEN %(a)s AND %(b)s
            UNION
            SELECT date AS d FROM todos
             WHERE user_id = %(uid)s AND date BETWEEN %(a)s AND %(b)s
        ) x
        WHERE d IS NOT NULL
        ORDER BY d
        """,
        {"uid": user_id, "a": start, "b": end},
    ).fetchall()

    for row in rows:
        rebuild_daily_stats(conn, user_id, row["d"])

    return [row["d"] for row in rows]


def _serialize(on_date: date_type, totals, slots):
    focus_total = (
        totals["pomodoro_duration_sec"] + totals["stopwatch_duration_sec"]
    )

    return {
        "date": on_date.isoformat(),
        **totals,
        "focus_duration_sec": focus_total,
        "time_slots": slots,
    }


def get_daily_stats(user_id: UUID, on_date: date_type | None = None):
    """하루치 통계. 읽기 전에 원천에서 다시 계산해 저장한다."""
    on_date = on_date or today_kst()

    with get_db_connection() as conn:
        totals, slots = rebuild_daily_stats(conn, user_id, on_date)

    return _serialize(on_date, totals, slots)


def get_stats_range(
    user_id: UUID,
    start: date_type,
    end: date_type,
    rebuild: bool = True,
):
    """기간 통계. 누적 분석이 쓴다."""
    if end < start:
        raise StatsError("invalid_range", "end must not be before start")

    if (end - start).days > 366:
        raise StatsError("range_too_long", "range must be 366 days or fewer")

    days = []

    with get_db_connection() as conn:
        cursor = start

        while cursor <= end:
            if rebuild:
                totals, slots = rebuild_daily_stats(conn, user_id, cursor)
            else:
                totals, slots = _compute(conn, user_id, cursor)

            days.append(_serialize(cursor, totals, slots))
            cursor += timedelta(days=1)

    return {
        "start": start.isoformat(),
        "end": end.isoformat(),
        "days": days,
    }
