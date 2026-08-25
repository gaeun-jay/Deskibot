"""
gaze_detect.py
--------------
Iris-based attention detection.

main.py already builds FaceMesh with refine_landmarks=True. That flag swaps in
the attention-mesh submodel, which re-runs the eye and lip regions at higher
resolution and appends 10 iris landmarks to the usual 468:

    468        left iris centre         473        right iris centre
    469-472    left iris rim            474-477    right iris rim

Nothing in the original pipeline reads them. Drowsiness works off the eyelid
contour points only (EAR is how OPEN the lid is, not where the eye points), and
the pan-tilt tracker uses five coarse face points, so indices 468 and above are
computed on every frame and thrown away. This module is the missing consumer.

Scope
-----
Two iris centres support a narrow set of claims, and this module deliberately
stops there. It does NOT estimate where on the screen the user is looking --
that needs a per-user 9-point calibration and a fixed head position, neither of
which a desk robot has. What it does answer:

    GAZE_AWAY    the gaze is held off to one side of (or well below) the
                 direction the user normally faces
    GAZE_WANDER  the gaze keeps travelling over a wide area -- looking round
                 the room rather than at one working surface
    GAZE_BLANK   the gaze has stopped moving while the eyes are open AND the
                 blink rate has climbed: the vacant stare of someone who has
                 checked out

All three are relative to a baseline captured at startup, because the raw
numbers depend on the user's face and on where they happen to sit.

What each state looks like at a real desk
-----------------------------------------
Everything below this docstring is angles and seconds. This is what those
correspond to in the room.

  FOCUSED
      Reading code with the eyes tracking along the lines. Glancing between
      screen, keyboard and notebook. Looking away for a moment to think and
      coming back. A quick check of the second monitor. Head turned aside
      while the eyes stay on the screen.

      FOCUSED has no test of its own -- it is whatever is left when none of
      the three below fire. That is deliberate. "The eyes show no evidence of
      having left the work" is the strongest claim two iris centres support;
      "this person is concentrating" is not, and a state that asserted it
      would be lying about its own evidence.

  GAZE_AWAY -- looking at something else
      Turning to talk to someone beside the desk. Watching something out of
      the window. Following a TV, or a neighbour's monitor, or a wall clock.
      Held past AWAY_SEC, which is what separates it from thinking.

  GAZE_WANDER -- the eyes will not settle
      Scanning the room, tracking people walking past, fidgeting. What
      separates it from GAZE_AWAY is shape rather than size: every individual
      sample can sit inside the attention zone, and it is the constant
      travelling that gives it away.

          GAZE_AWAY      o------------------>X    goes somewhere, stays
          GAZE_WANDER    X<---o--->X<---o--->X    never settles anywhere

  GAZE_BLANK -- looking without seeing
      Staring at one point on the screen without scrolling. Re-reading the
      same line while none of it goes in.

  Not this module's job, and handled elsewhere in the pipeline:
      eyes closed, head dropped   -> drowsy_detect
      phone in frame              -> phone_detect
      nobody at the desk          -> the no_person filter in the main loop

Two different things are being measured
---------------------------------------
The attention literature separates two phenomena that are easy to conflate, and
the states above straddle both:

  OFF-TASK GAZE   the eyes physically leave the work. Behavioural, obvious, and
                  the easy case for a camera. GAZE_AWAY and GAZE_WANDER.
  MIND WANDERING  the eyes stay on the work while the mind leaves it -- what
                  Smallwood calls perceptual decoupling. No amount of "where is
                  he looking" answers this; it only shows up in HOW the eyes
                  move. GAZE_BLANK.

Mixing them up is what makes naive attention detectors useless: they report the
person staring hard at the screen as maximally focused, which is the exact
posture of someone who checked out four minutes ago.

What the research supports
--------------------------
Markers that replicate across reading, lecture and free-viewing studies, and
whether this module can actually measure them off a 640x480 webcam:

  fixation duration UP, fixations/sec DOWN during mind wandering.
      The most reproduced pair. Reichle et al. 2010 (mindless reading), Educ.
      Sci. 2020 (video lecture), Zhang & Feng 2024 (panorama, where
      fixations/sec and mean fixation duration were the two top predictors,
      AUC 0.80).
      NOT MEASURABLE HERE -- see 'What is deliberately not computed' below.

  blink rate UP during mind wandering.
      Smilek, Carriere & Cheyne 2010: participants blinked more in the seconds
      before reporting a wandering mind, and read it as the body throttling
      visual input. Confirmed by Grandchamp et al. 2014 (blink rate AND blink
      duration both up). Not universal -- Educ. Sci. 2020 found blink count
      unusable for lecture viewing -- but it is the one well-replicated marker
      this hardware can measure honestly, because a blink is a huge signal next
      to the noise floor of everything else here.
      IMPLEMENTED, and required as corroboration for GAZE_BLANK.

  gaze dispersion: CONTRADICTORY, and the direction depends on the task.
      Screen-bounded tasks (slides, lecture, reading) report dispersion going
      DOWN during mind wandering -- fixations shrink into a smaller patch.
      Free-viewing tasks (panorama) report it going UP. A desk with a monitor
      is the screen-bounded case, so low dispersion is the mind-wandering
      direction here and GAZE_WANDER's high dispersion is NOT a mind-wandering
      marker at all -- it is an off-task-gaze marker. Kept, relabelled.

  pupil diameter DOWN during mind wandering.
      Grandchamp et al. 2014's single most reliable predictor (SVM 77-81%).
      NOT MEASURABLE HERE -- see below.

Gaze aversion is not distraction
--------------------------------
The finding that most directly contradicts the obvious rule. Glenberg,
Schroeder & Robertson 1998 showed that people avert their gaze when questions
get harder, that aversion frequency tracks cognitive difficulty, and -- the
important part -- that averting IMPROVES performance: it disengages the
environment so the non-visual task gets more resources. Doherty-Sneddon &
Phelps replicate it and frame it as load management rather than avoidance.

So a person who looks up and to the left for two seconds in the middle of hard
work is doing the single most on-task thing a pair of eyes can do, and an
attention detector that scolds them for it is actively wrong. AWAY_SEC below is
set from this, not from comfort: brief aversions must fall through.

What is deliberately not computed
---------------------------------
Each of these is a real marker in the literature and each is out of reach on
this hardware. Listed so the next person does not implement a fake version:

  pupil diameter -- MediaPipe fits the IRIS, not the pupil. Iris diameter is
      near-constant across adults (~11.7 mm), which is precisely why MediaPipe
      uses it as a depth reference. The pupil inside it is not landmarked at
      all, so pupil dilation is not merely noisy here, it is absent.

  individual fixations and saccades -- fixation-level algorithms (I-DT, I-VT)
      want sub-degree accuracy at 300 Hz+. Webcam gaze estimation runs about
      1-4 degrees of error, the Pi loop runs 15-30 fps, and a fixation lasts
      200-300 ms, i.e. under ten samples. The features would be noise wearing
      the name of a statistic. _shift_rate below is an admitted crude proxy and
      is logged only, never used to decide.

  anything inferred from gaze DIRECTION beyond 'away' -- the folk rule that up
      and to the left means recalling and up-right means inventing (NLP 'eye
      accessing cues') was tested directly by Wiseman & Watt 2012 across three
      studies and found to have no relationship to anything. Direction is used
      here for one purpose only: telling the user which way they drifted.

Known failure cases
-------------------
Written down because a detector whose failures are known can be designed
around, and one whose failures surface during a demo cannot.

  Phone held low in the lap -> reads as FOCUSED.
      It sits inside AWAY_RY_DOWN, which is the price of not flagging every
      person who looks at a keyboard. phone_detect is what actually covers
      this case, and it is why the two detectors run side by side rather than
      one being folded into the other.

  Hunting for a document across the desk -> reads as GAZE_WANDER.
      Working, scored as restless. The eyes cannot separate searching from
      fidgeting, because the difference is intent and intent does not show up
      in where the iris is.

  Thinking hard for longer than AWAY_SEC -> reads as GAZE_AWAY.
      The 4 s is a compromise, not a fix. It pushes this failure further out
      rather than removing it, and no threshold removes it, because a long
      look at the ceiling really is the same measurement either way.

  Watching a video lecture -> can read as GAZE_BLANK.
      The eyes genuinely do stop moving when the content is doing the work.
      The blink requirement is the only thing holding this back, and it is
      also the case where the literature is least settled -- the 2020 lecture
      study is exactly the one that found blink count unusable.

  Wide-eyed at the screen, mind elsewhere, blink rate unchanged -> FOCUSED.
      The hard limit of the whole approach. This is the case pupil diameter
      would catch, and pupil diameter is the one signal MediaPipe does not
      expose. Nothing in this module can reach it; saying so is more useful
      than a threshold that pretends otherwise.

Every threshold here is biased toward missing rather than toward flagging. A
desk robot that tells a concentrating person to concentrate is worse than one
that lets a lapse through: the first kind of error poisons every later alert,
the second costs one.

Why head pose is folded in
--------------------------
Iris position alone is not gaze. Turn your head toward the window while keeping
your eyes on the monitor and the eyes counter-roll: eye-in-head reads 'looking
hard left' while the real gaze never left the screen. The reverse case is
worse -- turn toward the window and let the eyes ride along with the head, and
the irises sit dead centre in their sockets, so an iris-only detector reports
perfect focus at the exact moment attention left.

So gaze is assembled the way oculomotor work decomposes it:

    gaze-in-space  =  eye-in-head  +  head-in-space

eye-in-head comes from the iris offset inside the eye opening, head-in-space
from a cheap nose-versus-eyeline proxy. Both are signed the same way (positive
toward the right and the bottom of the image), so a head turn the eyes cancel
sums back to zero, which is the correct answer. Setting HEAD_GAIN_X/Y to 0
degrades this to a pure iris detector if that is ever wanted for comparison.

Mirroring
---------
main.py runs cv2.flip(frame, 1) before inference, so every coordinate here is
in the mirrored image the user sees on the web page. Landmark indices are
anatomical and unaffected, but the direction LABELS ('LEFT'/'RIGHT') follow the
mirror, which is what makes them match the video overlay. Drop the flip and the
labels swap; the detection thresholds are symmetric and would not care.
"""

