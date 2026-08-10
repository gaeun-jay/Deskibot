"""
firebase_client.py
------------------
Firebase interface for the RPi detection node.

Responsibilities:
  - Realtime DB : reflect live drowsy/phone detection results under
                  users/{UID}/status/current_state as
                  is_detecting_drowsy / is_detecting_phone
  - Firestore   : append timestamped phone_events / drowsy_events to the
                  active focus session document under
                  users/{UID}/focus_sessions/{session_id}

Write conditions:
  Both writes require an active Pomodoro session, judged from current_state:
      type  == "pomodoro"
      state in ("start", "resume")
  Note the RTDB key is 'state', not 'status'. Anything else — a paused
  session, a different timer type, no session at all — is skipped, and every
  skip is logged with its reason.

Session polling:
  current_state is polled on a background thread once per second and cached,
  so the detection loop never blocks on a network round-trip.

Failure policy:
  Every Firebase call is wrapped — a network error, a missing Firestore
  document, or a permissions failure is logged and swallowed. Firebase
  problems must never take down the detection loop.
"""

import threading
import time

import firebase_admin
from firebase_admin import credentials, db, firestore

SERVICE_ACCOUNT_KEY = "/home/rpi/Deskibot/rpi/comm/serviceAccountKey.json"
DATABASE_URL        = "https://deskibot-b1377-default-rtdb.firebaseio.com/"
UID = "d97de62c-9f30-41b1-8869-00873bd043fe"

# Session gating — see module docstring. Compared case-insensitively.
ACTIVE_TYPE   = "pomodoro"
ACTIVE_STATES = ("start", "resume")

POLL_INTERVAL_SEC = 1.0   # Background refresh period for current_state
#60초로 수정 예정. 튜닝 편이를 위해 5초로 설정해놓음
MIN_EVENT_SEC     = 5    # Events shorter than this are not written to Firestore 


