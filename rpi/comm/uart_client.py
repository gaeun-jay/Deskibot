"""
uart_client.py
--------------
UART interface for sending detection state from the RPi to the ESP32.

Wire protocol (line-based, newline-terminated ASCII):
    DROWSY:<0|1>,PHONE:<0|1>\n

Example:
    DROWSY:1,PHONE:0\n   -> drowsy detected, no phone

The ESP32 parses one line per state change. State is only transmitted when
it changes (the caller gates on that), so the link stays quiet while idle.
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
    def update_detection(self, drowsy: bool, phone: bool) -> None:
        """
        Send the current detection booleans to the ESP32.

        Format: 'DROWSY:<0|1>,PHONE:<0|1>\\n'
        """
        msg = f"DROWSY:{int(drowsy)},PHONE:{int(phone)}\n"
        self._ser.write(msg.encode("ascii"))

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    def close(self) -> None:
        """Close the serial port."""
        if self._ser and self._ser.is_open:
            self._ser.close()
        print("[UART] Closed")
