"""
pantilt.py
----------
Pan-tilt servo controller for face/pose tracking.
 
Tracking behaviour (priority order):
  1. Full face in frame   — stop motors (no correction needed)
  2. Partial face         — center face using PID-style proportional control
  3. Pose only (shoulders)— pan toward shoulder midpoint, hold tilt steady
  4. No detection         — return to center position gradually
 
Full-face is defined as all 5 key landmarks (eyes, nose tip, mouth corners)
lying within the inner 90% of the frame on both axes.
"""

import time

import mediapipe as mp

from detection.drowsy_detect import select_primary_user
from tracking.servo_pwm import ServoPWM

# ---------------------------------------------------------------------------
# Servo channel assignment
# ---------------------------------------------------------------------------
# Hardware PWM channels on the RP1, not GPIO numbers -- see servo_pwm.py for
# why this cannot go back to RPi.GPIO. The overlay maps channel 0 to GPIO12 and
# channel 1 to GPIO13.
#
# Which channel drives which axis was measured with tools/servo_check.py, and
# it is the opposite of what this file assumed: GPIO12 is the top servo that
# pitches the camera, GPIO13 is the bottom one that rotates it. Pan corrections
# were being sent to the tilt servo and vice versa.
TILT_CHANNEL = 0   # GPIO12, top servo, pitches the camera up/down
PAN_CHANNEL  = 1   # GPIO13, bottom servo, rotates left/right

# ---------------------------------------------------------------------------
# Angle limits and defaults
# ---------------------------------------------------------------------------
# Both horns are seated so that 90 is level and straight ahead, so the centers
# are 90 and the limits are symmetric about it. They were not always: the horns
# used to be splined on with an offset that put tilt's level near 175 and pan's
# straight-ahead below 15, leaving almost no travel on one side of each axis.
PAN_MIN,  PAN_MAX  = 30, 150
TILT_MIN, TILT_MAX = 50, 130
PAN_CENTER  = 90
TILT_CENTER = 90

# ---------------------------------------------------------------------------
# Axis directions
# ---------------------------------------------------------------------------
# +1 means "a larger angle corrects a positive error", -1 flips the axis. These
# depend on how the servos are mounted, so they are measured, not derived.
#
# Tilt: a SMALLER angle aims the camera up, checked directly against the
# hardware (60 looks up, 120 looks down). Negative err_y means the face is high
# in the frame, which needs the camera to come up, which needs a smaller angle
# -- so the correction has to oppose the error and the sign is +1.
#
# Do not re-derive this from the tracking logs in the git history. Those were
# recorded before the horn was last re-seated, and seating a horn at a new
# offset can turn the linkage over with it, which is exactly what happened
# here. Any log written before the last mechanical change describes a
# different machine. Re-measure with tools/servo_check.py instead; it takes
# one command and it is the only evidence that is current.
#
# Pan: the frame is mirrored by main.py before any of this runs (cv2.flip), so
# the sign cannot be reasoned out from the servo mounting alone. Confirmed +1
# by watching the head follow the user rather than run from them; the log
# agrees, with err_x hovering around zero (-11, 4, -1) instead of diverging.
TILT_SIGN = +1
PAN_SIGN  = +1

# ---------------------------------------------------------------------------
# Controller gains and deadzone
# ---------------------------------------------------------------------------
# Every rate below is in DEGREES PER SECOND, not per frame. update() measures
# the real interval between calls and scales by it, so the observed speed is
# the same whether the detection loop manages 5fps or 30fps.
#
# Per-frame gains were the reason speed felt unpredictable: the loop runs
# FaceMesh, Pose and EfficientDet together, so its frame rate swings with CPU
# load, and the servos sped up or stalled along with it.
# These are deliberately much larger than the values they replace. The old ones
# were driven down towards nothing while chasing what looked like a runaway
# head, but the runaway was the software PWM backend losing pulse width under
# load, not the controller being too eager. Now that the pulse is generated in
# hardware the servo goes where it is told, and gains low enough to hide the
# old problem are simply too slow to track a face.
KP_PAN       = 0.04    # deg/s of pan correction per pixel of horizontal error
KP_TILT      = 0.04    # deg/s of tilt correction per pixel of vertical error
MAX_SLEW_DPS = 20      # Ceiling on either axis, so a large error cannot lurch
DEADZONE_PX  = 30      # Pixel error below which no correction is applied

# No-detection mode: speed at which the head slides back to center.
RECENTER_DPS = 8.0

# Pose-only mode. The pose model carries its own coarse face landmarks, so
# FaceMesh failing does not mean the head cannot be located -- it usually just
# means the eyes are hidden, which is exactly the case where the head is still
# perfectly findable. Below this confidence the nose landmark is extrapolated
# rather than seen, and following it would be following a guess.
POSE_NOSE_MIN_VISIBILITY = 0.5

