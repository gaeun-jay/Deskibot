# RPi 담당자 전달 자료 — Firebase 제거 및 UART 경로 확정

작성 2026-08-11 / HW팀

로봇(ESP)의 Firebase → PostgreSQL 이전이 끝나면서 **RPi의 Firebase 경로도 제거**했습니다.
이 문서는 무엇이 왜 바뀌었는지, 그리고 RPi가 앞으로 뭘 해야 하는지를 정리한 것입니다.

---

## 1. 결론부터

**RPi가 할 일은 UART로 감지 상태를 보내는 것 하나뿐입니다.** 서버·DB에 직접 쓰지 않습니다.

```
RPi (카메라 감지)
  │  UART  "DROWSY:<0|1>,PHONE:<0|1>\n"   ← 이것만 하면 됨
  ▼
ESP32-S3 ── WSS ──► EC2 ──► PostgreSQL (focus_session_events)
```

기존 `firebase_client.py`(RTDB 실시간 상태 + Firestore 이벤트 기록)는 **삭제**했습니다.

---

## 2. 왜 RPi가 직접 서버에 안 쓰나

기술적으로는 RPi 5도 네트워크가 되니 가능하지만, 세 가지 이유로 ESP를 거칩니다.

**① 세션 컨텍스트가 ESP에만 있습니다**
감지 이벤트는 DB에서 `focus_session_events.session_id`가 **NOT NULL**이라 반드시 집중
세션에 붙어야 합니다. 그런데 세션을 시작·종료하는 건 ESP이고, `session_id`와 진행
상태를 아는 것도 ESP뿐입니다. RPi는 뽀모도로가 돌고 있는지조차 모릅니다.

**② 자격증명이 하나로 유지됩니다**
서버 인증은 기기별 device token으로 하는데, 그 토큰은 ESP의 NVS에만 있습니다. RPi가
직접 쓰려면 토큰을 하나 더 발급해 RPi에도 심어야 하고, 그러면 기기 두 대가 키를 들게
됩니다. 물리적으로 한 로봇이라 보안상 이득이 없습니다.

**③ 기존 Firebase 경로는 이미 죽어 있었습니다**
`firebase_client._check_active()`가 RTDB의 `users/{UID}/status/current_state`를 1초마다
폴링해 "뽀모도로 중인가"를 판단했는데, **거기에 쓰던 게 ESP였고 이제 ESP는 Firebase를
쓰지 않습니다.** 즉 아무도 갱신하지 않는 값을 읽고 있어서, 모든 기록이
`skip ... — type=(empty)` 로 건너뛰어졌을 겁니다.

---

## 3. 변경 내역

백업: `rpi/_backup_pre_firebase_removal/` (수정 전 원본 보관)

| 파일 | 변경 |
|---|---|
| `comm/firebase_client.py` | **삭제** |
| `main.py` | `FirebaseClient` import·초기화·호출 5곳 제거 |
| `main.py` | 이벤트 기록 블록 → 콘솔 로그로 대체 (아래 4절) |
| `requirements.txt` | `firebase_admin==7.4.0` 제거 |
| `.gitignore` | `comm/serviceAccountKey.json` 항목 제거 |
| `detection/debounce.py` | 주석의 Firebase 언급 수정 |

**변경 없음:** `comm/uart_client.py`, `detection/*`, `tracking/*`, `comm/camera.py`

> ⚠ **실제 RPi 기기에 남아 있는 `comm/serviceAccountKey.json`을 삭제해 주세요.**
> 이 사본에는 없지만 기기에는 있을 겁니다. Firebase 프로젝트 전체 관리자 권한을
> 가진 키라, 안 쓰는 채로 두면 그대로 위험 요소입니다.

### `main.py` 로그 변경

Firebase 기록 자리에 콘솔 로그를 남겼습니다. 디바운스 동작을 눈으로 확인할 수 있게
"실제 종료 시점"도 함께 찍습니다.