import math
from collections import deque

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# Landmark indices
# ---------------------------------------------------------------------------
# refine_landmarks=False yields 468 landmarks, True yields 478. Everything here
# needs the extra 10, so the count is the feature check.
IRIS_MIN_LANDMARKS = 478

IRIS_L_CENTER = 468
IRIS_R_CENTER = 473
IRIS_L_RING   = (469, 470, 471, 472)
IRIS_R_RING   = (474, 475, 476, 477)

# Eye corners: 'outer' is the temple-side corner, 'inner' the nose-side one.
EYE_L_OUTER, EYE_L_INNER = 33, 133
EYE_R_OUTER, EYE_R_INNER = 263, 362

NOSE_TIP = 1

# ---------------------------------------------------------------------------
# Head-pose gains
# ---------------------------------------------------------------------------
# The eye term and the head term arrive in different natural units, so the head
# term is rescaled before they are summed. Both scales follow from average adult
# face geometry, which is why these are fixed constants rather than tunables:
#
#     eyeball radius       ~12 mm      nose protrusion   ~20 mm
#     eye corner-to-corner ~30 mm      outer eye span    ~90 mm
#
#   30 deg of pure EYE rotation moves the iris centre 12*sin30 = 6.0 mm,
#     i.e. 6.0/30 = 0.20 eye-widths
#   30 deg of pure head YAW swings the nose tip 20*sin30 = 10 mm sideways while
#     the eye span foreshortens to 90*cos30 = 78 mm,
#     i.e. 10/78 = 0.128 span-units      ->  gain 0.20/0.128 = 1.6
#   30 deg of pure head PITCH changes the nose tip's offset from the eye line by
#     20*sin30 = 10 mm over a span that does not foreshorten,
#     i.e. 10/90 = 0.111 span-units      ->  gain 0.20/0.111 = 1.8
#
# The useful by-product of that arithmetic: one unit of the combined measure is
# about 150 degrees of gaze, so 0.20 ~ 30 deg. Every threshold below is written
# with its angle in the comment.
HEAD_GAIN_X = 1.6
HEAD_GAIN_Y = 1.8

