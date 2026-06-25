"""
pantilt.py
----------
Pan-tilt servo controller for face/pose tracking.
 
Tracking behaviour (priority order):
  1. Full face in frame   — stop motors (no correction needed)
  2. Partial face         — center face using PID-style proportional control
  3. Pose only (shoulders)— pan toward shoulder midpoint, tilt upward to find face
  4. No detection         — return to center position gradually
 
Full-face is defined as all 5 key landmarks (eyes, nose tip, mouth corners)
lying within the inner 90% of the frame on both axes.
"""

import RPi.GPIO as GPIO
import mediapipe as mp

# ---------------------------------------------------------------------------
# GPIO pin assignment
# ---------------------------------------------------------------------------
PAN_GPIO  = 12
TILT_GPIO = 13
PWM_FREQ  = 50  # Hz (standard for hobby servos)

# ---------------------------------------------------------------------------
# Angle limits and defaults
# ---------------------------------------------------------------------------
PAN_MIN,  PAN_MAX  = 30, 150
TILT_MIN, TILT_MAX = 50, 120
PAN_CENTER  = 90
TILT_CENTER = 80

# ---------------------------------------------------------------------------
# Controller gains and deadzone
# ---------------------------------------------------------------------------
KP_PAN      = 0.008    # Proportional gain for pan axis
KP_TILT     = 0.008    # Proportional gain for tilt axis
DEADZONE_PX = 30       # Pixel error below which no correction is applied

# ---------------------------------------------------------------------------
# Landmark indices used for full-face detection (FaceMesh)
# left eye: 33, right eye: 263, nose tip: 1, mouth left: 61, mouth right: 291
# ---------------------------------------------------------------------------
FACE_FULL_LANDMARKS = [33, 263, 1, 61, 291]


def _angle_to_duty(angle: float) -> float:
    """Convert servo angle (0–180°) to PWM duty cycle (2.5–12.5%)."""
    return 2.5 + (angle / 180.0) * 10.0


def _is_full_face(face_res, frame_w, frame_h) -> tuple:
   
    """
    Check whether all key facial landmarks are fully within the frame.
 
    A face is considered 'full' when all 5 landmarks lie within
    the inner 90% of the frame (5%–95% on both axes).
 
    Args:
        face_res: MediaPipe FaceMesh result
        frame_w:  Frame width in pixels
        frame_h:  Frame height in pixels
 
    Returns:
        (is_full, face_cx, face_cy)
        face_cx / face_cy are pixel coordinates of the face centroid,
        or None if the face is not full.
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
    
    """
    Two-axis pan-tilt servo controller.
 
    Angles are maintained as floats internally and clamped to hardware limits
    before each PWM write.
    """
    
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

        print(f"[PanTilt] Initialized (Pan=GPIO{PAN_GPIO}, Tilt=GPIO{TILT_GPIO})")

    # ------------------------------------------------------------------
    # Internal servo writers
    # ------------------------------------------------------------------
    def _set_pan(self, angle: float) -> None:
        self.pan.ChangeDutyCycle(_angle_to_duty(angle))

    def _set_tilt(self, angle: float) -> None: 
        self.tilt.ChangeDutyCycle(_angle_to_duty(angle))

    # ------------------------------------------------------------------
    # Main update — called once per frame
    # ------------------------------------------------------------------
    def update(self, face_cx, face_cy, frame_w, frame_h,
           has_face, has_pose, pose_res=None, face_res=None) -> None:

        """
        Update servo positions based on the current detection state.
 
        Priority:
          1. Full face visible  → stop motors
          2. Partial face       → proportional correction toward center
          3. Pose only          → pan to shoulder midpoint, tilt up
          4. No detection       → slowly return to center
        """
        
        full_face, _, _ = _is_full_face(face_res, frame_w, frame_h)
        
        # 1. Full face in frame — cut PWM signal to reduce jitter
        if full_face:
            self.pan.ChangeDutyCycle(0)
            self.tilt.ChangeDutyCycle(0)
            return

        # 2. Partial face — proportional pan/tilt correction
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

        #3. Pose only — pan toward shoulders, tilt upward to locate face
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

        # 4. No detection — gradually return to center
        else:
            if abs(self.pan_angle - PAN_CENTER) > 1:
                self.pan_angle += (PAN_CENTER - self.pan_angle) * 0.05
                self._set_pan(self.pan_angle)

            if abs(self.tilt_angle - TILT_CENTER) > 1:
                self.tilt_angle += (TILT_CENTER - self.tilt_angle) * 0.05
                self._set_tilt(self.tilt_angle)

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    def close(self) -> None:
        """Stop PWM signals and release GPIO resources."""
        self.pan.stop()
        self.tilt.stop()
        GPIO.cleanup()
        print("[PanTilt] Shutdown complete")