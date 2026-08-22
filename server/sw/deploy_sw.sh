#!/usr/bin/env bash
# EC2 SW API 서버 배포 (deskibot-osaka)
#
#   bash server/sw/deploy_sw.sh [라벨]
#
# 라벨은 백업 디렉터리 이름에 붙는 메모다 (생략하면 manual).
#   bash server/sw/deploy_sw.sh pool
#     → backups/20260822-170000-pool
# 앞에 배포 시각이 붙으므로 같은 라벨을 재사용해도 백업이 겹치지 않는다.
#
# 백업 → 전송 → 설치 → import 검증 → 재시작 → health 확인 순으로 돌고,
# 재시작이나 health가 실패하면 백업으로 자동 롤백한다.
# .env 는 건드리지 않는다.
#
# hw 쪽 deploy_hw.sh 를 포팅한 것이다. 다른 점은 대상 경로(server/sw),
# 서비스명(deskibot-sw), 포트(8001), health 경로(/api/health), 그리고
# 파일이 아니라 app/ 패키지 전체를 옮긴다는 것뿐이다.
set -euo pipefail

HOST=deskibot-osaka
APP=/home/ubuntu/Deskibot/server/sw
STAGE=/tmp/deskibot-sw-deploy
LABEL="${1:-manual}"                  # 이번 배포를 알아볼 이름 (인자로 넘긴다)
BACKUP="backups/$(date +%Y%m%d-%H%M%S)-$LABEL"   # 시각이 붙어 절대 겹치지 않는다
LOCAL="$(cd "$(dirname "$0")" && pwd)"

echo "── 1. 로컬 검증 ──────────────────────────────────────────"
cd "$LOCAL"
python3 -m py_compile app/*.py
echo "[check] py_compile ok ($(ls app/*.py | wc -l | tr -d ' ')개 파일)"

echo
echo "── 2. 전송 ───────────────────────────────────────────────"
ssh "$HOST" "mkdir -p $STAGE"
# --delete 는 쓰지 않는다. 서버에만 있는 파일을 지우는 사고를 막는다.
rsync -av --exclude='__pycache__' app/ "$HOST:$STAGE/app/"
rsync -av requirements.txt "$HOST:$STAGE/"

echo
echo "── 3. 백업 · 설치 · 재시작 ───────────────────────────────"
ssh "$HOST" APP="$APP" STAGE="$STAGE" BACKUP="$BACKUP" 'bash -seuo pipefail' <<'REMOTE'
cd "$APP"

# 이미 있는 백업은 덮지 않는다 (직전 롤백 지점 보존).
# 이름에 배포 시각이 들어가므로 실제로는 겹칠 일이 없다.
if [ -e "$BACKUP" ]; then
    echo "[backup] $BACKUP 이미 존재 — 그대로 둔다"
else
    mkdir -p "$BACKUP"
    cp -a app "$BACKUP"/
    cp -a requirements.txt "$BACKUP"/
    echo "[backup] $BACKUP 생성 완료"
fi

rsync -a --exclude='__pycache__' "$STAGE/app/" app/
install -m 640 "$STAGE/requirements.txt" requirements.txt

.venv/bin/pip install -q -r requirements.txt
.venv/bin/python -m py_compile app/*.py

# app.main 을 실제로 import 해 본다. 라우터 등록과 커넥션 풀 생성까지
# 여기서 한 번 걸러진다 — 서비스를 재시작하기 전에 실패를 잡는 게 목적이다.
.venv/bin/python -c 'from app.main import app; print(f"[check] import ok, 라우트 {len(app.routes)}개")'

rollback() {
    echo "[rollback] 실패 감지 — $BACKUP 으로 되돌린다" >&2
    rm -rf app
    cp -a "$BACKUP"/app app
    cp -a "$BACKUP"/requirements.txt requirements.txt
    .venv/bin/pip install -q -r requirements.txt || true
    sudo systemctl restart deskibot-sw.service || true
    sudo systemctl status deskibot-sw.service --no-pager || true
    exit 1
}

sudo systemctl restart deskibot-sw.service || rollback
sleep 3
sudo systemctl is-active --quiet deskibot-sw.service || rollback
# /api/health 는 DB 조회까지 하고 나서 ok 를 준다. 커넥션 풀이 살아있는지도
# 이 한 줄로 함께 확인된다.
curl -fsS http://127.0.0.1:8001/api/health >/dev/null || rollback

echo "[check] 서비스 active + health ok"
sudo journalctl -u deskibot-sw.service -n 30 --no-pager
REMOTE

echo
echo "── 4. 공개 API 확인 ──────────────────────────────────────"
printf 'health            : '; curl -fsS https://api.deskibot.co.kr/api/health; echo
printf 'todos  무인증(401): '; curl -sS -o /dev/null -w '%{http_code}\n' https://api.deskibot.co.kr/api/todos
printf 'ws     업그레이드 : '; curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' https://api.deskibot.co.kr/ws/focus || true

echo
echo "✅ 배포 완료. 로그는 아래로 보세요:"
echo "   ssh $HOST 'sudo journalctl -u deskibot-sw.service -f'"