# ---------------------------------------------------------------------------
# Attention zone
# ---------------------------------------------------------------------------
# Radii of the ellipse around the calibrated straight-ahead direction that still
# counts as looking at the work.
AWAY_RX      = 0.16   # ~24 deg left or right
AWAY_RY_UP   = 0.16   # ~24 deg up
AWAY_RY_DOWN = 0.30   # ~45 deg down. Looking down is a keyboard or a notebook
                      # far more often than it is distraction, so the zone is
                      # stretched downward instead of being a circle.

AWAY_SEC = 4.0        # Sustained time outside the ellipse before it counts.
                      #
                      # This was 1.5 s on the reasoning that it only had to
                      # outlast a saccade to the second monitor. That is the
                      # wrong bar. Glenberg et al. 1998 and Doherty-Sneddon &
                      # Phelps 2005 both show gaze aversion is how people shed
                      # visual load while thinking, that it scales with question
                      # difficulty, and that it makes them perform BETTER -- so
                      # a couple of seconds of looking at the ceiling is a sign
                      # of hard work, and firing on it inverts the whole point
                      # of the feature.
                      #
                      # 4 s is long enough that a thinking aversion falls
                      # through and short enough to still catch a phone or a
                      # conversation. The literature gives the direction, not
                      # the number, so this is the threshold most worth
                      # re-tuning against the logged dev values.

# ---------------------------------------------------------------------------
# Movement windows
# ---------------------------------------------------------------------------
# Dispersion = RMS distance of the gaze samples from their own mean over a
# window. Spread rather than path length, because per-frame landmark jitter
# inflates path length without moving the spread.
SHORT_WINDOW_SEC = 3.0
LONG_WINDOW_SEC  = 6.0
MIN_WINDOW_SAMPLES = 12    # Below this the statistic is noise
WINDOW_FILL_TOL    = 0.4   # A window only counts once it holds this much history

SHIFT_MIN = 0.02     # ~3 deg between consecutive frames counts as a gaze shift.
                     # _shift_rate() turns this into a crude fixations-per-second
                     # proxy, the top predictor in the panorama study. DIAGNOSTIC
                     # ONLY -- at 15-30 fps and 1-4 deg of gaze error this cannot
                     # be a real fixation statistic; see the module docstring.

WANDER_DISP = 0.09   # ~13 deg RMS spread: eyes touring the room.
WANDER_SEC  = 2.0
# Note on what WANDER is: an OFF-TASK GAZE marker, not a mind-wandering one.
# The screen-bounded studies (lecture, reading, slides) find dispersion going
# DOWN when the mind wanders, not up. High dispersion at a desk means the eyes
# are physically touring the room, which is worth reporting on its own terms --
# it is just not evidence about what the mind is doing.

BLANK_DISP = 0.015   # Near-motionless, the screen-bounded mind-wandering
                     # direction: fixations contract into a small patch.
                     # Sits closest to the landmark noise floor of any
                     # threshold here, which is the other reason BLANK now
                     # demands a second, independent witness (below).
BLANK_SEC  = 2.0     # On top of LONG_WINDOW_SEC, so ~8 s of stillness in total

# ---------------------------------------------------------------------------
# Blinks
# ---------------------------------------------------------------------------
# The one mind-wandering marker from the literature that this hardware can
# measure honestly. Smilek, Carriere & Cheyne 2010 found blink rate rising in
# the seconds before people reported a wandering mind and argued it is the body
# throttling visual input; Grandchamp et al. 2014 found both rate and duration
# up. It is not universal -- the 2020 lecture study could not use blink count at
# all -- so it is used as corroboration, never on its own.
#
# Absolute rates are useless as a threshold because the task sets the baseline:
# Bentivoglio et al. 1997 measured 17 blinks/min at rest, 26 while talking, and
# 4.5 while READING -- a four-fold spread across ordinary desk activities. So
# the baseline is learned per user, the same way the gaze baseline is, and only
# the RATIO to it is thresholded.
BLINK_EAR_CLOSE = 0.15   # Falling edge; matches EYE_OPEN_EAR
BLINK_EAR_OPEN  = 0.20   # Rising edge, hysteresis so one noisy frame is not a blink
BLINK_MIN_SEC   = 0.04   # Shorter than a real blink -> a dropped mesh, not an eyelid
BLINK_MAX_SEC   = 0.60   # Longer than this is a closure, and drowsy_detect's problem
BLINK_WINDOW_SEC  = 60.0 # Rate is per minute, so the window is a minute
BLINK_WARMUP_SEC  = 45.0 # Do not report a rate off a half-filled window
BLINK_MW_RATIO    = 1.6  # Rate this many times the user's own on-task baseline
                         # counts as elevated

# Time constant of the on-task baseline, in SECONDS rather than frames.
#
# The obvious version -- a fixed alpha applied once per frame -- is wrong here,
# and wrong in a way that silently disables the whole feature: at 20 fps even
# alpha=0.02 gives a 2.5 s time constant, so the baseline chases the live rate
# and nothing is ever elevated relative to it. Worse, it would move at a
# different speed on a loaded Pi than an idle one, and this loop's frame rate is
# documented as swinging with CPU load. Five minutes, measured in seconds.
BLINK_BASE_TAU_SEC = 300.0

# Guards against a degenerate baseline. A ratio test against a near-zero
# reference calls everything elevated -- with a baseline of 0, even 0 blinks/min
# satisfies 'rate >= baseline * 1.6'. A baseline this low is not a measurement
# of a calm blinker, it means blinks are not being detected at all.
BLINK_BASE_MIN = 2.0     # Below this the baseline is not a usable reference
BLINK_MIN_RATE = 6.0     # And the live rate must clear this in absolute terms;
                         # Bentivoglio's reading baseline is 4.5/min

