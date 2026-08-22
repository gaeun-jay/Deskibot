-- 006_backfill_analysis_started_date.sql
--
-- users.analysis_started_date 를 기존 일간 분석 기록에서 채운다.
--
-- 이 컬럼은 deskibot_schema_v1.sql 에 처음부터 있었지만 여태 아무도 쓰지 않아
-- 대부분 NULL 이었다 (서버는 serialize_user 에서 읽기만 했다). 이제 누적 분석이
-- "이 유저가 그 기간을 통째로 겪었는가"를 이 값으로 판단하므로, NULL 이면
-- 누적 리포트가 영영 생성되지 않는다.
--
-- 앞으로는 daily_analysis_service.generate_daily_analysis 가 일간 분석을 만들
-- 때마다 가장 이른 날짜로 맞춰준다. 이 파일은 그 이전에 쌓인 기록을 위한 것이다.
--
-- 재실행해도 안전하다 (이미 값이 있으면 더 이른 날짜일 때만 당긴다).

BEGIN;

UPDATE users u
   SET analysis_started_date = first_analysis.started
  FROM (
        SELECT user_id, MIN(date) AS started
          FROM analysis_daily
         GROUP BY user_id
       ) AS first_analysis
 WHERE u.id = first_analysis.user_id
   AND (u.analysis_started_date IS NULL
        OR u.analysis_started_date > first_analysis.started);

COMMIT;

-- 확인용
--   SELECT login_id, analysis_started_date FROM users
--    WHERE analysis_started_date IS NOT NULL ORDER BY analysis_started_date;
--
-- 일간 분석 기록이 아예 없는 유저는 NULL 로 남는다. 의도된 것이다 — 분석이
-- 시작되지 않았으니 누적 리포트의 대상도 아니다.