# Speed of the upward search used when the shoulders are in frame but the head
# is not anywhere in it. Slower than tracking: this is a hunt, and overshooting
# carries the head past the face it is looking for.
TILT_SEARCH_DPS = 6.0

# Longest interval update() will integrate over. A stalled frame (GC pause,
# camera hiccup) must not discharge as one large jump.
MAX_DT_SEC = 0.2

# Print the branch taken and the live angles a few times a second. Leave on
# while the tilt behaviour is still being diagnosed — it is the only way to
# tell a servo/mounting problem (angle steady, head still moves) apart from a
# control problem (angle itself marching to a limit).
DEBUG_TRACKING   = True
DEBUG_INTERVAL_S = 0.5

# ---------------------------------------------------------------------------
# Landmark indices used for full-face detection (FaceMesh)
# left eye: 33, right eye: 263, nose tip: 1, mouth left: 61, mouth right: 291
# ---------------------------------------------------------------------------
FACE_FULL_LANDMARKS = [33, 263, 1, 61, 291]


def _clamp(value: float, lo: float, hi: float) -> float:
    """Constrain a value to the inclusive range [lo, hi]."""
    return max(lo, min(hi, value))


def _step_toward(current: float, target: float, max_step: float) -> float:
    """Move `current` toward `target` by at most `max_step` degrees."""
    delta = target - current
    if abs(delta) <= max_step:
        return target
    return current + (max_step if delta > 0 else -max_step)


