#pragma once
#include <WiFi.h>

#define WIFI_SSID "Songja"
#define WIFI_PASS ""         

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
        Serial.printf("[WiFi] ✅ IP: %s\n", WiFi.localIP().toString().c_str());
        // NTP 동기화 — UTC 기준 (KST = +9h 이지만 ISO 타임스탬프는 UTC로 저장)
        configTime(9 * 3600, 0, "pool.ntp.org", "time.nist.gov");  // KST = UTC+9
        struct tm ti;
        if (getLocalTime(&ti, 6000))
            Serial.printf("[NTP] ✅ %04d-%02d-%02dT%02d:%02d:%02d KST\n",
                ti.tm_year+1900, ti.tm_mon+1, ti.tm_mday,
                ti.tm_hour, ti.tm_min, ti.tm_sec);
        else
            Serial.println("[NTP] 동기화 진행 중 (백그라운드)");
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
        WiFi.disconnect(false);
    }
}
