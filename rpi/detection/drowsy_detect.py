import numpy as np
import mediapipe as mp

# =====================================================================
# EAR 설정
# =====================================================================
L_EYE = [33, 160, 158, 133, 153, 144]
R_EYE = [362, 385, 387, 263, 373, 380]

EAR_THRESHOLD  = 0.20
EYE_CLOSED_SEC = 1.5
FACE_LOST_SEC  = 5.0
MIN_POSE_VIS   = 0.5

mp_pose = mp.solutions.pose
POSE_L_SHOULDER = mp_pose.PoseLandmark.LEFT_SHOULDER.value
POSE_R_SHOULDER = mp_pose.PoseLandmark.RIGHT_SHOULDER.value


def _pt2(lms, idx, w, h):
    lm = lms[idx]
    return np.array([lm.x * w, lm.y * h], dtype=np.float32)

def ear(lms, idx, w, h):
    p = [_pt2(lms, i, w, h) for i in idx]
    v1 = np.linalg.norm(p[1] - p[5])
    v2 = np.linalg.norm(p[2] - p[4])
    hd = np.linalg.norm(p[0] - p[3])
    return (v1 + v2) / (2 * hd) if hd > 1e-6 else 1.0

def mean_ear(lms, w, h):
    return (ear(lms, L_EYE, w, h) + ear(lms, R_EYE, w, h)) / 2.0

def pose_present(pose_lms):
    if pose_lms is None:
        return False
    lms = pose_lms.landmark
    return (lms[POSE_L_SHOULDER].visibility > MIN_POSE_VIS or
            lms[POSE_R_SHOULDER].visibility > MIN_POSE_VIS)

def select_primary_user(multi_face_landmarks, w, h):
    frame_cx, frame_cy = w / 2, h / 2
    def face_center_dist(face_lms):
        xs = [lm.x * w for lm in face_lms.landmark]
        ys = [lm.y * h for lm in face_lms.landmark]
        cx = sum(xs) / len(xs)
        cy = sum(ys) / len(ys)
        return (cx - frame_cx) ** 2 + (cy - frame_cy) ** 2
    return min(multi_face_landmarks, key=face_center_dist)


class DrowsyDetector:
    def __init__(self):
        self.eye_closed_start = None
        self.face_lost_start  = None

    def update(self, face_res, pose_res, w, h, now):
        """
        반환: (drowsy_eye, drowsy_face_lost, ear_val, has_face, has_pose, face_cx, face_cy, lms)
        """
        has_face = (face_res.multi_face_landmarks is not None and
                    len(face_res.multi_face_landmarks) > 0)
        has_pose = pose_present(pose_res.pose_landmarks)

        ear_val    = None
        drowsy_eye = False
        face_cx = face_cy = None
        lms = None

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

        drowsy_face_lost = False
        if has_pose and not has_face:
            if self.face_lost_start is None:
                self.face_lost_start = now
            elif now - self.face_lost_start >= FACE_LOST_SEC:
                drowsy_face_lost = True
        else:
            self.face_lost_start = None

        return drowsy_eye, drowsy_face_lost, ear_val, has_face, has_pose, face_cx, face_cy, lms
