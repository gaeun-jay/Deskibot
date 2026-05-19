import threading
import time
import cv2
from flask import Flask, Response, render_template_string

app = Flask(__name__)

_frame_lock  = threading.Lock()
_status_lock = threading.Lock()
_current_frame  = None
_current_status = {
    "state":    "시작 중...",
    "ear":      "N/A",
    "has_face": False,
    "has_pose": False,
    "phone":    False,
    "drowsy":   False,
}

HTML = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Deskibot 모니터</title>
    <style>
        body { background: #1a1a1a; color: #fff; font-family: monospace; padding: 20px; margin: 0; }
        h1   { color: #00ffcc; margin-bottom: 10px; }
        .container { display: flex; gap: 20px; align-items: flex-start; }
        img  { border: 2px solid #00ffcc; border-radius: 8px; width: 640px; height: 480px; }
        .status { font-size: 1.1em; min-width: 200px; }
        .status p { margin: 8px 0; }
        .ok   { color: #00ff88; }
        .warn { color: #ff4444; }
        .gray { color: #888; }
    </style>
</head>
<body>
    <h1>🤖 Deskibot 실시간 모니터</h1>
    <div class="container">
        <img src="/video_feed">
        <div class="status" id="status">
            <p>불러오는 중...</p>
        </div>
    </div>
    <script>
        // 상태만 0.5초마다 fetch로 업데이트
        function updateStatus() {
            fetch('/status')
                .then(r => r.json())
                .then(data => {
                    const s = document.getElementById('status');
                    s.innerHTML = `
                        <p>상태: <span class="${data.drowsy ? 'warn' : 'ok'}">${data.state}</span></p>
                        <p>EAR: <span class="${data.drowsy ? 'warn' : 'ok'}">${data.ear}</span></p>
                        <p>얼굴: <span class="${data.has_face ? 'ok' : 'gray'}">${data.has_face ? '감지됨' : '미감지'}</span></p>
                        <p>자세: <span class="${data.has_pose ? 'ok' : 'gray'}">${data.has_pose ? '감지됨' : '미감지'}</span></p>
                        <p>핸드폰: <span class="${data.phone ? 'warn' : 'gray'}">${data.phone ? '감지됨 📱' : '없음'}</span></p>
                        <p>졸음: <span class="${data.drowsy ? 'warn' : 'ok'}">${data.drowsy ? '감지됨 😴' : '정상'}</span></p>
                    `;
                });
        }
        setInterval(updateStatus, 500);
        updateStatus();
    </script>
</body>
</html>
"""

def update_frame(frame):
    global _current_frame
    with _frame_lock:
        _current_frame = frame.copy()

def update_status(state, ear, has_face, has_pose, phone, drowsy):
    global _current_status
    with _status_lock:
        _current_status = {
            "state":    state,
            "ear":      ear,
            "has_face": has_face,
            "has_pose": has_pose,
            "phone":    phone,
            "drowsy":   drowsy,
        }

def _generate():
    while True:
        with _frame_lock:
            if _current_frame is None:
                time.sleep(0.05)
                continue
            _, buf = cv2.imencode('.jpg', _current_frame, [cv2.IMWRITE_JPEG_QUALITY, 60])
        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + buf.tobytes() + b'\r\n')
        time.sleep(0.033)  # ~30fps

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/video_feed')
def video_feed():
    return Response(_generate(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/status')
def status():
    with _status_lock:
        return _current_status.copy()

def start_server(host='0.0.0.0', port=5000):
    t = threading.Thread(
        target=lambda: app.run(host=host, port=port, debug=False, use_reloader=False),
        daemon=True
    )
    t.start()
    print(f"✅ 웹 서버 시작! http://<RPi5_IP>:5000")