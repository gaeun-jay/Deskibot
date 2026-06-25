"""
firebase_client.py
------------------
Firebase interface for the RPi detection node.
 
Responsibilities:
  - Realtime DB : reflect live drowsy/phone detection state under
                  users/{UID}/status/current_state
  - Firestore   : append timestamped phone_events / drowsy_events to the
                  active focus session document under
                  users/{UID}/focus_sessions/{session_id}
 
Write conditions:
  Both writes are gated on the is_detecting_drowsy / is_detecting_phone
  flags that the ESP32 sets when a Pomodoro session is active.
  RPi never writes when those flags are False.
"""

import time
import firebase_admin
from firebase_admin import credentials, db, firestore

SERVICE_ACCOUNT_KEY = "/home/rpi/Deskibot/rpi/comm/serviceAccountKey.json"
DATABASE_URL        = "https://deskibot-b1377-default-rtdb.firebaseio.com/"
UID = "d97de62c-9f30-41b1-8869-00873bd043fe"


class FirebaseClient:
    """Manages all Firebase I/O from the RPi detection node."""
    def __init__(self):
        cred = credentials.Certificate(SERVICE_ACCOUNT_KEY)
        firebase_admin.initialize_app(cred, {"databaseURL": DATABASE_URL})

        self._rtdb_ref = db.reference(f"users/{UID}")
        self._fs       = firestore.client()

        # Tracks the start of an ongoing detection event.
        # Reset to None once the event ends and is written to Firestore.
        self._phone_start_time  = None
        self._phone_start_date  = None
        self._drowsy_start_time = None
        self._drowsy_start_date = None

        print("[Firebase] Connected (Realtime DB + Firestore)")

    # ------------------------------------------------------------------
    # Realtime DB
    # ------------------------------------------------------------------
    def update_detection(self, drowsy: bool, phone: bool) -> None:
        
        """
        Push the current detection booleans to Realtime DB.
 
        Reads is_detecting_drowsy / is_detecting_phone from current_state
        before writing; skips fields whose detection is disabled by ESP32.
        """
        
        state = self._rtdb_ref.child("status/current_state").get()
        if not state:
            return

        update = {}
        if state.get("is_detecting_drowsy", False):
            update["drowsy"] = drowsy
        if state.get("is_detecting_phone", False):
            update["phone"] = phone

        if update:
            self._rtdb_ref.child("status/current_state").update(update)

    # ------------------------------------------------------------------
    # Firestore — phone events
    # ------------------------------------------------------------------
    def on_phone_start(self) -> None:
        
        """
        Record the start timestamp of a phone detection event.
        No-op if is_detecting_phone is False in Realtime DB.
        """
        
        state = self._rtdb_ref.child("status/current_state").get()
        if not state or not state.get("is_detecting_phone", False):
            return
        self._phone_start_time = time.strftime("%H:%M:%S")
        self._phone_start_date = time.strftime("%Y-%m-%d")

    def on_phone_end(self) -> None:
        
        """
        Finalize a phone detection event and append it to Firestore.
        Calculates duration from the stored start time.
        No-op if no start time is recorded or detection is disabled.
        """
        
        if self._phone_start_time is None:
            return

        state = self._rtdb_ref.child("status/current_state").get()
        if not state or not state.get("is_detecting_phone", False):
            self._phone_start_time = None
            self._phone_start_date = None
            return

        session_id = self._get_session_id()
        if not session_id:
            print("[Firebase] session_id not set — phone_event skipped")
            self._phone_start_time = None
            self._phone_start_date = None
            return

        end_time = time.strftime("%H:%M:%S")
        end_date = time.strftime("%Y-%m-%d")
        event = {
            "start_time":     self._phone_start_time,
            "start_date":     self._phone_start_date,
            "end_time":       end_time,
            "end_date":       end_date,
            "total_duration": self._calc_duration(self._phone_start_time, end_time),
        }
        self._append_event(session_id, "phone_events", event)
        print(f"[Firebase] phone_event written — session={session_id}")

        self._phone_start_time = None
        self._phone_start_date = None

    # ------------------------------------------------------------------
    # Firestore — drowsy events
    # ------------------------------------------------------------------
    def on_drowsy_start(self) -> None:
        
        """
        Record the start timestamp of a drowsiness detection event.
        No-op if is_detecting_drowsy is False in Realtime DB.
        """
        
        state = self._rtdb_ref.child("status/current_state").get()
        if not state or not state.get("is_detecting_drowsy", False):
            return
        self._drowsy_start_time = time.strftime("%H:%M:%S")
        self._drowsy_start_date = time.strftime("%Y-%m-%d")

    def on_drowsy_end(self) -> None:
        
        """
        Finalize a drowsiness event and append it to Firestore.
        Calculates duration from the stored start time.
        No-op if no start time is recorded or detection is disabled.
        """
        
        if self._drowsy_start_time is None:
            return

        state = self._rtdb_ref.child("status/current_state").get()
        if not state or not state.get("is_detecting_drowsy", False):
            self._drowsy_start_time = None
            self._drowsy_start_date = None
            return

        session_id = self._get_session_id()
        if not session_id:
            print("[Firebase] session_id not set — drowsy_event skipped")
            self._drowsy_start_time = None
            self._drowsy_start_date = None
            return

        end_time = time.strftime("%H:%M:%S")
        end_date = time.strftime("%Y-%m-%d")
        event = {
            "start_time":     self._drowsy_start_time,
            "start_date":     self._drowsy_start_date,
            "end_time":       end_time,
            "end_date":       end_date,
            "total_duration": self._calc_duration(self._drowsy_start_time, end_time),
        }
        self._append_event(session_id, "drowsy_events", event)
        print(f"[Firebase] drowsy_event written — session={session_id}")

        self._drowsy_start_time = None
        self._drowsy_start_date = None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    def _get_session_id(self) -> str:
        
        """
        Read the active session_id written by ESP32 on session start.
        Returns an empty string if not set.
        """
        
        val = self._rtdb_ref.child("status/current_state/session_id").get()
        return val if val else ""

    def _append_event(self, session_id: str, field: str, event: dict) -> None:
       
        """
        Append a single event dict to an array field in the Firestore
        focus_sessions document identified by session_id.
        Uses ArrayUnion to avoid overwriting concurrent writes.
        """
        
        self._fs \
            .collection("users") \
            .document(UID) \
            .collection("focus_sessions") \
            .document(session_id) \
            .update({field: firestore.ArrayUnion([event])})

    @staticmethod
    def _calc_duration(start: str, end: str) -> int:
      
        """
        Compute elapsed time in minutes between two HH:MM:SS strings.
        Returns 0 on parse error or negative difference.
        """
        
        try:
            fmt = "%H:%M:%S"
            s = time.strptime(start, fmt)
            e = time.strptime(end, fmt)
            diff = (
                (e.tm_hour * 3600 + e.tm_min * 60 + e.tm_sec) -
                (s.tm_hour * 3600 + s.tm_min * 60 + s.tm_sec)
            )
            return max(0, diff // 60)
        except Exception:
            return 0