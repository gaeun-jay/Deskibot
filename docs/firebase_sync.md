# ESP Firebase 동기화 로직

---

## 전체 구조

```
┌─────────────┐        RTDB         ┌─────────────┐
│    ESP32    │ ◄─────────────────► │     RPI     │
│             │                     │ (졸음/폰 감지)│
└──────┬──────┘                     └─────────────┘
       │
       │  Firestore REST API
       ▼
┌─────────────┐        RTDB         ┌─────────────┐
│  Firestore  │                     │ Flutter 앱  │
│ (세션 영구  │◄────────────────────│             │
│   기록)     │    (세션 상태 공유) └─────────────┘
└─────────────┘
```

- **RTDB** — ESP / RPI / Flutter 앱이 공유하는 실시간 상태 채널
- **Firestore** — 완료된 세션 영구 기록. 세션 시작한 주체가 직접 기록

---

## 1. RTDB 구조

경로: `/users/{uid}/status/current_state`

| 필드 | 쓰는 주체 | 설명 |
|------|-----------|------|
| `session_id` | ESP / 앱 | ESP 시작 시 `"esp_"` 접두사 |
| `type` | ESP / 앱 | `"pomodoro"` / `"stopwatch"` |
| `state` | ESP / 앱 | `"start"` / `"pause"` / `"resume"` / `"end"` |
| `duration` | ESP / 앱 | 뽀모도로 설정 시간 (분) |
| `started_at` | ESP / 앱 | ISO 8601 타임스탬프 |
| `paused_at` | ESP / 앱 | 일시정지 타임스탬프 |
| `total_pause_sec` | ESP / 앱 | 총 일시정지 시간 (초) |
| `is_detecting_drowsy` | RPI | 졸음 감지 여부 |
| `is_detecting_phone` | RPI | 폰 사용 감지 여부 |

---

## 2. RTDB 폴링 — `_alert_poll_task()`

> **방식**: REST 폴링 / **주기**: 4초 / **실행**: FreeRTOS 백그라운드 태스크 (Core 1)

```
매 4초
  └── Firebase.RTDB.getJSON(current_state)
        │
        ├── [졸음 / 폰 감지]
        │     is_detecting_* 값 변화 감지
        │     → _drowsy_changed / _phone_changed 플래그 세팅
        │
        └── [앱 세션 감지]
              session_id가 "esp_" 아님 + 값이 변했으면
              → _rtdb_app_sync_pending 플래그 세팅
```

---

## 3. 경보 처리 — `firebase_check_alerts()`

> 메인 루프에서 매 틱 호출. 폴링 태스크가 세운 플래그를 소비.

```
is_detecting_* : false → true
  └── 뽀모도로 RUNNING 중일 때만 동작
        ├── show_alert()   팝업 표시 + pulse 애니메이션
        └── sound_play()   경보음 재생 → true인 동안 2초마다 반복

is_detecting_* : true → false
  └── hide_alert()   팝업 숨김 + 반복 중지
```

> 뽀모도로가 실행 중(`POMO_RUNNING`)이 아니면 감지 값이 바뀌어도 무시

---

## 4. RTDB 쓰기 — `rtdb_send_state()`

ESP가 세션을 직접 조작할 때마다 RTDB에 현재 상태 기록.

| 호출 시점 | state 값 |
|-----------|----------|
| 세션 시작 | `"start"` |
| 일시정지 | `"pause"` |
| 재개 | `"resume"` |
| 종료 | `"end"` |

```
rtdb_send_state(session_id, type, state, ...)
  └── FreeRTOS 비동기 태스크
        └── Firebase.RTDB.setJSON(current_state)
```

---

## 5. 앱 세션 감지 및 UI 반영 — `firebase_sync_from_app()`

Flutter 앱이 RTDB에 세션 상태를 쓰면, ESP가 폴링으로 감지해 화면을 맞춤.

```
_rtdb_app_sync_pending == true (메인 루프에서 처리)
  ├── type == "pomodoro" && 현재 화면 == 뽀모도로
  │     → pomo_rtdb_sync()   뽀모도로 타이머 UI 동기화
  └── type == "stopwatch" && 현재 화면 == 스톱워치
        → sw_rtdb_sync()     스톱워치 UI 동기화
```

> ESP와 앱이 직접 통신하지 않고 **RTDB를 중간 채널**로 사용

---

## 6. Firestore 세션 저장

> 세션 **종료 시 한 번만** POST. FreeRTOS 비동기 태스크.

### 스톱워치

```
sw_post_focus_session()  →  POST focus_sessions/{auto-id}

저장 필드:
  session_id, type, status("completed"),
  date, start_date, start_time, end_date, end_time,
  actual_duration, total_pause_duration,
  pause_events: [ { paused_at_date, paused_at_time,
                    resumed_at_date, resumed_at_time } ]
```

### 뽀모도로

```
pomo_post_focus_session()  →  POST focus_sessions/{auto-id}

저장 필드:
  session_id, type,
  status: actual_min >= planned_min - 1  →  "completed"
          actual_min <  planned_min - 1  →  "incomplete"
  date, start_date, start_time, end_date, end_time,
  planned_duration, actual_duration
```

> `drowsy_events` / `phone_events`는 RPI가 Firestore에 직접 기록 — ESP 관여 없음

---

## 7. Firestore todos 조회 — `firebase_fetch_tasks()`

> Voice 화면 진입 시 호출. **60초 쿨다운** (이내 재호출 무시)

```
GET users/{uid}  (todos + settings 필드만)
  └── todos 파싱: 오늘 날짜 + is_done == false인 항목만
        → fs_task_assignment[]  (음성 컨텍스트 문자열로 server.py에 전달)
```

> todo 추가 / 삭제 / 완료는 **server.py가 LLM 처리 후 Firestore 직접 처리** — ESP 관여 없음

---

## 8. 동시 SSL 연결 방지

ESP32는 SSL 연결을 동시에 여러 개 열면 힙 부족으로 크래시 발생.

**해결 방식**:
- `FirebaseData` 전역 객체 1개(`_g_rtdb_fbd`)만 유지
- `_ssl_mutex` (FreeRTOS Mutex) — 모든 SSL 작업은 뮤텍스 점유 후 실행
- RTDB `setJSON` / `getJSON` + Firestore `HTTPClient` 요청이 절대 동시에 실행되지 않도록 보장

```
xSemaphoreTake(_ssl_mutex, portMAX_DELAY)
  └── SSL 작업 (RTDB or Firestore)
xSemaphoreGive(_ssl_mutex)
```

---

## 9. 메인 루프 호출 순서

```
loop()
  ├── firebase_check_alerts()     경보 플래그 처리 (졸음 / 폰)
  ├── firebase_sync_from_app()    앱 세션 동기화 플래그 처리
  └── firebase_fetch_tasks()      todos 갱신 (Voice 화면 + 60초 쿨다운)
```

> 모든 네트워크 I/O는 FreeRTOS 태스크로 분리 — `loop()`는 블로킹 없이 실행
