BEGIN;

ALTER TABLE focus_session_events
    ALTER COLUMN ended_at DROP NOT NULL;

ALTER TABLE focus_session_events
    ADD CONSTRAINT chk_pause_event_must_be_closed
    CHECK (
        kind <> 'pause'
        OR ended_at IS NOT NULL
    );

CREATE UNIQUE INDEX
    uq_focus_events_one_open_detection
ON focus_session_events (
    session_id,
    kind
)
WHERE
    ended_at IS NULL
    AND kind IN ('drowsy', 'phone');

COMMIT;