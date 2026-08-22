#!/usr/bin/env python3
"""학생/직장인 통합 테스트 fixture를 PostgreSQL에 재현 가능하게 구성한다.

기본 실행은 전체 SQL과 제약을 검증한 뒤 롤백한다. 실제 적용에는 ``--apply``가
필요하다. 기존 학생 계정과 연결된 device/token은 변경하지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import secrets
from datetime import datetime, time, timedelta
from uuid import NAMESPACE_URL, UUID, uuid5
from zoneinfo import ZoneInfo

import psycopg
from dotenv import load_dotenv
from psycopg.types.json import Jsonb


KST = ZoneInfo("Asia/Seoul")
STUDENT_LOGIN = "deskibot_test"
WORKER_LOGIN = "deskibot_test_worker"
WORKER_DEVICE_UID = "deskibot-test-worker"


def stable_uuid(label: str) -> UUID:
    return uuid5(NAMESPACE_URL, f"https://deskibot.co.kr/test-fixture/{label}")


def db_config() -> dict:
    config = {
        "host": os.environ.get("DB_HOST", ""),
        "port": os.environ.get("DB_PORT", ""),
        "dbname": os.environ.get("DB_NAME", ""),
        "user": os.environ.get("DB_USER", ""),
        "password": os.environ.get("DB_PASSWORD", ""),
    }
    missing = [name for name, value in config.items() if not value]
    if missing:
        raise SystemExit("missing PostgreSQL settings: " + ", ".join(missing))
    try:
        config["port"] = int(config["port"])
    except ValueError as exc:
        raise SystemExit("DB_PORT must be an integer") from exc
    return config


def seed(apply: bool) -> dict[str, int | bool]:
    now = datetime.now(KST).replace(microsecond=0)
    today = now.date()
    worker_token_created = False

    conn = psycopg.connect(**db_config())
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, password_hash FROM users WHERE login_id = %s FOR UPDATE",
                (STUDENT_LOGIN,),
            )
            student = cur.fetchone()
            if student is None:
                raise RuntimeError(f"required existing user not found: {STUDENT_LOGIN}")
            student_id, student_password_hash = student
            cur.execute(
                """
                UPDATE users
                   SET user_type = 'student',
                       analysis_started_date = COALESCE(analysis_started_date, %s)
                 WHERE id = %s
                """,
                (today - timedelta(days=30), student_id),
            )

            cur.execute(
                "SELECT id FROM users WHERE login_id = %s FOR UPDATE",
                (WORKER_LOGIN,),
            )
            worker = cur.fetchone()
            if worker is None:
                cur.execute(
                    """
                    INSERT INTO users
                        (login_id, password_hash, name, user_type, analysis_started_date)
                    VALUES (%s, %s, %s, 'worker', %s)
                    RETURNING id
                    """,
                    (
                        WORKER_LOGIN,
                        student_password_hash,
                        "테스트 직장인",
                        today - timedelta(days=30),
                    ),
                )
                worker_id = cur.fetchone()[0]
            else:
                worker_id = worker[0]
                cur.execute(
                    """
                    UPDATE users
                       SET user_type = 'worker',
                           analysis_started_date = COALESCE(analysis_started_date, %s)
                     WHERE id = %s
                    """,
                    (today - timedelta(days=30), worker_id),
                )

            cur.execute("SELECT device_uid FROM devices WHERE user_id = %s", (student_id,))
            if cur.fetchone() is None:
                raise RuntimeError("existing student device link is required")

            cur.execute(
                "SELECT user_id FROM devices WHERE device_uid = %s FOR UPDATE",
                (WORKER_DEVICE_UID,),
            )
            worker_device = cur.fetchone()
            if worker_device is None:
                cur.execute("SELECT device_uid FROM devices WHERE user_id = %s", (worker_id,))
                if cur.fetchone() is not None:
                    raise RuntimeError("worker user is already linked to another device")
                worker_token = os.environ.get("WORKER_DEVICE_TOKEN", "")
                if not worker_token:
                    if apply:
                        raise RuntimeError("WORKER_DEVICE_TOKEN is required for first --apply")
                    worker_token = secrets.token_urlsafe(32)
                if len(worker_token) > 127 or any(
                    ord(ch) <= 0x20 or ord(ch) == 0x7F for ch in worker_token
                ):
                    raise RuntimeError("WORKER_DEVICE_TOKEN has an invalid format")
                token_hash = hashlib.sha256(worker_token.encode("utf-8")).hexdigest()
                cur.execute(
                    """
                    INSERT INTO devices (device_uid, user_id, token_hash, paired_at)
                    VALUES (%s, %s, %s, NOW())
                    """,
                    (WORKER_DEVICE_UID, worker_id, token_hash),
                )
                worker_token_created = True
            elif worker_device[0] != worker_id:
                raise RuntimeError("worker fixture device belongs to another user")

            user_ids = (student_id, worker_id)
            for table in (
                "stats_daily_timeslot",
                "stats_daily",
                "analysis_daily",
                "analysis_cumulative",
                "focus_sessions",
                "todos",
                "categories",
            ):
                cur.execute(
                    f"DELETE FROM {table} WHERE user_id IN (%s, %s)",
                    user_ids,
                )

            # '기타'는 모든 계정의 필수 카테고리다. 음성으로 할 일을 추가할 때
            # 분류가 애매하면 여기로 들어가므로 계정마다 반드시 하나 있어야 한다.
            category_rows = [
                (stable_uuid("student-category-study"), student_id, "학업", "#3B82F6", 0),
                (stable_uuid("student-category-schedule"), student_id, "일정", "#8B5CF6", 1),
                (stable_uuid("student-category-health"), student_id, "건강", "#10B981", 2),
                (stable_uuid("student-category-etc"), student_id, "기타", "#6B7280", 99),
                (stable_uuid("worker-category-work"), worker_id, "업무", "#2563EB", 0),
                (stable_uuid("worker-category-meeting"), worker_id, "회의", "#F59E0B", 1),
                (stable_uuid("worker-category-personal"), worker_id, "개인", "#14B8A6", 2),
                (stable_uuid("worker-category-etc"), worker_id, "기타", "#6B7280", 99),
            ]
            cur.executemany(
                """
                INSERT INTO categories (id, user_id, name, color, sort_order)
                VALUES (%s, %s, %s, %s, %s)
                """,
                category_rows,
            )
            # '기타'처럼 두 계정에 같은 이름이 있으므로 (user_id, name)으로 키를 잡는다.
            # 이름만 쓰면 뒤 사용자의 id가 앞 사용자를 덮어 cross-user 참조가 된다.
            category = {(row[1], row[2]): row[0] for row in category_rows}
            student_cat = lambda name: category[(student_id, name)]
            worker_cat  = lambda name: category[(worker_id, name)]

            todo_rows = [
                (student_id, student_cat("학업"), "수학 과제 제출", today, None, False, None, False),
                (student_id, student_cat("학업"), "영어 과제 제출", today, time(23, 59), True, 30, False),
                (student_id, student_cat("일정"), "보고서 제출", today, time(18, 0), False, None, False),
                (student_id, student_cat("건강"), "저녁 스트레칭", today, time(21, 0), True, 10, False),
                (student_id, student_cat("학업"), "완료된 독서 기록", today, None, False, None, True),
                (student_id, student_cat("학업"), "지난 과제", today - timedelta(days=1), None, False, None, False),
                (student_id, student_cat("일정"), "내일 수업 준비", today + timedelta(days=1), None, False, None, False),
                (worker_id, worker_cat("업무"), "주간 보고서 제출", today, time(17, 0), True, 30, False),
                (worker_id, worker_cat("업무"), "월간 보고서 제출", today, None, False, None, False),
                (worker_id, worker_cat("업무"), "보고서 제출", today, time(18, 0), False, None, False),
                (worker_id, worker_cat("회의"), "오후 팀 회의", today, time(15, 0), True, 10, False),
                (worker_id, worker_cat("개인"), "완료된 경비 정산", today, None, False, None, True),
                (worker_id, worker_cat("업무"), "지난주 후속 업무", today - timedelta(days=7), None, False, None, False),
                (worker_id, worker_cat("개인"), "내일 병원 예약", today + timedelta(days=1), time(10, 0), True, 60, False),
            ]
            cur.executemany(
                """
                INSERT INTO todos
                    (user_id, category_id, content, date, deadline_time,
                     notify, notify_before_min, is_done)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                todo_rows,
            )

            sessions = [
                (
                    stable_uuid("student-pomodoro-completed"), student_id, "pomodoro", "completed",
                    "과제 집중", now - timedelta(days=2, minutes=25), now - timedelta(days=2),
                    1500, 1500, 0, 2, "robot", "robot",
                ),
                (
                    stable_uuid("student-stopwatch-completed"), student_id, "stopwatch", "completed",
                    "자율 학습", now - timedelta(days=1, minutes=50), now - timedelta(days=1),
                    None, 2700, 300, 4, "app", "robot",
                ),
                (
                    stable_uuid("student-pomodoro-incomplete"), student_id, "pomodoro", "incomplete",
                    "짧은 복습", now - timedelta(hours=5, minutes=10), now - timedelta(hours=5),
                    1500, 600, 0, 1, "robot", "robot",
                ),
                (
                    stable_uuid("worker-pomodoro-completed"), worker_id, "pomodoro", "completed",
                    "문서 작업", now - timedelta(days=2, minutes=25), now - timedelta(days=2),
                    1500, 1500, 0, 2, "app", "robot",
                ),
                (
                    stable_uuid("worker-stopwatch-completed"), worker_id, "stopwatch", "completed",
                    "프로젝트 업무", now - timedelta(days=1, hours=1), now - timedelta(days=1),
                    None, 3300, 300, 4, "robot", "app",
                ),
                (
                    stable_uuid("worker-stopwatch-interrupted"), worker_id, "stopwatch", "interrupted",
                    "긴급 업무", now - timedelta(hours=4, minutes=20), now - timedelta(hours=4),
                    None, 1200, 0, 1, "robot", "robot",
                ),
            ]
            cur.executemany(
                """
                INSERT INTO focus_sessions
                    (id, user_id, type, status, title, started_at, ended_at,
                     planned_duration_sec, actual_duration_sec,
                     total_pause_duration_sec, runtime_state, paused_at,
                     state_version, initiated_by, last_changed_by)
                VALUES
                    (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                     NULL, NULL, %s, %s, %s)
                """,
                sessions,
            )

            session_by_name = {
                "student_stopwatch": stable_uuid("student-stopwatch-completed"),
                "student_pomodoro": stable_uuid("student-pomodoro-completed"),
                "worker_stopwatch": stable_uuid("worker-stopwatch-completed"),
                "worker_pomodoro": stable_uuid("worker-pomodoro-completed"),
            }
            event_rows = [
                (session_by_name["student_stopwatch"], "pause", now - timedelta(days=1, minutes=35), now - timedelta(days=1, minutes=30)),
                (session_by_name["student_stopwatch"], "drowsy", now - timedelta(days=1, minutes=20), now - timedelta(days=1, minutes=18)),
                (session_by_name["student_pomodoro"], "phone", now - timedelta(days=2, minutes=10), now - timedelta(days=2, minutes=9)),
                (session_by_name["worker_stopwatch"], "pause", now - timedelta(days=1, minutes=40), now - timedelta(days=1, minutes=35)),
                (session_by_name["worker_stopwatch"], "phone", now - timedelta(days=1, minutes=20), now - timedelta(days=1, minutes=15)),
                (session_by_name["worker_pomodoro"], "drowsy", now - timedelta(days=2, minutes=12), now - timedelta(days=2, minutes=10)),
            ]
            cur.executemany(
                """
                INSERT INTO focus_session_events (session_id, kind, started_at, ended_at)
                VALUES (%s, %s, %s, %s)
                """,
                event_rows,
            )

            stats_rows = [
                (student_id, today - timedelta(days=1), 1, 1500, 1, 2700, 1, 120, 1, 60, 6, 3),
                (student_id, today, 1, 600, 0, 0, 0, 0, 0, 0, 5, 1),
                (worker_id, today - timedelta(days=1), 1, 1500, 1, 3300, 0, 0, 1, 300, 6, 4),
                (worker_id, today, 0, 0, 1, 1200, 1, 120, 0, 0, 5, 1),
            ]
            cur.executemany(
                """
                INSERT INTO stats_daily
                    (user_id, date, pomodoro_count, pomodoro_duration_sec,
                     stopwatch_count, stopwatch_duration_sec, drowsy_count,
                     drowsy_duration_sec, phone_count, phone_duration_sec,
                     todo_total, todo_done)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                stats_rows,
            )

            timeslot_rows = []
            for user_id, base in ((student_id, 600), (worker_id, 900)):
                for index, slot in enumerate(("dawn", "morning", "afternoon", "night")):
                    timeslot_rows.append((user_id, today, slot, base + index * 300, index % 2, (index + 1) % 2))
            cur.executemany(
                """
                INSERT INTO stats_daily_timeslot
                    (user_id, date, slot, focus_duration_sec, drowsy_count, phone_count)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                timeslot_rows,
            )

            daily_analysis_rows = [
                (student_id, today - timedelta(days=1), "오후 집중력이 좋았습니다. 짧은 휴식을 유지해 보세요."),
                (student_id, today, "과제 우선순위를 정하고 한 번에 하나씩 진행해 보세요."),
                (worker_id, today - timedelta(days=1), "회의 전후의 집중 시간을 분리하면 효율이 좋아집니다."),
                (worker_id, today, "오후 업무 중 짧은 방해 요소를 줄여 보세요."),
            ]
            cur.executemany(
                "INSERT INTO analysis_daily (user_id, date, advice) VALUES (%s, %s, %s)",
                daily_analysis_rows,
            )

            cumulative_rows = [
                (student_id, "weekly", today - timedelta(days=6), today, "학업 집중 패턴이 안정적입니다.", Jsonb(["오후 집중 우수"]), Jsonb(["과제 전 5분 계획"])),
                (student_id, "monthly", today.replace(day=1), today, "월간 학습 루틴을 유지하고 있습니다.", Jsonb(["주중 집중 증가"]), Jsonb(["저녁 복습"])),
                (worker_id, "weekly", today - timedelta(days=6), today, "업무 집중과 회의 시간이 균형을 이루고 있습니다.", Jsonb(["오전 업무 우수"]), Jsonb(["회의 전 집중 블록"])),
                (worker_id, "monthly", today.replace(day=1), today, "월간 업무 흐름이 점차 안정되고 있습니다.", Jsonb(["오후 방해 증가"]), Jsonb(["알림 끄기"])),
            ]
            cur.executemany(
                """
                INSERT INTO analysis_cumulative
                    (user_id, period_type, period_start, period_end,
                     summary, patterns, routine)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                cumulative_rows,
            )

            expected = {
                "users": 2,
                "devices": 2,
                "categories": len(category_rows),
                "todos": len(todo_rows),
                "focus_sessions": len(sessions),
                "focus_events": len(event_rows),
                "stats_daily": len(stats_rows),
                "stats_timeslots": len(timeslot_rows),
                "analysis_daily": len(daily_analysis_rows),
                "analysis_cumulative": len(cumulative_rows),
            }
            validation_queries = {
                "users": "SELECT count(*) FROM users WHERE id IN (%s, %s)",
                "devices": "SELECT count(*) FROM devices WHERE user_id IN (%s, %s)",
                "categories": "SELECT count(*) FROM categories WHERE user_id IN (%s, %s)",
                "todos": "SELECT count(*) FROM todos WHERE user_id IN (%s, %s)",
                "focus_sessions": "SELECT count(*) FROM focus_sessions WHERE user_id IN (%s, %s)",
                "focus_events": """
                    SELECT count(*) FROM focus_session_events e
                    JOIN focus_sessions s ON s.id = e.session_id
                    WHERE s.user_id IN (%s, %s)
                """,
                "stats_daily": "SELECT count(*) FROM stats_daily WHERE user_id IN (%s, %s)",
                "stats_timeslots": "SELECT count(*) FROM stats_daily_timeslot WHERE user_id IN (%s, %s)",
                "analysis_daily": "SELECT count(*) FROM analysis_daily WHERE user_id IN (%s, %s)",
                "analysis_cumulative": "SELECT count(*) FROM analysis_cumulative WHERE user_id IN (%s, %s)",
            }
            for name, query in validation_queries.items():
                cur.execute(query, user_ids)
                actual = cur.fetchone()[0]
                if actual != expected[name]:
                    raise RuntimeError(f"fixture validation failed: {name}={actual}")

            cur.execute(
                """
                SELECT count(*)
                  FROM todos t
                  JOIN categories c ON c.id = t.category_id
                 WHERE t.user_id IN (%s, %s)
                   AND t.user_id <> c.user_id
                """,
                user_ids,
            )
            if cur.fetchone()[0] != 0:
                raise RuntimeError("cross-user category ownership detected")

        if apply:
            conn.commit()
        else:
            conn.rollback()
        return {**expected, "worker_token_created": worker_token_created, "applied": apply}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--env-file",
        default=".env",
        help="PostgreSQL 접속 설정을 읽을 dotenv 파일 (기본값: .env)",
    )
    parser.add_argument(
        "--worker-token-file",
        help="WORKER_DEVICE_TOKEN만 저장한 별도 dotenv 파일",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="검증 후 롤백하지 않고 fixture를 실제 반영",
    )
    args = parser.parse_args()
    load_dotenv(args.env_file)
    if args.worker_token_file:
        load_dotenv(args.worker_token_file, override=False)
    summary = seed(args.apply)
    mode = "applied" if args.apply else "dry-run rolled back"
    print(f"fixture {mode}")
    for name in sorted(summary):
        print(f"{name}={summary[name]}")


if __name__ == "__main__":
    main()