# Require the blink evidence before calling a still gaze 'blank'.
#
# A motionless gaze is ALSO exactly what deep concentration looks like, and one
# threshold sitting on the noise floor cannot tell the two apart. Every
# classifier in this literature combines features rather than trusting one, and
# this is the two-feature version of that: stillness says the eyes stopped
# scanning, the blink rise says the visual channel is being shut down. Set to
# False to go back to stillness alone and expect false positives on anyone who
# concentrates without moving.
BLANK_REQUIRE_BLINK = True

# ---------------------------------------------------------------------------
# Calibration
# ---------------------------------------------------------------------------
CALIB_SEC         = 3.0
CALIB_MIN_SAMPLES = 20

# Slow pull of the baseline toward the current gaze, applied only while the user
# is comfortably inside the zone. People sink into their chair over an hour and
# the whole ellipse has to follow them. At ~20 fps this is a ~50 s time constant.
DRIFT_ALPHA = 0.001
DRIFT_ZONE  = 0.08

# A face gone this long usually comes back in a different posture, or belongs to
# a different person; either way the old baseline would read as a permanent
# offset, so it is discarded and recalibrated.
RECALIB_AFTER_LOST_SEC = 8.0

# ---------------------------------------------------------------------------
# Eye-open gate
# ---------------------------------------------------------------------------
# The iris landmarks are still emitted for a shut eye, fitted to whatever the
# lid crop happens to contain, so samples have to be gated on EAR. Lower than
# drowsy_detect's 0.20 threshold on purpose: a squint is still a usable gaze.
EYE_OPEN_EAR = 0.15

# A blink must not clear a verdict that took seconds to build, so the previous
# result is held across short closures and only dropped past this.
EYE_CLOSED_GRACE_SEC = 0.6

DISTRACTED_STATES = ("GAZE_AWAY", "GAZE_WANDER", "GAZE_BLANK")

STATE_LABELS_KO = {
    "FOCUSED":     "집중 중",
    "GAZE_AWAY":   "집중 안함 — 다른 곳을 보고 있음",
    "GAZE_WANDER": "집중 안함 — 시선이 계속 움직임 (두리번)",
    "GAZE_BLANK":  "집중 안함 — 멍때리는 중 (시선 정지 + 깜빡임 증가)",
    "CALIBRATING": "기준 시선 측정 중",
    "EYES_CLOSED": "눈 감음",
    "NO_IRIS":     "홍채 랜드마크 없음 (refine_landmarks=True 확인)",
    "NO_FACE":     "얼굴 미감지",
}


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------
def _pt(lms, idx, w, h):
    """Convert a normalized landmark to pixel coordinates."""
    lm = lms[idx]
    return np.array([lm.x * w, lm.y * h], dtype=np.float32)


def has_iris(lms) -> bool:
    """True when the landmark list carries the refine_landmarks iris points."""
    return lms is not None and len(lms) >= IRIS_MIN_LANDMARKS


def _face_axes(lms, w, h):

    """
    Build a face-local coordinate frame from the two outer eye corners.

    Returns (u, v, span, eye_mid):
        u        unit vector along the eye line, pointing toward the image right
        v        unit vector perpendicular to it, pointing toward the chin
        span     outer-corner to outer-corner distance, in pixels
        eye_mid  midpoint of the two outer corners

    Projecting onto u/v instead of reading raw x/y makes every measurement below
    immune to head roll: tilt your head 20 degrees and the numbers do not move.
    Returns None for a degenerate face (both corners on the same pixel).
    """

    p_l = _pt(lms, EYE_L_OUTER, w, h)
    p_r = _pt(lms, EYE_R_OUTER, w, h)
    axis = p_r - p_l
    span = float(np.linalg.norm(axis))
    if span < 1e-6:
        return None
    u = axis / span
    v = np.array([-u[1], u[0]], dtype=np.float32)   # +90 deg in image coords = down
    return u, v, span, (p_l + p_r) / 2.0


def _iris_center(lms, center_idx, ring_idx, w, h):

    """
    Iris centre in pixels.

    MediaPipe already regresses a centre point, but the centre and the four rim
    points are five independent outputs rather than one circle plus four derived
    corners, so averaging them costs nothing and shaves a little of the
    frame-to-frame jitter the eye crop introduces.
    """

    pts = [_pt(lms, center_idx, w, h)]
    pts += [_pt(lms, i, w, h) for i in ring_idx]
    return np.mean(pts, axis=0)


def _iris_radius(lms, center_pt, ring_idx, w, h) -> float:
    """Mean centre-to-rim distance in pixels. Drawing only."""
    return float(np.mean([np.linalg.norm(_pt(lms, i, w, h) - center_pt)
                          for i in ring_idx]))


def _eye_offset(lms, iris_pt, outer_idx, inner_idx, u, v, w, h):

    """
    Eye-in-head offset for one eye, in eye-widths.

    (0, 0) is the iris sitting exactly on the midpoint of the line joining the
    two corners. That midpoint is NOT anatomically where the pupil rests when
    looking straight ahead -- the two canthi are not symmetric about it -- which
    is precisely why the caller calibrates a baseline instead of trusting zero.

    Dividing BOTH axes by the eye WIDTH, rather than the vertical one by the lid
    opening, is deliberate. The lid aperture changes with every blink and every
    squint, so normalising y by it would turn 'narrowed the eyes' into 'looked
    down'. The corner-to-corner distance is bone geometry: it only foreshortens
    with head yaw, which the head term already accounts for.
    """

    p_out = _pt(lms, outer_idx, w, h)
    p_in  = _pt(lms, inner_idx, w, h)
    eye_w = float(np.linalg.norm(p_out - p_in))
    if eye_w < 1e-6:
        return None
    d = iris_pt - (p_out + p_in) / 2.0
    return float(np.dot(d, u)) / eye_w, float(np.dot(d, v)) / eye_w


