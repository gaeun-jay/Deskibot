import logging
from contextlib import contextmanager
from datetime import datetime, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from app.analysis_service import (
    AnalysisError,
    generate_cumulative_analysis,
    has_cumulative_analysis,
    resolve_period,
)
from app.daily_analysis_service import generate_daily_analysis, get_daily_analysis
from app.db import get_db_connection
from app.stats_service import KST, today_kst

logger = logging.getLogger(__name__)

_scheduler: BackgroundScheduler | None = None

# 이 시각(KST)이 지나면 전날 세션이 아직 진행 중이어도 더 기다리지 않고, 공부 일지를 생성함
WAIT_CUTOFF_HOUR = 6

# ── 중복 실행 방지 ───────────────────────────────────────────────────────────
#
# uvicorn 을 --workers 2 이상으로 띄우면 워커마다 이 스케줄러가 하나씩 뜬다.
# 같은 시각에 같은 sweep 이 동시에 돌면 유저마다 Claude 를 두 번 부른다.
# (analysis_* 는 ON CONFLICT 라 데이터는 안 깨지지만 비용이 그대로 배가 된다.)
#
# PostgreSQL advisory lock 으로 한 번에 하나만 통과시킨다. 세션에 걸리는 잠금이라
# 연결이 닫히면 자동으로 풀린다 — 워커가 중간에 죽어도 잠금이 남지 않는다.
# 워커뿐 아니라 서버를 여러 대로 늘려도 같은 DB 를 보면 그대로 동작한다.
_LOCK_NAMESPACE = 8722  # 다른 잠금과 겹치지 않게 SW 전용으로 정한 값

_LOCK_IDS = {
    "daily": 0,
    "weekly": 1,
    "monthly": 2,
    "quarterly": 3,
    "half_yearly": 4,
    "yearly": 5,
}


@contextmanager
def _sweep_lock(name: str):
    """이 sweep 을 지금 돌려도 되는지. 다른 워커가 이미 잡았으면 False 를 준다."""

    lock_id = _LOCK_IDS[name]

    with get_db_connection() as conn:
        acquired = conn.execute(
            "SELECT pg_try_advisory_lock(%s, %s) AS ok",
            (_LOCK_NAMESPACE, lock_id),
        ).fetchone()["ok"]

        try:
            yield acquired
        finally:
            if acquired:
                conn.execute(
                    "SELECT pg_advisory_unlock(%s, %s)",
                    (_LOCK_NAMESPACE, lock_id),
                )


def _all_user_ids() -> list[str]:
    with get_db_connection() as conn:
        rows = conn.execute("SELECT id FROM users").fetchall()
    return [str(row["id"]) for row in rows]


