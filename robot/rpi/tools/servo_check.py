"""
servo_check.py
--------------
Pan/tilt calibration helper, driving the servos through the RP1 hardware PWM.

Run it with the detection loop STOPPED -- both programs drive the same two
channels and will fight over them.

    cd ~/Deskibot/rpi && python3 tools/servo_check.py

Servos are addressed by GPIO number here, deliberately. Which one is 'pan' and
which is 'tilt' is a wiring question that this tool exists to answer, so naming
them after the axes up front would beg the question.

    a  ->  GPIO12  (hardware PWM channel 0)
    b  ->  GPIO13  (hardware PWM channel 1)

What to work out
================
  1. Which of a / b is the bottom servo (rotates left-right) and which is the
     top one (pitches the camera up and down)?
  2. On the top servo, does a LARGER number aim the camera up or down?
  3. What number on the top servo is physically level?
  4. What number on the bottom servo is physically straight ahead?

Those four answers set PAN_CHANNEL / TILT_CHANNEL and the limits in pantilt.py.

Commands
========
    a 120       move GPIO12 to 120 degrees      b 120    same for GPIO13
    a +5        nudge GPIO12 up by 5            a -5     nudge down by 5
    sweep a     walk GPIO12 across its range, pausing at each step
    off         stop driving both (servos go limp -- do they sag?)
    hold        resume driving both
    s           show current angles and pulse widths
    q           quit
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Note: nothing here imports RPi.GPIO. Touching it would steal the pin mux
# away from the hardware PWM driver and put us back on jittery software PWM.
from tracking.servo_pwm import ServoPWM, CHANNEL_GPIO

START_ANGLE = 90.0

# Kept inside the travel of a typical hobby servo. Beyond this a horn that is
# already near a mechanical stop can stall and cook itself -- if the servo
# starts buzzing or straining, back the angle off immediately.
#
# Kept inside the travel of a typical hobby servo. Beyond this a horn that is
# already near a mechanical stop can stall and cook itself -- if the servo
# starts buzzing or straining, back the angle off immediately.
#
# This was briefly opened to the full 0-180 to find where each axis actually
# sat, back when both horns were splined on with an offset large enough to put
# their neutrals outside any sane limit. The horns have since been re-seated so
# that 90 is level and straight ahead on both axes, which puts the whole useful
# range comfortably back inside these bounds.
SAFE_MIN, SAFE_MAX = 20.0, 160.0

SWEEP_STEP_DEG = 10
SWEEP_PAUSE_S  = 0.8


def main() -> int:
    servos = {
        "a": ServoPWM(channel=0, initial_angle=START_ANGLE),
        "b": ServoPWM(channel=1, initial_angle=START_ANGLE),
    }
    time.sleep(0.5)

    def show() -> None:
        for key, s in servos.items():
            print(f"  {key} = GPIO{s.gpio:<3} angle={s.angle:6.1f}  pulse={s.pulse_us:7.1f}us")

    def move(key: str, angle: float) -> None:
        clamped = max(SAFE_MIN, min(SAFE_MAX, angle))
        if clamped != angle:
            print(f"  (clamped {angle:.1f} to the safe range {SAFE_MIN:.0f}..{SAFE_MAX:.0f})")
        servos[key].set_angle(clamped)
        s = servos[key]
        print(f"  {key} = GPIO{s.gpio}  angle={s.angle:.1f}  pulse={s.pulse_us:.1f}us")

    print(__doc__)
    print("Both servos are now at 90 degrees.")
    show()
    print()

    try:
        while True:
            try:
                raw = input("servo> ").strip().split()
            except EOFError:
                break

            # The prompt is easy to copy along with the command when following
            # written instructions; drop it rather than rejecting the line.
            while raw and raw[0].lower().rstrip(">") == "servo":
                raw.pop(0)
            if not raw:
                continue

            cmd = raw[0].lower()

            if cmd == "q":
                break

            elif cmd == "s":
                show()

            elif cmd == "off":
                for s in servos.values():
                    s.relax()
                print("  Both channels disabled. Does either one sag or drift on its own?")

            elif cmd == "hold":
                for s in servos.values():
                    s.hold()
                print("  Both channels driving again.")
                show()

            elif cmd == "sweep":
                if len(raw) < 2 or raw[1].lower() not in servos:
                    print("  Need which servo, e.g. 'sweep a'")
                    continue
                key = raw[1].lower()
                print(f"  Sweeping {key} (GPIO{servos[key].gpio}). Watch which end is which.")
                for angle in range(int(SAFE_MIN), int(SAFE_MAX) + 1, SWEEP_STEP_DEG):
                    move(key, angle)
                    time.sleep(SWEEP_PAUSE_S)
                move(key, START_ANGLE)

            elif cmd in servos:
                if len(raw) < 2:
                    print(f"  Need an angle, e.g. '{cmd} 120' or '{cmd} +5'")
                    continue
                arg = raw[1]
                try:
                    value = float(arg)
                except ValueError:
                    print(f"  Not a number: {arg}")
                    continue
                # A leading + or - means 'relative to where we are now'.
                target = servos[cmd].angle + value if arg[0] in "+-" else value
                move(cmd, target)

            else:
                print(f"  Unknown command: {cmd}   (try: a, b, sweep, off, hold, s, q)")

    except KeyboardInterrupt:
        print()
    finally:
        for s in servos.values():
            s.close()
        print("PWM channels released.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
