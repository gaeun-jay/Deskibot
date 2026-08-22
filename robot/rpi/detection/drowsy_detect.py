"""
drowsy_detect.py
----------------
Drowsiness detection module using Eye Aspect Ratio (EAR) and pose analysis.
 
Detection conditions:
  1. DROWSY_EYE       — EAR drops below threshold for EYE_CLOSED_SEC seconds
  2. DROWSY_FACE_LOST — Face disappears while pose (upper body) is still visible
                        for FACE_LOST_SEC seconds (head-drop heuristic)
 
Multi-face handling: the largest face is selected as the primary user, with
hysteresis so the choice does not flip between people. See select_primary_user().
"""
import cv2
import numpy as np
import mediapipe as mp

#---------------------------------------------------------------------------
# Landmark indices
# ---------------------------------------------------------------------------
L_EYE = [33, 160, 158, 133, 153, 144]
R_EYE = [362, 385, 387, 263, 373, 380]

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------
EAR_THRESHOLD  = 0.20   # Below this → eyes considered closed
EYE_CLOSED_SEC = 1.5    # Sustained eye-closed duration to trigger drowsy_eye
FACE_LOST_SEC  = 5.0    # Sustained face-lost duration to trigger drowsy_face_lost
MIN_POSE_VIS   = 0.5    # Minimum landmark visibility for pose presence check

mp_pose = mp.solutions.pose
POSE_L_SHOULDER = mp_pose.PoseLandmark.LEFT_SHOULDER.value
POSE_R_SHOULDER = mp_pose.PoseLandmark.RIGHT_SHOULDER.value


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
def _pt2(lms, idx, w, h):
    """Convert a normalized landmark to pixel coordinates."""
    lm = lms[idx]
    return np.array([lm.x * w, lm.y * h], dtype=np.float32)

def ear(lms, idx, w, h) -> float:
    
    """
    Compute Eye Aspect Ratio for a single eye.
 
    EAR = (||p1-p5|| + ||p2-p4||) / (2 * ||p0-p3||)
    Returns 1.0 if the horizontal distance is near-zero (degenerate case).
    """
    
    p = [_pt2(lms, i, w, h) for i in idx]
    v1 = np.linalg.norm(p[1] - p[5])
    v2 = np.linalg.norm(p[2] - p[4])
    hd = np.linalg.norm(p[0] - p[3])
    return (v1 + v2) / (2 * hd) if hd > 1e-6 else 1.0

def mean_ear(lms, w, h):
    """Average EAR across both eyes."""
    return (ear(lms, L_EYE, w, h) + ear(lms, R_EYE, w, h)) / 2.0

def pose_present(pose_lms):
    """Return True if at least one shoulder landmark is sufficiently visible."""
    if pose_lms is None:
        return False
    lms = pose_lms.landmark
    return (lms[POSE_L_SHOULDER].visibility > MIN_POSE_VIS or
            lms[POSE_R_SHOULDER].visibility > MIN_POSE_VIS)

# ---------------------------------------------------------------------------
# Primary user selection
# ---------------------------------------------------------------------------
PRIMARY_KEEP_RATIO = 0.70   # Min size ratio to keep the incumbent primary (by face height)
PRIMARY_MATCH_DIST = 0.25   # Max distance to treat a face as the same person (normalized)

# Face center of the primary user picked on the previous frame (normalized
# coords). MediaPipe builds fresh landmark objects every frame, so object
# identity cannot tell us whether it is the same person — we match by position.
_last_primary_center = None


def select_primary_user(multi_face_landmarks, w, h):

    """
    Pick the primary user when several faces are detected: the largest face.

    Why size:
      On a desk robot the user sits 40–70cm away while passers-by are 1.5m or
      more back, so their face areas differ several-fold. Picking by 'closest
      to frame center' instead creates a feedback loop with the pan-tilt — the
      moment tracking hands over to someone else, the motors pull that person
      to the center, which locks the choice in and never recovers the original
      user. Face size does not change with where the motors point, so it has
      no such loop.

    Hysteresis:
      The previous primary is kept as long as it is still visible and at least
      PRIMARY_KEEP_RATIO of the largest face. That way a brief lean toward the
      camera by someone else does not steal the role unless they become clearly
      larger, and it also stops the per-frame flip-flopping that happens when
      two faces are of similar size.

    Args:
        multi_face_landmarks: Face list returned by FaceMesh (at least one)
        w, h: Frame size. Sizes and distances are computed in normalized
              coordinates, so the result is resolution-independent.

    Returns:
        The face chosen as primary user (an element of multi_face_landmarks)
    """

    global _last_primary_center

    # (face, center_x, center_y, face_height, squared distance to frame center)
    # — all in normalized coordinates. Size is measured as height rather than
    # area for two reasons:
    #   - Area is quadratic, so a 20% narrower face shrinks 36% and makes the
    #     threshold far too twitchy
    #   - Turning the head sideways cuts the width sharply while the height
    #     barely changes
    faces = []
    for face_lms in multi_face_landmarks:
        xs = [lm.x for lm in face_lms.landmark]
        ys = [lm.y for lm in face_lms.landmark]
        cx = sum(xs) / len(xs)
        cy = sum(ys) / len(ys)
        size = max(ys) - min(ys)
        faces.append((face_lms, cx, cy, size, (cx - 0.5) ** 2 + (cy - 0.5) ** 2))

    # Default choice: the largest face; ties broken by closeness to the center.
    chosen = max(faces, key=lambda f: (f[3], -f[4]))

    # Hysteresis: keep the incumbent primary while it is still large enough.
    if _last_primary_center is not None:
        px, py = _last_primary_center
        incumbent = min(faces, key=lambda f: (f[1] - px) ** 2 + (f[2] - py) ** 2)
        moved = ((incumbent[1] - px) ** 2 + (incumbent[2] - py) ** 2) ** 0.5
        if moved <= PRIMARY_MATCH_DIST and incumbent[3] >= PRIMARY_KEEP_RATIO * chosen[3]:
            chosen = incumbent

    # Updated so that repeated calls within one frame (drowsiness check,
    # pan-tilt, box drawing) return the same result for the same input — the
    # conditions above are already satisfied on re-entry, so this is idempotent.
    _last_primary_center = (chosen[1], chosen[2])
    return chosen[0]


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------
PRIMARY_BOX_COLOR = (0, 220, 0)        # Primary user — green (BGR)
OTHER_BOX_COLOR   = (150, 150, 150)    # Everyone else — gray
BOX_PAD_RATIO     = 0.12               # Box padding relative to landmark extent