```
[14:23:10] Drowsiness detected
[14:25:12] Drowsiness cleared (실제 종료 2.0초 전)
```

---

## 4. UART 프로토콜 (변경 없음 — 이미 맞습니다)

```
포트   /dev/ttyAMA0   115200 8N1
배선   RPi GPIO14(물리 8, TX) → ESP IO18(RX)
       RPi GPIO15(물리 10, RX) ← ESP IO17(TX)
       GND 공통 필수  ※ 이거 빠지면 신호가 깨집니다 (지난번 브링업 실패 원인)

형식   "DROWSY:<0|1>,PHONE:<0|1>\n"
       "PING\n"  →  ESP가 "PONG\n" 회신 (3선 왕복 확인용)
```

ESP 쪽 파서는 `sscanf(buf, "DROWSY:%d,PHONE:%d", &d, &p)` 이고, **정확히 2개를 못 읽으면
그 줄을 버립니다.** 형식이 어긋나면 조용히 무시되니 주의하세요.

**동작 규칙**

- **값이 바뀔 때만 전송** — 현재 `main.py`가 이미 그렇게 하고 있습니다
  (같은 값을 계속 보내도 ESP가 중복 전송하지 않으니 주기 전송으로 바꿔도 무방)
- ESP가 `0→1`을 `detection_start`, `1→0`을 `detection_end`로 서버에 전달
- WSS가 끊겨 있으면 ESP가 최신 상태를 보관했다가 재연결 후 재전송
- 32바이트 넘는 줄은 그 줄 전체가 버려집니다

**RPi는 시각·지속시간을 보내지 않습니다.** 서버가 도착 시점에 `NOW()`로 찍고 지속시간을
계산합니다. 구간의 시작과 끝만 알려주면 됩니다.

---

## 5. 감지 기록 조건 (알아두셔야 할 것)

서버가 감지 이벤트를 저장하는 조건입니다. 만족하지 않으면 **조용히 거부**됩니다.

| 상황 | 기록 |
|---|---|
| 뽀모도로 **진행 중** | ✅ 저장 |
| 스톱워치 진행 중 | ❌ `detection_not_allowed` |
| 집중 세션 없음 | ❌ `no_active_session` |

**즉 사용자가 뽀모도로를 돌리고 있을 때만 감지가 기록됩니다.** 설계상 의도된 동작입니다
(졸음·폰 감지는 뽀모도로 전용). 테스트할 때 "감지는 되는데 DB에 안 쌓인다" 싶으면
십중팔구 뽀모도로가 안 돌고 있는 겁니다.

세션이 끝날 때 아직 열려 있는 감지 이벤트는 **서버가 자동으로 닫습니다.** RPi나 ESP가
`detection_end`를 놓쳐도 미종료 이벤트로 남지 않습니다.

---

## 6. ⚠ 지속시간에 상수 편향이 있습니다

`main.py`의 디바운스 설정입니다.

```python
PHONE_RISE_SEC  = 0.0   # 감지는 즉시 보고
PHONE_FALL_SEC  = 2.0   # 해제는 2초 늦춤 (손/각도 가림 방어)
DROWSY_RISE_SEC = 0.0
DROWSY_FALL_SEC = 2.0   # 얼굴 메시 순간 유실 방어
```

시작은 지연이 없지만 **종료는 항상 `FALL_SEC`(2.0초) 늦게 UART로 나갑니다.**
서버는 도착 시각으로 `ended_at`을 찍으므로, **기록된 지속시간이 실제보다 정확히
2초 깁니다.**

`Debouncer`가 raw 신호가 뒤집힐 때마다 타이머를 리셋하므로, 신호가 중간에 깜빡여도
지연은 항상 정확히 `FALL_SEC`입니다. **가변이 아니라 상수입니다.**

- 졸음 120초 → 122초로 기록 (오차 1.7%)
- 폰 5초 → 7초로 기록 (오차 40%)

