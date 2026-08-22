"""
phone_detect.py
---------------
Phone detection module using MediaPipe ObjectDetector with EfficientDet-Lite0.
 
Detects 'cell phone' objects in RGB frames and draws bounding boxes.
Other detected objects are rendered with low-opacity outlines for debug visibility.
"""

import mediapipe as mp
import cv2

from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision as mp_vision

MODEL_PATH       = "detection/efficientdet_lite0.tflite"
OBJ_SCORE_THRESH = 0.45
PHONE_LABEL      = "cell phone"


class PhoneDetector:
    """Wraps the MediaPipe ObjectDetector for phone-specific detection."""
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
            print("[PhoneDetector] Initialized")
        except Exception as e:
            print(f"[PhoneDetector] Disabled — {e}")

    def detect(self, frame_rgb) -> list:
       
        """
        Run object detection on an RGB frame.
 
        Args:
            frame_rgb: numpy array in RGB format (H, W, 3)
 
        Returns:
            List of Detection objects; empty list if detector is unavailable.
        """
        
        if self.detector is None:
            return []
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame_rgb)
        return self.detector.detect(mp_image).detections

    def draw(self, frame, detections, h, w) -> bool:
        
        """
        Overlay bounding boxes on the BGR frame and return phone detection flag.

        Phone detections are highlighted in orange; other objects in gray.

        Args:
            frame:      BGR frame to draw on (modified in-place)
            detections: Detection list from detect()
            h, w:       Frame height and width

        Returns:
            True if at least one 'cell phone' was detected, False otherwise.
        """
        
        phone_detected = False
       
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
        """Release the underlying MediaPipe detector."""
        if self.detector:
            self.detector.close()
