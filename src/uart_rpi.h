#pragma once
#include <Arduino.h>

// ─── RPi 감지 링크 (UART) ────────────────────────────────────────────────────
// RPi5가 잡은 졸음/폰 감지 상태를 UART로 직접 받는다.
// 프로토콜: "DROWSY:<0|1>,PHONE:<0|1>\n"   예) "DROWSY:1,PHONE:0"
//
// 배선 — RPi GPIO14(물리 8, TX) → IO18(RX) / RPi GPIO15(물리 10, RX) ← IO17(TX)
//        RPi GND(물리 6 또는 14) — ESP GND  ※ GND 없으면 신호가 깨진다
//
// GPIO 33~37은 옥타 PSRAM(qio_opi)이 쓰므로 절대 사용 금지.
// GPIO 43/44는 UART0라 부팅 시 ROM 부트로그가 나가므로 17/18을 쓴다.

#define RPI_UART_TX_PIN  17
#define RPI_UART_RX_PIN  18
#define RPI_UART_BAUD    115200

static HardwareSerial _rpi_serial(1);

// ─── 링크 디버깅 통계 ─────────────────────────────────────────────────────────
// RPi↔ESP UART가 실제로 살아있는지 ESP 스스로 판단하기 위한 카운터.
// rpi_uart_link_str() 이 이 값들을 사람이 읽을 문자열로 만들어 [Diag]에 실린다.
static uint32_t _rpi_lines_rx   = 0;   // 개행까지 온 줄 총 개수 (깨진 것 포함)
static uint32_t _rpi_det_rx     = 0;   // 정상 파싱된 DET 줄 개수
static uint32_t _rpi_last_rx_ms = 0;   // 마지막으로 뭔가 받은 시각 (0 = 아직 없음)

// 마지막 수신 후 이 시간 넘게 조용하면 "끊김"으로 본다.
#define RPI_LINK_TIMEOUT_MS 5000

void rpi_uart_init() {
    _rpi_serial.begin(RPI_UART_BAUD, SERIAL_8N1, RPI_UART_RX_PIN, RPI_UART_TX_PIN);
    Serial.printf("[RPi] UART 시작 — RX=%d TX=%d @%d\n",
                  RPI_UART_RX_PIN, RPI_UART_TX_PIN, RPI_UART_BAUD);
}

// 링크 상태를 한 줄 문자열로. loop()의 [Diag] 출력에 끼워 넣어 쓴다.
//   아직 아무것도 못 받음        → "수신없음"
//   최근 수신 있음               → "OK 1.2s전 줄42 DET40"
//   한 번은 받았는데 지금은 조용  → "끊김 8.3s전 줄42 DET40"
const char *rpi_uart_link_str() {
    static char s[64];
    if (_rpi_last_rx_ms == 0) {
        snprintf(s, sizeof(s), "수신없음");
        return s;
    }
    uint32_t ago = millis() - _rpi_last_rx_ms;
    snprintf(s, sizeof(s), "%s %lu.%lus전 줄%lu DET%lu",
             (ago > RPI_LINK_TIMEOUT_MS) ? "끊김" : "OK",
             (unsigned long)(ago / 1000), (unsigned long)((ago % 1000) / 100),
             (unsigned long)_rpi_lines_rx, (unsigned long)_rpi_det_rx);
    return s;
}

// 메인 루프에서 호출. 한 줄씩 파싱해 _drowsy_changed / _phone_changed 를 세운다.
// 팝업·경고음은 detection_check_alerts() 가 그 플래그를 보고 처리하므로 여기선 관여하지 않는다.
void rpi_uart_poll() {
    static char    buf[32];
    static uint8_t len      = 0;
    static bool    overflow = false;

    while (_rpi_serial.available()) {
        char c = _rpi_serial.read();

        if (c == '\r') continue;

        if (c != '\n') {
            if (len < sizeof(buf) - 1) buf[len++] = c;
            else                       overflow = true;  // 줄 끝까지 버리고 다음 줄부터 재개
            continue;
        }

        // 줄 끝 도달
        buf[len] = '\0';
        uint8_t line_len = len;
        len = 0;

        if (overflow) { overflow = false; continue; }
        if (line_len == 0) continue;

        // 여기까지 왔다는 건 개행으로 끝나는 한 줄을 받았다는 뜻 → 링크가 살아있다.
        _rpi_lines_rx++;
        _rpi_last_rx_ms = millis();

        // 배선/GND 왕복 테스트: RPi가 "PING" 보내면 ESP가 "PONG"으로 되받는다.
        // RPi 쪽에서 PONG만 읽히면 TX·RX·GND 3선이 모두 정상이라는 증거.
        if (strcmp(buf, "PING") == 0) {
            _rpi_serial.print("PONG\n");
            Serial.println("[RPi] PING 수신 → PONG 응답 (링크 왕복 OK)");
            continue;
        }

        int d = 0, p = 0;
        if (sscanf(buf, "DROWSY:%d,PHONE:%d", &d, &p) != 2) {
            Serial.printf("[RPi] 알 수 없는 입력: %s\n", buf);
            continue;
        }
        _rpi_det_rx++;

        bool drowsy = (d != 0);
        bool phone  = (p != 0);

        if (drowsy != _last_drowsy) {
            _last_drowsy = drowsy;
            _new_drowsy = drowsy;
            _drowsy_changed = true;
            aws_detection_send("drowsy", drowsy);
        }
        if (phone != _last_phone) {
            _last_phone = phone;
            _new_phone = phone;
            _phone_changed = true;
            aws_detection_send("phone", phone);
        }
    }
}
