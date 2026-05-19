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
from tracking.pantilt        import PanTilt
from feedback.alert          import AlertManager, log, Color
from comm.firebase_client    import FirebaseClient
from comm.camera import update_frame, update_status, start_server #flask 서버를 위함
from tracking.pantilt import PanTilt, _is_full_face

# =====================================================================
# 상수
# =====================================================================
OBJ_DETECT_EVERY      = 3
STATUS_PRINT_INTERVAL = 3.0

# =====================================================================
# 초기화
# =====================================================================
print(f"\n{Color.BOLD}{Color.CYAN}=== Deskibot 졸음 + 핸드폰 감지 시스템 시작 ==={Color.RESET}")

# 카메라
picam = Picamera2()
picam.configure(picam.create_preview_configuration(
    main={'format': 'RGB888', 'size': (640, 480)},
    buffer_count=2,
    controls={"AfMode": 2, "AfSpeed": 1, "FrameRate": 30.0}
))
picam.start()
time.sleep(2)
log("카메라 초기화 완료", Color.GREEN)

# 모듈
pantilt  = PanTilt()
drowsy   = DrowsyDetector()
phone    = PhoneDetector()
alert    = AlertManager()
firebase = FirebaseClient()
start_server() #flask

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
log("MediaPipe 초기화 완료", Color.GREEN)

# =====================================================================
# 상태 변수
# =====================================================================
frame_count        = 0
last_detections    = []
_last_status_print = 0.0
_prev_state        = ""
_phone_was_detected = False
_drowsy_was_detected = False
_prev_drowsy       = False
_prev_phone        = False

# =====================================================================
# 메인 루프
# =====================================================================
log("감지 루프 시작", Color.CYAN)

try:
    while True:
        rgb   = picam.capture_array()
        frame = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        frame = cv2.flip(frame, 1)
        rgb   = cv2.flip(rgb, 1)

        h, w  = frame.shape[:2]
        now   = time.time()
        frame_count += 1

        face_res = face_mesh.process(rgb)
        pose_res = pose_model.process(rgb)

        # ── 졸음 감지 ───────────────────────────────────────────────
        (drowsy_eye, drowsy_face_lost, ear_val,
         has_face, has_pose,
         face_cx, face_cy, lms) = drowsy.update(face_res, pose_res, w, h, now)

        # ── 팬틸트 추적 ─────────────────────────────────────────────
        full_face, _, _ = _is_full_face(face_res, w, h)
        print(f"full_face={full_face}, has_face={has_face}, has_pose={has_pose}")

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
        # if has_face and face_cx is not None:
        #     full_face, _, _ = _is_full_face(face_res, w, h)
        #     print(f"full_face={full_face}, has_face={has_face}, has_pose={has_pose}")
        #     # ── 팬틸트 추적 ─────────────────────────────────────────────
        #     pantilt.update(
        #         face_cx  = face_cx,
        #         face_cy  = face_cy,
        #         frame_w  = w,
        #         frame_h  = h,
        #         has_face = has_face,
        #         has_pose = has_pose,
        #         pose_res = pose_res,
        #         face_res = face_res,
        #     )

        # ── 핸드폰 감지 ─────────────────────────────────────────────
        if frame_count % OBJ_DETECT_EVERY == 0:
            last_detections = phone.detect(rgb)
        phone_detected = phone.draw(frame, last_detections, h, w)

        # ── 상태 결정 ───────────────────────────────────────────────
        is_drowsy = drowsy_eye or drowsy_face_lost

        if drowsy_eye:
            state = "DROWSY_EYE"
            alert.trigger("눈 감김", "drowsy_eye")
        elif drowsy_face_lost:
            state = "DROWSY_FACE_LOST"
            alert.trigger("얼굴 미감지", "face_lost")
        else:
            state = "NORMAL" if has_face else ("POSE_ONLY" if has_pose else "NO_PERSON")

        # ── Firebase 업데이트 (상태 변화 시에만) ────────────────────
        if is_drowsy != _prev_drowsy or phone_detected != _prev_phone:
            firebase.update_detection(drowsy=is_drowsy, phone=phone_detected)
            _prev_drowsy = is_drowsy
            _prev_phone  = phone_detected

        # ── 핸드폰 감지 로그 ────────────────────────────────────────
        if phone_detected and not _phone_was_detected:
            _phone_was_detected = True
            log("📱 핸드폰 감지됨!", Color.MAGENTA)
            firebase.log_detection("phone", mode="pomodoro")
        elif not phone_detected and _phone_was_detected:
            _phone_was_detected = False
            log("핸드폰 사라짐", Color.GRAY)
            
        # ── 졸음 감지 로그 ────────────────────────────────────────────
        if is_drowsy and not _drowsy_was_detected:
            _drowsy_was_detected = True
            log("😴 졸음 감지됨!", Color.RED)
            firebase.log_detection("drowsy", mode="pomodoro")
        elif not is_drowsy and _drowsy_was_detected:
            _drowsy_was_detected = False
            log("졸음 해제됨", Color.GREEN)

        # ── 상태 변화 출력 ──────────────────────────────────────────
        if state != _prev_state:
            state_labels = {
                "NORMAL":           ("정상 감지 중",              Color.GREEN),
                "DROWSY_EYE":       ("⚠️  졸음 감지 (눈 감김)",   Color.RED),
                "DROWSY_FACE_LOST": ("⚠️  졸음 의심 (얼굴 소실)", Color.YELLOW),
                "POSE_ONLY":        ("상체만 감지",                Color.YELLOW),
                "NO_PERSON":        ("인물 미감지",                Color.GRAY),
            }
            label, c = state_labels.get(state, (state, Color.WHITE))
            log(f"상태 변경 → {label}", c)
            _prev_state = state

        # ── 주기적 상태 로그 ────────────────────────────────────────
        if now - _last_status_print >= STATUS_PRINT_INTERVAL:
            _last_status_print = now
            sc       = Color.RED   if "DROWSY" in state else Color.GREEN if state == "NORMAL" else Color.GRAY
            ear_str  = f"EAR={ear_val:.3f}" if ear_val is not None else "EAR=N/A"
            face_str = f"{Color.GREEN}얼굴O{Color.RESET}" if has_face else f"{Color.RED}얼굴X{Color.RESET}"
            pose_str = f"{Color.GREEN}자세O{Color.RESET}" if has_pose else f"{Color.GRAY}자세X{Color.RESET}"
            phone_str = f"{Color.MAGENTA}📱폰감지{Color.RESET}" if phone_detected else f"{Color.GRAY}폰없음{Color.RESET}"
            print(f"\r{Color.GRAY}[{time.strftime('%H:%M:%S')}]{Color.RESET} "
                  f"{sc}{Color.BOLD}[{state}]{Color.RESET} {sc}{ear_str}{Color.RESET} | "
                  f"{face_str} | {pose_str} | {phone_str}")
        
        # ── 웹 스트리밍 업데이트 ────────────────────────────────────────
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
    log("종료 중...", Color.GRAY)
    picam.stop()
    phone.close()
    pantilt.close()
    log("정상 종료", Color.GREEN)