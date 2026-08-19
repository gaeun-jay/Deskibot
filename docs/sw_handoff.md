# SW팀 전달 자료 — AWS 구조 · DB · 로봇 연결 방식

작성 2026-08-11 / HW팀

HW(로봇) 쪽의 Firebase → PostgreSQL 이전이 끝났습니다. 이 문서는 SW팀이 앱을
같은 백엔드로 옮길 때 필요한 정보를 정리한 것입니다.

문서의 값은 **실제 서버·DB에서 확인한 것**이며, 미구현 항목은 명시했습니다.

---

## 0. 한눈에 보기

| 경로 | 담당 | 상태 |
|---|---|---|
| ESP ↔ EC2 | HW | ✅ 완료·실기기 검증 |
| RPi ↔ ESP (UART) | HW | 코드 완료, 실기기 E2E 미검증 |
| **앱 ↔ EC2** | **SW** | **미착수** — 앱은 아직 Firestore 직접 접근 |

로봇은 이미 EC2만 바라보고 동작합니다. 앱만 아직 Firebase에 남아 있습니다.

```
                    ┌──────────────────────────────┐
   ESP32-S3 ──WSS──►│  api.deskibot.co.kr (nginx)  │
      │    ──HTTPS──►│                              │
      │              │   /hw/  → :8000  hw 서버     │──► PostgreSQL
   UART│              │   /api/ → :8001  sw 서버     │
      │              │   /ws/  → :8001  sw 서버     │
  Raspberry Pi       └──────────────────────────────┘
  (토큰·유저 개념 없음)          ▲
                                 │  ← 앱은 아직 여기로 오지 않음
                            Flutter 앱
```

**로봇과 유저의 연결은 페어링이 아니라 토큰 수동 등록으로 합니다** (4절).

---

## 1. AWS 구조

### 1.1 서버

