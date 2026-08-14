## 앱 PostgreSQL 이전 — 파일별 작업 목록

현재 앱 코드(`platform/app/lib`) 기준으로 정리했습니다. 서비스 9개가 전부
Firestore/RTDB에 직접 접근하고 HTTP 호출이 0건인 상태입니다.

### 1. 서버에 새로 만들 API

| 엔드포인트 | 대응 테이블 | 쓰는 곳 |
|---|---|---|
| `POST /api/auth/signup` | `users` + `categories` | `auth_service.signUp()` |
| `POST /api/auth/login` | `users` | `auth_service.login()` → **세션 토큰 발급** |
| `GET /api/users/me` | `users` | `user_service.dart` |
| `GET/POST/PATCH/DELETE /api/todos` | `todos` | `todo_service`, `timetable_service` |
| `GET /api/sessions` | `focus_sessions` | `focus_session_service`, `cumulative_stats` |
| `GET /api/stats/daily` | `stats_daily`, `stats_daily_timeslot` | `daily_service`, `timetable_service` |
| `GET /api/analysis/daily` | `analysis_daily` | `daily_service` |
| `GET /api/analysis/cumulative` | `analysis_cumulative` | `cumulative_stats_service` |

> ⚠ **회원가입은 `users`와 `categories`를 함께 만들어야 합니다.**
> `todos.category_id`가 NOT NULL FK라 카테고리 없이는 할 일을 만들 수 없습니다.
>
> ⚠ **기본 카테고리에 `기타`를 반드시 포함하세요.** 로봇이 음성으로 할 일을
> 추가할 때(`add_todo`) 사용자 카테고리 중 가장 비슷한 이름을 고르는데,
> 마땅한 게 없으면 `기타`로 넣습니다. `기타`가 없는 계정은 애매한 할 일이
> 엉뚱하게 첫 번째 카테고리로 들어갑니다. 삭제도 막아 주세요.

### 2. 앱 파일별 작업

| 파일 | 현재 데이터 출처 | 작업 |
|---|---|---|
| `auth_service.dart` (121줄) | Firestore 직접 조회로 로그인 | API 호출 + 세션 토큰 저장 |
| `user_service.dart` (20줄) | `collection('users')` | API 교체 (작음) |
| `todo_service.dart` (67줄) | `collection('todos')` | API 교체 |
| `timetable_service.dart` (165줄) | todos + focus_sessions + stats | API 교체 |
| `focus_session_service.dart` (43줄) | `collection('focus_sessions')` | API 교체 |
| `daily_service.dart` (51줄) | analysis / stats / aggregations | API 교체 |
| `cumulative_stats_service.dart` (297줄) | analysis + sessions + todos | API 교체 |
| **`timer_service.dart` (386줄)** | Firestore + **RTDB `users/$uid/status/current_state`** | **WS `/ws/focus`로 전환 — 가장 큰 작업** |
| `timer_provider.dart` (501줄) | `timer_service` 래퍼 (UI 상태) | 서비스 교체되면 대부분 유지 |
| — | 없음 | **`ApiClient` 신규** (세션 토큰 자동 첨부) |

### 3. `timer_service.dart`가 핵심입니다

여기가 **앱이 로봇과 실시간으로 만나는 유일한 지점**입니다. 현재는 RTDB
`users/$uid/status/current_state`에 세션 상태를 쓰는데, **로봇은 더 이상 그곳을
읽지 않습니다.** WS로 바꿔야 앱↔로봇 동기화가 살아납니다.

```
현재:  앱 → RTDB current_state 쓰기      (로봇이 안 읽음 → 동기화 끊김)
이후:  앱 → WS /ws/focus                 (로봇과 같은 채널)
```

```json
{"type":"auth","token":"<세션 토큰>","source":"app"}
{"type":"focus_start","mode":"pomodoro","planned_duration_sec":1500}
{"type":"focus_pause","session_id":"...","revision":0}
{"type":"focus_end","session_id":"...","revision":1}
```

