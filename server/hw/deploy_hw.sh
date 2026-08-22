#!/usr/bin/env bash
# EC2 HW 음성 서버 배포 (deskibot-osaka)
#
#   bash server/hw/deploy_hw.sh [라벨]
#
# 라벨은 백업 디렉터리 이름에 붙는 메모다 (생략하면 manual).
#   bash server/hw/deploy_hw.sh clova-switch
#     → backups/20260822-152202-clova-switch
# 앞에 배포 시각이 붙으므로 같은 라벨을 재사용해도 백업이 겹치지 않는다.
#
# 백업 → 전송 → 설치 → import 검증 → 재시작 → health 확인 순으로 돌고,
# 재시작이나 health가 실패하면 백업으로 자동 롤백한다.
# .env와 Firebase 서비스 계정 파일은 건드리지 않는다.
set -euo pipefail

HOST=deskibot-osaka
APP=/home/ubuntu/Deskibot/server/hw
STAGE=/tmp/deskibot-hw-deploy
LABEL="${1:-manual}"                  # 이번 배포를 알아볼 이름 (인자로 넘긴다)
BACKUP="backups/$(date +%Y%m%d-%H%M%S)-$LABEL"   # 시각이 붙어 절대 겹치지 않는다
LOCAL="$(cd "$(dirname "$0")" && pwd)"

echo "── 1. 로컬 검증 ──────────────────────────────────────────"
cd "$LOCAL"
python3 -m py_compile app/*.py tools/*.py
python3 -m unittest test_todo_matching test_todo_add 2>&1 | tail -3

echo
echo "── 2. 전송 ───────────────────────────────────────────────"
ssh "$HOST" "mkdir -p $STAGE"
# app/ 을 통째로 옮긴다. 예전에는 파일을 하나씩 나열해서, 새 모듈을 만들고
# 여기 추가하는 걸 잊으면 서버가 기동조차 못 했다.
# --delete 는 쓰지 않는다 — 서버에만 있는 파일을 지우는 사고를 막는다.
rsync -av --exclude='__pycache__' app/ "$HOST:$STAGE/app/"
# common/ 은 hw·sw 가 함께 쓰는 모듈이라 앱 바깥(server/)에 있다.
# 한쪽만 배포하면 다른 쪽이 옛 코드를 보게 되므로 양쪽 스크립트가 모두 옮긴다.
rsync -av --exclude='__pycache__' ../common/ "$HOST:$STAGE/common/"
rsync -av --exclude='__pycache__' tools/ "$HOST:$STAGE/tools/"
rsync -av requirements.txt "$HOST:$STAGE/"

echo
echo "── 3. 백업 · 설치 · 재시작 ───────────────────────────────"
ssh "$HOST" APP="$APP" STAGE="$STAGE" BACKUP="$BACKUP" 'bash -seuo pipefail' <<'REMOTE'
cd "$APP"

# 이미 있는 백업은 덮지 않는다 (직전 롤백 지점 보존)
if [ -e "$BACKUP" ]; then
    echo "[backup] $BACKUP 이미 존재 — 그대로 둔다"
else
    mkdir -p "$BACKUP"
    cp -a requirements.txt "$BACKUP"/
    [ -e ../common ] && cp -a ../common "$BACKUP"/common || true
    # app/ 은 이번 배포에서 처음 생긴다(예전에는 파일이 평평하게 놓여 있었다).
    [ -e app ] && cp -a app "$BACKUP"/ || true
    for f in server.py voice_prompt.py audio_codec.py todo_matching.py todo_add.py; do
        [ -e "$f" ] && cp -a "$f" "$BACKUP"/ || true
    done
    echo "[backup] $BACKUP 생성 완료"
fi

mkdir -p app tools
rsync -a --exclude='__pycache__' "$STAGE/app/"   app/
mkdir -p ../common
rsync -a --exclude='__pycache__' "$STAGE/common/" ../common/
rsync -a --exclude='__pycache__' "$STAGE/tools/" tools/
chmod 750 tools/*
install -m 640 "$STAGE/requirements.txt" requirements.txt

# 평평하던 시절의 파일이 남아 있으면 지운다. 남겨두면 uvicorn 이 app/ 을 쓰는데
# 옛 server.py 가 옆에 있어, 어느 코드가 도는지 헷갈린다.
rm -f server.py voice_prompt.py audio_codec.py todo_matching.py todo_add.py \
      register_test_device.py seed_test_fixtures.py watch_todos.py

.venv/bin/pip install -q -r requirements.txt
.venv/bin/python -m py_compile app/*.py
# app.main 을 실제로 import 한다. 라우트 등록과 커넥션 풀 생성까지 여기서
# 걸러지므로, 문제가 있으면 서비스를 재시작하기 전에 실패한다.
.venv/bin/python -c 'from app.main import app; from app import voice_prompt, audio_codec; assert len(voice_prompt.TOOLS) == 4; assert audio_codec.ulaw_to_pcm16(bytes([0xFF])) == bytes(2); print(f"[check] import ok, 라우트 {len(app.routes)}개")'

rollback() {
    echo "[rollback] 실패 감지 — $BACKUP 으로 되돌린다" >&2
    rm -rf app
    [ -e "$BACKUP"/app ] && cp -a "$BACKUP"/app app || true
    # app/ 이전 버전으로 되돌리는 경우 평평한 파일들도 복원해야 한다
    for f in server.py voice_prompt.py audio_codec.py todo_matching.py todo_add.py; do
        [ -e "$BACKUP/$f" ] && cp -a "$BACKUP/$f" "$f" || true
    done
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
