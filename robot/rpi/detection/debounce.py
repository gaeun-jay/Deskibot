"""
debounce.py
-----------
Time-based debounce filter for noisy boolean detection signals.

Detectors can drop out for a frame or two (a hand passes over the phone, the
face mesh loses tracking briefly). Feeding those raw flags straight into the
state machine causes rapid true/false chatter, which in turn spams the
UART link with meaningless transitions.

Debouncer holds the confirmed value until the raw signal has been stable for a
configured duration, using separate rise and fall delays:

  rise_sec — raw must stay True  this long before the output turns True
  fall_sec — raw must stay False this long before the output turns False

All timing is based on time.monotonic(), so the filter is unaffected by wall
clock adjustments (NTP sync, manual date changes).
"""

import time


class Debouncer:

    """
    Asymmetric time-based debounce filter for a single boolean signal.

    Call update() once per frame with the raw detector flag; it returns the
    confirmed (filtered) value.

    Example:
        phone_filter = Debouncer(rise_sec=1.0, fall_sec=3.0, name="phone")
        phone_detected = phone_filter.update(raw_phone, mono)
    """

    def __init__(self, rise_sec: float, fall_sec: float, name: str = ""):

        """
        Args:
            rise_sec: Seconds the raw signal must stay True to confirm True.
                      Use 0.0 to turn on immediately.
            fall_sec: Seconds the raw signal must stay False to confirm False.
            name:     Optional label, used only for debugging/repr.
        """

        self.rise_sec = rise_sec
        self.fall_sec = fall_sec
        self.name     = name

        self._state     = False   # Confirmed (filtered) output
        self._raw       = False   # Most recent raw input
        self._raw_since = None    # When the raw input last changed value

    # -- Main entry point ---------------------------------------------------
    def update(self, raw: bool, now: float = None) -> bool:

        """
        Feed one raw sample and return the confirmed value.

        Args:
            raw: Raw detector flag for this frame.
            now: Monotonic timestamp. Defaults to time.monotonic() when omitted;
                 pass an explicit value to keep several filters on the same
                 per-frame clock.

        Returns:
            The confirmed (debounced) boolean state.
        """

        if now is None:
            now = time.monotonic()

        raw = bool(raw)

        # Restart the stability timer whenever the raw signal flips
        # (and on the very first call, to seed _raw_since).
        if self._raw_since is None or raw != self._raw:
            self._raw       = raw
            self._raw_since = now

        if raw != self._state:
            delay = self.rise_sec if raw else self.fall_sec
            if now - self._raw_since >= delay:
                self._state = raw

        return self._state

    # -- Read-only accessors ------------------------------------------------
    @property
    def state(self) -> bool:
        """Current confirmed value, without feeding a new sample."""
        return self._state

    @property
    def raw(self) -> bool:
        """Most recent raw sample."""
        return self._raw

    @property
    def raw_false_since(self):

        """
        Monotonic timestamp at which the raw signal most recently went False,
        or None while the raw signal is True.

        This is the true end of the detection event — the confirmed state only
        follows fall_sec seconds later. Read it when logging an event end so
        the recorded duration reflects the real signal rather than the filter
        delay:

            if not phone_detected and _phone_was_detected:
                ended_at = phone_filter.raw_false_since   # monotonic
                age      = time.monotonic() - ended_at    # seconds ago
        """

        return None if self._raw else self._raw_since

    def reset(self) -> None:
        """Clear all state back to False, as if freshly constructed."""
        self._state     = False
        self._raw       = False
        self._raw_since = None

    def __repr__(self):
        return (f"<Debouncer {self.name!r} state={self._state} raw={self._raw} "
                f"rise={self.rise_sec}s fall={self.fall_sec}s>")
