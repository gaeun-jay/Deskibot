#!/usr/bin/env bash
# EC2 HW 음성 서버 배포 (deskibot-osaka)
#
#   bash server/deploy_hw.sh [라벨]
#
# 라벨은 백업 디렉터리 이름에 붙는 메모다 (생략하면 manual).
#   bash server/deploy_hw.sh clova-switch
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
python3 -m py_compile server.py todo_matching.py todo_add.py register_test_device.py
python3 -m unittest test_todo_matching test_todo_add 2>&1 | tail -3

echo
echo "── 2. 전송 ───────────────────────────────────────────────"
ssh "$HOST" "mkdir -p $STAGE"
rsync -av \
    server.py voice_prompt.py audio_codec.py todo_matching.py todo_add.py requirements.txt register_test_device.py \
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
    # voice_prompt.py는 이번 배포에서 처음 올라가므로 아직 없을 수 있다
    for f in voice_prompt.py audio_codec.py; do
        [ -e "$f" ] && cp -a "$f" "$BACKUP"/ || true
    done
    echo "[backup] $BACKUP 생성 완료"
fi

install -m 640 "$STAGE/server.py"             server.py
install -m 640 "$STAGE/voice_prompt.py"       voice_prompt.py
install -m 640 "$STAGE/audio_codec.py"        audio_codec.py
install -m 640 "$STAGE/todo_matching.py"      todo_matching.py
install -m 640 "$STAGE/todo_add.py"           todo_add.py
install -m 640 "$STAGE/requirements.txt"      requirements.txt
install -m 750 "$STAGE/register_test_device.py" register_test_device.py

.venv/bin/pip install -q -r requirements.txt
.venv/bin/python -m py_compile server.py voice_prompt.py audio_codec.py todo_matching.py todo_add.py
.venv/bin/python -c 'import todo_add, todo_matching, voice_prompt, audio_codec; assert len(voice_prompt.TOOLS) == 4; assert audio_codec.ulaw_to_pcm16(bytes([0xFF])) == bytes(2); print("[check] import ok")'

rollback() {
    echo "[rollback] 실패 감지 — $BACKUP 으로 되돌린다" >&2
    cp -a "$BACKUP"/server.py        server.py
    cp -a "$BACKUP"/voice_prompt.py  voice_prompt.py 2>/dev/null || true
    cp -a "$BACKUP"/audio_codec.py   audio_codec.py  2>/dev/null || true
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
