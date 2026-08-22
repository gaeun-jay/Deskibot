import logging
from datetime import datetime, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from app.analysis_service import AnalysisError
from app.daily_analysis_service import generate_daily_analysis, get_daily_analysis
from app.db import get_db_connection
from app.stats_service import KST, today_kst

logger = logging.getLogger(__name__)

_scheduler: BackgroundScheduler | None = None

# 이 시각(KST)이 지나면 전날 세션이 아직 진행 중이어도 더 기다리지 않고, 공부 일지를 생성함
WAIT_CUTOFF_HOUR = 6


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
    _scheduler.start()
    logger.info("daily analysis scheduler started (hourly, on the hour, KST)")
    return _scheduler


def stop_scheduler() -> None:
    global _scheduler

    if _scheduler is not None:
        _scheduler.shutdown(wait=False)
        _scheduler = None
