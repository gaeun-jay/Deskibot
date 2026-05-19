import RPi.GPIO as GPIO
import mediapipe as mp

# =====================================================================
# 서보 설정
# =====================================================================
PAN_GPIO  = 12
TILT_GPIO = 13
PWM_FREQ  = 50

PAN_MIN,  PAN_MAX  = 30, 150
TILT_MIN, TILT_MAX = 50, 120
PAN_CENTER  = 90
TILT_CENTER = 80

KP_PAN  = 0.008
KP_TILT = 0.008
DEADZONE_PX = 30

# 눈코입 랜드마크 인덱스 (FaceMesh)
# 좌안 중심: 33, 우안 중심: 263, 코끝: 1, 입 좌: 61, 입 우: 291
FACE_FULL_LANDMARKS = [33, 263, 1, 61, 291]


def _angle_to_duty(angle: float) -> float:
    return 2.5 + (angle / 180.0) * 10.0


def _is_full_face(face_res, frame_w, frame_h) -> tuple:
    """
    눈코입 5개 랜드마크가 전부 프레임 안(5~95%)에 있으면 True
    하나라도 프레임 밖이면 False
    """
    if not face_res or not face_res.multi_face_landmarks:
        return False, None, None

    lms = face_res.multi_face_landmarks[0].landmark

    for idx in FACE_FULL_LANDMARKS:
        lm = lms[idx]
        if not (0.05 < lm.x < 0.95 and 0.05 < lm.y < 0.95):
            return False, None, None

    xs = [lm.x for lm in lms]
    ys = [lm.y for lm in lms]
    cx = (sum(xs) / len(xs)) * frame_w
    cy = (sum(ys) / len(ys)) * frame_h
    return True, cx, cy


class PanTilt:
    def __init__(self):
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        GPIO.setup(PAN_GPIO,  GPIO.OUT)
        GPIO.setup(TILT_GPIO, GPIO.OUT)

        self.pan  = GPIO.PWM(PAN_GPIO,  PWM_FREQ)
        self.tilt = GPIO.PWM(TILT_GPIO, PWM_FREQ)

        self.pan_angle  = float(PAN_CENTER)
        self.tilt_angle = float(TILT_CENTER)

        self.pan.start(_angle_to_duty(self.pan_angle))
        self.tilt.start(_angle_to_duty(self.tilt_angle))

        print(f"✅ 서보모터 초기화 완료 (Pan={PAN_GPIO}, Tilt={TILT_GPIO})")

    def _set_pan(self, angle: float):
        self.pan.ChangeDutyCycle(_angle_to_duty(angle))

    def _set_tilt(self, angle: float):
        self.tilt.ChangeDutyCycle(_angle_to_duty(angle))

    def update(self, face_cx, face_cy, frame_w, frame_h,
           has_face, has_pose, pose_res=None, face_res=None):

        full_face, _, _ = _is_full_face(face_res, frame_w, frame_h)
        if full_face:
            # 신호 완전히 끊기
            self.pan.ChangeDutyCycle(0)
            self.tilt.ChangeDutyCycle(0)
            return

        # ── 얼굴은 감지됐지만 일부만 보임 (반쪽) ───────────────────
        elif has_face and face_cx is not None:
            err_x = face_cx - frame_w / 2
            err_y = face_cy - frame_h / 2

            if abs(err_x) > DEADZONE_PX:
                self.pan_angle += KP_PAN * err_x
                self.pan_angle  = max(PAN_MIN, min(PAN_MAX, self.pan_angle))
                self._set_pan(self.pan_angle)

            elif abs(err_y) > DEADZONE_PX:
                self.tilt_angle += KP_TILT * err_y
                self.tilt_angle  = max(TILT_MIN, min(TILT_MAX, self.tilt_angle))
                self._set_tilt(self.tilt_angle)

        # ── 어깨만 감지 → 위로 올리기 ──────────────────────────────
        elif has_pose and pose_res is not None:
            mp_pose = mp.solutions.pose
            lms = pose_res.pose_landmarks.landmark

            l_shoulder = lms[mp_pose.PoseLandmark.LEFT_SHOULDER.value]
            r_shoulder = lms[mp_pose.PoseLandmark.RIGHT_SHOULDER.value]
            shoulder_cx = ((l_shoulder.x + r_shoulder.x) / 2) * frame_w

            err_x = shoulder_cx - frame_w / 2
            if abs(err_x) > DEADZONE_PX:
                self.pan_angle -= KP_PAN * err_x
                self.pan_angle  = max(PAN_MIN, min(PAN_MAX, self.pan_angle))
                self._set_pan(self.pan_angle)

            if self.tilt_angle > TILT_MIN + 5:
                self.tilt_angle -= 0.5
                self._set_tilt(self.tilt_angle)

        # ── 아무것도 없음 → 센터 복귀 ──────────────────────────────
        else:
            if abs(self.pan_angle - PAN_CENTER) > 1:
                self.pan_angle += (PAN_CENTER - self.pan_angle) * 0.05
                self._set_pan(self.pan_angle)

            if abs(self.tilt_angle - TILT_CENTER) > 1:
                self.tilt_angle += (TILT_CENTER - self.tilt_angle) * 0.05
                self._set_tilt(self.tilt_angle)

    def close(self):
        self.pan.stop()
        self.tilt.stop()
        GPIO.cleanup()
        print("✅ 서보모터 종료 완료")