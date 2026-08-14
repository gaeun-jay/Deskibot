#!/usr/bin/env bash
# EC2 HW 음성 서버 배포 (deskibot-osaka)
#
#   bash server/deploy_hw.sh
#
# 백업 → 전송 → 설치 → import 검증 → 재시작 → health 확인 순으로 돌고,
# 재시작이나 health가 실패하면 백업으로 자동 롤백한다.
# .env와 Firebase 서비스 계정 파일은 건드리지 않는다.
set -euo pipefail

HOST=deskibot-osaka
APP=/home/ubuntu/Deskibot/server/hw
STAGE=/tmp/deskibot-hw-deploy
BACKUP="backups/pre-voice-add-todo"      # 배포 건마다 새 이름을 쓸 것
LOCAL="$(cd "$(dirname "$0")" && pwd)"

echo "── 1. 로컬 검증 ──────────────────────────────────────────"
cd "$LOCAL"
python3 -m py_compile server.py todo_matching.py todo_add.py register_test_device.py
python3 -m unittest test_todo_matching test_todo_add 2>&1 | tail -3

echo
echo "── 2. 전송 ───────────────────────────────────────────────"
ssh "$HOST" "mkdir -p $STAGE"
rsync -av \
    server.py todo_matching.py todo_add.py requirements.txt register_test_device.py \
    "$HOST:$STAGE/"

echo
echo "── 3. 백업 · 설치 · 재시작 ───────────────────────────────"
ssh "$HOST" APP="$APP" STAGE="$STAGE" BACKUP="$BACKUP" 'bash -seuo pipefail' <<'REMOTE'
cd "$APP"

# 이미 있는 백업은 덮지 않는다 (직전 롤백 지점 보존)
if [ -e "$BACKUP" ]; then
    echo "[backup] $BACKUP 이미 존재 — 그대로 둔다"
else
    mkdir -p "$BACKUP"
    cp -a server.py todo_matching.py requirements.txt "$BACKUP"/
    echo "[backup] $BACKUP 생성 완료"
fi

install -m 640 "$STAGE/server.py"             server.py
install -m 640 "$STAGE/todo_matching.py"      todo_matching.py
install -m 640 "$STAGE/todo_add.py"           todo_add.py
install -m 640 "$STAGE/requirements.txt"      requirements.txt
install -m 750 "$STAGE/register_test_device.py" register_test_device.py

.venv/bin/pip install -q -r requirements.txt
.venv/bin/python -m py_compile server.py todo_matching.py todo_add.py
.venv/bin/python -c 'import todo_add, todo_matching; print("[check] import ok")'

rollback() {
    echo "[rollback] 실패 감지 — $BACKUP 으로 되돌린다" >&2
    cp -a "$BACKUP"/server.py        server.py
    cp -a "$BACKUP"/todo_matching.py todo_matching.py
    cp -a "$BACKUP"/requirements.txt requirements.txt
    sudo systemctl restart deskibot-hw.service || true
    sudo systemctl status deskibot-hw.service --no-pager || true
    exit 1
}

sudo systemctl restart deskibot-hw.service || rollback
sleep 3
sudo systemctl is-active --quiet deskibot-hw.service || rollback
curl -fsS http://127.0.0.1:8000/health >/dev/null || rollback

echo "[check] 서비스 active + health ok"
sudo journalctl -u deskibot-hw.service -n 30 --no-pager
REMOTE

echo
echo "── 4. 공개 API 확인 ──────────────────────────────────────"
printf 'health          : '; curl -fsS https://api.deskibot.co.kr/hw/health; echo
printf 'no token   (401): '; curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://api.deskibot.co.kr/hw/process
printf 'bad token  (401): '; curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'X-Device-Key: invalid-test-token' https://api.deskibot.co.kr/hw/process

echo
echo "✅ 배포 완료. 로봇에 대고 말한 뒤 아래로 로그를 보세요:"
echo "   ssh $HOST 'sudo journalctl -u deskibot-hw.service -f'"
