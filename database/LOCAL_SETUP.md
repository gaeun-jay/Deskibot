# 로컬 PostgreSQL에 EC2 DB 복원하기

EC2(`api.deskibot.co.kr`)의 `deskibot` DB를 로컬 개발용으로 그대로 가져오는 절차.
**EC2는 HW팀과 공유하므로 로컬에서만 실험한다.**

## 이 폴더의 파일

| 파일 | 내용 | Git |
|---|---|---|
| `deskibot_schema_v1.sql` | 최초 스키마 (테이블 11개, 트리거, 인덱스) | 커밋 대상 |
| `002_focus_realtime.sql` | focus_sessions에 실시간 동기화 컬럼 추가 | 커밋 대상 |
| `003_focus_events_realtime.sql` | focus_session_events 열린 감지 허용 | 커밋 대상 |
| `004_focus_outcome_view.sql` | focus_session_outcomes 뷰 (status → end_reason). HW팀 작성 | 커밋 대상 |
| `005_analysis_daily_title.sql` | analysis_daily에 title/subtitle 추가 + 기존 행 백필 | 커밋 대상 |
| `006_backfill_analysis_started_date.sql` | users.analysis_started_date 채우기 | 커밋 대상 |
| `deskibot_full_20260813.sql` | **스키마 + 데이터 전체 덤프** | `.gitignore` 처리됨 |

## ⚠️ 코드를 받았으면 이걸 먼저 실행한다

`git pull` 로 서버 코드를 받았다면 **DB 마이그레이션을 먼저 돌려야 한다.**
안 돌리면 `GET /api/analysis/daily` 부터 500 이 난다 (없는 컬럼을 SELECT 한다).

```bash
cd database
psql -U deskibot_app -d deskibot -v ON_ERROR_STOP=1 -f 004_focus_outcome_view.sql
psql -U deskibot_app -d deskibot -v ON_ERROR_STOP=1 -f 005_analysis_daily_title.sql
psql -U deskibot_app -d deskibot -v ON_ERROR_STOP=1 -f 006_backfill_analysis_started_date.sql
```

셋 다 **재실행해도 안전하다.** 이미 적용됐으면 아무 일도 일어나지 않으니, 내 DB에
뭐가 적용됐는지 모르겠으면 그냥 세 개 다 돌리면 된다.

적용됐는지 확인:

```bash
psql -U deskibot_app -d deskibot -c "\d analysis_daily"   # title, subtitle 있어야 함
psql -U deskibot_app -d deskibot -c "\dv"                 # focus_session_outcomes 있어야 함
```

> `peer authentication failed` 가 나면 `-h 127.0.0.1` 을 붙인다. 소켓 접속은 리눅스
> 계정명과 DB 계정명이 같아야 통과하는 `peer` 인증을 쓰기 때문이다.

**EC2 적용 현황 (2026-08-22 기준)** — `004`는 적용됨, `005`·`006`은 **미적용**.

덤프는 2026-08-13 06:5x UTC 시점 스냅샷이다. HW팀이 계속 쓰므로 시간이 지나면
실서버와 벌어진다. 필요하면 아래 명령으로 다시 받는다.

## 사전 준비

- **PostgreSQL 16.x** (EC2가 16.14). 복원은 psql 16 이상으로 해야 한다 —
  덤프 앞뒤에 `\restrict` / `\unrestrict` 메타명령이 들어 있어서
  구버전 psql로는 실패한다. pgAdmin에 딸린 구버전 클라이언트 주의.

## 복원

### 1. 역할 만들기

덤프에 `OWNER TO deskibot_app`이 16곳 들어 있어서 역할이 먼저 있어야 한다.
비밀번호는 **로컬 전용으로 새로 정한다** (EC2 것을 쓰지 말 것).

```sql
-- psql -U postgres
CREATE ROLE deskibot_app WITH LOGIN PASSWORD '로컬용_비밀번호';
CREATE DATABASE deskibot OWNER deskibot_app;
```

### 2. 덤프 넣기

`pgcrypto` 확장 생성이 들어 있어 **superuser로 복원**해야 한다.

```bash
psql -U postgres -d deskibot -f deskibot_full_20260813.sql
```

### 3. 확인

```sql
-- psql -U postgres -d deskibot
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;
```

기대값 (EC2 2026-08-13 기준):

```
analysis_cumulative     4     focus_sessions         28
analysis_daily          4     pairing_codes           0
categories              6     stats_daily             4
devices                 2     stats_daily_timeslot    8
focus_session_events   38     todos                  18
                              users                   2
```

## 스키마만 새로 만들고 싶을 때

데이터 없이 빈 DB가 필요하면 덤프 대신 SQL 3개를 **순서대로** 실행한다.

```bash
psql -U postgres -d deskibot_clean -f deskibot_schema_v1.sql
psql -U postgres -d deskibot_clean -f 002_focus_realtime.sql
psql -U postgres -d deskibot_clean -f 003_focus_events_realtime.sql
psql -U postgres -d deskibot_clean -f 004_focus_outcome_view.sql
```

> `005`는 `deskibot_schema_v1.sql` 에 이미 title/subtitle 이 들어 있어서
> 빈 DB에는 실행할 필요가 없다. 실행해도 아무 일도 일어나지 않는다.

> `002`는 `focus_sessions`에 `NOT NULL` 컬럼(`initiated_by`, `last_changed_by`)을
> 기본값 없이 추가하므로, 기존 행이 있는 DB에는 그대로 적용되지 않는다.
> 빈 DB에만 이 순서가 통한다.

## 로컬 .env

EC2 `.env`와 섞이지 않게 별도 파일로 둔다.

```
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=deskibot
DB_USER=deskibot_app
DB_PASSWORD=로컬용_비밀번호
```

## 덤프 다시 받기

EC2에 파일을 만들지 않고 stdout으로 바로 흘려받는다 (읽기 전용).

```bash
ssh -i ~/.ssh/deskibot-nayoung-key.pem ubuntu@15.168.152.125 \
  'sudo -n -u postgres pg_dump -d deskibot --format=plain --encoding=UTF8 --no-privileges' \
  > deskibot_full_$(date +%Y%m%d).sql
```

## 주의

- 로컬 계정 두 개(`deskibot_test`, `deskibot_test_worker`)는 `password_hash`가
  `TEST_ACCOUNT...` 플레이스홀더라 **로그인이 안 된다.** 인증을 테스트하려면
  회원가입 API로 새 계정을 만들어야 한다.
- 안드로이드 에뮬레이터에서 로컬 FastAPI를 부를 때는 `127.0.0.1`이 아니라 `10.0.2.2`.
