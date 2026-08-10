# EC2 HW 음성 서버 PostgreSQL 인증 배포

실제 운영 구성:

- SSH alias: `deskibot-osaka`
- 앱 경로: `/home/ubuntu/Deskibot/server/hw`
- systemd: `deskibot-hw.service`
- Gunicorn: `127.0.0.1:8000`
- Nginx: 외부 `/hw/`를 내부 `/`로 전달
- DB 설정: 기존 `.env`의 `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`

평문 device token, DB 비밀번호, API 키는 명령행·로그·Git에 출력하지 않는다.

## 1. 로컬 검증

```bash
cd /Users/gaeun/Documents/PlatformIO/Projects/esp/server
python3 -m py_compile server.py todo_matching.py register_test_device.py
python3 -m unittest -v test_todo_matching.py
```

## 2. EC2 기존 파일 백업

서비스를 건드리기 전에 EC2에서 백업 디렉터리를 만들고 현재 파일을 보존한다.

```bash
ssh deskibot-osaka
cd /home/ubuntu/Deskibot/server/hw
mkdir -p backups/pre-pg-todo
cp -a server.py requirements.txt backups/pre-pg-todo/
cp -a .env backups/pre-pg-todo/.env
chmod 600 backups/pre-pg-todo/.env
exit
```

## 3. 파일 전송

`.env`와 Firebase 서비스 계정 파일은 덮어쓰거나 삭제하지 않는다.

```bash
cd /Users/gaeun/Documents/PlatformIO/Projects/esp
ssh deskibot-osaka 'mkdir -p /tmp/deskibot-hw-pg'
rsync -av server/server.py server/todo_matching.py server/requirements.txt server/register_test_device.py deskibot-osaka:/tmp/deskibot-hw-pg/
ssh deskibot-osaka
cd /home/ubuntu/Deskibot/server/hw
install -m 640 /tmp/deskibot-hw-pg/server.py server.py
install -m 640 /tmp/deskibot-hw-pg/todo_matching.py todo_matching.py
install -m 640 /tmp/deskibot-hw-pg/requirements.txt requirements.txt
install -m 750 /tmp/deskibot-hw-pg/register_test_device.py register_test_device.py
```

## 4. 의존성과 환경 확인

기존 개별 DB 환경변수를 그대로 사용한다. `DATABASE_URL`을 추가하거나
`devices.token_hash` 인덱스를 새로 만들지 않는다.

```bash
cd /home/ubuntu/Deskibot/server/hw
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m py_compile server.py todo_matching.py register_test_device.py
sudo awk -F= '/^(DB_HOST|DB_PORT|DB_NAME|DB_USER|DB_PASSWORD)=/ {print $1}' .env
```

다섯 환경변수 이름이 모두 출력되어야 한다. 값은 출력하지 않는다.

## 5. 서비스 재시작

기존 systemd와 Nginx 설정은 변경하지 않는다.

```bash
sudo systemctl restart deskibot-hw.service
sudo systemctl status deskibot-hw.service --no-pager
sudo journalctl -u deskibot-hw.service -n 100 --no-pager
```

로그에 token, token hash, DB 비밀번호가 없어야 한다.

## 6. 공개 API 검증

```bash
curl -fsS https://api.deskibot.co.kr/hw/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://api.deskibot.co.kr/hw/process
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'X-Device-Key: invalid-test-token' https://api.deskibot.co.kr/hw/process
```

예상 결과는 health `ok`, 토큰 없음 `401`, 잘못된 토큰 `401`이다. 올바른 토큰은
안전한 로컬 입력 방식으로 헤더에 넣고 빈 body를 보내 `400`을 확인한다. 이후 실제
PCM 요청으로 조회·완료·삭제와 사용자 격리를 검증한다.

검증 완료 전에는 `.env`의 기존 `DEVICE_API_KEY`, Firebase 항목이나 서비스 계정
파일을 삭제하지 않는다. 새 런타임은 해당 항목을 읽지 않는다.

## 7. 롤백

```bash
cd /home/ubuntu/Deskibot/server/hw
cp -a backups/pre-pg-todo/server.py server.py
cp -a backups/pre-pg-todo/requirements.txt requirements.txt
cp -a backups/pre-pg-todo/.env .env
chmod 600 .env
.venv/bin/pip install -r requirements.txt
sudo systemctl restart deskibot-hw.service
sudo systemctl status deskibot-hw.service --no-pager
```
