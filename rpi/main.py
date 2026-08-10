import os
os.environ["QT_QPA_PLATFORM"] = "offscreen"
import sys
sys.path.insert(0, '/usr/local/lib/python3.11/site-packages')
sys.path.append('/usr/lib/python3/dist-packages')

import time
import cv2
import mediapipe as mp
from picamera2 import Picamera2

from detection.drowsy_detect import DrowsyDetector
from detection.phone_detect  import PhoneDetector
from detection.debounce      import Debouncer
from tracking.pantilt        import PanTilt
from comm.firebase_client    import FirebaseClient
from comm.uart_client        import UartClient
from comm.camera import update_frame, update_status, start_server
from tracking.pantilt import PanTilt, _is_full_face

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OBJ_DETECT_EVERY      = 3     # Run object detection every N frames
STATUS_PRINT_INTERVAL = 3.0   # Periodic status log interval (seconds)

# Debounce delays (seconds): how long a raw flag must hold before it is confirmed.
# Rise is 0.0 so detection registers immediately; only the release is damped.
PHONE_RISE_SEC  = 0.0   # Report a phone the moment it is seen
PHONE_FALL_SEC  = 2.0   # Keep phone state through hand/angle occlusion
DROWSY_RISE_SEC = 0.0   # Drowsiness is already time-gated inside DrowsyDetector
DROWSY_FALL_SEC = 2.0   # Ride out momentary face-mesh tracking dropouts

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------
print("=== Deskibot Detection System Initializing ===")


picam = Picamera2()
picam.configure(picam.create_preview_configuration(
    main={'format': 'RGB888', 'size': (640, 480)},
    buffer_count=2,
    controls={"AfMode": 2, "AfSpeed": 1, "FrameRate": 30.0}
))
picam.start()
time.sleep(2)
print("[Camera] Initialized")


pantilt  = PanTilt()
drowsy   = DrowsyDetector()
phone    = PhoneDetector()
phone_filter  = Debouncer(PHONE_RISE_SEC,  PHONE_FALL_SEC,  name="phone")
drowsy_filter = Debouncer(DROWSY_RISE_SEC, DROWSY_FALL_SEC, name="drowsy")
firebase = FirebaseClient()
uart     = UartClient()
start_server()


# MediaPipe
mp_face_mesh = mp.solutions.face_mesh
mp_pose      = mp.solutions.pose

face_mesh = mp_face_mesh.FaceMesh(
    static_image_mode=False, max_num_faces=1,
    refine_landmarks=True,
    min_detection_confidence=0.5, min_tracking_confidence=0.5
)
pose_model = mp_pose.Pose(
    static_image_mode=False, model_complexity=1,
    enable_segmentation=False,
    min_detection_confidence=0.5, min_tracking_confidence=0.5
)
print("[MediaPipe] Initialized")

# ---------------------------------------------------------------------------
# State variables
# ---------------------------------------------------------------------------
frame_count          = 0
last_detections      = []
_last_status_print   = 0.0
_prev_state          = ""
_phone_was_detected  = False
_drowsy_was_detected = False
_prev_drowsy         = False
_prev_phone          = False
_drowsy_reason       = "DROWSY_EYE"   # Latched cause of the current drowsy episode

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
print("[System] Detection loop started")

