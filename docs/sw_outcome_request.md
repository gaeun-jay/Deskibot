# SW팀 요청 — 집중 세션 종료 사유 구분

작성 2026-08-19 / HW팀

이 문서 하나만 읽으면 됩니다. `sw_handoff.md`를 따로 열지 않아도 되도록
필요한 맥락을 여기 다 옮겨 놨습니다.

**부탁드릴 것은 두 가지입니다.**

1. 이미 만들어 둔 뷰의 **마이그레이션 파일을 `database/` 시퀀스에 넣기**
   (프로덕션 DB에는 HW팀이 이미 적용했습니다 — 3절)
2. `daily_analysis_service.py` 2줄 수정

---

## 1. 무엇이 바뀌었나

로봇에 **자리 비움 감지**가 들어갔습니다.

RPi가 카메라로 "책상에 아무도 없음"을 5분 이상 확인하면 ESP에 알리고,
ESP는 **진행 중인 뽀모도로를 강제 종료**합니다. 사용자가 화면을 두 번 탭해
직접 끄는 것과는 다른, **시스템이 끊은 종료**입니다.

여기서 문제가 하나 드러났습니다.

**지금까지 로봇이 보내는 모든 종료가 DB에 `completed`로 기록되고 있었습니다.**
로봇이 `focus_end`에 `outcome`을 싣지 않았고, 서버가
`message.get("outcome", "completed")`로 기본값을 채웠기 때문입니다
(`app/main.py`). 타이머를 끝까지 채운 세션과 사용자가 중간에 끈 세션이
DB에서 구분되지 않았습니다.

로봇 펌웨어를 고쳐서 이제 `outcome`을 함께 보냅니다.

---

## 2. `focus_end`의 `outcome` — 서버는 이미 지원합니다

서버 코드는 **바꿀 것이 없습니다.** `end_focus_session()`이 원래 `outcome`
파라미터를 받고 있었고, 로봇이 그동안 안 보냈을 뿐입니다.

```json
{"type":"focus_end","session_id":"...","revision":2,"outcome":"incomplete"}
```

이 값이 그대로 `focus_sessions.status`가 됩니다.

| `outcome` | 의미 | 보내는 쪽 |
|---|---|---|
| `completed` | 뽀모도로 타이머 만료 / 스톱워치 정상 종료 | 로봇·앱 |
| `incomplete` | 사용자가 직접 강제 종료 (로봇은 화면 두 번 탭) | 로봇·앱 |
| `interrupted` | **자리 비움 5분으로 시스템이 강제 종료** | 로봇 |

- 세 값 모두 `focus_sessions`의 기존 CHECK
  (`in_progress / completed / incomplete / interrupted`)에 이미 있습니다.
  **스키마 마이그레이션 없습니다.**
- `FINAL_STATUSES`(`app/focus_service.py`)도 세 값을 그대로 갖고 있습니다.
- 스톱워치는 `outcome`을 아예 싣지 않으므로 종전대로 `completed`입니다.
- 자리 비움 자체는 `focus_session_events`에 남기지 않습니다.
  `kind`의 CHECK가 `drowsy | phone | pause`뿐이라 값을 늘리려면 마이그레이션이
  필요한데, 세션 `status`만으로 분석이 되므로 스키마를 건드리지 않는 쪽을
  골랐습니다. 이벤트 단위 기록이 필요해지면 그때 따로 요청드리겠습니다.

---

## 3. 부탁 ① — 뷰 마이그레이션 파일을 시퀀스에 넣어주세요

`incomplete` / `interrupted`가 로그 분석에서 한눈에 안 읽혀서, **값은 그대로 두고
이름만 붙이는 읽기 전용 뷰**를 만들었습니다.

```
HW 레포 esp 브랜치 → server/sql/004_focus_outcome_view.sql
```

> ### 프로덕션 DB에는 2026-08-19에 이미 적용했습니다
>
> HW팀이 `deskibot-osaka`에서 직접 돌렸습니다. **지금 바로 조회 가능합니다.**
> 그래서 부탁드릴 건 DB 작업이 아니라 **파일을 `database/` 시퀀스의 `004`로
> 넣는 것**입니다.
>
> 안 넣으면 뷰가 프로덕션에만 존재하고 마이그레이션에는 없는 상태가 됩니다.
> 나중에 마이그레이션으로 DB를 다시 세우면 뷰가 사라지고, 그 시점에
> `daily_analysis_service.py`가 `relation "focus_session_outcomes" does not exist`로
> 죽습니다. **4절 코드 변경이 먼저 배포돼 있으면 더 나쁩니다.**

뷰 하나 추가라 기존 테이블·제약·앱 어느 쪽도 건드리지 않습니다.

