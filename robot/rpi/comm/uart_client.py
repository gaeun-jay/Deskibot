"""
uart_client.py
--------------
UART interface for sending detection state from the RPi to the ESP32.

Wire protocol (line-based, newline-terminated ASCII):
    DROWSY:<0|1>,PHONE:<0|1>,NOPERSON:<0|1>\n

Example:
    DROWSY:1,PHONE:0,NOPERSON:0\n   -> drowsy detected, no phone, user present

The ESP32 parses one line per state change. State is only transmitted when
it changes (the caller gates on that), so the link stays quiet while idle.

NOPERSON was appended after the first two fields shipped, so the ESP parser
accepts a two-field line as well and reads the missing field as 0. Keep the
new field at the end for that reason.

Unlike drowsy and phone, NOPERSON is not recorded as a detection event on the
server — focus_session_events.kind has no such value. The ESP uses it to force
the pomodoro session to end, which lands in the DB as status='interrupted'.
"""

import serial

SERIAL_PORT = "/dev/ttyAMA0"
BAUD_RATE   = 115200
TIMEOUT_S   = 1


class UartClient:
    """Sends detection state to the ESP32 over UART."""

    def __init__(self, port: str = SERIAL_PORT, baud: int = BAUD_RATE):
        self._ser = serial.Serial(port, baud, timeout=TIMEOUT_S)
        print(f"[UART] Connected ({port} @ {baud})")

    # ------------------------------------------------------------------
    # Detection state
    # ------------------------------------------------------------------
    def update_detection(
        self,
        drowsy: bool,
        phone: bool,
        no_person: bool = False,
    ) -> None:
        """
        Send the current detection booleans to the ESP32.

        Format: 'DROWSY:<0|1>,PHONE:<0|1>,NOPERSON:<0|1>\\n'

        Args:
            drowsy:    Drowsiness confirmed and held long enough to report.
            phone:     Phone use confirmed and held long enough to report.
            no_person: Desk empty for at least NO_PERSON_HOLD_SEC. The ESP
                       force-ends a running pomodoro on the rising edge.
        """
        msg = (
            f"DROWSY:{int(drowsy)},"
            f"PHONE:{int(phone)},"
            f"NOPERSON:{int(no_person)}\n"
        )
        self._ser.write(msg.encode("ascii"))

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    def close(self) -> None:
        """Close the serial port."""
        if self._ser and self._ser.is_open:
            self._ser.close()
        print("[UART] Closed")