**대응:** 분석 단계에서 `duration_sec - 2`로 빼면 실제 값이 됩니다. 프로토콜로 보정하려면
RPi·ESP·서버 세 곳을 동시에 고쳐야 해서, 지금은 편향을 문서화하는 쪽을 택했습니다.
정밀도가 필요해지면 UART에 "몇 초 전에 끝났는지" 필드를 추가하는 방식으로 확장할 수
있습니다 (`raw_false_since`로 이미 계산 가능합니다).

---

## 7. 없어진 기능 — 짧은 이벤트 필터

기존 `firebase_client.py`에 있던 필터입니다.

```python
MIN_EVENT_SEC = 5    # 5초 미만 이벤트는 기록하지 않음
```

**UART 경로에는 이게 없어서 1~2초짜리 짧은 감지도 전부 DB에 쌓입니다.** 분석에 노이즈가
되면 서버나 분석 단계에서 거르면 되고, 짧은 감지도 의미가 있다면 그대로 두면 됩니다.
**결정이 필요한 사항**이라 임의로 넣지 않았습니다.

---

## 8. 테스트 절차

RPi를 연결하면 아래 순서로 확인하면 됩니다.

**1단계 — 배선 확인**
RPi에서 `PING\n`을 보내고 `PONG\n`이 돌아오면 TX·RX·GND 3선이 모두 정상입니다.

**2단계 — ESP 수신 확인**
ESP 시리얼의 `[Diag]` 줄에 링크 상태가 표시됩니다.
```
RPi=수신없음                    ← 아직 아무것도 못 받음
RPi=OK 1.2s전 줄42 DET40        ← 정상 (총 42줄, 그중 정상 파싱 40건)
RPi=끊김 8.3s전 줄42 DET40      ← 받다가 조용해짐
```

**3단계 — 서버 전달 확인**
ESP 시리얼에 이렇게 찍히면 서버로 나간 것입니다.
```
[AWS WS] detection_start kind=drowsy
[AWS WS] detection_end kind=drowsy
```

**4단계 — DB 확인** (뽀모도로를 돌린 상태여야 합니다)
```sql
SELECT kind, started_at, ended_at, duration_sec
FROM focus_session_events
WHERE kind IN ('drowsy','phone')
ORDER BY started_at DESC LIMIT 10;
```

**확인할 것**
- `DROWSY:1` → `ended_at`이 NULL인 row 생성
- `DROWSY:0` → 같은 row에 `ended_at`·`duration_sec` 채워짐
- 같은 값을 반복 전송해도 이벤트가 중복 생성되지 않음
- 뽀모도로 종료 시 열려 있던 이벤트가 자동으로 닫힘
- 뽀모도로 없이 감지 → 아무것도 안 쌓임 (정상)

---

## 9. 참고 — 분석에 쓰이는 데이터

감지 이벤트는 `focus_session_events`에 이렇게 저장됩니다.

```
session_id   uuid        어느 세션에 속하는지
kind         text        drowsy | phone | pause
started_at   timestamptz 서버가 detection_start 도착 시 NOW()
ended_at     timestamptz 서버가 detection_end 도착 시 NOW()
duration_sec integer     위 둘의 차
```

여기서 "언제 / 몇 회 / 각 몇 분 / 총 몇 분"이 전부 나옵니다.

```sql
SELECT to_char(started_at AT TIME ZONE 'Asia/Seoul','HH24') AS 시각,
       kind, count(*) AS 횟수, sum(duration_sec) AS 총초,
       array_agg(duration_sec ORDER BY started_at) AS 각각초
FROM focus_session_events WHERE kind IN ('drowsy','phone')
GROUP BY 1,2 ORDER BY 1;
```

**신뢰도·심각도·EAR 값 같은 건 DB에 저장할 컬럼이 없습니다.** 그래서 RPi가 불리언 2개만
보내면 충분하고, 더 보내려면 스키마부터 바꿔야 합니다.
