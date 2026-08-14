#!/usr/bin/env bash
# 할 일 DB 실시간 모니터를 EC2에서 띄운다.
#
#   bash server/watch_todos.sh [갱신초]    # 기본 3초
#
# 읽기 전용이며 운영 서비스는 건드리지 않는다. Ctrl+C로 종료.
set -euo pipefail

HOST=deskibot-osaka
APP=/home/ubuntu/Deskibot/server/hw
LOCAL="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${1:-3}"

scp -q "$LOCAL/watch_todos.py" "$HOST:/tmp/watch_todos.py"
exec ssh -t "$HOST" "cd $APP && .venv/bin/python /tmp/watch_todos.py $INTERVAL"
