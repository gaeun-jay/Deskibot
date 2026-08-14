# 누적 분석 서버 포팅 (Node/Express + Firestore → FastAPI + PostgreSQL)

기존 `platform/app/server/` (Node)의 누적 분석 기능을 SW FastAPI 서버로 옮긴 것.
**아직 EC2에 배포하지 않았음.** 아래 절차를 검토한 뒤 진행할 것.

## 추가된 파일

| 파일 | 대응 Node 파일 | 역할 |
|---|---|---|
| `app/prompt.py` | `src/prompt.js` | 기간별 Claude 프롬프트 빌더 |
| `app/analysis_service.py` | `src/firestore.js` + `src/analyze.js` | 데이터 조회 → Claude 호출 → DB upsert |
| `app/analysis_api.py` | `src/index.js` | REST 엔드포인트 |

## 라우트 매핑

| Node | FastAPI |
|---|---|
| `POST /analyze/weekly` | `POST /api/analysis/cumulative/weekly` |
| `POST /analyze/monthly` | `POST /api/analysis/cumulative/monthly` |
| `POST /analyze/quarterly` | `POST /api/analysis/cumulative/quarterly` |
| `POST /analyze/6monthly` | `POST /api/analysis/cumulative/half_yearly` |
| `POST /analyze/yearly` | `POST /api/analysis/cumulative/yearly` |
| — (신규) | `GET /api/analysis/cumulative/{period_type}/latest?user_id=...` |

요청 본문은 Node와 동일하게 `{"user_id": "<uuid>"}`.
응답은 `{ok, data}` 래퍼 대신 `analysis_cumulative` 레코드를 그대로 반환하고,
오류는 HTTP 상태 코드 + `{"detail": {"code", "message"}}`로 전달한다.

## main.py 패치 (2줄)

```python
from app.analysis_api import router as analysis_router   # 기존 import 블록 끝에
...
app.include_router(analysis_router)                      # app = FastAPI(...) 이후
```

## 의존성

`anthropic` 패키지가 SW venv에 없음. 설치 후 requirements.txt 갱신 필요.

```bash
cd ~/Deskibot/server/sw
.venv/bin/pip install anthropic
.venv/bin/pip freeze > requirements.txt
```

## .env 추가 키 (server/sw/.env)

```
ANTHROPIC_API_KEY=...     # HW .env에 이미 있는 키를 재사용하거나 별도 발급
CLAUDE_MODEL=claude-opus-5  # 선택. 미설정 시 claude-opus-5
```

## nginx — 타임아웃 확인 필요

현재 `/api/`의 `proxy_read_timeout`은 **60초**인데, Opus 5 호출은 이를 넘길 수 있다.
분석 경로에만 별도 location 블록을 두는 것을 권장한다.

```nginx
location /api/analysis/ {
    proxy_pass http://127.0.0.1:8001;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 180s;
    proxy_send_timeout 180s;
}
```

## 검증 로컬 결과

- 세 모듈 모두 문법 검사 통과 (Python 3.12)
- `prompt.py` 기능 테스트 통과 (요일 매핑, 결측일 처리, 시간대 포맷, 월별 집계 정렬)
- 3개 SELECT 전부 실제 스키마에서 정상 실행
- upsert는 `EXPLAIN`으로만 검증 (미실행). ON CONFLICT 대상이
  `analysis_cumulative_user_id_period_type_period_start_key`와 일치함을 확인

## 미검증

- Claude 실제 호출 (anthropic 미설치 상태라 실행 불가)
- upsert 실제 실행
- 엔드포인트 통합 테스트

## 배포 후 스모크 테스트

```bash
# 재시작 전 import 검증
cd ~/Deskibot/server/sw && .venv/bin/python -c "from app.main import app"

sudo systemctl restart deskibot-sw
curl -fsS http://127.0.0.1:8001/api/health

curl -sS -X POST http://127.0.0.1:8001/api/analysis/cumulative/weekly \
  -H 'Content-Type: application/json' \
  -d '{"user_id":"<TEST_USER_ID>"}' | jq
```

## 남은 이슈

1. **인증 없음** — `user_id`를 요청 본문으로 받는다. 아무나 남의 분석을 생성·조회할 수 있다.
   `/api/analysis/`는 인증이 붙기 전까지 외부 노출하지 말 것.
2. **커넥션 풀 없음** — 기존 SW 코드 관례를 따라 요청마다 새 연결을 연다.
   HW는 `psycopg_pool`을 쓰므로 추후 통일 필요.
3. **동기 호출** — 요청이 Claude 응답까지 블로킹된다. 사용자가 늘면
   비동기 잡 + 상태 폴링 구조로 바꿔야 한다.
4. **집계 데이터 공급원 부재** — `stats_daily` / `stats_daily_timeslot` /
   `analysis_daily`를 채우는 코드가 아직 없다. 현재 값은 테스트 픽스처.
   이게 없으면 분석 결과가 의미 없다.
5. **Node 서버** — `platform/app/server/`는 이 포팅으로 대체된다.
   전환 확인 후 제거할 것. `serviceAccountKey.json`(Firebase 개인키)도 함께 폐기.
