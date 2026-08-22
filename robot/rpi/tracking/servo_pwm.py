"""
servo_pwm.py
------------
Hardware PWM backend for the pan/tilt servos.

Why not RPi.GPIO
================
This board is a Pi 5, where the real RPi.GPIO does not work at all; `import
RPi.GPIO` actually resolves to the rpi-lgpio compatibility shim. That shim is
pure Python and generates PWM from a background thread, so the pulse width
wanders whenever the CPU is busy.

For a servo that is fatal. The pulse range below spans 0.5-2.5ms across 180
degrees of travel, which works out at about 11us per degree -- so 100us of
scheduling delay is roughly 9 degrees of unwanted movement, and a full
millisecond is most of the travel. main.py runs FaceMesh, Pose and EfficientDet
in one loop and keeps the CPU saturated, which is exactly the condition that
produces those delays. The symptom is a servo that twitches, moves far less
than commanded, and drifts toward a limit no matter what angle is asked for.

The RP1 has PWM hardware wired to GPIO12/GPIO13, and /boot/firmware/config.txt
already routes them:

    dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4

This module drives that through /sys/class/pwm. The timer runs in silicon, so
CPU load has no effect on the output.

Note that using this module and using RPi.GPIO on the same pins are mutually
exclusive: whichever runs last steals the pin mux away from the other. Nothing
here may import RPi.GPIO.

Channel map
===========
The pwm-2chan overlay assigns `pin` to channel 0 and `pin2` to channel 1:

    channel 0 -> GPIO12
    channel 1 -> GPIO13

Which channel is the pan axis and which is the tilt axis is a wiring question,
not a software one -- see PAN_CHANNEL / TILT_CHANNEL in pantilt.py.
"""

import time
from pathlib import Path

PWMCHIP = Path("/sys/class/pwm/pwmchip0")   # RP1 PWM0 (1f00098000.pwm)

CHANNEL_GPIO = {0: 12, 1: 13}               # For log messages only

# 50Hz frame, the standard for hobby servos.
PERIOD_NS = 20_000_000

# Pulse width at 0 and 180 degrees. These reproduce the 2.5%-12.5% duty cycle
# range the old RPi.GPIO code used, so any angle that was calibrated by hand
# under the old backend still means the same thing here.
MIN_PULSE_NS = 500_000
MAX_PULSE_NS = 2_500_000

# udev fixes up the permissions on a freshly exported channel a moment after
# the directory appears, so the first writes can lose a race with it.
_RETRY_ATTEMPTS = 50
_RETRY_DELAY_S  = 0.02


def angle_to_pulse_ns(angle: float) -> int:
    """Convert a servo angle (0-180 degrees) to a pulse width in nanoseconds."""
    angle = max(0.0, min(180.0, angle))
    return int(MIN_PULSE_NS + (angle / 180.0) * (MAX_PULSE_NS - MIN_PULSE_NS))


def _write(path: Path, value) -> None:
    """Write to a sysfs attribute, retrying while udev settles permissions."""
    last_err = None
    for _ in range(_RETRY_ATTEMPTS):
        try:
            path.write_text(f"{value}\n")
            return
        except (PermissionError, FileNotFoundError, OSError) as exc:
            last_err = exc
            time.sleep(_RETRY_DELAY_S)
    raise RuntimeError(f"could not write {value!r} to {path}: {last_err}")


class ServoPWM:

    """
    One servo on one hardware PWM channel.

    Example:
        servo = ServoPWM(channel=0, initial_angle=90)
        servo.set_angle(120)
        servo.close()
    """

    def __init__(self, channel: int, initial_angle: float = 90.0):
        if channel not in CHANNEL_GPIO:
            raise ValueError(f"channel must be 0 or 1, got {channel}")
        if not PWMCHIP.exists():
            raise RuntimeError(
                f"{PWMCHIP} does not exist. Check that config.txt still has "
                f"'dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4' and reboot."
            )

        self.channel = channel
        self.gpio    = CHANNEL_GPIO[channel]
        self._dir    = PWMCHIP / f"pwm{channel}"
        self.angle   = float(initial_angle)

        # Already exported by an earlier run that did not clean up; reuse it.
        if not self._dir.exists():
            _write(PWMCHIP / "export", channel)
            for _ in range(_RETRY_ATTEMPTS):
                if self._dir.exists():
                    break
                time.sleep(_RETRY_DELAY_S)
            else:
                raise RuntimeError(f"channel {channel} did not appear at {self._dir}")

        # Period first: duty_cycle is rejected while it would exceed the period,
        # and a freshly exported channel starts with period=0.
        _write(self._dir / "enable", 0)
        _write(self._dir / "period", PERIOD_NS)
        _write(self._dir / "duty_cycle", angle_to_pulse_ns(self.angle))
        _write(self._dir / "enable", 1)

    def set_angle(self, angle: float) -> None:
        """Command the servo to an absolute angle in degrees."""
        self.angle = max(0.0, min(180.0, float(angle)))
        _write(self._dir / "duty_cycle", angle_to_pulse_ns(self.angle))

    @property
    def pulse_us(self) -> float:
        """Current pulse width in microseconds, for diagnostics."""
        return angle_to_pulse_ns(self.angle) / 1000.0

    def relax(self) -> None:
        """
        Stop driving the servo, leaving it with no holding torque.

        The output goes idle rather than to some other angle, so the horn is
        free to be turned by hand or by gravity.
        """
        _write(self._dir / "enable", 0)

    def hold(self) -> None:
        """Resume driving the last commanded angle after relax()."""
        _write(self._dir / "duty_cycle", angle_to_pulse_ns(self.angle))
        _write(self._dir / "enable", 1)

    def close(self) -> None:
        """Disable the channel and release it back to the kernel."""
        try:
            _write(self._dir / "enable", 0)
            _write(PWMCHIP / "unexport", self.channel)
        except RuntimeError:
            pass  # Nothing useful to do while shutting down
