#!/usr/bin/env python3
"""앱↔로봇 E2E 테스트용 DB 실시간 모니터.

집중 세션·감지 이벤트·할 일을 한 화면에서 본다. 읽기 전용이다.

watch_todos.py 가 할 일만 보는 것과 달리, 여기서는 앱과 로봇이 서로를 보고
있는지 확인하는 데 필요한 것들을 함께 띄운다. 특히 다음 세 가지다.

  status / runtime_state   status 는 생명주기(in_progress/completed)라
                           일시정지 중에도 in_progress 다. 일시정지 여부는
                           runtime_state 에만 있다. 이걸 혼동하면 pause 를
                           무한 재전송하는 버그가 난다.
  initiated_by / last_changed_by
                           누가 시작했고 마지막으로 누가 바꿨는지. app 에서
                           시작한 세션을 robot 이 일시정지하면 양방향이
                           도는 것이다.
  revision                 낙관적 잠금. 명령이 반영되면 올라간다.

사용: python3 watch_e2e.py [갱신초] [login_id]
"""

import os
import sys
import time
from datetime import datetime, timedelta, timezone

import psycopg
from dotenv import load_dotenv
from psycopg.rows import dict_row

ENV_PATH = "/home/ubuntu/Deskibot/server/hw/.env"
KST = timezone(timedelta(hours=9))

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
RED = "\033[31m"


def connect():
    load_dotenv(ENV_PATH)
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        row_factory=dict_row,
        application_name="deskibot-watch",
    )


def hhmm(ts):
    return ts.astimezone(KST).strftime("%H:%M:%S") if ts else "-"


def fetch(cur, login_id):
    cur.execute("SELECT id, login_id, name FROM users WHERE login_id = %s", (login_id,))
    user = cur.fetchone()
    if user is None:
        return None
    uid = user["id"]

    # 활성 세션. 없으면 가장 최근 것을 보여준다 — 방금 끝난 세션의 결과를
    # 확인하고 싶은 경우가 대부분이다.
    cur.execute(
        """
        SELECT id, type, status, runtime_state, revision_or_version AS revision,
               initiated_by, last_changed_by, started_at, ended_at, paused_at,
               planned_duration_sec, total_pause_duration_sec
          FROM (
            SELECT f.*, f.state_version AS revision_or_version
              FROM focus_sessions f
             WHERE f.user_id = %s
             ORDER BY f.started_at DESC
             LIMIT 1
          ) s
        """,
        (uid,),
    )
    session = cur.fetchone()

    events = []
    if session:
        cur.execute(
            """
            SELECT kind, started_at, ended_at, duration_sec
              FROM focus_session_events
             WHERE session_id = %s
             ORDER BY started_at DESC
             LIMIT 6
            """,
            (session["id"],),
        )
        events = cur.fetchall()

    cur.execute(
        """
        SELECT content, deadline_time, notify, notify_before_min, is_done
          FROM todos
         WHERE user_id = %s AND date = (now() AT TIME ZONE 'Asia/Seoul')::date
         ORDER BY deadline_time NULLS LAST, id
         LIMIT 12
        """,
        (uid,),
    )
    todos = cur.fetchall()
    return {"user": user, "session": session, "events": events, "todos": todos}


def render(d, interval, changed):
    out = []
    now = datetime.now(KST).strftime("%H:%M:%S")
    u = d["user"]
    mark = f"  {YELLOW}● 변화{RESET}" if changed else ""
    out.append(f"{BOLD}Deskibot E2E 모니터{RESET}  {u['login_id']} ({u['name']})"
               f"   {DIM}{now} · {interval}초 갱신 · Ctrl+C 종료{RESET}{mark}")
    out.append("")

    s = d["session"]
    out.append(f"{BOLD}집중 세션{RESET}")
    if s is None:
        out.append(f"  {DIM}없음{RESET}")
    else:
        live = s["status"] == "in_progress"
        color = GREEN if live else DIM
        # status 와 runtime_state 를 나란히 둔다. 둘을 혼동하는 것이 이 프로젝트의
        # 대표적인 함정이라 화면에서도 붙여 놓는다.
        rs = s["runtime_state"] or "-"
        rs_col = YELLOW if rs == "paused" else GREEN if rs == "running" else DIM
        out.append(f"  {color}{s['type']}{RESET}"
                   f"   status={color}{s['status']}{RESET}"
                   f"   runtime={rs_col}{rs}{RESET}"
                   f"   revision={CYAN}{s['revision']}{RESET}")
        out.append(f"  {DIM}시작{RESET} {hhmm(s['started_at'])}"
                   f"   {DIM}종료{RESET} {hhmm(s['ended_at'])}"
                   f"   {DIM}일시정지{RESET} {hhmm(s['paused_at'])}"
                   f"   {DIM}누적정지{RESET} {s['total_pause_duration_sec']}초")
        # 양방향이 도는지 보는 자리다. app 이 시작하고 robot 이 바꿨으면 성공.
        ib, lb = s["initiated_by"], s["last_changed_by"]
        both = ib != lb
        out.append(f"  {DIM}시작 주체{RESET} {CYAN}{ib}{RESET}"
                   f"   {DIM}최종 변경{RESET} {CYAN}{lb}{RESET}"
                   + (f"   {GREEN}← 양방향 확인{RESET}" if both else ""))
        if s["planned_duration_sec"]:
            out.append(f"  {DIM}계획{RESET} {s['planned_duration_sec']//60}분")
    out.append("")

    out.append(f"{BOLD}세션 이벤트{RESET} {DIM}(최근 6){RESET}")
    if not d["events"]:
        out.append(f"  {DIM}없음{RESET}")
    for e in d["events"]:
        open_mark = f"{RED}진행 중{RESET}" if e["ended_at"] is None else f"{e['duration_sec']}초"
        kc = YELLOW if e["kind"] in ("drowsy", "phone") else DIM
        out.append(f"  {kc}{e['kind']:<8}{RESET} {hhmm(e['started_at'])} → "
                   f"{hhmm(e['ended_at'])}  {open_mark}")
    out.append("")

    out.append(f"{BOLD}오늘 할 일{RESET}")
    if not d["todos"]:
        out.append(f"  {DIM}없음{RESET}")
    for t in d["todos"]:
        done = f"{GREEN}✓{RESET}" if t["is_done"] else " "
        dl = t["deadline_time"].strftime("%H:%M") if t["deadline_time"] else "  -  "
        # 로봇이 알림을 띄우는 조건과 같게 표시한다 — notify 가 켜져 있고
        # 마감·사전알림이 모두 있어야 /hw/todos 응답에 알림 필드가 실린다.
        alert = (f"{YELLOW}🔔 {t['notify_before_min']}분 전{RESET}"
                 if t["notify"] and t["deadline_time"] and t["notify_before_min"] is not None
                 else "")
        out.append(f"  {done} {dl}  {t['content'][:36]:<36} {alert}")

    return "\n".join(out)


def main():
    interval = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    login_id = sys.argv[2] if len(sys.argv) > 2 else "test1"
    prev = None
    with connect() as conn:
        with conn.cursor() as cur:
            while True:
                d = fetch(cur, login_id)
                conn.rollback()          # 읽기 전용 — 트랜잭션을 열어두지 않는다
                if d is None:
                    print(f"계정을 찾을 수 없습니다: {login_id}")
                    return
                snap = repr(d)
                changed = prev is not None and snap != prev
                prev = snap
                print("\033[2J\033[H" + render(d, interval, changed), flush=True)
                time.sleep(interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n종료")
