import time

ALERT_COOLDOWN = 5.0


class Color:
    RED     = "\033[91m"
    YELLOW  = "\033[93m"
    GREEN   = "\033[92m"
    CYAN    = "\033[96m"
    MAGENTA = "\033[95m"
    WHITE   = "\033[97m"
    GRAY    = "\033[90m"
    RESET   = "\033[0m"
    BOLD    = "\033[1m"


def log(msg: str, color: str = Color.WHITE):
    ts = time.strftime("%H:%M:%S")
    print(f"\r{Color.GRAY}[{ts}]{Color.RESET} {color}{msg}{Color.RESET}")


class AlertManager:
    def __init__(self):
        self.last_alert_t        = 0.0
        self._last_terminal_alert = ""

    def trigger(self, reason: str, alert_type: str = "drowsy_eye"):
        now = time.time()
        if now - self.last_alert_t < ALERT_COOLDOWN:
            return
        self.last_alert_t = now
        self._terminal(reason, alert_type)

    def _terminal(self, reason: str, alert_type: str):
        key = f"{reason}_{int(time.time() // ALERT_COOLDOWN)}"
        if key == self._last_terminal_alert:
            return
        self._last_terminal_alert = key

        line = "=" * 55
        if alert_type == "drowsy_eye":
            print(f"\n{Color.RED}{Color.BOLD}{line}")
            print(f"  ⚠️  졸음 감지! - {reason}")
            print(f"{line}{Color.RESET}")
        elif alert_type == "face_lost":
            print(f"\n{Color.YELLOW}{Color.BOLD}{line}")
            print(f"  ⚠️  졸음 감지! - {reason}")
            print(f"{line}{Color.RESET}")
        elif alert_type == "phone":
            print(f"\n{Color.MAGENTA}{Color.BOLD}{line}")
            print(f"  📱 핸드폰 감지!")
            print(f"{line}{Color.RESET}")
