#!/usr/bin/env bash
# 로컬 PostgreSQL 16에 EC2 덤프를 복원한다. Git Bash에서 실행.
#   bash database/setup_local.sh
set -u

PGBIN="/c/Program Files/PostgreSQL/16/bin"
PSQL="$PGBIN/psql.exe"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP="$HERE/deskibot_full_20260813.sql"

# 로컬 개발 전용 비밀번호. EC2와 다르게 두는 것이 핵심이다.
APP_PASSWORD="deskibot_local_dev"

[ -f "$DUMP" ] || { echo "덤프를 찾을 수 없음: $DUMP"; exit 1; }

printf 'postgres superuser 비밀번호: '
read -rs PGPASSWORD
export PGPASSWORD
echo

run() { "$PSQL" -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 "$@"; }

echo "[1/5] 접속 확인"
run -d postgres -Atc "SELECT version()" >/dev/null || {
  echo "  접속 실패 — 비밀번호를 확인하세요."; exit 1; }
echo "  OK"

echo "[2/5] 역할 deskibot_app"
run -d postgres -q -c "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'deskibot_app') THEN
    CREATE ROLE deskibot_app LOGIN PASSWORD '$APP_PASSWORD';
    RAISE NOTICE '  생성함';
  ELSE
    RAISE NOTICE '  이미 있음';
  END IF;
END \$\$;"

echo "[3/5] 데이터베이스 deskibot"
if [ "$(run -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='deskibot'")" = "1" ]; then
  echo "  이미 있음 — 덮어쓰려면 먼저 DROP DATABASE deskibot; 하세요."
  echo "  기존 DB에 그대로 복원하면 충돌합니다. 중단합니다."
  exit 1
fi
run -d postgres -q -c "CREATE DATABASE deskibot OWNER deskibot_app;"
echo "  생성함"

echo "[4/5] 덤프 복원"
run -d deskibot -q -f "$DUMP" || { echo "  복원 실패"; exit 1; }
echo "  완료"

echo "[5/5] 검증"
run -d deskibot -c "
SELECT relname AS 테이블, n_live_tup AS 행
  FROM pg_stat_user_tables ORDER BY relname;"

ENVFILE="$HERE/../server/sw/.env.local"
if [ -f "$ENVFILE" ]; then
  echo
  echo ".env.local 이 이미 있어 그대로 둡니다 (JWT_SECRET 보존)."
else
  cat > "$ENVFILE" <<ENVEOF
# 로컬 개발 전용. EC2 .env 와 절대 섞지 말 것.
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=deskibot
DB_USER=deskibot_app
DB_PASSWORD=$APP_PASSWORD
ENVEOF
  echo
  echo ".env.local 을 새로 만들었습니다. JWT_SECRET 은 따로 추가해야 합니다."
fi

echo "완료. deskibot_app 로컬 비밀번호: $APP_PASSWORD"
