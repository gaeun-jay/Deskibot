BEGIN;

ALTER TABLE focus_sessions
  ADD COLUMN runtime_state TEXT,
  ADD COLUMN paused_at TIMESTAMPTZ,
  ADD COLUMN state_version BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN state_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN initiated_by TEXT NOT NULL,
  ADD COLUMN last_changed_by TEXT NOT NULL,

  ADD CONSTRAINT chk_focus_runtime_state
    CHECK (
      (
        status = 'in_progress'
        AND runtime_state IN ('running', 'paused')
      )
      OR
      (
        status <> 'in_progress'
        AND runtime_state IS NULL
      )
    ),

  ADD CONSTRAINT chk_focus_paused_at
    CHECK (
      (
        runtime_state = 'paused'
        AND paused_at IS NOT NULL
      )
      OR
      (
        runtime_state IS DISTINCT FROM 'paused'
        AND paused_at IS NULL
      )
    ),

  ADD CONSTRAINT chk_focus_state_version
    CHECK (state_version >= 0),

  ADD CONSTRAINT chk_focus_initiated_by
    CHECK (initiated_by IN ('app', 'robot')),

  ADD CONSTRAINT chk_focus_last_changed_by
    CHECK (last_changed_by IN ('app', 'robot'));

-- 한 사용자에게 진행 중인 집중 세션은 최대 하나만 허용한다.
CREATE UNIQUE INDEX uq_focus_sessions_one_active_per_user
  ON focus_sessions(user_id)
  WHERE status = 'in_progress';

COMMIT;