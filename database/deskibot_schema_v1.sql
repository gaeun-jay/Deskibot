-- =============================================================================
-- Deskibot PostgreSQL schema v1 (execution-ready, integrity-hardened)
-- Based on the 2026-07-16 final schema.
--
-- Global rules:
--   1. All timestamps use timestamptz. The API rejects timestamps without offsets.
--   2. All durations use seconds.
--   3. IDs use UUID except todos, focus_session_events, devices, and reports.
--   4. Enum-like values use CHECK constraints rather than native ENUM types.
--   5. RealtimeDB is not used. Session IDs are client-generated UUIDs.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

-- users -----------------------------------------------------------------------
CREATE TABLE users (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  login_id               TEXT UNIQUE NOT NULL,
  password_hash          TEXT NOT NULL, -- Argon2id; do not use plain SHA-256
  name                   TEXT NOT NULL,
  user_type              TEXT NOT NULL CHECK (user_type IN ('student', 'worker')),
  analysis_started_date  DATE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  CHECK (btrim(login_id) <> ''),
  CHECK (btrim(name) <> '')
);

-- categories ------------------------------------------------------------------
CREATE TABLE categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  color       TEXT NOT NULL,
  sort_order  INT NOT NULL DEFAULT 0,

  -- Required for the composite FK from todos. It guarantees that a category
  -- and its owner are treated as one consistent reference target.
  UNIQUE (id, user_id),
  UNIQUE (user_id, name),
  CHECK (btrim(name) <> ''),
  CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  CHECK (sort_order >= 0)
);

CREATE INDEX idx_categories_user_sort
  ON categories(user_id, sort_order);

-- Serialize category inserts for the same user before checking the five-item
-- limit, so concurrent requests cannot both pass the count check.
CREATE OR REPLACE FUNCTION enforce_category_limit()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM 1
  FROM users
  WHERE id = NEW.user_id
  FOR UPDATE;

  IF (SELECT count(*) FROM categories WHERE user_id = NEW.user_id) >= 5 THEN
    RAISE EXCEPTION 'category limit (5) exceeded for user %', NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_category_limit
  BEFORE INSERT ON categories
  FOR EACH ROW EXECUTE FUNCTION enforce_category_limit();

-- todos -----------------------------------------------------------------------
CREATE TABLE todos (
  id                 BIGSERIAL PRIMARY KEY,
  user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category_id        UUID NOT NULL,
  content            TEXT NOT NULL,
  date               DATE NOT NULL,
  deadline_time      TIME,
  notify             BOOLEAN NOT NULL DEFAULT false,
  notify_before_min  INT,
  is_done            BOOLEAN NOT NULL DEFAULT false,

  -- Prevent a user's todo from referring to another user's category.
  FOREIGN KEY (category_id, user_id)
    REFERENCES categories(id, user_id)
    ON DELETE RESTRICT,

  CHECK (btrim(content) <> ''),
  CHECK (
    (notify = true AND deadline_time IS NOT NULL
                        AND notify_before_min IS NOT NULL
                        AND notify_before_min >= 0)
    OR
    (notify = false AND notify_before_min IS NULL)
  )
);

CREATE INDEX idx_todos_user_date
  ON todos(user_id, date);

CREATE INDEX idx_todos_user_open_date
  ON todos(user_id, date)
  WHERE is_done = false;

-- focus_sessions --------------------------------------------------------------
-- The ESP or app creates the UUID. There is no RealtimeDB ID mapping.
CREATE TABLE focus_sessions (
  id                        UUID PRIMARY KEY,
  user_id                   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type                      TEXT NOT NULL
                              CHECK (type IN ('pomodoro', 'stopwatch')),
  status                    TEXT NOT NULL
                              CHECK (status IN (
                                'in_progress', 'completed', 'incomplete', 'interrupted'
                              )),
  title                     TEXT,
  started_at                TIMESTAMPTZ NOT NULL,
  ended_at                  TIMESTAMPTZ,
  session_date              DATE GENERATED ALWAYS AS
                              ((started_at AT TIME ZONE 'Asia/Seoul')::date) STORED,
  planned_duration_sec      INT,
  actual_duration_sec       INT,
  total_pause_duration_sec  INT NOT NULL DEFAULT 0,

  CHECK (title IS NULL OR btrim(title) <> ''),
  CHECK (ended_at IS NULL OR ended_at >= started_at),
  CHECK (
    (status = 'in_progress' AND ended_at IS NULL)
    OR
    (status <> 'in_progress' AND ended_at IS NOT NULL)
  ),
  CHECK (
    (type = 'pomodoro' AND planned_duration_sec IS NOT NULL
                       AND planned_duration_sec > 0)
    OR
    (type = 'stopwatch' AND planned_duration_sec IS NULL)
  ),
  CHECK (actual_duration_sec IS NULL OR actual_duration_sec >= 0),
  CHECK (total_pause_duration_sec >= 0),
  CHECK (type = 'stopwatch' OR total_pause_duration_sec = 0)
);

CREATE INDEX idx_sessions_user_started
  ON focus_sessions(user_id, started_at);

CREATE INDEX idx_sessions_user_date
  ON focus_sessions(user_id, session_date);

CREATE INDEX idx_sessions_user_active
  ON focus_sessions(user_id, started_at)
  WHERE status = 'in_progress';