def gaze_and_vergence(lms, w, h):

    """
    Uncalibrated gaze-in-space direction and eye vergence for one face.

    Returns (gx, gy, vergence) in eye-widths, or None when the iris landmarks
    are absent or the face is degenerate. Positive x points to the right of the
    (mirrored) image, positive y down.

    Vergence is the DIFFERENCE between the two eyes, which the gaze average
    throws away. Positive means the eyes are turned toward each other, i.e.
    converged on something near; negative means diverged toward far focus.
    Huang et al. 2019 detect internal thought from exactly this signal, on the
    grounds that when attention goes inward the eyes relax outward off the
    screen plane.

    It is measured and logged here but does NOT feed the verdict, on purpose.
    Zhang & Feng 2024 found vergence added nothing at a 1.8 m viewing distance,
    the effect should be larger at a 40-70 cm desk, and whether it clears this
    camera's noise floor is an empirical question about this hardware rather
    than something to assume. The number is in the heartbeat and in /gaze so it
    can be checked against a real face before anything is wired to it.
    """

    if not has_iris(lms):
        return None
    axes = _face_axes(lms, w, h)
    if axes is None:
        return None
    u, v, span, eye_mid = axes

    l_iris = _iris_center(lms, IRIS_L_CENTER, IRIS_L_RING, w, h)
    r_iris = _iris_center(lms, IRIS_R_CENTER, IRIS_R_RING, w, h)
    l_off = _eye_offset(lms, l_iris, EYE_L_OUTER, EYE_L_INNER, u, v, w, h)
    r_off = _eye_offset(lms, r_iris, EYE_R_OUTER, EYE_R_INNER, u, v, w, h)
    if l_off is None or r_off is None:
        return None

    # Both eyes point nearly the same way at desk distance, so averaging them is
    # mostly free noise reduction.
    ex = (l_off[0] + r_off[0]) / 2.0
    ey = (l_off[1] + r_off[1]) / 2.0

    # The residual the average discards. Each eye's nose-side is the other's
    # temple-side, so converging moves the left offset positive and the right
    # offset negative, and the difference picks that out.
    vergence = l_off[0] - r_off[0]

    # Head-in-space, from where the nose tip sits relative to the eye line.
    d_nose = _pt(lms, NOSE_TIP, w, h) - eye_mid
    yaw   = float(np.dot(d_nose, u)) / span
    pitch = float(np.dot(d_nose, v)) / span

    return ex + HEAD_GAIN_X * yaw, ey + HEAD_GAIN_Y * pitch, vergence


def raw_gaze(lms, w, h):
    """Gaze direction only, for callers that do not want the vergence residual."""
    g = gaze_and_vergence(lms, w, h)
    return None if g is None else (g[0], g[1])


def _direction(dx: float, dy: float) -> str:
    """Dominant axis of a deviation, scored against that axis' own radius."""
    ry = AWAY_RY_DOWN if dy > 0 else AWAY_RY_UP
    if abs(dx) / AWAY_RX >= abs(dy) / ry:
        return "RIGHT" if dx > 0 else "LEFT"
    return "DOWN" if dy > 0 else "UP"


# ---------------------------------------------------------------------------
# Blink tracking
# ---------------------------------------------------------------------------
class BlinkTracker:

    """
    Blink counter and per-minute rate, driven by the EAR drowsy_detect already
    computes for the primary face. No extra landmarks, no extra model pass.

    A blink is a closure that crosses BLINK_EAR_CLOSE going down and
    BLINK_EAR_OPEN coming back up, lasting between BLINK_MIN_SEC and
    BLINK_MAX_SEC. The two thresholds differ on purpose: with a single one, an
    EAR hovering at the boundary would score several blinks per real blink.

    Closures longer than BLINK_MAX_SEC are discarded rather than counted. That
    is a sustained closure and drowsy_detect's problem, and counting it would
    push the rate up hardest exactly when the user is falling asleep rather than
    wandering -- the one confusion this signal must not make.
    """

    def __init__(self):
        self._closed_since = None
        self._times   = deque()   # Monotonic timestamps of accepted blinks
        self._started = None      # First sample seen, for the warmup check
        self._last_learn = None   # Last baseline update, for the time-based EMA
        self.baseline = None      # Learned on-task rate, blinks/min

    def update(self, ear_val, now) -> None:
        """Feed one frame's EAR. None means the eyes were not measurable."""
        if self._started is None:
            self._started = now
        if ear_val is not None:
            if self._closed_since is None:
                if ear_val < BLINK_EAR_CLOSE:
                    self._closed_since = now
            elif ear_val > BLINK_EAR_OPEN:
                duration = now - self._closed_since
                self._closed_since = None
                if BLINK_MIN_SEC <= duration <= BLINK_MAX_SEC:
                    self._times.append(now)
        cutoff = now - BLINK_WINDOW_SEC
        while self._times and self._times[0] < cutoff:
            self._times.popleft()

    def rate(self, now):
        """Blinks per minute, or None until the window has warmed up."""
        if self._started is None or now - self._started < BLINK_WARMUP_SEC:
            return None
        span = min(now - self._started, BLINK_WINDOW_SEC)
        return len(self._times) * 60.0 / span if span > 0 else None

    def learn(self, rate, now) -> None:
        """
        Pull the on-task baseline toward `rate`. Call only while FOCUSED.

        Learned rather than fixed because the task sets the rate: Bentivoglio
        et al. measured 4.5 blinks/min reading against 17 at rest and 26 while
        talking, so a constant threshold would read every reader as permanently
        mind-wandering and every idler as permanently fine.

        The pull is exponential in elapsed TIME, not in frames -- see
        BLINK_BASE_TAU_SEC for why that distinction decides whether this feature
        works at all.
        """
        if rate is None:
            return
        if self.baseline is None or self._last_learn is None:
            self.baseline = rate
            self._last_learn = now
            return
        dt = now - self._last_learn
        self._last_learn = now
        if dt <= 0:
            return
        alpha = min(1.0, dt / BLINK_BASE_TAU_SEC)
        self.baseline += alpha * (rate - self.baseline)

    def elevated(self, rate) -> bool:
        """
        True when the rate has risen meaningfully above this user's own baseline.

        Both guards earn their place. Without the absolute floor, a baseline of
        zero makes every rate 'elevated' -- including zero itself, since
        0 >= 0 * 1.6 holds.
        """
        if rate is None or self.baseline is None:
            return False
        if self.baseline < BLINK_BASE_MIN or rate < BLINK_MIN_RATE:
            return False
        return rate >= self.baseline * BLINK_MW_RATIO

    def reset(self) -> None:
        self._closed_since = None
        self._times.clear()
        self._started = None
        self._last_learn = None
        self.baseline = None


