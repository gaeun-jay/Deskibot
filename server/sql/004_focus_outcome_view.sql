-- 004_focus_outcome_view.sql
--
-- focus_sessions.status를 로그 분석에서 읽기 쉬운 이름으로 노출하는 읽기 전용 뷰.
--
-- status 값 자체는 바꾸지 않는다. 바꾸면 네 군데가 동시에 깨진다:
--   · app/focus_service.py의 FINAL_STATUSES가 모르는 값을 invalid_outcome으로
--     거부 → focus_end 실패 → 세션이 in_progress로 남고
--     uq_focus_sessions_one_active_per_user에 걸려 다음 세션 시작이 막힘
--   · 앱 timer_service.dart의 3분기가 모르는 값을 'start'로 떨어뜨려
--     종료된 세션을 진행 중으로 표시
--   · focus_sessions의 status CHECK 제약
--   · 로봇 펌웨어가 보내는 outcome
--
-- 그래서 값은 그대로 두고 이름만 여기서 붙인다. 기존 소비자는 전혀 건드리지 않는다.
--
-- ※ 이 파일은 HW팀이 작성했지만 적용 대상은 SW팀 DB다.
--   database/ 시퀀스의 004로 옮겨 관리해 주시면 됩니다.

BEGIN;

-- 컬럼을 명시적으로 나열한다. SELECT *를 쓰면 focus_sessions에 컬럼이 추가될 때
-- CREATE OR REPLACE VIEW가 실패한다 (기존 컬럼 뒤에만 추가할 수 있는데,
-- 새 테이블 컬럼은 end_reason 앞에 끼어들기 때문).
CREATE OR REPLACE VIEW focus_session_outcomes AS
SELECT
    s.id,
    s.user_id,
    s.type,
    s.status,
    s.title,
    s.started_at,
    s.ended_at,
    s.session_date,
    s.planned_duration_sec,
    s.actual_duration_sec,
    s.total_pause_duration_sec,
    s.initiated_by,
    s.last_changed_by,

    -- 종료 사유. 진행 중인 세션은 아직 사유가 없으므로 NULL이다.
    CASE s.status
        WHEN 'completed'   THEN 'timer_completed'  -- 뽀모도로 타이머 만료 / 스톱워치 정상 종료
        WHEN 'incomplete'  THEN 'user_stopped'     -- 사용자가 직접 종료 (로봇은 화면 두 번 탭)
        WHEN 'interrupted' THEN 'no_user'          -- 자리 비움 5분으로 시스템이 강제 종료
        ELSE NULL                                  -- in_progress
    END AS end_reason
FROM focus_sessions AS s;

COMMENT ON VIEW focus_session_outcomes IS
    '로그 분석용 focus_sessions 뷰. end_reason은 status를 읽기 쉬운 이름으로 옮긴 것이다.';

COMMENT ON COLUMN focus_session_outcomes.end_reason IS
    'timer_completed(타이머 만료) / user_stopped(사용자 종료) / no_user(자리 비움 5분) / NULL(진행 중)';

COMMIT;