def _has_in_progress_session(user_id: str, on_date) -> bool:
    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT 1 FROM focus_sessions
            WHERE user_id = %s AND session_date = %s AND status = 'in_progress'
            LIMIT 1
            """,
            (user_id, on_date),
        ).fetchone()
    return row is not None


def run_daily_analysis_for_all_users() -> None:
    """전날(KST) 몫을 유저별로 생성한다. 한 명이 실패해도 나머지는 계속 진행."""

    with _sweep_lock("daily") as acquired:
        if not acquired:
            logger.info("daily analysis sweep skipped: another worker holds the lock")
            return

        _run_daily_analysis_sweep()


def _run_daily_analysis_sweep() -> None:
    now = datetime.now(KST)
    target_date = today_kst() - timedelta(days=1)  # 일간 공부일지에 사용되는 날짜
    past_cutoff = now.hour >= WAIT_CUTOFF_HOUR # 새벽 6시 제한
    user_ids = _all_user_ids()
    logger.info(
        "daily analysis sweep start: date=%s users=%d past_cutoff=%s",
        target_date,
        len(user_ids),
        past_cutoff,
    )

    ok = 0 # 이번에 새로 생성한 사람 수 
    already = 0 # 이미 일지가 있어서 조회하지 않은 사람 수
    waiting = 0 # 세션이 진행 중이라 건너뛴 사람 수
    skipped = 0 # 그날 활동이 아예 없어서 건너뛴 사람 수 
    for user_id in user_ids:
        try:
            if get_daily_analysis(user_id, target_date) is not None:
                already += 1
                continue

            if not past_cutoff and _has_in_progress_session(user_id, target_date):
                waiting += 1
                continue

            generate_daily_analysis(user_id, target_date)
            ok += 1
        except AnalysisError as error:
            if error.code == "no_data":
                skipped += 1
            else:
                logger.warning(
                    "daily analysis failed: user=%s date=%s code=%s",
                    user_id,
                    target_date,
                    error.code,
                )
        except Exception:
            logger.exception(
                "unexpected daily analysis error: user=%s date=%s",
                user_id,
                target_date,
            )

    logger.info(
        "daily analysis sweep done: date=%s ok=%d already=%d waiting=%d skipped=%d total=%d",
        target_date,
        ok,
        already,
        waiting,
        skipped,
        len(user_ids),
    )


def run_cumulative_analysis_for_all_users(period_type: str) -> None:
    """직전 달력 기간(지난주 / 지난달 / …) 몫을 유저별로 생성한다.

    한 명이 실패해도 나머지는 계속 진행한다. 이미 있으면 건너뛰므로 같은
    기간에 두 번 돌아도 Claude 를 다시 부르지 않는다.
    """

    with _sweep_lock(period_type) as acquired:
        if not acquired:
            logger.info(
                "cumulative sweep skipped: type=%s (another worker holds the lock)",
                period_type,
            )
            return

        _run_cumulative_sweep(period_type)


def _run_cumulative_sweep(period_type: str) -> None:
    period_start, period_end, _ = resolve_period(period_type)
    user_ids = _all_user_ids()
    logger.info(
        "cumulative sweep start: type=%s period=%s~%s users=%d",
        period_type,
        period_start,
        period_end,
        len(user_ids),
    )

    ok = 0        # 이번에 새로 생성한 사람 수
    already = 0   # 이미 그 기간 리포트가 있는 사람 수
    too_new = 0   # 그 기간을 통째로 겪지 않아 건너뛴 사람 수
    no_data = 0   # 기간 내 활동이 없어서 건너뛴 사람 수
    for user_id in user_ids:
        try:
            if has_cumulative_analysis(user_id, period_type, period_start):
                already += 1
                continue

            generate_cumulative_analysis(user_id, period_type)
            ok += 1
        except AnalysisError as error:
            if error.code == "period_not_covered":
                too_new += 1
            elif error.code == "no_data":
                no_data += 1
            else:
                logger.warning(
                    "cumulative analysis failed: user=%s type=%s code=%s",
                    user_id,
                    period_type,
                    error.code,
                )
        except Exception:
            logger.exception(
                "unexpected cumulative analysis error: user=%s type=%s",
                user_id,
                period_type,
            )

    logger.info(
        "cumulative sweep done: type=%s ok=%d already=%d too_new=%d "
        "no_data=%d total=%d",
        period_type,
        ok,
        already,
        too_new,
        no_data,
        len(user_ids),
    )


# 직전 달력 기간이 끝난 직후에 돈다. 일간 분석 sweep 이 06시 컷오프까지
# 전날 몫을 밀어넣으므로, 그보다 늦은 새벽 5시에 둬서 마지막 날 데이터가
# 빠지지 않게 한다.
CUMULATIVE_SCHEDULE = {
    # 매주 월요일 — 지난주 월~일
    "weekly": CronTrigger(day_of_week="mon", hour=5, minute=0, timezone=KST),
    # 매월 1일 — 지난달
    "monthly": CronTrigger(day=1, hour=5, minute=10, timezone=KST),
    # 1/4/7/10월 1일 — 지난 분기
    "quarterly": CronTrigger(
        month="1,4,7,10", day=1, hour=5, minute=20, timezone=KST
    ),
    # 1/7월 1일 — 지난 반기
    "half_yearly": CronTrigger(
        month="1,7", day=1, hour=5, minute=30, timezone=KST
    ),
    # 1월 1일 — 작년
    "yearly": CronTrigger(month=1, day=1, hour=5, minute=40, timezone=KST),
}


def start_scheduler() -> BackgroundScheduler:
    global _scheduler

    if _scheduler is not None:
        return _scheduler

    _scheduler = BackgroundScheduler(timezone=KST)
    _scheduler.add_job(
        run_daily_analysis_for_all_users,
        CronTrigger(minute=0, timezone=KST),
        id="daily_analysis_hourly",
        misfire_grace_time=1800,
        coalesce=True,
    )

    # 기간이 겹치는 날(1월 1일은 5개가 전부 해당된다)에도 Claude 호출이
    # 몰리지 않도록 10분씩 띄워 두었다.
    for period_type, trigger in CUMULATIVE_SCHEDULE.items():
        _scheduler.add_job(
            run_cumulative_analysis_for_all_users,
            trigger,
            args=[period_type],
            id=f"cumulative_analysis_{period_type}",
            misfire_grace_time=6 * 3600,
            coalesce=True,
        )

    _scheduler.start()
    logger.info(
        "scheduler started: daily(hourly) + cumulative(%s), KST",
        ", ".join(CUMULATIVE_SCHEDULE),
    )
    return _scheduler


def stop_scheduler() -> None:
    global _scheduler

    if _scheduler is not None:
        _scheduler.shutdown(wait=False)
        _scheduler = None