# ---------------------------------------------------------------------------
# Result object
# ---------------------------------------------------------------------------
class GazeResult:

    """
    One frame's attention verdict.

    A small object rather than the tuple the other detectors return, because
    this one carries a dozen fields and half of them are diagnostics that only
    the web page and the heartbeat read. Positional unpacking would make every
    call site fragile the moment another diagnostic is added.
    """

    __slots__ = ("ok", "state", "distracted", "direction", "dx", "dy", "dev",
                 "disp_short", "disp_long", "held_sec", "calibrated", "progress",
                 "blink_rate", "blink_base", "blink_elevated",
                 "vergence", "shift_rate")

    def __init__(self, ok, state, distracted=False, direction="", dx=0.0, dy=0.0,
                 dev=0.0, disp_short=None, disp_long=None, held_sec=0.0,
                 calibrated=False, progress=0.0, blink_rate=None, blink_base=None,
                 blink_elevated=False, vergence=None, shift_rate=None):
        self.ok         = ok
        self.state      = state
        self.distracted = distracted
        self.direction  = direction
        self.dx         = dx
        self.dy         = dy
        self.dev        = dev
        self.disp_short = disp_short
        self.disp_long  = disp_long
        self.held_sec   = held_sec
        self.calibrated = calibrated
        self.progress   = progress
        # Blink rate is evidence for GAZE_BLANK; vergence and shift_rate are
        # measured and reported but never decide anything. See the module
        # docstring for why each is where it is.
        self.blink_rate     = blink_rate
        self.blink_base     = blink_base
        self.blink_elevated = blink_elevated
        self.vergence       = vergence
        self.shift_rate     = shift_rate

    @classmethod
    def neutral(cls, state):
        """A frame with nothing to say: no face, no iris, or eyes shut too long."""
        return cls(ok=False, state=state)

    @classmethod
    def calibrating(cls, progress):
        return cls(ok=False, state="CALIBRATING", progress=progress)

    def held(self):

        """
        Copy of this verdict marked stale.

        Returned while the eyes are shut for less than EYE_CLOSED_GRACE_SEC, so
        a 150 ms blink cannot wipe out a verdict that took seconds to build.
        """

        clone = GazeResult(self.ok, self.state, self.distracted, self.direction,
                           self.dx, self.dy, self.dev, self.disp_short,
                           self.disp_long, self.held_sec, self.calibrated,
                           self.progress, self.blink_rate, self.blink_base,
                           self.blink_elevated, self.vergence, self.shift_rate)
        clone.ok = False
        return clone

    def label(self) -> str:
        """Korean one-liner for the web page."""
        return STATE_LABELS_KO.get(self.state, self.state)

    def hud(self) -> str:
        """Short ASCII line for the video overlay (cv2 cannot render Hangul)."""
        if self.state == "GAZE_AWAY":
            return f"AWAY {self.direction} {self.held_sec:.1f}s"
        if self.state == "GAZE_WANDER":
            return f"WANDERING {self.held_sec:.1f}s"
        if self.state == "GAZE_BLANK":
            blink = ("" if self.blink_rate is None
                     else f" blink {self.blink_rate:.0f}/min")
            return f"BLANK STARE {self.held_sec:.1f}s{blink}"
        if self.state == "CALIBRATING":
            return f"CALIBRATING {self.progress:.0%}"
        if self.state == "FOCUSED":
            return "FOCUSED"
        return self.state.replace("_", " ")

    def to_dict(self) -> dict:
        """JSON-ready snapshot for the /gaze endpoint."""
        return {
            "state":      self.state,
            "label":      self.label(),
            "distracted": bool(self.distracted),
            "direction":  self.direction,
            "dx":         round(self.dx, 4),
            "dy":         round(self.dy, 4),
            "dev":        round(self.dev, 4),
            "disp_short": None if self.disp_short is None else round(self.disp_short, 4),
            "disp_long":  None if self.disp_long is None else round(self.disp_long, 4),
            "held_sec":   round(self.held_sec, 1),
            "calibrated": bool(self.calibrated),
            "progress":   round(self.progress, 2),
            "fresh":      bool(self.ok),
            "blink_rate": None if self.blink_rate is None else round(self.blink_rate, 1),
            "blink_base": None if self.blink_base is None else round(self.blink_base, 1),
            "blink_elevated": bool(self.blink_elevated),
            "vergence":   None if self.vergence is None else round(self.vergence, 4),
            "shift_rate": None if self.shift_rate is None else round(self.shift_rate, 2),
        }


