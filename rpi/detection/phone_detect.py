import mediapipe as mp
import cv2

from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision as mp_vision

MODEL_PATH       = "detection/efficientdet_lite0.tflite"
OBJ_SCORE_THRESH = 0.45
PHONE_LABEL      = "cell phone"


class PhoneDetector:
    def __init__(self):
        self.detector = None
        try:
            base_options = mp_python.BaseOptions(model_asset_path=MODEL_PATH)
            det_options  = mp_vision.ObjectDetectorOptions(
                base_options=base_options,
                score_threshold=OBJ_SCORE_THRESH,
                max_results=5
            )
            self.detector = mp_vision.ObjectDetector.create_from_options(det_options)
            print("✅ Object Detector 초기화 완료 (핸드폰 감지 활성화)")
        except Exception as e:
            print(f"⚠️  Object Detector 비활성화: {e}")

    def detect(self, frame_rgb):
        """핸드폰 감지 실행, 결과 detections 반환"""
        if self.detector is None:
            return []
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame_rgb)
        return self.detector.detect(mp_image).detections

    def draw(self, frame, detections, h, w):
        """감지 결과 프레임에 시각화, phone_detected bool 반환"""
        phone_detected = False
        for det in detections:
            if not det.categories:
                continue
            label = det.categories[0].category_name.lower()
            score = det.categories[0].score
            bbox  = det.bounding_box
            x1 = max(0, int(bbox.origin_x))
            y1 = max(0, int(bbox.origin_y))
            x2 = min(w, int(bbox.origin_x + bbox.width))
            y2 = min(h, int(bbox.origin_y + bbox.height))

            if label == PHONE_LABEL:
                phone_detected = True
                cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 165, 255), 3)
                text = f"Phone {score:.0%}"
                (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.65, 2)
                cv2.rectangle(frame, (x1, y1 - th - 8), (x1 + tw + 6, y1), (0, 165, 255), -1)
                cv2.putText(frame, text, (x1 + 3, y1 - 4),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2)
            else:
                cv2.rectangle(frame, (x1, y1), (x2, y2), (180, 180, 180), 1)
                cv2.putText(frame, f"{label} {score:.0%}", (x1, y1 - 4),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 180), 1)
        return phone_detected

    def close(self):
        if self.detector:
            self.detector.close()
