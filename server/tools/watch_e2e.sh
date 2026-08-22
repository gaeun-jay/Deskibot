#!/usr/bin/env bash
# 앱↔로봇 E2E 모니터를 EC2 에서 띄운다.
#
#   bash server/tools/watch_e2e.sh [갱신초] [계정]     # 기본 3초, test1
#
# 집중 세션·감지 이벤트·할 일을 한 화면에서 본다. 읽기 전용이며 운영 서비스를
# 건드리지 않는다. Ctrl+C 로 종료.
set -euo pipefail

HOST=deskibot-osaka
VENV=/home/ubuntu/Deskibot/server/hw/.venv/bin/python
LOCAL="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${1:-3}"
LOGIN="${2:-test1}"

scp -q "$LOCAL/watch_e2e.py" "$HOST:/tmp/watch_e2e.py"
exec ssh -t "$HOST" "$VENV /tmp/watch_e2e.py $INTERVAL $LOGIN"