메시지 형식은 로봇이 쓰는 것과 동일하고 `source`만 `"app"`입니다.
서버의 `WS_TEST_TOKEN` / `TEST_USER_ID` 하드코딩을 제거하고 세션 토큰 기반으로
바꾸는 작업이 여기 포함됩니다.

> ⚠ **`status`는 일시정지 여부가 아닙니다.** 세션 생명주기(`in_progress`/`completed`)일
> 뿐이고, 일시정지는 `runtime_state`(`running`/`paused`/`null`)에만 있습니다.
> HW에서 이걸 혼동해 pause 무한루프 버그를 겪었습니다.
> ```
> status != "in_progress"     → 종료됨
> runtime_state == "paused"   → 일시정지
> 그 외                        → 진행 중
> ```

### 4. 집계 테이블을 채울 코드가 없습니다

`stats_daily`, `stats_daily_timeslot`, `analysis_daily`, `analysis_cumulative` —
**어느 코드도 이 테이블에 쓰지 않습니다.** 현재 들어있는 값은 테스트 fixture뿐이고
세션이 끝나도 갱신되지 않습니다.

- **(A)** 집계를 쓰지 않고 `focus_sessions`·`focus_session_events`에서 그때그때 계산
  — 데이터가 적어 성능 문제 없고, 집계 불일치 위험도 없음
- **(B)** 세션 종료 시 또는 배치로 집계 갱신 코드 작성

**SW팀이 정할 사항입니다.** 원시 데이터는 이미 쌓이고 있으므로 나중에 언제든 (B)로
전환할 수 있습니다.

참고로 감지 이벤트는 `focus_session_events`에 `kind`(`drowsy`/`phone`/`pause`),
`started_at`, `ended_at`, `duration_sec`로 개별 row가 쌓입니다. 아래처럼 하면
"언제 / 몇 회 / 각 몇 분 / 총 몇 분"이 그대로 나옵니다.

```sql
SELECT to_char(started_at AT TIME ZONE 'Asia/Seoul','HH24') AS 시각,
       kind, count(*) AS 횟수, sum(duration_sec) AS 총초,
       array_agg(duration_sec ORDER BY started_at) AS 각각초
FROM focus_session_events WHERE kind IN ('drowsy','phone')
GROUP BY 1,2 ORDER BY 1;
```

### 5. 테스트 계정 준비 (2~5개)

계정마다 아래를 1회씩 수행합니다.

1. **앱 회원가입** → `users` + `categories` 생성
2. 생성된 `id`(uuid)를 **HW팀에 전달**
3. HW팀이 device 슬롯과 토큰을 발급 (`--device-uid deskibot-slot-N`)

> `devices.user_id`에 UNIQUE 제약이 있어 **로봇이 1대라도 사용자마다 별도 `devices`
> row가 필요**합니다. `device_uid`는 MAC이 아니라 `deskibot-slot-1..5` 같은 임의
> 슬롯 이름으로 두세요. MAC으로 하면 1대 = 1명이 되어 시분할이 불가능해집니다.

**사용자 전환 시 앱과 로봇을 반드시 쌍으로 바꿔야 합니다.**

```
1. 로봇: 진행 중인 세션이 있으면 먼저 종료
         (남기고 바꾸면 이전 사용자 세션이 in_progress로 남아 새 집중이 거부됨)
2. 로봇: 시리얼에  token <해당 사용자 토큰>
3. 앱:   로그아웃 → 해당 계정으로 로그인
```

### 6. 작업 순서 제안

```
1. ApiClient + auth (로그인/회원가입)     ← 나머지 전부의 전제
2. todo_service, user_service            ← 작고 검증이 쉬움
3. timer_service → WS 전환               ← 가장 크고, 로봇 연동 지점
4. 통계·분석 서비스                        ← 집계 정책(4절) 결정 후
```