| `status` | 뷰의 `end_reason` |
|---|---|
| `completed` | `timer_completed` |
| `incomplete` | `user_stopped` |
| `interrupted` | `no_user` |
| `in_progress` | `NULL` |

`focus_sessions`의 컬럼을 하나도 빼지 않고 그대로 통과시키므로, 조회 쿼리는
`FROM`만 바꾸면 됩니다.

```sql
SELECT end_reason, count(*), avg(actual_duration_sec)
FROM focus_session_outcomes
WHERE user_id = %s AND session_date >= %s
GROUP BY end_reason;
```

---

## 4. 부탁 ② — `daily_analysis_service.py` 2줄

하루 분석 프롬프트에 종료 사유가 그대로 실립니다. 지금은 `(incomplete)`가
들어가서 **모델이 "자리를 떠서 끊긴 것"과 "본인이 그만둔 것"을 구분하지
못합니다.** 조언 문구가 갈려야 하는 지점이라 여기만 바꿔주시면 좋겠습니다.

```python
# :110  조회를 뷰로
SELECT type, status, end_reason, actual_duration_sec
FROM focus_session_outcomes
WHERE user_id = %s AND session_date = %s AND status <> 'in_progress'

# :80   프롬프트에 싣는 값
f" ({s['end_reason']})"     # 기존: f" ({s['status']})"
```

> 줄 번호는 `origin/sw-temp` 스냅샷 기준입니다. 그 사이 파일이 바뀌었으면
> `f" ({s['status']})"` 문자열로 찾으시면 됩니다.

---

## 5. 하지 말아야 할 것

**`focus_sessions.status` 값 자체를 `user_stopped` / `no_user` 같은 이름으로
바꾸지 말아 주세요.** 네 군데가 동시에 깨집니다.

- `app/focus_service.py`의 `FINAL_STATUSES`가 모르는 값을 `invalid_outcome`으로
  거부 → `focus_end` 실패 → 세션이 `in_progress`로 남고 →
  `uq_focus_sessions_one_active_per_user`에 걸려 **다음 세션 시작까지 막힙니다.**
- 앱 `timer_service.dart`의 3분기가 모르는 값을 `'start'`로 떨어뜨려 종료된
  세션을 **진행 중으로 표시**합니다. 에러도 안 납니다.
- `focus_sessions`의 `status` CHECK 제약
- 로봇 펌웨어가 보내는 `outcome`

이름이 안 읽히는 문제는 뷰의 `end_reason`으로 푸는 게 이 문서의 취지입니다.

---

## 6. 이번에 안 하는 것

**`focus_history_service.py`는 건드리지 않습니다.** 앱에 종료 사유를 표시하는
화면이 아직 없어서, API에 `end_reason`을 내려도 읽는 쪽이 없습니다.
앱에 자리가 생기면 그때 앱 작업과 함께 요청드리겠습니다.

(참고 — 나중에 하실 때 주의점: 같은 파일 `:191`의 `RETURNING {_SESSION_COLUMNS}`는
UPDATE 문이라 뷰가 아니라 테이블을 대상으로 합니다. `_SESSION_COLUMNS`에
`end_reason`을 넣으면 그 줄에서 `column "end_reason" does not exist`로 깨지므로,
`RETURNING`용 컬럼 목록을 따로 떼야 합니다.)

---

## 7. 검증 상태 (솔직하게)

- **SQL은 프로덕션에 적용·검증 완료했습니다** (2026-08-19).
  `BEGIN / CREATE VIEW / COMMENT ×2 / COMMIT` 정상 통과했고, 실제 데이터로
  매핑도 확인했습니다:

  ```
     status    |   end_reason    | count
  -------------+-----------------+-------
   completed   | timer_completed |    26
   incomplete  | user_stopped    |     1
   interrupted | no_user         |     1
  ```

  조회 시점에 활성 세션이 없어 `in_progress → NULL` 분기만 데이터로 확인하지
  못했습니다 (`CASE`에 `ELSE NULL`이 있어 동작 자체는 보장됩니다).
- **종단 검증 미완입니다.** 로봇 화면 렌더링까지만 확인했고, RPi가 실제로 5분을
  재서 신호를 보내고 → ESP가 강제 종료하고 → DB에 `interrupted`가 꽂히는
  전 구간은 아직 실기기에서 못 돌려봤습니다. HW 쪽에서 확인 후 공유드리겠습니다.
- 서버·앱 코드는 이번 변경으로 **깨질 곳이 없습니다.** `outcome`은 서버가 원래
  받던 파라미터고, 세 status 값 모두 앱의 3분기에 이미 들어 있습니다.

---

관련 문서: `sw_handoff.md`(로봇↔서버 전체 계약), `rpi_handoff.md`(UART 프로토콜)