def _is_full_face(face_res, frame_w, frame_h) -> tuple:
   
    """
    Check whether all key facial landmarks are fully within the frame.

    A face is considered 'full' when all 5 landmarks lie within
    the inner 90% of the frame (5%–95% on both axes).

    Since several faces may be detected, the check runs on the primary user
    chosen by select_primary_user(). It must be the same face used for
    drowsiness detection and the on-screen USER box — indexing [0] as before
    makes the motors track a different person.

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

    lms = select_primary_user(face_res.multi_face_landmarks, frame_w, frame_h).landmark

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
        self.pan_angle  = float(PAN_CENTER)
        self.tilt_angle = float(TILT_CENTER)

        self.pan  = ServoPWM(PAN_CHANNEL,  initial_angle=self.pan_angle)
        self.tilt = ServoPWM(TILT_CHANNEL, initial_angle=self.tilt_angle)

        self._last_update = time.monotonic()  # For the per-frame dt measurement
        self._last_debug  = 0.0               # Throttles the DEBUG_TRACKING print

        print(f"[PanTilt] Initialized (Pan=GPIO{self.pan.gpio}, Tilt=GPIO{self.tilt.gpio})")

    # ------------------------------------------------------------------
    # Internal servo writers
    # ------------------------------------------------------------------
    def _set_pan(self, angle: float) -> None:
        self.pan.set_angle(angle)

    def _set_tilt(self, angle: float) -> None:
        self.tilt.set_angle(angle)

    # ------------------------------------------------------------------
    # Diagnostics
    # ------------------------------------------------------------------
    def _debug(self, now: float, branch: str, err_x=None, err_y=None) -> None:
        """Print the active branch and current angles, at most every DEBUG_INTERVAL_S."""
        if not DEBUG_TRACKING or now - self._last_debug < DEBUG_INTERVAL_S:
            return
        self._last_debug = now
        ex = "   --" if err_x is None else f"{err_x:5.0f}"
        ey = "   --" if err_y is None else f"{err_y:5.0f}"
        print(f"[PanTilt] {branch:<10} pan={self.pan_angle:6.1f} tilt={self.tilt_angle:6.1f} "
              f"err_x={ex} err_y={ey}")

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
          3. Pose only          → pan to shoulder midpoint, tilt holds
          4. No detection       → slowly return to center
        """

        # Real elapsed time since the previous call. Advanced before any early
        # return, so a run of full-face frames cannot bank up dt and discharge
        # it as a single jump the moment tracking resumes.
        now = time.monotonic()
        dt  = min(now - self._last_update, MAX_DT_SEC)
        self._last_update = now

        full_face, _, _ = _is_full_face(face_res, frame_w, frame_h)

        # 1. Full face in frame — hold position, no correction needed.
        #
        # This used to drop both duty cycles to zero, which under the software
        # PWM backend genuinely did quiet the jitter. Hardware PWM has no
        # jitter to quiet, and cutting the pulse train costs holding torque:
        # the tilt arm carries the camera and sags under it the moment it stops
        # being driven, so the head drooped through every full-face frame and
        # snapped back up when tracking resumed.
        if full_face:
            self._debug(now, "FULL/hold")
            return

        max_step = MAX_SLEW_DPS * dt

        # 2. Partial face — proportional pan/tilt correction
        if has_face and face_cx is not None:
            err_x = face_cx - frame_w / 2
            err_y = face_cy - frame_h / 2

            # Both axes are corrected on the same frame. These used to be an
            # if/elif chain, so tilt only ever moved once pan had settled
            # inside the deadzone.
            if abs(err_x) > DEADZONE_PX:
                step = _clamp(PAN_SIGN * KP_PAN * err_x * dt, -max_step, max_step)
                self.pan_angle = _clamp(self.pan_angle + step, PAN_MIN, PAN_MAX)
                self._set_pan(self.pan_angle)

            if abs(err_y) > DEADZONE_PX:
                step = _clamp(TILT_SIGN * KP_TILT * err_y * dt, -max_step, max_step)
                self.tilt_angle = _clamp(self.tilt_angle + step, TILT_MIN, TILT_MAX)
                self._set_tilt(self.tilt_angle)

            self._debug(now, "FACE", err_x, err_y)

        # 3. Pose only — pan toward the shoulders, and tilt toward the head.
        #
        # This branch has been wrong twice, in opposite directions. It first
        # held tilt frozen, which stranded the head bowed at the desk with no
        # way back. Replacing that with a drift to level fixed the stranding
        # but gave up on tracking entirely: the axis returned to 90 no matter
        # where the user actually was, so anyone who moved up and out of frame
        # was never found again.
        #
        # Neither was necessary, because 'no face' here means FaceMesh failed,
        # not that the head is unlocatable. The pose model has its own nose
        # landmark and it usually survives the conditions FaceMesh does not --
        # the eyes being hidden is the common cause, and the nose is unaffected
        # by it. When that landmark is confident, this is ordinary tracking
        # against a coarser estimate rather than a fallback at all.
        #
        # Only when the head is genuinely outside the frame does this search,
        # and then upward: shoulders visible with no head above them places the
        # head past the top edge. The search is bounded by TILT_MAX, so unlike
        # the original ratchet it stops rather than pinning.
        elif has_pose and pose_res is not None:
            mp_pose = mp.solutions.pose
            lms = pose_res.pose_landmarks.landmark

            l_shoulder = lms[mp_pose.PoseLandmark.LEFT_SHOULDER.value]
            r_shoulder = lms[mp_pose.PoseLandmark.RIGHT_SHOULDER.value]
            shoulder_cx = ((l_shoulder.x + r_shoulder.x) / 2) * frame_w

            # Same sign as branch 2: err_x is measured the same way off the same
            # (already flipped) frame, so the correction has to go the same way.
            # This was negated before, which reversed pan the instant tracking
            # dropped from face to pose and drove the head away from the user.
            err_x = shoulder_cx - frame_w / 2
            if abs(err_x) > DEADZONE_PX:
                step = _clamp(PAN_SIGN * KP_PAN * err_x * dt, -max_step, max_step)
                self.pan_angle = _clamp(self.pan_angle + step, PAN_MIN, PAN_MAX)
                self._set_pan(self.pan_angle)

            nose = lms[mp_pose.PoseLandmark.NOSE.value]
            if nose.visibility >= POSE_NOSE_MIN_VISIBILITY:
                err_y = nose.y * frame_h - frame_h / 2
                if abs(err_y) > DEADZONE_PX:
                    step = _clamp(TILT_SIGN * KP_TILT * err_y * dt, -max_step, max_step)
                    self.tilt_angle = _clamp(self.tilt_angle + step, TILT_MIN, TILT_MAX)
                    self._set_tilt(self.tilt_angle)
                self._debug(now, "POSE/nose", err_x, err_y)
            else:
                # Aim higher. 'Higher' is whichever direction opposes TILT_SIGN,
                # by the same definition branch 2 uses, so this stays correct if
                # the axis is ever re-mounted and the sign flips with it.
                self.tilt_angle = _clamp(
                    self.tilt_angle - TILT_SIGN * TILT_SEARCH_DPS * dt,
                    TILT_MIN, TILT_MAX)
                self._set_tilt(self.tilt_angle)
                self._debug(now, "POSE/seek", err_x)

        # 4. No detection — gradually return to center
        else:
            recenter_step = RECENTER_DPS * dt

            if abs(self.pan_angle - PAN_CENTER) > 1:
                self.pan_angle = _step_toward(self.pan_angle, PAN_CENTER, recenter_step)
                self._set_pan(self.pan_angle)

            if abs(self.tilt_angle - TILT_CENTER) > 1:
                self.tilt_angle = _step_toward(self.tilt_angle, TILT_CENTER, recenter_step)
                self._set_tilt(self.tilt_angle)

            self._debug(now, "NONE")

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    def close(self) -> None:
        """Stop driving both servos and release the PWM channels."""
        self.pan.close()
        self.tilt.close()
        print("[PanTilt] Shutdown complete")