def face_bbox(face_lms, w, h) -> tuple:
    """Return the pixel rect (x1, y1, x2, y2) enclosing all face landmarks."""
    xs = [lm.x * w for lm in face_lms.landmark]
    ys = [lm.y * h for lm in face_lms.landmark]
    return min(xs), min(ys), max(xs), max(ys)


def draw_faces(frame, face_res, w, h) -> None:

    """
    Draw boxes on detected faces, in the same style as the phone detection boxes.

    The primary user (the face select_primary_user() picked) gets a thick green
    box labeled USER; everyone else gets a thin gray one. This makes it visible
    at a glance which person the robot considers the primary user when others
    are in frame.

    It calls the same select_primary_user() used for detection, so the green box
    on screen always matches the face that drowsiness detection and pan-tilt
    tracking are actually working on.

    Args:
        frame:    BGR frame (modified in-place)
        face_res: MediaPipe FaceMesh result
        w, h:     Frame width and height
    """

    if not face_res or not face_res.multi_face_landmarks:
        return

    primary = select_primary_user(face_res.multi_face_landmarks, w, h)

    for face_lms in face_res.multi_face_landmarks:
        x1, y1, x2, y2 = face_bbox(face_lms, w, h)

        # Landmarks only reach the face outline, so pad the box to keep the
        # forehead and chin from being cut off.
        pad = (y2 - y1) * BOX_PAD_RATIO
        x1 = max(0, int(x1 - pad))
        y1 = max(0, int(y1 - pad))
        x2 = min(w, int(x2 + pad))
        y2 = min(h, int(y2 + pad))

        if face_lms is primary:
            text, color, thick, scale = "USER", PRIMARY_BOX_COLOR, 3, 0.65
        else:
            text, color, thick, scale = "other", OTHER_BOX_COLOR, 1, 0.45

        cv2.rectangle(frame, (x1, y1), (x2, y2), color, thick)

        # Push the label down when the face sits against the top of the frame,
        # otherwise it gets clipped.
        (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, 2)
        ty = max(y1, th + 8)
        cv2.rectangle(frame, (x1, ty - th - 8), (x1 + tw + 6, ty), color, -1)
        cv2.putText(frame, text, (x1 + 3, ty - 4),
                    cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), 2)


# ---------------------------------------------------------------------------
# Detector class
# ---------------------------------------------------------------------------
class DrowsyDetector:
   
    """
    Stateful drowsiness detector.
 
    Maintains timers for sustained eye-closure and face-loss events.
    Call update() once per frame with MediaPipe face mesh and pose results.
    """
   
    def __init__(self):
        self.eye_closed_start = None
        self.face_lost_start  = None

    def update(self, face_res, pose_res, w, h, now) -> tuple:
     
        """
        Process one frame and return detection results.
 
        Args:
            face_res: MediaPipe FaceMesh result
            pose_res: MediaPipe Pose result
            w, h:     Frame width and height
            now:      Current timestamp (time.time())
 
        Returns:
            (drowsy_eye, drowsy_face_lost, ear_val,
             has_face, has_pose, face_cx, face_cy, lms)
        """
       
        has_face = (face_res.multi_face_landmarks is not None and
                    len(face_res.multi_face_landmarks) > 0)
        has_pose = pose_present(pose_res.pose_landmarks)

        ear_val    = None
        drowsy_eye = False
        face_cx = face_cy = None
        lms = None

        # -- Eye aspect ratio -----------------------------------------------
        if has_face:
            primary_face = select_primary_user(face_res.multi_face_landmarks, w, h)
            lms     = primary_face.landmark
            ear_val = mean_ear(lms, w, h)

            xs = [lm.x * w for lm in lms]
            ys = [lm.y * h for lm in lms]
            face_cx = sum(xs) / len(xs)
            face_cy = sum(ys) / len(ys)

            if ear_val < EAR_THRESHOLD:
                if self.eye_closed_start is None:
                    self.eye_closed_start = now
                elif now - self.eye_closed_start >= EYE_CLOSED_SEC:
                    drowsy_eye = True
            else:
                self.eye_closed_start = None
        else:
            self.eye_closed_start = None

        # -- Face-lost heuristic --------------------------------------------
        drowsy_face_lost = False
        if has_pose and not has_face:
            if self.face_lost_start is None:
                self.face_lost_start = now
            elif now - self.face_lost_start >= FACE_LOST_SEC:
                drowsy_face_lost = True
        else:
            self.face_lost_start = None

        return drowsy_eye, drowsy_face_lost, ear_val, has_face, has_pose, face_cx, face_cy, lms
