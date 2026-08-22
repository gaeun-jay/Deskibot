#pragma once
#include <WiFi.h>

#define WIFI_SSID "Songja"
#define WIFI_PASS ""         

static bool _wifi_was_connected = false;

// 연결 직후 공통 처리 — NTP는 연결된 뒤에만 맞출 수 있다.
// 시각이 없으면 세션 복원의 경과 시간 계산도 통째로 포기하게 되므로 중요하다.
static void _wifi_on_connected() {
    Serial.printf("[WiFi] ✅ IP: %s\n", WiFi.localIP().toString().c_str());
    configTime(9 * 3600, 0, "pool.ntp.org", "time.nist.gov");  // KST = UTC+9
    struct tm ti;
    if (getLocalTime(&ti, 6000))
        Serial.printf("[NTP] ✅ %04d-%02d-%02dT%02d:%02d:%02d KST\n",
            ti.tm_year+1900, ti.tm_mon+1, ti.tm_mday,
            ti.tm_hour, ti.tm_min, ti.tm_sec);
    else
        Serial.println("[NTP] 동기화 진행 중 (백그라운드)");
}

void wifi_init() {
    WiFi.persistent(false);
    WiFi.disconnect(true);
    delay(100);
    WiFi.mode(WIFI_STA);
    delay(300);

    // ── 스캔: 주변 네트워크 목록 출력 ──────────────────────────────────────
    Serial.println("[WiFi] 스캔 중...");
    int n = WiFi.scanNetworks();
    if (n <= 0) {
        Serial.println("[WiFi] 주변 네트워크 없음 (안테나/채널 문제 의심)");
    } else {
        Serial.printf("[WiFi] %d개 발견:\n", n);
        for (int i = 0; i < n; i++) {
            Serial.printf("  [%d] SSID=\"%s\"  RSSI=%d  Ch=%d  %s\n",
                i,
                WiFi.SSID(i).c_str(),
                WiFi.RSSI(i),
                WiFi.channel(i),
                WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? "OPEN" : "PWD");
        }
    }
    WiFi.scanDelete();

    // ── 연결 시도 ──────────────────────────────────────────────────────────
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    Serial.println("[WiFi] 연결 시도...");

    uint32_t t = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t < 20000) {
        delay(500);
        Serial.print(".");
    }
    Serial.println();

    if (WiFi.status() == WL_CONNECTED) {
        _wifi_was_connected = true;
        _wifi_on_connected();
    } else {
        // 상태 코드로 원인 출력
        const char* reason = "?";
        switch (WiFi.status()) {
            case WL_NO_SSID_AVAIL:   reason = "SSID 없음 (네트워크 미발견)"; break;
            case WL_CONNECT_FAILED:  reason = "연결 실패 (비밀번호 오류?)";   break;
            case WL_CONNECTION_LOST: reason = "연결 끊김";                     break;
            case WL_DISCONNECTED:    reason = "Disconnected";                   break;
            default:                 reason = "알 수 없음";                     break;
        }
        Serial.printf("[WiFi] ❌ 실패 (status=%d: %s)\n", WiFi.status(), reason);
        Serial.println("[WiFi] 15초마다 재시도합니다");
        WiFi.disconnect(false);
    }
}

// 메인 루프에서 호출. wifi_init()은 20초만 기다리고 포기하는데, 로봇이 라우터보다
// 먼저 켜지거나 도중에 끊기는 일이 드물지 않다. 재연결이 없으면 WiFi.status()가
// 영영 WL_CONNECTED가 되지 않아 WS 자동 시작도 Todo 페치도 살아나지 못한다.
void wifi_loop() {
    static uint32_t last_try_ms = 0;

    if (WiFi.status() == WL_CONNECTED) {
        if (!_wifi_was_connected) {
            _wifi_was_connected = true;
            Serial.println("[WiFi] 재연결됨");
            _wifi_on_connected();     // 끊긴 동안 흐트러졌을 수 있어 NTP도 다시 맞춘다
        }
        return;
    }

    if (_wifi_was_connected) {
        _wifi_was_connected = false;
        Serial.println("[WiFi] 연결 끊김 — 재시도 시작");
        last_try_ms = 0;              // 즉시 한 번 시도
    }
    if (last_try_ms && millis() - last_try_ms < 15000) return;
    last_try_ms = millis();
    WiFi.disconnect(false);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
}