try:
    while True:
        # Picamera2's 'RGB888' format actually yields BGR-ordered arrays
        frame = picam.capture_array()
        frame = cv2.flip(frame, 1)
        rgb   = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        h, w  = frame.shape[:2]
        now   = time.time()
        mono  = time.monotonic()   # Shared clock for the debounce filters
        frame_count += 1

        face_res = face_mesh.process(rgb)
        pose_res = pose_model.process(rgb)

        # -- Drowsiness detection -------------------------------------------
        (drowsy_eye, drowsy_face_lost, ear_val,
         has_face, has_pose,
         face_cx, face_cy, lms) = drowsy.update(face_res, pose_res, w, h, now)

        # -- Pan-tilt tracking ----------------------------------------------
        full_face, _, _ = _is_full_face(face_res, w, h)
        #print(f"full_face={full_face}, has_face={has_face}, has_pose={has_pose}")

        pantilt.update(
            face_cx  = face_cx,
            face_cy  = face_cy,
            frame_w  = w,
            frame_h  = h,
            has_face = has_face,
            has_pose = has_pose,
            pose_res = pose_res,
            face_res = face_res,
        )

        # -- Phone detection (throttled) ------------------------------------
        if frame_count % OBJ_DETECT_EVERY == 0:
            last_detections = phone.detect(rgb)
        raw_phone = phone.draw(frame, last_detections, h, w)

        # -- State determination --------------------------------------------
        is_drowsy = drowsy_eye or drowsy_face_lost

        # Debounce both flags; everything below this point uses the filtered
        # values so a one-frame dropout does not clear the state.
        is_drowsy      = drowsy_filter.update(is_drowsy, mono)
        phone_detected = phone_filter.update(raw_phone, mono)

        # Latch why we became drowsy — the raw cause may already be gone while
        # the filter is still holding the state through its fall delay.
        if drowsy_eye:
            _drowsy_reason = "DROWSY_EYE"
        elif drowsy_face_lost:
            _drowsy_reason = "DROWSY_FACE_LOST"

        if is_drowsy:
            state = _drowsy_reason
        else:
            state = "NORMAL" if has_face else ("POSE_ONLY" if has_pose else "NO_PERSON")

        # -- Push detection state on change only ----------------------------
        if is_drowsy != _prev_drowsy or phone_detected != _prev_phone:
            firebase.update_detection(drowsy=is_drowsy, phone=phone_detected)
            uart.update_detection(drowsy=is_drowsy, phone=phone_detected)
            print(f"[{time.strftime('%H:%M:%S')}] UART → DROWSY:{int(is_drowsy)},PHONE:{int(phone_detected)}")
            _prev_drowsy = is_drowsy
            _prev_phone  = phone_detected

        # -- Firebase: phone event logging ----------------------------------
        if phone_detected and not _phone_was_detected:
            _phone_was_detected = True
            print(f"[{time.strftime('%H:%M:%S')}] Phone detected")
            firebase.on_phone_start()
        elif not phone_detected and _phone_was_detected:
            _phone_was_detected = False
            print(f"[{time.strftime('%H:%M:%S')}] Phone cleared")
            # Report when the raw signal actually stopped, not when the
            # debounce filter released, so the logged duration is honest.
            firebase.on_phone_end(phone_filter.raw_false_since)

        # -- Firebase: drowsy event logging ---------------------------------
        if is_drowsy and not _drowsy_was_detected:
            _drowsy_was_detected = True
            print(f"[{time.strftime('%H:%M:%S')}] Drowsiness detected")
            firebase.on_drowsy_start()
        elif not is_drowsy and _drowsy_was_detected:
            _drowsy_was_detected = False
            print(f"[{time.strftime('%H:%M:%S')}] Drowsiness cleared")
            firebase.on_drowsy_end(drowsy_filter.raw_false_since)

        # -- State transition log -------------------------------------------
        if state != _prev_state:
            STATE_LABELS = {
                "NORMAL":           "Normal — face tracked",
                "DROWSY_EYE":       "Drowsy — eyes closed",
                "DROWSY_FACE_LOST": "Drowsy — face lost",
                "POSE_ONLY":        "Pose only — face not visible",
                "NO_PERSON":        "No person detected",
            }
            print(f"[{time.strftime('%H:%M:%S')}] State → {STATE_LABELS.get(state, state)}")
            _prev_state = state

        # -- Periodic status heartbeat --------------------------------------
        if now - _last_status_print >= STATUS_PRINT_INTERVAL:
            _last_status_print = now
            ear_str   = f"EAR={ear_val:.3f}" if ear_val is not None else "EAR=N/A"
            face_str  = "face=Y" if has_face else "face=N"
            pose_str  = "pose=Y" if has_pose else "pose=N"
            phone_str = "phone=Y" if phone_detected else "phone=N"
            print(f"[{time.strftime('%H:%M:%S')}] [{state}] {ear_str} | {face_str} | {pose_str} | {phone_str}")

        # -- Web streaming update -------------------------------------------
        update_frame(frame)
        update_status(
            state    = state,
            ear      = f"{ear_val:.3f}" if ear_val is not None else "N/A",
            has_face = has_face,
            has_pose = has_pose,
            phone    = phone_detected,
            drowsy   = is_drowsy,
        )

        time.sleep(0.01)

finally:
    picam.stop()
    phone.close()
    pantilt.close()
    uart.close()
    print("[System] Clean exit")