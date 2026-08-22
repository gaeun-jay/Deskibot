#pragma once
#include <WiFi.h>
#include <Preferences.h>

// ─── WiFi 자격증명 ───────────────────────────────────────────────────────────
// device token과 같은 방식으로 NVS에 저장한다. 시리얼 `wifi <ssid> <비밀번호>`
// 한 줄이면 바뀌고, 재부팅·전원차단·펌웨어 재업로드에도 유지된다.
//
// 예전에는 SSID와 비밀번호가 이 파일에 #define으로 박혀 있었다. 그러면
// 두 가지가 문제였다.
//   1. 이 파일은 추적 대상이라 실제 비밀번호가 커밋되면 그대로 공개된다.
//   2. WiFi를 바꾸려면 PlatformIO가 깔린 노트북으로 재빌드 + 재플래싱을
//      해야 한다. 시연장 WiFi는 개발 환경과 다를 게 확실한데, 그 자리에서
//      할 일이 아니다.
//
// 컴파일 기본값은 비워 둔다. 굳이 넣어야 하면 platformio.ini의 build_flags로
// 넘기고 (-DWIFI_SSID_DEFAULT='"..."'), 소스에는 두지 않는다.
#ifndef WIFI_SSID_DEFAULT
#define WIFI_SSID_DEFAULT ""
#endif
#ifndef WIFI_PASS_DEFAULT
#define WIFI_PASS_DEFAULT ""
#endif

static Preferences _wifi_prefs;
static char _wifi_ssid[33] = {};   // 802.11 SSID 최대 32바이트 + NUL
static char _wifi_pass[65] = {};   // WPA2 PSK 최대 63자 + NUL

static bool _wifi_was_connected = false;

// NVS에서 자격증명을 읽는다. 비어 있으면 컴파일 기본값으로 떨어진다.
static void wifi_creds_load() {
    _wifi_prefs.begin("deskibot", true);              // 읽기 전용
    String s = _wifi_prefs.getString("wifi_ssid", "");
    String p = _wifi_prefs.getString("wifi_pass", "");
    _wifi_prefs.end();

    if (s.isEmpty()) { s = WIFI_SSID_DEFAULT; p = WIFI_PASS_DEFAULT; }

    strlcpy(_wifi_ssid, s.c_str(), sizeof(_wifi_ssid));
    strlcpy(_wifi_pass, p.c_str(), sizeof(_wifi_pass));
}

static bool wifi_creds_saved() { return _wifi_ssid[0] != '\0'; }

// 시리얼 `wifi` 명령에서 호출. 저장 후 새 네트워크로 다시 붙는다.
// 비밀번호는 로그에 남기지 않는다 — 길이만 출력한다.
bool wifi_set_credentials(const char *ssid, const char *pass) {
    if (!ssid || ssid[0] == '\0') {
        Serial.println("[WiFi] SSID가 비었습니다");
        return false;
    }
    if (strlen(ssid) >= sizeof(_wifi_ssid)) {
        Serial.printf("[WiFi] SSID가 너무 깁니다 (최대 %u자)\n",
                      (unsigned)(sizeof(_wifi_ssid) - 1));
        return false;
    }
    if (pass && strlen(pass) >= sizeof(_wifi_pass)) {
        Serial.printf("[WiFi] 비밀번호가 너무 깁니다 (최대 %u자)\n",
                      (unsigned)(sizeof(_wifi_pass) - 1));
        return false;
    }
    // WPA2는 8자 이상을 요구한다. 개방망(빈 비밀번호)은 허용한다.
    if (pass && pass[0] != '\0' && strlen(pass) < 8) {
        Serial.println("[WiFi] WPA2 비밀번호는 8자 이상이어야 합니다");
        return false;
    }

    if (!_wifi_prefs.begin("deskibot", false)) {
        Serial.println("[WiFi] NVS 열기 실패");
        return false;
    }
    bool ok = _wifi_prefs.putString("wifi_ssid", ssid) > 0;
    _wifi_prefs.putString("wifi_pass", pass ? pass : "");
    _wifi_prefs.end();

    if (!ok) {
        Serial.println("[WiFi] NVS 저장 실패");
        return false;
    }

    strlcpy(_wifi_ssid, ssid, sizeof(_wifi_ssid));
    strlcpy(_wifi_pass, pass ? pass : "", sizeof(_wifi_pass));
    Serial.printf("[WiFi] 저장됨 SSID=\"%s\" (비밀번호 %u자) — 재연결\n",
                  _wifi_ssid, (unsigned)strlen(_wifi_pass));

    _wifi_was_connected = false;
    WiFi.disconnect(false);
    delay(100);
    WiFi.begin(_wifi_ssid, _wifi_pass);
    return true;
}

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
    wifi_creds_load();

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

    // 자격증명이 없으면 연결을 시도해봐야 실패만 한다. 원인을 알 수 없는
    // "연결 실패" 대신 무엇을 해야 하는지 알려준다. 위 스캔 목록에서
    // SSID를 골라 그대로 입력하면 된다.
    if (!wifi_creds_saved()) {
        Serial.println("[WiFi] ⚠ 저장된 WiFi가 없습니다.");
        Serial.println("[WiFi]   시리얼에 다음을 입력하세요:");
        Serial.println("[WiFi]     wifi <SSID> <비밀번호>");
        Serial.println("[WiFi]   개방망이면 비밀번호를 생략합니다: wifi <SSID>");
        return;
    }

    // ── 연결 시도 ──────────────────────────────────────────────────────────
    WiFi.begin(_wifi_ssid, _wifi_pass);
    Serial.printf("[WiFi] 연결 시도... SSID=\"%s\"\n", _wifi_ssid);

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
        Serial.println("[WiFi] 15초마다 재시도합니다. 다른 네트워크면 `wifi <SSID> <비밀번호>`");
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

    // 자격증명이 없으면 재시도해도 소용없다. 시리얼 입력을 기다린다.
    if (!wifi_creds_saved()) return;

    if (_wifi_was_connected) {
        _wifi_was_connected = false;
        Serial.println("[WiFi] 연결 끊김 — 재시도 시작");
        last_try_ms = 0;              // 즉시 한 번 시도
    }
    if (last_try_ms && millis() - last_try_ms < 15000) return;
    last_try_ms = millis();
    WiFi.disconnect(false);
    WiFi.begin(_wifi_ssid, _wifi_pass);
}