-- focus_session_events --------------------------------------------------------
CREATE TABLE focus_session_events (
  id           BIGSERIAL PRIMARY KEY,
  session_id   UUID NOT NULL REFERENCES focus_sessions(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('drowsy', 'phone', 'pause')),
  started_at   TIMESTAMPTZ NOT NULL,
  ended_at     TIMESTAMPTZ NOT NULL,
  duration_sec INT GENERATED ALWAYS AS
                 (EXTRACT(EPOCH FROM (ended_at - started_at))::int) STORED,

  CHECK (ended_at >= started_at)
);

CREATE INDEX idx_events_session_started
  ON focus_session_events(session_id, started_at);

-- devices ---------------------------------------------------------------------
-- One user can have at most one paired robot. PostgreSQL permits multiple NULL
-- values in a UNIQUE column, so multiple unpaired devices remain possible.
CREATE TABLE devices (
  id            BIGSERIAL PRIMARY KEY,
  device_uid    TEXT UNIQUE NOT NULL,
  user_id       UUID UNIQUE REFERENCES users(id) ON DELETE SET NULL,
  token_hash    TEXT UNIQUE,
  paired_at     TIMESTAMPTZ,
  last_seen_at  TIMESTAMPTZ,

  CHECK (btrim(device_uid) <> ''),
  CHECK (
    user_id IS NULL
    OR (token_hash IS NOT NULL AND paired_at IS NOT NULL)
  )
);

-- pairing_codes ---------------------------------------------------------------
CREATE TABLE pairing_codes (
  code         TEXT PRIMARY KEY CHECK (code ~ '^[0-9]{6}$'),
  device_uid   TEXT NOT NULL REFERENCES devices(device_uid) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ NOT NULL,
  consumed_at  TIMESTAMPTZ,

  CHECK (expires_at > created_at),
  CHECK (
    consumed_at IS NULL
    OR (consumed_at >= created_at AND consumed_at <= expires_at)
  )
);

CREATE INDEX idx_pairing_codes_device
  ON pairing_codes(device_uid);

CREATE INDEX idx_pairing_codes_expires
  ON pairing_codes(expires_at)
  WHERE consumed_at IS NULL;

-- stats_daily -----------------------------------------------------------------
CREATE TABLE stats_daily (
  user_id                UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date                   DATE NOT NULL,
  pomodoro_count         INT NOT NULL DEFAULT 0,
  pomodoro_duration_sec  INT NOT NULL DEFAULT 0,
  stopwatch_count        INT NOT NULL DEFAULT 0,
  stopwatch_duration_sec INT NOT NULL DEFAULT 0,
  drowsy_count           INT NOT NULL DEFAULT 0,
  drowsy_duration_sec    INT NOT NULL DEFAULT 0,
  phone_count            INT NOT NULL DEFAULT 0,
  phone_duration_sec     INT NOT NULL DEFAULT 0,
  todo_total             INT NOT NULL DEFAULT 0,
  todo_done              INT NOT NULL DEFAULT 0,

  PRIMARY KEY (user_id, date),
  CHECK (pomodoro_count >= 0),
  CHECK (pomodoro_duration_sec >= 0),
  CHECK (stopwatch_count >= 0),
  CHECK (stopwatch_duration_sec >= 0),
  CHECK (drowsy_count >= 0),
  CHECK (drowsy_duration_sec >= 0),
  CHECK (phone_count >= 0),
  CHECK (phone_duration_sec >= 0),
  CHECK (todo_total >= 0),
  CHECK (todo_done >= 0 AND todo_done <= todo_total)
);

-- Backfill missing dates if the daily job is skipped. Daily todo totals are
-- frozen snapshots; cumulative analysis may be recalculated from source rows.

-- stats_daily_timeslot --------------------------------------------------------
-- Slot boundaries: dawn 00-06, morning 06-12, afternoon 12-18, night 18-24.
-- Sessions and events belong to one slot based on their start time.
CREATE TABLE stats_daily_timeslot (
  user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date                DATE NOT NULL,
  slot                TEXT NOT NULL
                        CHECK (slot IN ('dawn', 'morning', 'afternoon', 'night')),
  focus_duration_sec  INT NOT NULL DEFAULT 0,
  drowsy_count        INT NOT NULL DEFAULT 0,
  phone_count         INT NOT NULL DEFAULT 0,

  PRIMARY KEY (user_id, date, slot),
  CHECK (focus_duration_sec >= 0),
  CHECK (drowsy_count >= 0),
  CHECK (phone_count >= 0)
);

-- analysis_daily --------------------------------------------------------------
CREATE TABLE analysis_daily (
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date          DATE NOT NULL,
  advice        TEXT NOT NULL,
  generated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, date),
  CHECK (btrim(advice) <> '')
);

-- analysis_cumulative ---------------------------------------------------------
CREATE TABLE analysis_cumulative (
  id            BIGSERIAL PRIMARY KEY,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_type   TEXT NOT NULL
                  CHECK (period_type IN (
                    'weekly', 'monthly', 'quarterly', 'half_yearly', 'yearly'
                  )),
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,
  summary       TEXT NOT NULL,
  patterns      JSONB NOT NULL DEFAULT '[]'::jsonb,
  routine       JSONB NOT NULL DEFAULT '[]'::jsonb,
  generated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (user_id, period_type, period_start),
  CHECK (period_end >= period_start),
  CHECK (btrim(summary) <> ''),
  CHECK (jsonb_typeof(patterns) = 'array'),
  CHECK (jsonb_typeof(routine) = 'array')
);

CREATE INDEX idx_analysis_cumulative_history
  ON analysis_cumulative(user_id, period_type, period_start DESC);

COMMIT;
