-- 005_analysis_daily_title.sql
--
-- analysis_daily 에 공부일지 제목/부제목(title, subtitle)을 추가한다.
-- 원래 advice 한 컬럼뿐이라 서버가 title/subtitle 을 null 로 내려보내고 있었다.
--
-- deskibot_schema_v1.sql 은 "빈 DB를 처음 만들 때" 쓰는 파일이라 거기만 고치면
-- 이미 돌고 있는 DB(로컬 복원본, EC2)에는 아무 효과가 없다. 그래서 이 파일이 있다.
--
-- ※ 그냥 `ADD COLUMN title TEXT NOT NULL` 은 기존 행이 있으면 실패한다.
--   nullable 로 붙이고 → 백필하고 → NOT NULL 로 조이는 3단계를 거친다.
--
-- 재실행해도 안전하다 (IF NOT EXISTS + 제약 존재 확인).

BEGIN;

-- 1단계: 일단 nullable 로 붙인다.
ALTER TABLE analysis_daily
  ADD COLUMN IF NOT EXISTS title    TEXT,
  ADD COLUMN IF NOT EXISTS subtitle TEXT;

-- 2단계: 이 마이그레이션 이전에 생성된 행을 채운다.
--   그 행들에는 advice 만 있고 title/subtitle 을 만들 재료가 없다. Claude 를
--   다시 부르지 않고 고정 문구로 둔다. 필요하면 나중에
--   POST /api/analysis/daily/generate?date=... 로 해당 날짜만 다시 만들면 된다.
UPDATE analysis_daily
   SET title = '지난 공부일지'
 WHERE title IS NULL OR btrim(title) = '';

UPDATE analysis_daily
   SET subtitle = '제목이 없던 시절에 만들어진 기록이에요'
 WHERE subtitle IS NULL OR btrim(subtitle) = '';

-- 3단계: NOT NULL 로 조인다.
ALTER TABLE analysis_daily
  ALTER COLUMN title    SET NOT NULL,
  ALTER COLUMN subtitle SET NOT NULL;

-- 4단계: 빈 문자열 금지. advice 와 같은 규칙이다.
--   CHECK 제약에는 IF NOT EXISTS 가 없어서 직접 확인한다. 이름은 이름 없는
--   CHECK 를 PostgreSQL 이 자동으로 붙이는 이름과 같게 맞췄다 — 빈 DB에
--   deskibot_schema_v1.sql 로 만든 결과와 제약 이름까지 동일해진다.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'analysis_daily'::regclass
       AND conname  = 'analysis_daily_title_check'
  ) THEN
    ALTER TABLE analysis_daily
      ADD CONSTRAINT analysis_daily_title_check CHECK (btrim(title) <> '');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'analysis_daily'::regclass
       AND conname  = 'analysis_daily_subtitle_check'
  ) THEN
    ALTER TABLE analysis_daily
      ADD CONSTRAINT analysis_daily_subtitle_check CHECK (btrim(subtitle) <> '');
  END IF;
END $$;

COMMENT ON COLUMN analysis_daily.title IS
  '공부일지 제목. 하루 집중/방해 패턴을 요약한 한 문장.';
COMMENT ON COLUMN analysis_daily.subtitle IS
  '공부일지 부제목. title 을 보완하는 핵심 패턴 한 줄.';

COMMIT;
