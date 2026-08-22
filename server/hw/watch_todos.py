#!/usr/bin/env python3
"""EC2에서 돌리는 할 일 실시간 모니터.

음성으로 추가/완료/삭제한 결과가 DB에 어떻게 들어갔는지 눈으로 확인하려고 만든
테스트 보조 도구다. 서비스와 무관하며 읽기만 한다.

    .venv/bin/python watch_todos.py [갱신초]

todos에는 생성 시각 컬럼이 없으므로, 시작 시점의 최대 id를 기억해 두고 그보다
큰 id를 이번 세션에서 새로 생긴 항목(NEW)으로 표시한다.
"""

import os
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone

from dotenv import load_dotenv
import psycopg
from psycopg.rows import dict_row

ENV_PATH = "/home/ubuntu/Deskibot/server/hw/.env"
KST = timezone(timedelta(hours=9))

DIM, RESET, GREEN, YELLOW, BOLD = "\033[2m", "\033[0m", "\033[32m", "\033[33m", "\033[1m"


def _width(text: str) -> int:
    """한글·이모지는 터미널에서 2칸을 먹는다."""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def pad(text: str, cells: int) -> str:
    """표시 폭 기준으로 자르고 오른쪽을 공백으로 채운다."""
    out = ""
    used = 0
    for ch in text:
        w = 2 if unicodedata.east_asian_width(ch) in "WF" else 1
        if used + w > cells:
            break
        out += ch
        used += w
    return out + " " * (cells - used)


def connect():
    load_dotenv(ENV_PATH)
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ["DB_PORT"]),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        row_factory=dict_row,
    )


QUERY = """
    SELECT t.id, u.name AS user_name, c.name AS category,
           t.content, t.date, t.deadline_time,
           t.notify, t.notify_before_min, t.is_done
      FROM todos t
      JOIN users u      ON u.id = t.user_id
      JOIN categories c ON c.id = t.category_id
     WHERE t.date BETWEEN CURRENT_DATE - 1 AND CURRENT_DATE + 7
     ORDER BY u.name, t.date, t.deadline_time NULLS LAST, t.id
"""


# (헤더, 표시 폭) — 한글이 섞이므로 폭은 문자 수가 아니라 셀 수 기준이다.
COLUMNS = [("계정", 14), ("날짜", 8), ("카테고리", 10), ("제목", 26),
           ("마감", 7), ("알림", 8), ("상태", 6)]


def render(rows, baseline_id, interval):
    today = datetime.now(KST).date()
    header = "   " + " ".join(pad(name, w) for name, w in COLUMNS)
    out = [
        f"{BOLD}Deskibot 할 일 실시간 모니터{RESET}  "
        f"{DIM}{datetime.now(KST):%Y-%m-%d %H:%M:%S} KST · {interval}초 갱신 · Ctrl+C 종료{RESET}",
        "",
        f"{DIM}{header}{RESET}",
        f"{DIM}{'─' * _width(header)}{RESET}",
    ]

    if not rows:
        out.append(f"{DIM}   (어제~일주일 뒤 범위에 할 일이 없습니다){RESET}")

    for r in rows:
        is_new = r["id"] > baseline_id

        if r["notify"] and r["notify_before_min"] is not None:
            notify = f"{r['notify_before_min']}분 전"
        else:
            notify = "없음"

        cells = [
            r["user_name"],
            "오늘" if r["date"] == today else f"{r['date']:%m-%d}",
            r["category"],
            r["content"] or "",
            f"{r['deadline_time']:%H:%M}" if r["deadline_time"] else "—",
            notify,
            "완료" if r["is_done"] else "미완료",
        ]
        body = " ".join(pad(text, w) for text, (_, w) in zip(cells, COLUMNS))
        mark = f"{GREEN}▶{RESET} " if is_new else "  "
        line = f"{mark} {body}"
        out.append(f"{GREEN}{line}{RESET}" if is_new else line)

    out += [
        "",
        f"{DIM}{GREEN}▶{DIM} = 모니터 시작 이후 새로 생긴 항목 "
        f"(기준 id > {baseline_id}){RESET}",
    ]
    return "\n".join(out)


def main():
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
    conn = connect()
    with conn.cursor() as cur:
        cur.execute("SELECT COALESCE(max(id), 0) AS m FROM todos")
        baseline_id = cur.fetchone()["m"]

    try:
        while True:
            with conn.cursor() as cur:
                cur.execute(QUERY)
                rows = cur.fetchall()
            conn.rollback()   # 스냅샷 고정 방지 — 다음 루프에서 새 커밋이 보이게 한다
            sys.stdout.write("\033[H\033[2J" + render(rows, baseline_id, interval) + "\n")
            sys.stdout.flush()
            time.sleep(interval)
    except KeyboardInterrupt:
        pass
    finally:
        conn.close()


if __name__ == "__main__":
    main()