# ---------------------------------------------------------------------------
# Detector
# ---------------------------------------------------------------------------
class GazeDetector:

    """
    Stateful attention detector driven by the iris landmarks.

    Call update() once per frame with the PRIMARY user's landmarks -- the same
    list drowsy_detect already picked -- and it returns a GazeResult.

    Nothing in here is expensive: a dozen landmarks of arithmetic and a deque of
    a few hundred floats. It adds no model pass, because refine_landmarks has
    been paying for the iris inference on every frame all along.
    """

    def __init__(self):
        self._samples       = deque()   # (t, gx, gy), raw, pruned to LONG_WINDOW_SEC
        self._calib         = []
        self._calib_start   = None
        self._base          = None      # (bx, by); None until calibrated
        self._away_since    = None
        self._wander_since  = None
        self._blank_since   = None
        self._invalid_since = None
        self._lost_since    = None
        self._blinks        = BlinkTracker()
        self._last          = GazeResult.neutral("NO_FACE")

    # -- Main entry point ---------------------------------------------------
    def update(self, lms, ear_val, w, h, now) -> GazeResult:

        """
        Process one frame.

        Args:
            lms:     Landmark list of the primary user (drowsy.update()'s 8th
                     return value), or None when no face was found.
            ear_val: That face's mean EAR, used to reject blinks. None is
                     treated as 'eyes not measurable'.
            w, h:    Frame size in pixels.
            now:     time.monotonic() for this frame -- the same clock the
                     Debouncers run on, so the two can never disagree about how
                     long something has held.

        Returns:
            GazeResult for this frame.
        """

        # -- No face ---------------------------------------------------------
        if lms is None:
            if self._lost_since is None:
                self._lost_since = now
            if (self._base is not None
                    and now - self._lost_since >= RECALIB_AFTER_LOST_SEC):
                print("[Gaze] Face gone too long — baseline dropped, will recalibrate")
                self.reset()
            self._clear_timers()
            self._last = GazeResult.neutral("NO_FACE")
            return self._last
        self._lost_since = None

        # -- refine_landmarks is off -----------------------------------------
        # Not worth crashing over, but the whole module is inert without it, so
        # the state says so explicitly rather than silently reading zeros.
        if not has_iris(lms):
            self._last = GazeResult.neutral("NO_IRIS")
            return self._last

        # -- Blinks ----------------------------------------------------------
        # Updated before the closed-eye gate below, and deliberately so: the
        # frames that gate is about to throw away are exactly the ones a blink
        # is made of.
        self._blinks.update(ear_val, now)
        blink_rate = self._blinks.rate(now)

        # -- Blink / closed-eye gate -----------------------------------------
        eyes_open = ear_val is not None and ear_val >= EYE_OPEN_EAR
        g = gaze_and_vergence(lms, w, h) if eyes_open else None

        if g is None:
            if self._invalid_since is None:
                self._invalid_since = now
            if now - self._invalid_since >= EYE_CLOSED_GRACE_SEC:
                # A long closure. Whatever the eyes do on reopening is a new
                # fixation, so the movement window would be measuring a jump
                # that never happened -- drop it along with the timers.
                self._clear_timers()
                self._last = GazeResult.neutral("EYES_CLOSED")
            else:
                self._last = self._last.held()
            return self._last
        self._invalid_since = None

        # -- Baseline calibration --------------------------------------------
        if self._base is None:
            if self._calib_start is None:
                self._calib_start = now
                print("[Gaze] Calibrating — keep looking at your usual working spot")
            self._calib.append((g[0], g[1]))
            elapsed = now - self._calib_start
            if elapsed < CALIB_SEC or len(self._calib) < CALIB_MIN_SAMPLES:
                self._last = GazeResult.calibrating(min(1.0, elapsed / CALIB_SEC))
                return self._last
            # Median, not mean: one glance away during those three seconds is a
            # large outlier, and a mean would carry that offset all session.
            arr = np.asarray(self._calib, dtype=np.float32)
            self._base = (float(np.median(arr[:, 0])), float(np.median(arr[:, 1])))
            self._calib.clear()
            print(f"[Gaze] Baseline set  x={self._base[0]:+.3f}  y={self._base[1]:+.3f}")

        dx  = g[0] - self._base[0]
        dy  = g[1] - self._base[1]
        dev = math.hypot(dx, dy)

        # -- Movement window --------------------------------------------------
        # Raw gaze is stored, not the deviation: spread is unaffected by the
        # offset, and storing raw keeps the slow baseline drift below from
        # smearing itself back across the history.
        self._samples.append((now, g[0], g[1]))
        cutoff = now - LONG_WINDOW_SEC
        while self._samples and self._samples[0][0] < cutoff:
            self._samples.popleft()

        disp_short = self._dispersion(now - SHORT_WINDOW_SEC)
        disp_long  = self._dispersion(now - LONG_WINDOW_SEC)
        shift_rate = self._shift_rate(now - SHORT_WINDOW_SEC)

        # -- The three conditions ---------------------------------------------
        ry = AWAY_RY_DOWN if dy > 0 else AWAY_RY_UP
        outside = (dx / AWAY_RX) ** 2 + (dy / ry) ** 2 > 1.0

        self._away_since = self._hold(self._away_since, outside, now)
        away = self._elapsed(self._away_since, now) >= AWAY_SEC

        wandering = disp_short is not None and disp_short >= WANDER_DISP
        self._wander_since = self._hold(self._wander_since, wandering, now)
        wander = self._elapsed(self._wander_since, now) >= WANDER_SEC

        # Blank needs two independent witnesses.
        #
        #   stillness   the eyes have stopped scanning -- the mind-wandering
        #               direction for screen-bounded tasks
        #   blink rise  the visual channel is being throttled (Smilek et al.)
        #
        # Stillness alone is not enough, because deep concentration produces the
        # same reading and the threshold for it sits on the noise floor. Two
        # weak, independent signals agreeing is worth far more than one of them
        # pushed harder, which is also how every classifier in this literature
        # is built.
        #
        # It also stays confined to the zone: a motionless gaze pointed off to
        # the side is already described, more usefully, as GAZE_AWAY.
        blink_elevated = self._blinks.elevated(blink_rate)
        still = (not outside and disp_long is not None and disp_long <= BLANK_DISP)
        if BLANK_REQUIRE_BLINK:
            still = still and blink_elevated
        self._blank_since = self._hold(self._blank_since, still, now)
        blank = self._elapsed(self._blank_since, now) >= BLANK_SEC

        # -- Baseline drift ----------------------------------------------------
        # Pulled only while the gaze is well inside the zone, so time spent
        # looking away can never drag the reference toward the distraction and
        # quietly normalise it.
        if dev < DRIFT_ZONE:
            self._base = (self._base[0] + DRIFT_ALPHA * dx,
                          self._base[1] + DRIFT_ALPHA * dy)

        # -- Verdict -----------------------------------------------------------
        # Ordered by how specific the claim is. AWAY is a measured direction,
        # WANDER is a measured spread, BLANK is an ABSENCE of movement and so the
        # weakest inference of the three -- it only wins when neither fired.
        if away:
            state, held = "GAZE_AWAY", self._elapsed(self._away_since, now)
        elif wander:
            state, held = "GAZE_WANDER", self._elapsed(self._wander_since, now)
        elif blank:
            state, held = "GAZE_BLANK", self._elapsed(self._blank_since, now)
        else:
            state, held = "FOCUSED", 0.0
            # The blink baseline is only ever learned from on-task frames, so a
            # wandering stretch can never raise the bar it is measured against.
            self._blinks.learn(blink_rate, now)

        self._last = GazeResult(
            ok=True, state=state, distracted=state in DISTRACTED_STATES,
            direction=_direction(dx, dy) if state == "GAZE_AWAY" else "",
            dx=dx, dy=dy, dev=dev,
            disp_short=disp_short, disp_long=disp_long,
            held_sec=held, calibrated=True, progress=1.0,
            blink_rate=blink_rate, blink_base=self._blinks.baseline,
            blink_elevated=blink_elevated, vergence=g[2], shift_rate=shift_rate,
        )
        return self._last

    # -- Internals ----------------------------------------------------------
    def _dispersion(self, since):

        """
        RMS distance of the samples since `since` from their own mean.

        Returns None while the window is not yet full, which is what keeps a
        freshly started (or freshly cleared) history from reading as a perfectly
        still gaze and firing GAZE_BLANK on its second frame.
        """

        if not self._samples or self._samples[0][0] > since + WINDOW_FILL_TOL:
            return None
        pts = [(x, y) for (t, x, y) in self._samples if t >= since]
        if len(pts) < MIN_WINDOW_SAMPLES:
            return None
        arr = np.asarray(pts, dtype=np.float32)
        centre = arr.mean(axis=0)
        return float(np.sqrt(np.mean(np.sum((arr - centre) ** 2, axis=1))))

    def _shift_rate(self, since):

        """
        Gaze shifts per second since `since`: a crude fixations-per-second proxy.

        Fixations/sec falling is the single strongest mind-wandering predictor
        in the gaze literature, so it is worth having the number in front of us.
        It is NOT worth pretending this is that number -- a real fixation lasts
        200-300 ms, this loop samples every 33-66 ms, and the gaze estimate
        carries 1-4 degrees of error, so consecutive-frame displacement is a
        blunt stand-in for saccade detection. Reported, never decided on.
        """

        pts = [(t, x, y) for (t, x, y) in self._samples if t >= since]
        if len(pts) < MIN_WINDOW_SAMPLES:
            return None
        span = pts[-1][0] - pts[0][0]
        if span <= 0:
            return None
        shifts = sum(1 for a, b in zip(pts, pts[1:])
                     if math.hypot(b[1] - a[1], b[2] - a[2]) >= SHIFT_MIN)
        return shifts / span

    @staticmethod
    def _hold(since, active, now):
        """Start the timer on the rising edge, clear it the moment it lapses."""
        if not active:
            return None
        return now if since is None else since

    @staticmethod
    def _elapsed(since, now) -> float:
        return 0.0 if since is None else now - since

    def _clear_timers(self) -> None:
        """Drop the condition timers and the movement history, keep the baseline."""
        self._away_since   = None
        self._wander_since = None
        self._blank_since  = None
        self._samples.clear()

    def reset(self) -> None:

        """
        Full reset, baselines included: the next frames recalibrate.

        The blink baseline goes too. It is a per-person number -- 4.5 blinks/min
        reading against 17 at rest is a four-fold spread between ordinary desk
        activities, and between two different people it is wider still -- so
        carrying one person's baseline over to whoever sits down next is worse
        than having none.
        """

        self._clear_timers()
        self._calib.clear()
        self._calib_start   = None
        self._base          = None
        self._invalid_since = None
        self._blinks.reset()
        self._last          = GazeResult.neutral("NO_FACE")


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------
IRIS_COLOR      = (255, 200, 0)     # Cyan-ish, distinct from the green USER box
GAZE_OK_COLOR   = (0, 220, 0)
GAZE_WARN_COLOR = (0, 165, 255)     # The same orange the phone box uses for 'bad'
GAZE_IDLE_COLOR = (150, 150, 150)
ARROW_PX = 90.0                     # Pixels drawn for one AWAY_RX of deviation


