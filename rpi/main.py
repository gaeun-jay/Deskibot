import os
os.environ["QT_QPA_PLATFORM"] = "offscreen"
import sys
sys.path.insert(0, '/usr/local/lib/python3.11/site-packages')
sys.path.append('/usr/lib/python3/dist-packages')

import time
import cv2
import mediapipe as mp
from picamera2 import Picamera2

from detection.drowsy_detect import DrowsyDetector, draw_faces
from detection.phone_detect  import PhoneDetector
from detection.debounce      import Debouncer
from tracking.pantilt        import PanTilt
from comm.uart_client        import UartClient
from comm.camera import update_frame, update_status, start_server
from tracking.pantilt import PanTilt, _is_full_face

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OBJ_DETECT_EVERY      = 3     # Run object detection every N frames
STATUS_PRINT_INTERVAL = 3.0   # Periodic status log interval (seconds)

# Debounce delays (seconds): how long a raw flag must hold before it is confirmed.
# Rise is 0.0 so detection registers immediately; only the release is damped.
PHONE_RISE_SEC  = 0.0   # Report a phone the moment it is seen
PHONE_FALL_SEC  = 2.0   # Keep phone state through hand/angle occlusion
DROWSY_RISE_SEC = 0.0   # Drowsiness is already time-gated inside DrowsyDetector
DROWSY_FALL_SEC = 2.0   # Ride out momentary face-mesh tracking dropouts

# No-person runs the delays the other way round, on purpose.
#
# Phone and drowsiness damp the RELEASE so a dropped frame does not clear a real
# detection. Doing that for an empty desk would be dangerous: a user who is
# sitting right there but whose face/pose blinks out every second or two would
# hold the filter True the whole time, and the 5-minute clock below (which stops
# at raw_false_since, not at the confirmed edge) would keep counting and kill
# their session. So here the RISE is damped instead — the desk must read empty
# for 2 uninterrupted seconds — and the release is instant, so a single frame
# with a person in it resets the clock to zero.
NO_PERSON_RISE_SEC = 2.0
NO_PERSON_FALL_SEC = 0.0

# Short-event filter: a detection must hold this long before it is sent to the ESP.
# A detection that clears before reaching 10s never goes out over UART, so the
# server never records it either.
UART_MIN_HOLD_SEC = 10.0

# The desk must read empty this long before the ESP is told. The ESP turns that
# into a forced end of a running pomodoro (status='interrupted' in the DB), so
# the bar is deliberately much higher than the 10s used for phone/drowsy.
NO_PERSON_HOLD_SEC = 300.0   # 5 minutes


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def held_long_enough(detected: bool, since: float, filt, mono: float,
                     hold_sec: float = UART_MIN_HOLD_SEC) -> bool:
    """
    Report whether a detection has held for at least hold_sec.

    Args:
        detected: Current debounced detection state.
        since:    Monotonic timestamp at which that state became True;
                  None while it is False.
        filt:     Debouncer for this channel, used to read when the raw
                  signal actually stopped.
        mono:     Monotonic timestamp for this frame.
        hold_sec: Required duration. Defaults to the 10s phone/drowsy gate;
                  no-person passes NO_PERSON_HOLD_SEC instead.

    Elapsed time is measured up to raw_false_since, not up to mono. The
    debounced flag already carries the 2s fall delay, so measuring against
    mono would score a 9-second detection as 11 seconds and let it through.
    Stopping the clock the instant the raw signal drops is what makes a
    '9 seconds, then released' detection evaluate as 9 seconds and get filtered.

    When the raw signal blips and comes back (a hand covers the phone, the face
    mesh drops a frame), the debounced flag stays True and so does `since` —
    a blip therefore never resets the timer.
    """
    if not detected or since is None:
        return False
    raw_end = filt.raw_false_since        # None while raw is still True
    end = mono if raw_end is None else raw_end
    return (end - since) >= hold_sec


# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------
print("=== Deskibot Detection System Initializing ===")


picam = Picamera2()
picam.configure(picam.create_preview_configuration(
    main={'format': 'RGB888', 'size': (640, 480)},
    buffer_count=2,
    controls={"AfMode": 2, "AfSpeed": 1, "FrameRate": 30.0}
))
picam.start()
time.sleep(2)
print("[Camera] Initialized")


pantilt  = PanTilt()
drowsy   = DrowsyDetector()
phone    = PhoneDetector()
phone_filter  = Debouncer(PHONE_RISE_SEC,  PHONE_FALL_SEC,  name="phone")
drowsy_filter = Debouncer(DROWSY_RISE_SEC, DROWSY_FALL_SEC, name="drowsy")
no_person_filter = Debouncer(NO_PERSON_RISE_SEC, NO_PERSON_FALL_SEC,
                             name="no_person")
