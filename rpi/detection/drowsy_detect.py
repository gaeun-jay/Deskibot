"""
drowsy_detect.py
----------------
Drowsiness detection module using Eye Aspect Ratio (EAR) and pose analysis.
 
Detection conditions:
  1. DROWSY_EYE       — EAR drops below threshold for EYE_CLOSED_SEC seconds
  2. DROWSY_FACE_LOST — Face disappears while pose (upper body) is still visible
                        for FACE_LOST_SEC seconds (head-drop heuristic)
 
Multi-face handling: when multiple faces are detected, the one closest to the
frame center is selected as the primary user.
"""
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

def select_primary_user(multi_face_landmarks, w, h):
   
    """
    Select the face closest to the frame center when multiple faces are detected.
    Assumes the primary user is typically centered in frame.
    """
    
    frame_cx, frame_cy = w / 2, h / 2
    def face_center_dist(face_lms):
        xs = [lm.x * w for lm in face_lms.landmark]
        ys = [lm.y * h for lm in face_lms.landmark]
        cx = sum(xs) / len(xs)
        cy = sum(ys) / len(ys)
        return (cx - frame_cx) ** 2 + (cy - frame_cy) ** 2
    return min(multi_face_landmarks, key=face_center_dist)


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