def draw_gaze(frame, lms, result, w, h) -> None:

    """
    Draw the iris circles, the gaze vector and a status line onto the frame.

    Args:
        frame:  BGR frame, modified in place
        lms:    Primary user's landmarks, or None
        result: GazeResult from GazeDetector.update()
        w, h:   Frame width and height

    The status line sits along the bottom edge, clear of the face boxes at the
    top and the phone boxes in the middle. Its text is ASCII because cv2's
    Hershey fonts have no Hangul glyphs -- the Korean wording lives on the web
    page instead.
    """

    color = (GAZE_WARN_COLOR if result.distracted
             else GAZE_OK_COLOR if result.state == "FOCUSED"
             else GAZE_IDLE_COLOR)

    if has_iris(lms):
        # Iris outlines, so it is visible at a glance that the extra landmarks
        # are actually being tracked and not merely requested.
        for c_idx, ring in ((IRIS_L_CENTER, IRIS_L_RING), (IRIS_R_CENTER, IRIS_R_RING)):
            centre = _iris_center(lms, c_idx, ring, w, h)
            radius = _iris_radius(lms, centre, ring, w, h)
            cv2.circle(frame, (int(centre[0]), int(centre[1])),
                       max(2, int(radius)), IRIS_COLOR, 1)
            cv2.circle(frame, (int(centre[0]), int(centre[1])), 1, IRIS_COLOR, -1)

        # Gaze vector, drawn from between the eyes. The deviation is expressed in
        # the face frame, so it has to be rotated back into image space first --
        # otherwise a tilted head would point the arrow the wrong way.
        axes = _face_axes(lms, w, h)
        if axes is not None and result.calibrated:
            u, v, _, eye_mid = axes
            vec = (result.dx * u + result.dy * v) * (ARROW_PX / AWAY_RX)
            tip = eye_mid + vec
            cv2.arrowedLine(frame,
                            (int(eye_mid[0]), int(eye_mid[1])),
                            (int(tip[0]), int(tip[1])),
                            color, 2, tipLength=0.25)

    text = f"GAZE: {result.hud()}"
    (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
    y = h - 10
    cv2.rectangle(frame, (8, y - th - 8), (8 + tw + 8, y + 4), color, -1)
    cv2.putText(frame, text, (12, y),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