class FirebaseClient:
    """Manages all Firebase I/O from the RPi detection node."""

    def __init__(self):
        cred = credentials.Certificate(SERVICE_ACCOUNT_KEY)
        firebase_admin.initialize_app(cred, {"databaseURL": DATABASE_URL})

        self._rtdb_ref = db.reference(f"users/{UID}")
        self._fs       = firestore.client()

        # Cached snapshot of current_state, refreshed by _poll_loop().
        self._cache_lock = threading.Lock()
        self._type       = ""
        self._state      = ""
        self._session_id = ""
        self._cache_ready = False   # False until the first successful read

        # Start of an ongoing detection event.
        # *_start_mono drives the duration; the date/time strings are display
        # values recorded at the same instant. All reset once the event ends.
        self._phone_start_mono  = None
        self._phone_start_time  = None
        self._phone_start_date  = None
        self._drowsy_start_mono = None
        self._drowsy_start_time = None
        self._drowsy_start_date = None

        self._refresh_state()   # Prime the cache before the loop starts
        threading.Thread(target=self._poll_loop, daemon=True).start()

        print("[Firebase] Connected (Realtime DB + Firestore)")

    # ------------------------------------------------------------------
    # Session state cache
    # ------------------------------------------------------------------
    def _refresh_state(self) -> None:
        """Read current_state once and update the cache. Never raises."""
        try:
            snap = self._rtdb_ref.child("status/current_state").get() or {}
        except Exception as e:
            print(f"[Firebase] current_state read failed — {e}")
            return

        with self._cache_lock:
            self._type        = str(snap.get("type", "") or "")
            self._state       = str(snap.get("state", "") or "")
            self._session_id  = str(snap.get("session_id", "") or "")
            self._cache_ready = True

    def _poll_loop(self) -> None:
        """Background refresh of the session snapshot, once per second."""
        while True:
            time.sleep(POLL_INTERVAL_SEC)
            self._refresh_state()

    def _session_snapshot(self) -> tuple:
        """Return (type, state, session_id, ready) from the cache."""
        with self._cache_lock:
            return self._type, self._state, self._session_id, self._cache_ready

    def _check_active(self) -> tuple:

        """
        Decide whether writes are currently allowed.

        Returns:
            (True, "") when a Pomodoro session is running,
            (False, reason) otherwise — reason is ready to print.
        """

        stype, state, _, ready = self._session_snapshot()

        if not ready:
            return False, "session state not loaded yet"
        if stype.strip().lower() != ACTIVE_TYPE:
            return False, f"type={stype or '(empty)'}"
        if state.strip().lower() not in ACTIVE_STATES:
            return False, f"state={state or '(empty)'}"
        return True, ""

    # ------------------------------------------------------------------
    # Realtime DB
    # ------------------------------------------------------------------
    def update_detection(self, drowsy: bool, phone: bool) -> None:

        """
        Push the live detection results to Realtime DB.

        is_detecting_drowsy / is_detecting_phone hold the detection results
        themselves — they are written by the RPi, not read as enable switches.
        Unlike Firestore events, this is not subject to MIN_EVENT_SEC: the
        real-time state always mirrors the current detection.
        """

        active, reason = self._check_active()
        if not active:
            print(f"[Firebase] skip update_detection — {reason}")
            return

        try:
            self._rtdb_ref.child("status/current_state").update({
                "is_detecting_drowsy": bool(drowsy),
                "is_detecting_phone":  bool(phone),
            })
        except Exception as e:
            print(f"[Firebase] update_detection failed — {e}")

    # ------------------------------------------------------------------
    # Firestore — phone events
    # ------------------------------------------------------------------
    def on_phone_start(self) -> None:
        """Record the start of a phone detection event."""
        active, reason = self._check_active()
        if not active:
            print(f"[Firebase] skip phone_start — {reason}")
            return
        self._phone_start_mono = time.monotonic()
        self._phone_start_time = time.strftime("%H:%M:%S")
        self._phone_start_date = time.strftime("%Y-%m-%d")

    def on_phone_end(self, end_mono: float = None) -> None:

        """
        Finalize a phone detection event and append it to Firestore.

        Args:
            end_mono: Monotonic timestamp at which the event actually ended.
                      Defaults to now. Pass the debounce filter's
                      raw_false_since so the recorded duration excludes the
                      filter's fall delay.
        """

        self._finish_event("phone", "phone_events", end_mono)

    # ------------------------------------------------------------------
    # Firestore — drowsy events
    # ------------------------------------------------------------------
    def on_drowsy_start(self) -> None:
        """Record the start of a drowsiness detection event."""
        active, reason = self._check_active()
        if not active:
            print(f"[Firebase] skip drowsy_start — {reason}")
            return
        self._drowsy_start_mono = time.monotonic()
        self._drowsy_start_time = time.strftime("%H:%M:%S")
        self._drowsy_start_date = time.strftime("%Y-%m-%d")

    def on_drowsy_end(self, end_mono: float = None) -> None:

        """
        Finalize a drowsiness event and append it to Firestore.

        Args:
            end_mono: Monotonic timestamp at which the event actually ended.
                      Defaults to now. See on_phone_end().
        """

        self._finish_event("drowsy", "drowsy_events", end_mono)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    def _finish_event(self, kind: str, field: str, end_mono: float = None) -> None:

        """
        Shared tail for on_phone_end() / on_drowsy_end().

        Computes the duration from monotonic timestamps (immune to midnight
        rollover and clock adjustments), drops events shorter than
        MIN_EVENT_SEC, and appends the rest to Firestore.

        Args:
            kind:     "phone" or "drowsy" — selects the stored start fields.
            field:    Firestore array field to append to.
            end_mono: Actual end timestamp; defaults to now.
        """

        start_mono = getattr(self, f"_{kind}_start_mono")
        start_time = getattr(self, f"_{kind}_start_time")
        start_date = getattr(self, f"_{kind}_start_date")

        # Clearing up front guarantees the event is never written twice, no
        # matter which branch below returns.
        self._clear_event(kind)

        if start_mono is None:
            print(f"[Firebase] skip {kind}_end — no start recorded")
            return

        active, reason = self._check_active()
        if not active:
            print(f"[Firebase] skip {kind}_end — {reason}")
            return

        if end_mono is None:
            end_mono = time.monotonic()
        duration = int(end_mono - start_mono)

        if duration < MIN_EVENT_SEC:
            print(f"[Firebase] skip {kind}_event — {duration}s < {MIN_EVENT_SEC}s")
            return

        _, _, session_id, _ = self._session_snapshot()
        if not session_id:
            print(f"[Firebase] skip {kind}_event — session_id not set")
            return

        event = {
            "start_time":     start_time,
            "start_date":     start_date,
            "end_time":       time.strftime("%H:%M:%S"),
            "end_date":       time.strftime("%Y-%m-%d"),
            "total_duration_sec": duration,
        }

        try:
            self._append_event(session_id, field, event)
        except Exception as e:
            print(f"[Firebase] {kind}_event write failed — {e}")
            return

        print(f"[Firebase] {kind}_event written — {duration}s, session={session_id}")

    def _clear_event(self, kind: str) -> None:
        """Reset the stored start markers for one event kind."""
        setattr(self, f"_{kind}_start_mono", None)
        setattr(self, f"_{kind}_start_time", None)
        setattr(self, f"_{kind}_start_date", None)

    def _append_event(self, session_id: str, field: str, event: dict) -> None:

        """
        Append a single event dict to an array field in the Firestore
        focus_sessions document identified by session_id.
        Uses ArrayUnion to avoid overwriting concurrent writes.

        Raises on failure (missing document, network error) — the caller logs.
        """

        self._fs \
            .collection("users") \
            .document(UID) \
            .collection("focus_sessions") \
            .document(session_id) \
            .update({field: firestore.ArrayUnion([event])})