uart     = UartClient()
start_server()


# MediaPipe
mp_face_mesh = mp.solutions.face_mesh
mp_pose      = mp.solutions.pose

face_mesh = mp_face_mesh.FaceMesh(
    # Accept several faces so select_primary_user() still has a choice when
    # bystanders are in frame. With max_num_faces=1 MediaPipe returns whichever
    # face it is most confident about, and primary-user selection never runs.
    static_image_mode=False, max_num_faces=3,
    refine_landmarks=True,
    min_detection_confidence=0.5, min_tracking_confidence=0.5
)
pose_model = mp_pose.Pose(
    static_image_mode=False, model_complexity=1,
    enable_segmentation=False,
    min_detection_confidence=0.5, min_tracking_confidence=0.5
)
print("[MediaPipe] Initialized")

# ---------------------------------------------------------------------------
# State variables
# ---------------------------------------------------------------------------
frame_count          = 0
last_detections      = []
_last_status_print   = 0.0
_prev_state          = ""
_phone_was_detected  = False
_drowsy_was_detected = False
_prev_drowsy         = False          # Last value actually sent over UART
_prev_phone          = False
_prev_no_person      = False
_drowsy_since        = None           # Monotonic start of the detection; None once cleared
_phone_since         = None
_no_person_since     = None
_no_person_reported  = False          # Console-log edge tracking only
_drowsy_reason       = "DROWSY_EYE"   # Latched cause of the current drowsy episode

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
print("[System] Detection loop started")