| 항목 | 값 |
|---|---|
| EC2 | 오사카 `ap-northeast-3`, t3.small |
| 도메인 | `api.deskibot.co.kr` (Let's Encrypt) |
| 리버스 프록시 | nginx |

> ⚠ **Elastic IP를 쓰지 않습니다.** EC2를 중지·시작하면 공인 IP가 바뀌어
> DNS A레코드와 보안그룹을 다시 맞춰야 합니다.

### 1.2 nginx 라우팅

```nginx
server_name api.deskibot.co.kr;

location /hw/  { proxy_pass http://127.0.0.1:8000/; }   # ← 끝 슬래시: /hw 접두어 제거됨
location /api/ { proxy_pass http://127.0.0.1:8001;  }   # ← 접두어 유지
location /ws/  { proxy_pass http://127.0.0.1:8001;  }   # ← 접두어 유지
```

`/hw/`만 끝에 슬래시가 있어 접두어가 벗겨집니다. hw 서버는 내부적으로
`/process`, `/todos`, `/health`로 라우트를 정의하고 외부에선 `/hw/process`로
보입니다. **sw 서버는 접두어가 유지되므로 코드에도 `/api/...`를 그대로 씁니다.**

### 1.3 두 서비스

| | HW 서버 | SW 서버 |
|---|---|---|
| systemd | `deskibot-hw.service` | `deskibot-sw.service` |
| 실행 | gunicorn (Flask) | uvicorn (FastAPI) |
| 포트 | `127.0.0.1:8000` | `127.0.0.1:8001` |
| 경로 | `/home/ubuntu/Deskibot/server/hw` | `/home/ubuntu/Deskibot/server/sw` |
| 역할 | 음성 파이프라인, 로봇용 할 일 조회 | 집중 세션·감지 이벤트 WebSocket |

### 1.4 엔드포인트

| 엔드포인트 | 메서드 | 인증 | 용도 | 상태 |
|---|---|---|---|---|
| `/hw/health` | GET | 없음 | 헬스체크 | ✅ |
| `/hw/process` | POST | `X-Device-Key` | 음성 (PCM → STT/LLM/TTS) | ✅ |
| `/hw/todos` | GET | `X-Device-Key` | 오늘 할 일 + 마감 알림 | ✅ |
| `/api/health` | GET | 없음 | 헬스체크 | ✅ |
| `/ws/focus` | WS | 첫 메시지 auth | 집중 세션·감지 이벤트 | ✅ |
| **앱용 REST 전반** | — | — | 로그인·할 일·통계·분석 | **미구현 (SW팀)** |

### 1.5 인증 방식

**로봇 — 구현 완료**

기기별 device token을 씁니다. 서버가 받은 토큰을 SHA-256 해시해
`devices.token_hash`와 대조하고, 연결된 `devices.user_id`를 인증 사용자로 삼습니다.

- 평문 토큰은 **DB에도 로그에도 남기지 않습니다**
- HTTP는 `X-Device-Key` 헤더, WebSocket은 첫 메시지로 전달
- 인증 실패 → HTTP `401` / WS close `4401`, DB 오류 → HTTP `503`

```json
{"type":"auth","token":"<device_token>","source":"robot"}
```

**앱 — 임시 상태**

> ⚠ 현재 `/ws/focus`의 앱 인증은 **환경변수 하드코딩**입니다.
> ```python
> if source == "app":
>     expected_token = os.environ.get("WS_TEST_TOKEN", "")
>     user_id = os.environ["TEST_USER_ID"]
> ```
> **누가 로그인하든 같은 유저 한 명**으로 동작합니다. 5인 테스트를 하려면 이
> 부분이 실제 로그인 기반으로 바뀌어야 합니다.

---

## 2. DB 구조

PostgreSQL, 스키마 `public`, 11개 테이블, 소유자 `deskibot_app`.

| 테이블 | 역할 |
|---|---|
| `users` | 계정 |
| `devices` | 로봇 등록·소유자 연결 |
| `pairing_codes` | 페어링용 (**스키마만 있고 미사용** — 4절 참고) |
| `categories` | 할 일 분류 |
| `todos` | 할 일 |
| `focus_sessions` | 집중 세션 (뽀모도로/스톱워치) |
| `focus_session_events` | 세션 내 이벤트 (일시정지, 졸음·폰 감지) |
| `stats_daily` | 일별 집계 |
| `stats_daily_timeslot` | 시간대별 집계 |
| `analysis_daily` | 일별 AI 조언 |
| `analysis_cumulative` | 누적 AI 분석 |

### 2.1 users

```
id                     uuid        PK
login_id               text        NOT NULL, UNIQUE
password_hash          text        NOT NULL
name                   text        NOT NULL
user_type              text        NOT NULL      -- student / worker
analysis_started_date  date
created_at             timestamptz NOT NULL
```

> ⚠ **현재 `password_hash`에 실제 해시가 없습니다.** 테스트 계정 2개 모두
> `TEST...` 로 시작하는 21자 플레이스홀더이고, 서버에 인증 라이브러리
> (bcrypt/passlib 등)도 없습니다. 로그인 구현 시 해시 방식을 정하고 fixture도
> 다시 넣어야 합니다.
>
> 참고로 현재 앱은 `SHA-256(비밀번호)` 64자 hex를 만들어 Firestore에서 직접
> 비교합니다. 솔트가 없어 취약하니 서버로 옮기는 김에 bcrypt/argon2 권장합니다.

### 2.2 devices

```
id           bigint      PK
device_uid   text        NOT NULL, UNIQUE
user_id      uuid        UNIQUE, FK → users(id) ON DELETE SET NULL
token_hash   text        UNIQUE
paired_at    timestamptz
last_seen_at timestamptz

CHECK (user_id IS NULL OR (token_hash IS NOT NULL AND paired_at IS NOT NULL))
```

- **`user_id`에 UNIQUE** → **1인 1로봇이 DB 레벨에서 강제**됩니다
- CHECK 제약으로 "연결됐는데 토큰 없음" 같은 어중간한 상태가 차단됩니다
- `token_hash`는 UNIQUE지만 NULL은 여러 개 허용 → 미등록 기기 여러 대 가능

### 2.3 todos

```
id                bigint  PK
user_id           uuid    NOT NULL
category_id       uuid    NOT NULL, FK → categories(id, user_id)
content           text    NOT NULL,  CHECK (btrim(content) <> '')
date              date    NOT NULL
deadline_time     time
notify            boolean NOT NULL DEFAULT false
notify_before_min integer
is_done           boolean NOT NULL DEFAULT false

CHECK ((notify AND deadline_time IS NOT NULL AND notify_before_min >= 0)
       OR (NOT notify AND notify_before_min IS NULL))
INDEX (user_id, date),  INDEX (user_id, date) WHERE is_done = false
```

알림을 켜면 마감시각과 사전알림 분이 **둘 다 있어야** 합니다(CHECK).

### 2.4 focus_sessions

```
id                        uuid        PK
user_id                   uuid        NOT NULL
type                      text        NOT NULL   -- pomodoro / stopwatch
status                    text        NOT NULL   -- in_progress / completed
title                     text
started_at                timestamptz NOT NULL
ended_at                  timestamptz
session_date              date
planned_duration_sec      integer
actual_duration_sec       integer
total_pause_duration_sec  integer     NOT NULL
runtime_state             text                   -- running / paused / NULL
paused_at                 timestamptz
state_version             bigint      NOT NULL   -- = API의 revision
state_updated_at          timestamptz NOT NULL
initiated_by              text        NOT NULL   -- app / robot
last_changed_by           text        NOT NULL
```

> ⚠ **`status`와 `runtime_state`는 다릅니다.** 3.1절에서 설명합니다. 혼동하면
> 실제로 버그가 납니다(HW 쪽에서 이미 겪었습니다).

### 2.5 focus_session_events

```
id           bigint      PK
session_id   uuid        NOT NULL, FK → focus_sessions(id)
kind         text        NOT NULL   -- 일시정지 / drowsy / phone
started_at   timestamptz NOT NULL
ended_at     timestamptz
duration_sec integer
```

**졸음·스마트폰 감지 이벤트도 여기 들어갑니다.** 별도 테이블이 아닙니다.
그리고 **진행 중(running)인 세션이 있어야만 기록됩니다** — 없으면 서버가
`detection_not_allowed`로 거부합니다.

---

## 3. 로봇이 쓰는 확정 계약

SW팀이 같은 서버를 건드릴 때 **깨면 안 되는 부분**입니다.

### 3.1 WebSocket `/ws/focus`

**로봇 → 서버**

```json
{"type":"auth","token":"<device_token>","source":"robot"}

{"type":"focus_start","mode":"pomodoro","planned_duration_sec":1500}
{"type":"focus_start","mode":"stopwatch"}
{"type":"focus_pause","session_id":"...","revision":0}
{"type":"focus_resume","session_id":"...","revision":1}
{"type":"focus_end","session_id":"...","revision":2,"outcome":"incomplete"}

{"type":"detection_start","kind":"drowsy"}   // kind: drowsy | phone
{"type":"detection_end","kind":"phone"}
```

**서버 → 클라이언트 (브로드캐스트)**

```json
{
  "type": "focus_state",
  "action": "focus_pause",          // 명령 에코 (재접속 스냅샷에는 없음)
  "changed_by": "robot",
  "session": {                       // 활성 세션이 없으면 null
    "session_id": "...",
    "mode": "pomodoro",              // ← DB의 type
    "status": "in_progress",         // in_progress | completed
    "runtime_state": "paused",       // running | paused | null
    "revision": 3,                   // ← DB의 state_version
    "started_at": "2026-08-11T04:31:46.210600+00:00",
    "paused_at": "...",
    "planned_duration_sec": 1500,
    "total_pause_duration_sec": 126
  }
}
```

> ### ⚠ 가장 중요한 함정 — `status`는 일시정지 여부가 아닙니다
>
> **`status`는 세션 생명주기라 일시정지 중에도 계속 `in_progress`입니다.**
> 일시정지 여부는 **`runtime_state`에만** 있습니다.
>
> `status`만 보고 판단하면 일시정지 확인 응답을 "진행 중"으로 오해해 pause를
> 무한 재전송하고, 서버가 그걸 중복 거부하는 버그가 납니다. HW에서 실제로
> 겪었고 `runtime_state`를 함께 보도록 고쳐 해결했습니다.
>
> ```
> status != "in_progress"     → 종료됨
> runtime_state == "paused"   → 일시정지
> 그 외                        → 진행 중
> ```

#### `focus_end`의 `outcome` — 종료 사유 구분

로봇도 이제 `outcome`을 함께 보냅니다. 서버는 이 값을 그대로
`focus_sessions.status`에 넣고, 생략되면 `completed`로 처리합니다
(`app/main.py`의 `message.get("outcome", "completed")`).

| outcome | 의미 | 보내는 쪽 |
|---|---|---|
| `completed` | 뽀모도로 타이머 만료 / 스톱워치 정상 종료 | 로봇·앱 |
| `incomplete` | 사용자가 직접 강제 종료 (로봇은 화면 두 번 탭) | 로봇·앱 |
| `interrupted` | 자리 비움 5분 감지로 **시스템이** 강제 종료 | 로봇 |

`interrupted`는 사용자 조작이 아닌 종료를 뜻합니다. 로그 분석에서 "본인이 그만둔 것"과
"자리를 떠서 끊긴 것"을 구분해야 해서 값을 나눴습니다. 세 값 모두 기존 스키마 CHECK
(`in_progress / completed / incomplete / interrupted`)에 이미 있어 **마이그레이션은
없습니다.** 스톱워치는 `outcome`을 아예 싣지 않으므로 종전대로 `completed`가 됩니다.

자리 비움 자체는 `focus_session_events`에 남기지 않습니다 —
`kind`의 CHECK에 값이 없고, 세션 status만으로 분석이 가능해서 스키마를 건드리지
않는 쪽을 골랐습니다. 이벤트 단위 기록이 필요해지면 그때 `kind`에
`no_person` 추가를 요청드리겠습니다.

**그 외 주의점**

- 일시정지 누적 필드명은 `total_pause_duration_sec`입니다 (`total_pause_sec` 아님)
- `revision`은 낙관적 잠금입니다. 명령에 현재 revision을 싣고, 서버가 더 높은
  revision의 `focus_state`를 줄 때까지 다음 명령을 보내지 않습니다
- 재접속 시 서버가 활성 세션 스냅샷을 보냅니다. `action` 필드가 없고, 활성
  세션이 없으면 `"session": null`입니다 (오류가 아님)
- 뽀모도로는 서버가 pause를 거부합니다 (스톱워치 전용)
- `started_at`은 UTC 오프셋이 붙은 ISO8601입니다. 재부팅 복구 시 경과 시간을
  계산하려면 오프셋을 반드시 반영해야 합니다

### 3.2 `GET /hw/todos`

```
헤더: X-Device-Key: <device_token>
```

```json
{
  "date": "2026-08-11",
  "todos": [
    {"content": "내일 병원 예약", "deadline_time": "10:00", "notify_before_min": 60},
    {"content": "수학 과제 제출"}
  ]
}
```

- 오늘·미완료만, `deadline_time` 오름차순(NULL은 뒤), 최대 20건
- 알림 필드는 `notify`가 켜져 있고 마감·사전알림이 모두 있는 항목에만 포함
- 인증된 `user_id`로만 조회 → **토큰을 바꾸면 할 일도 따라 바뀝니다**

### 3.3 `POST /hw/process` (음성)

요청 본문은 16-bit mono 16kHz PCM 원본, 헤더는 `X-Device-Key`.
응답은 바이너리입니다.

```
[4바이트 STT 문자열 길이][STT UTF-8]
[4바이트 command JSON 길이][command JSON UTF-8]
[16-bit mono 16kHz PCM]
```

서버가 할 일 조회·완료·삭제를 처리합니다. 대상 선택은 정확 일치 우선, 포함
일치는 후보가 유일할 때만 허용, 모호하면 아무것도 바꾸지 않습니다.

---

## 4. 로봇 ↔ 유저 연결 — 토큰 수동 등록

### 4.1 페어링은 하지 않습니다

6자리 코드 페어링은 **도입하지 않기로 했습니다.** 페어링은 "이미 로그인된 앱이
로봇에 신원을 넘겨주는" 방식인데, 지금은 앱 로그인이 서버에 없어서 넘겨줄 신원
자체가 없습니다. 세션 없이 앱이 `user_id`를 그대로 보내는 방식은 아무나 남의
계정에 로봇을 붙일 수 있어 테스트 데이터가 섞입니다.

`pairing_codes` 테이블은 스키마만 만들어 두고 **쓰지 않습니다** (현재 0행).
정식 배포 단계에서 필요해지면 그때 검토합니다.

### 4.2 지금 하는 방법

```bash
# 1. 토큰 생성 (43자)
python3 -c "import secrets; print(secrets.token_urlsafe(32))"

# 2. DB에 등록 (EC2 — 입력은 숨김 처리되고 SHA-256 해시만 저장됨)
cd /home/ubuntu/Deskibot/server/hw
.venv/bin/python register_test_device.py \
  --device-uid deskibot-test-001 \
  --user-id <user uuid>

# 3. 로봇 시리얼에 입력
token <값>
→ [Token] 저장됨 (len=43) — WS 재연결
→ [AWS WS] 인증 완료
```

**토큰은 ESP의 NVS에 저장되어 재부팅·전원차단·펌웨어 재업로드에도 유지됩니다.**
한 번 넣으면 USB를 빼도 되고, 유저를 바꿀 때만 3번을 다시 하면 됩니다.
5인 시분할이면 전환은 **총 4회**입니다.

전환하면 할 일·마감 알림·음성 조회가 **모두 새 유저 기준으로 바뀝니다**
(이전 유저의 캐시는 폐기됩니다). 실기기에서 학생 ↔ 직장인 양방향으로
DB까지 대조해 확인했습니다.

### 4.3 테스트 중 유의점

지금은 **유저마다 별도 `devices` row**를 씁니다
(`deskibot-test-001` = 학생, `deskibot-test-worker` = 직장인).
`devices.user_id`가 UNIQUE라 그렇게 하지 않으면 한 대를 여러 유저가 돌려쓸 수
없기 때문입니다.

> 나중에 `device_uid`를 실제 MAC으로 바꾸면 **로봇 1대 = row 1개 = 유저 1명**이
> 되어 시분할이 불가능해집니다. 테스트 동안은 `device_uid`를 "슬롯"으로 두고,
> 정식 배포 때 MAC 기반으로 전환하는 것을 전제로 하세요.

### 4.4 평문 토큰은 복구할 수 없습니다

DB에는 SHA-256 해시만 저장되고 등록 스크립트도 숨김 입력으로 받습니다.
**분실하면 복구 경로가 없고 재발급이 유일한 방법**입니다. 재발급은 같은
스크립트를 실행하면 `ON CONFLICT DO UPDATE`로 덮어씁니다.

`--device-uid`를 잘못 넣으면 **다른 유저의 토큰을 날립니다.** 되돌릴 수 없습니다.

---

## 5. 앱 이전 시 유의점

현재 앱은 **`lib/services/` 9개 파일 전부가 Firestore/RTDB에 직접 접근**하고
HTTP 호출이 0건입니다. 즉 EC2와 아예 통신하지 않습니다.

**PostgreSQL로 옮기면 구조가 근본적으로 바뀝니다.** Firestore는 클라이언트 SDK로
직접 조회가 됐지만, **PostgreSQL은 모바일에서 직접 접속하면 안 됩니다**
(DB 자격증명이 앱에 박힘). 반드시 EC2 API를 거쳐야 합니다.

필요한 것:

1. 서버에 앱용 REST API (로그인·할 일·통계·분석)
2. 앱에 API 클라이언트 + 세션 토큰 관리
3. `auth_service.dart`의 Firestore 직접 조회 → `POST /api/auth/login`

---

## 6. SW팀 작업 우선순위

| 순위 | 작업 | 비고 |
|---|---|---|
| **1** | **앱 로그인** — `users.login_id` / 실제 `password_hash` + 세션 토큰 | 이게 없으면 5인 테스트가 앱에서 불가능. 해시가 플레이스홀더라 해싱부터 필요 |
| 2 | 앱용 REST API (할 일·통계·분석) | 앱 서비스 9개가 Firestore 직접 접근 중 |
| 3 | 앱 WS 인증을 `WS_TEST_TOKEN` → 로그인 유저 기준으로 교체 | 현재 환경변수 하드코딩 |

로봇 쪽은 위 작업과 무관하게 이미 동작하므로, **SW 작업이 로봇을 막지 않습니다.**

---

## 7. 참고 — HW에서 겪은 함정

SW팀에도 해당될 수 있는 것들입니다.

- **`status` vs `runtime_state` 혼동** → 일시정지 무한루프 (3.1절)
- **`total_pause_duration_sec` 필드명** → 잘못 쓰면 값이 항상 0
- **ISO8601 UTC 오프셋 무시** → 재부팅 복구 시 경과 시간이 어긋남
- **재접속 스냅샷의 `session: null`** → 오류가 아니라 "활성 세션 없음"
- **감지 이벤트는 진행 중 세션이 있어야 기록됨** → 없으면 `detection_not_allowed`

현재 로봇은 Firebase 의존성이 0이고(라이브러리·코드·이름·EC2 파일 전부 제거),
집중모드·음성·할 일·마감 알림 전 경로가 실기기와 DB 대조까지 검증된 상태입니다.
