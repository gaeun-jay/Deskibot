import time
import firebase_admin
from firebase_admin import credentials, db

SERVICE_ACCOUNT_KEY = "/home/rpi/Deskibot/rpi/comm/serviceAccountKey.json"
DATABASE_URL        = "https://deskibot-b1377-default-rtdb.firebaseio.com/"
TEST_UID            = "test_user"   # 나중에 실제 uid로 교체


class FirebaseClient:
    def __init__(self):
        cred = credentials.Certificate(SERVICE_ACCOUNT_KEY)
        firebase_admin.initialize_app(cred, {"databaseURL": DATABASE_URL})
        self._ref = db.reference(f"users/{TEST_UID}")
        print("✅ Firebase 연결 완료!")
        self.update_detection(drowsy=False, phone=False)

    def update_detection(self, drowsy: bool, phone: bool):
        """감지 상태를 Firebase에 업데이트, 감지 시에만 시각 기록"""
        now = time.strftime("%H:%M:%S")
        update = {"drowsy": drowsy, "phone": phone}
        if drowsy:
            update["drowsy_at"] = now
        if phone:
            update["phone_at"] = now
        self._ref.child("device_state").update(update)

    def log_detection(self, detect_type: str, mode: str, session_id: str = ""):
        """감지 이벤트를 detection_log에 기록"""
        self._ref.child("detection_log").push({
            "type":          detect_type,
            "detected_time": time.strftime("%H:%M:%S"),
            "mode":          mode,
            "session_id":    session_id,
        })