try:
    while True:
        # Picamera2's 'RGB888' format actually yields BGR-ordered arrays
        frame = picam.capture_array()
        frame = cv2.flip(frame, 1)
        rgb   = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        h, w  = frame.shape[:2]
        now   = time.time()
        mono  = time.monotonic()   # Shared clock for the debounce filters
        frame_count += 1

        face_res = face_mesh.process(rgb)
        pose_res = pose_model.process(rgb)

        # -- Drowsiness detection -------------------------------------------
        (drowsy_eye, drowsy_face_lost, ear_val,
         has_face, has_pose,
         face_cx, face_cy, lms) = drowsy.update(face_res, pose_res, w, h, now)

        # -- Pan-tilt tracking ----------------------------------------------
        full_face, _, _ = _is_full_face(face_res, w, h)
        #print(f"full_face={full_face}, has_face={has_face}, has_pose={has_pose}")

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

        # -- Phone detection (throttled) ------------------------------------
        if frame_count % OBJ_DETECT_EVERY == 0:
            last_detections = phone.detect(rgb)
        raw_phone = phone.draw(frame, last_detections, h, w)

        # -- Face boxes ------------------------------------------------------
        # Primary user gets a green USER box; everyone else a gray 'other' box.
        draw_faces(frame, face_res, w, h)

        # -- State determination --------------------------------------------
        is_drowsy = drowsy_eye or drowsy_face_lost

        # Debounce both flags; everything below this point uses the filtered
        # values so a one-frame dropout does not clear the state.
        is_drowsy      = drowsy_filter.update(is_drowsy, mono)
        phone_detected = phone_filter.update(raw_phone, mono)

        # An empty desk means neither a face nor a body anywhere in frame.
        # drowsy_face_lost needs has_pose, and drowsy_eye needs has_face, so a
        # truly empty desk can never also read as drowsy — the two are disjoint.
        raw_no_person  = not has_face and not has_pose
        no_person_detected = no_person_filter.update(raw_no_person, mono)

        # Latch why we became drowsy — the raw cause may already be gone while
        # the filter is still holding the state through its fall delay.
        if drowsy_eye:
            _drowsy_reason = "DROWSY_EYE"
        elif drowsy_face_lost:
            _drowsy_reason = "DROWSY_FACE_LOST"

        if is_drowsy:
            state = _drowsy_reason
        else:
            state = "NORMAL" if has_face else ("POSE_ONLY" if has_pose else "NO_PERSON")

        # -- Minimum-hold gate for UART -------------------------------------
        # Record when each detection started; only those that reach
        # UART_MIN_HOLD_SEC are forwarded to the ESP. The on-screen state and
        # the web stream keep using the ungated values.
        _drowsy_since = (mono if _drowsy_since is None else _drowsy_since) if is_drowsy      else None
        _phone_since  = (mono if _phone_since  is None else _phone_since)  if phone_detected else None
        # NO_PERSON_FALL_SEC is 0.0, so one frame with a person in it drops the
        # confirmed flag and clears this timestamp — the 5-minute clock restarts
        # from scratch rather than resuming.
        _no_person_since = ((mono if _no_person_since is None else _no_person_since)
                            if no_person_detected else None)

        uart_drowsy = held_long_enough(is_drowsy,      _drowsy_since, drowsy_filter, mono)
        uart_phone  = held_long_enough(phone_detected, _phone_since,  phone_filter,  mono)
        uart_no_person = held_long_enough(no_person_detected, _no_person_since,
                                          no_person_filter, mono,
                                          hold_sec=NO_PERSON_HOLD_SEC)

        # -- Push detection state on change only ----------------------------
        # The ESP32 is the only uplink. It holds the focus session (session_id)
        # and the device token, so it is the only side that can attach a
        # detection event to the server. The RPi reports nothing but "detected
        # right now / not detected"; timestamps and durations are the server's job.
        #
        # No-person is the exception to "the server owns the timing": it is not a
        # detection event at all. The ESP reads it as "force-end the pomodoro",
        # and the DB records that as status='interrupted' — distinct from the
        # user's own double-tap stop ('incomplete') and from a natural finish
        # ('completed'). Nothing is written to focus_session_events for it.
        if (uart_drowsy != _prev_drowsy
                or uart_phone != _prev_phone
                or uart_no_person != _prev_no_person):
            uart.update_detection(drowsy=uart_drowsy, phone=uart_phone,
                                  no_person=uart_no_person)
            print(f"[{time.strftime('%H:%M:%S')}] UART → "
                  f"DROWSY:{int(uart_drowsy)},PHONE:{int(uart_phone)},"
                  f"NOPERSON:{int(uart_no_person)}")
            _prev_drowsy    = uart_drowsy
            _prev_phone     = uart_phone
            _prev_no_person = uart_no_person

        # -- Event logging (console only) ------------------------------------
        # The server owns event recording; these are human-readable logs only.
        # On release we also print how long ago the signal really stopped,
        # because the debounce fall delay makes the UART 0 arrive FALL_SEC after
        # the true end. The server stamps ended_at on arrival, so every recorded
        # duration carries that constant bias.
        # (Subtract FALL_SEC from duration_sec during analysis to recover the
        #  real value.)
        if phone_detected and not _phone_was_detected:
            _phone_was_detected = True
            print(f"[{time.strftime('%H:%M:%S')}] Phone detected")
        elif not phone_detected and _phone_was_detected:
            _phone_was_detected = False
            lag = mono - phone_filter.raw_false_since if phone_filter.raw_false_since else 0.0
            print(f"[{time.strftime('%H:%M:%S')}] Phone cleared "
                  f"(really ended {lag:.1f}s ago)")

        if is_drowsy and not _drowsy_was_detected:
            _drowsy_was_detected = True
            print(f"[{time.strftime('%H:%M:%S')}] Drowsiness detected")
        elif not is_drowsy and _drowsy_was_detected:
            _drowsy_was_detected = False
            lag = mono - drowsy_filter.raw_false_since if drowsy_filter.raw_false_since else 0.0
            print(f"[{time.strftime('%H:%M:%S')}] Drowsiness cleared "
                  f"(really ended {lag:.1f}s ago)")

        # No-person is logged off the reported (5-minute) flag rather than the
        # debounced one, because the debounced flag flips every time somebody
        # walks past the desk and would bury the log.
        if uart_no_person and not _no_person_reported:
            _no_person_reported = True
            print(f"[{time.strftime('%H:%M:%S')}] Desk empty for "
                  f"{int(NO_PERSON_HOLD_SEC)}s → reported to ESP")
        elif not uart_no_person and _no_person_reported:
            _no_person_reported = False
            print(f"[{time.strftime('%H:%M:%S')}] User back at the desk")

        # -- State transition log -------------------------------------------
        if state != _prev_state:
            STATE_LABELS = {
                "NORMAL":           "Normal — face tracked",
                "DROWSY_EYE":       "Drowsy — eyes closed",
                "DROWSY_FACE_LOST": "Drowsy — face lost",
                "POSE_ONLY":        "Pose only — face not visible",
                "NO_PERSON":        "No person detected",
            }
            print(f"[{time.strftime('%H:%M:%S')}] State → {STATE_LABELS.get(state, state)}")
            _prev_state = state

        # -- Periodic status heartbeat --------------------------------------
        if now - _last_status_print >= STATUS_PRINT_INTERVAL:
            _last_status_print = now
            ear_str   = f"EAR={ear_val:.3f}" if ear_val is not None else "EAR=N/A"
            face_str  = "face=Y" if has_face else "face=N"
            pose_str  = "pose=Y" if has_pose else "pose=N"
            phone_str = "phone=Y" if phone_detected else "phone=N"
            print(f"[{time.strftime('%H:%M:%S')}] [{state}] {ear_str} | {face_str} | {pose_str} | {phone_str}")

        # -- Web streaming update -------------------------------------------
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
    picam.stop()
    phone.close()
    pantilt.close()
    uart.close()
    print("[System] Clean exit")