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
cd <저장소>/server/hw
python3 -m py_compile server.py todo_matching.py todo_add.py register_test_device.py
python3 -m unittest -v test_todo_matching test_todo_add
```

## 2. EC2 기존 파일 백업

서비스를 건드리기 전에 EC2에서 백업 디렉터리를 만들고 현재 파일을 보존한다.

> `deploy_hw.sh`를 쓰면 이 절은 건너뛴다. 스크립트가 `backups/<배포시각>-<라벨>`로
> 알아서 만든다(`bash server/hw/deploy_hw.sh clova-switch`). 아래는 손으로 배포할 때만 쓴다.

백업 디렉터리는 **배포마다 새 이름**을 쓴다. 이름을 재사용하면 두 방향으로 다치는데,
둘 다 조용히 일어나서 사고 때까지 모른다.

- 수동(아래 절차) — `cp -a`가 직전 롤백 지점을 덮어써 사라진다.
- 스크립트 — 기존 백업을 보존하느라 **새 롤백 지점을 아예 안 만든다.**
  2026-08-22 실제로 이 일이 났다. 전날 쓴 이름을 그대로 재실행해서, 롤백을 눌렀다면
  전날 올린 커넥션 풀 수정까지 함께 되돌아갈 뻔했다. 그래서 자동 생성으로 바꿨다.

```bash
ssh deskibot-osaka
cd /home/ubuntu/Deskibot/server/hw
BACKUP=backups/$(date +%Y%m%d-%H%M%S)-voice-add-todo   # 시각을 붙여 겹치지 않게
mkdir -p "$BACKUP"
cp -a server.py todo_matching.py requirements.txt "$BACKUP"/
cp -a .env "$BACKUP"/.env
chmod 600 "$BACKUP"/.env
exit
```

## 3. 파일 전송

`.env`와 Firebase 서비스 계정 파일은 덮어쓰거나 삭제하지 않는다.

`todo_add.py`는 `server.py`가 import하는 새 모듈이라 **빠뜨리면 서비스가 기동하지
않는다.** 반드시 `server.py`와 함께 올린다.

```bash
cd /Users/gaeun/Documents/PlatformIO/Projects/esp
ssh deskibot-osaka 'mkdir -p /tmp/deskibot-hw-pg'
rsync -av server/server.py server/todo_matching.py server/todo_add.py server/requirements.txt server/register_test_device.py deskibot-osaka:/tmp/deskibot-hw-pg/
ssh deskibot-osaka
cd /home/ubuntu/Deskibot/server/hw
install -m 640 /tmp/deskibot-hw-pg/server.py server.py
install -m 640 /tmp/deskibot-hw-pg/todo_matching.py todo_matching.py
install -m 640 /tmp/deskibot-hw-pg/todo_add.py todo_add.py
install -m 640 /tmp/deskibot-hw-pg/requirements.txt requirements.txt
install -m 750 /tmp/deskibot-hw-pg/register_test_device.py register_test_device.py
```

## 4. 의존성과 환경 확인

기존 개별 DB 환경변수를 그대로 사용한다. `DATABASE_URL`을 추가하거나
`devices.token_hash` 인덱스를 새로 만들지 않는다.

```bash
cd /home/ubuntu/Deskibot/server/hw
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m py_compile server.py todo_matching.py todo_add.py register_test_device.py
.venv/bin/python -c 'import todo_add, todo_matching; print("import ok")'
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
PCM 요청으로 조회·추가·완료·삭제와 사용자 격리를 검증한다.

### 6.1 음성 할 일 추가 확인

로봇에 대고 말한 뒤 `journalctl -u deskibot-hw.service -f`의 `[LLM] 🔧 tool=` 과
`[PostgreSQL] ✅ todo 추가:` 줄을 본다. 앱 목록에도 같은 항목이 보여야 한다.

| 발화 | 기대 결과 |
|---|---|
| "데스키봇, 나 오늘 영어 숙제 있어" | 제목 `영어 숙제`, 카테고리 학업류, **마감 없음 / 알림 없음** |
| "나 오늘 오후 9시까지 알고리즘 과제 해야해" | 마감 `21:00`, `notify=true`, `notify_before_min=60` |
| "내일 3시까지 병원 가야 해, 30분 전에 알려줘" | 날짜 내일, 마감 `15:00`, `notify_before_min=30` |
| 같은 발화를 연달아 두 번 | 두 번째는 "이미 등록되어 있습니다" (중복 방지) |

로봇 화면의 할 일 목록은 `/hw/todos` 60초 폴링으로 갱신되므로 최대 1분 걸린다.

검증 완료 전에는 `.env`의 기존 `DEVICE_API_KEY`, Firebase 항목이나 서비스 계정
파일을 삭제하지 않는다. 새 런타임은 해당 항목을 읽지 않는다.

## 7. 롤백

되돌릴 배포의 백업 디렉터리를 지정한다(`ls backups/`로 확인).

```bash
cd /home/ubuntu/Deskibot/server/hw
BACKUP=backups/pre-voice-add-todo
cp -a "$BACKUP"/server.py server.py
cp -a "$BACKUP"/todo_matching.py todo_matching.py
cp -a "$BACKUP"/requirements.txt requirements.txt
cp -a "$BACKUP"/.env .env
chmod 600 .env
.venv/bin/pip install -r requirements.txt
sudo systemctl restart deskibot-hw.service
sudo systemctl status deskibot-hw.service --no-pager
```

되돌린 `server.py`는 `todo_add.py`를 import하지 않으므로 남아 있는 `todo_add.py`는
지우지 않아도 무해하다.
