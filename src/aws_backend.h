#pragma once

#include <Arduino.h>
#include <WebSocketsClient.h>
#include <Firebase_ESP_Client.h>
#include <WiFi.h>
#include <Preferences.h>
#include "deskibot_tls.h"

#define DESKIBOT_API_HOST "api.deskibot.co.kr"
#define DESKIBOT_WS_PORT  443
#define DESKIBOT_WS_PATH  "/ws/focus"

// ─── device_token NVS 저장소 ─────────────────────────────────────────────────
// 테스트 시분할: 로봇 1대를 유저별로 3일씩 돌림. 유저 전환 = 시리얼 `token <값>` 한 줄.
// 재플래싱 없이 토큰만 바꾸고, 이 로직은 나중에 페어링에서 그대로 재사용한다.
static Preferences  _dev_prefs;
static char         _device_token[128] = {};   // 런타임 실사용 토큰
static portMUX_TYPE _device_token_mux = portMUX_INITIALIZER_UNLOCKED;

// NVS에서 토큰을 _device_token 으로 로드
static void aws_token_load() {
    _dev_prefs.begin("deskibot", true);              // 읽기 전용
    String t = _dev_prefs.getString("token", "");
    _dev_prefs.end();
    if (t.length() >= sizeof(_device_token)) {
        Serial.println("[Token] NVS 토큰 길이 오류 — 재등록 필요");
        t = "";
    }
    portENTER_CRITICAL(&_device_token_mux);
    strlcpy(_device_token, t.c_str(), sizeof(_device_token));
    portEXIT_CRITICAL(&_device_token_mux);
}

// 새 토큰을 NVS에 저장하고 _device_token 갱신 (시리얼 명령에서 호출)
static bool aws_token_save(const char *tok) {
    if (!_dev_prefs.begin("deskibot", false)) return false;
    size_t saved = _dev_prefs.putString("token", tok);
    _dev_prefs.end();
    if (saved == 0) return false;
    portENTER_CRITICAL(&_device_token_mux);
    strlcpy(_device_token, tok, sizeof(_device_token));
    portEXIT_CRITICAL(&_device_token_mux);
    return true;
}

// WSS와 HTTPS 음성 요청이 같은 NVS 토큰을 사용하도록 안전하게 복사한다.
bool aws_get_device_token(char *out, size_t out_len) {
    if (!out || out_len == 0) return false;
    portENTER_CRITICAL(&_device_token_mux);
    strlcpy(out, _device_token, out_len);
    portEXIT_CRITICAL(&_device_token_mux);
    return out[0] != '\0';
}

static WebSocketsClient _deskibot_ws;
static bool _deskibot_ws_connected = false;
static bool _deskibot_auth_sent = false;
static bool _focus_command_pending = false;
static int  _focus_command_revision = -1;

static char _focus_session_id[64] = {};
static int  _focus_revision = -1;

// focus_state 콜백에서는 데이터만 복사하고, LVGL 상태 반영은 메인 loop에서 한다.
static volatile bool _focus_state_pending = false;
static char _focus_in_mode[16] = {};
static char _focus_in_state[16] = {};
static char _focus_in_session_id[64] = {};
static char _focus_in_started_at[40] = {};
static char _focus_in_paused_at[40] = {};
static int  _focus_in_planned_sec = 0;
static int  _focus_in_total_pause_sec = 0;

static bool _drowsy_detection_state = false;
static bool _phone_detection_state = false;
static bool _drowsy_detection_dirty = false;
static bool _phone_detection_dirty = false;
static uint32_t _detection_retry_ms = 0;

bool aws_detection_send(const char *kind, bool active);
void switch_screen(AppScreen screen);

static bool _aws_json_string(FirebaseJson &json, const char *path,
                             char *out, size_t out_len) {
    FirebaseJsonData value;
    if (!json.get(value, path) || !value.success) return false;
    strlcpy(out, value.stringValue.c_str(), out_len);
    return true;
}

static bool _aws_json_int(FirebaseJson &json, const char *path, int &out) {
    FirebaseJsonData value;
    if (!json.get(value, path) || !value.success) return false;
    out = value.intValue;
    return true;
}

static bool _aws_json_string_any(FirebaseJson &json,
                                 const char *const *paths, size_t path_count,
                                 char *out, size_t out_len) {
    for (size_t i = 0; i < path_count; ++i) {
        if (_aws_json_string(json, paths[i], out, out_len)) return true;
    }
    return false;
}

static bool _aws_json_int_any(FirebaseJson &json,
                              const char *const *paths, size_t path_count,
                              int &out) {
    for (size_t i = 0; i < path_count; ++i) {
        if (_aws_json_int(json, paths[i], out)) return true;
    }
    return false;
}

static bool _aws_send_text(String &message) {
    if (!_deskibot_ws_connected || !_deskibot_auth_sent) {
        Serial.println("[AWS WS] 전송 보류 — 연결/인증 전");
        return false;
    }
    return _deskibot_ws.sendTXT(message);
}

static void _aws_send_auth() {
    char device_token[sizeof(_device_token)] = {};
    if (!aws_get_device_token(device_token, sizeof(device_token))) {
        Serial.println("[AWS WS] device_token 미설정 — 시리얼에 'token <값>' 입력 필요");
        return;
    }
    String auth = F("{\"type\":\"auth\",\"token\":\"");
    auth += device_token;
    auth += F("\",\"source\":\"robot\"}");
    _deskibot_auth_sent = _deskibot_ws.sendTXT(auth);
    Serial.println(_deskibot_auth_sent ? "[AWS WS] 인증 메시지 전송" :
                                         "[AWS WS] 인증 메시지 전송 실패");
}

static void _aws_receive_focus_state(const char *payload) {
    FirebaseJson json;
    json.setJsonData(payload);

    // ── 서버 계약: deskibot-sw app/focus_service.py::serialize_focus_session ──
    //   {"type":"focus_state","action":"focus_*","changed_by":...,"session":{...}|null}
    //     session.status        = in_progress | completed   ← 세션 생명주기
    //     session.runtime_state = running | paused | null   ← 일시정지 여부
    //     session.revision      = state_version
    // status는 일시정지 중에도 in_progress로 남는다. runtime_state를 함께 보지 않으면
    // pause 확인 응답을 '재개'로 오해해 pause를 무한 재전송하게 된다.
    char mode[16] = {}, status[20] = {}, runtime[16] = {}, session_id[64] = {};
    char started_at[40] = {}, paused_at[40] = {};
    int revision = -1, planned_sec = 0, total_pause_sec = 0;

    static const char *const mode_paths[]        = { "session/mode", "mode" };
    static const char *const status_paths[]      = { "session/status", "status" };
    static const char *const runtime_paths[]     = { "session/runtime_state", "runtime_state" };
    static const char *const session_id_paths[]  = { "session/session_id", "session_id" };
    static const char *const revision_paths[]    = { "session/revision", "revision" };
    static const char *const planned_paths[]     = { "session/planned_duration_sec",
                                                     "planned_duration_sec" };
    // 서버 필드명은 total_pause_duration_sec — total_pause_sec로 찾으면 항상 0이 된다.
    static const char *const pause_total_paths[] = { "session/total_pause_duration_sec",
                                                     "total_pause_duration_sec" };
    static const char *const started_paths[]     = { "session/started_at", "started_at" };
    static const char *const paused_paths[]      = { "session/paused_at", "paused_at" };

#define _AWS_N(a) (sizeof(a) / sizeof((a)[0]))
    const bool has_mode = _aws_json_string_any(
        json, mode_paths, _AWS_N(mode_paths), mode, sizeof(mode));
    const bool has_status = _aws_json_string_any(
        json, status_paths, _AWS_N(status_paths), status, sizeof(status));
    const bool has_session_id = _aws_json_string_any(
        json, session_id_paths, _AWS_N(session_id_paths), session_id, sizeof(session_id));
    const bool has_revision = _aws_json_int_any(
        json, revision_paths, _AWS_N(revision_paths), revision);
    _aws_json_string_any(json, runtime_paths, _AWS_N(runtime_paths), runtime, sizeof(runtime));
    _aws_json_int_any(json, planned_paths, _AWS_N(planned_paths), planned_sec);
    _aws_json_int_any(json, pause_total_paths, _AWS_N(pause_total_paths), total_pause_sec);
    _aws_json_string_any(json, started_paths, _AWS_N(started_paths),
                         started_at, sizeof(started_at));
    _aws_json_string_any(json, paused_paths, _AWS_N(paused_paths),
                         paused_at, sizeof(paused_at));
#undef _AWS_N

    // 활성 세션이 없으면 서버는 session:null을 보낸다 — 오류가 아니라 정상 스냅샷.
    if (!has_session_id) {
        FirebaseJsonData probe;
        if (json.get(probe, "session")) {
            Serial.println("[AWS WS] 활성 집중 세션 없음");
            _focus_session_id[0] = '\0';
            _focus_revision = -1;
            _focus_command_pending = false;
            return;
        }
    }

    if (!has_session_id || !has_mode || !has_status || !has_revision) {
        Serial.printf("[AWS WS] focus_state 필드 상태: session_id=%s mode=%s status=%s revision=%s\n",
                      has_session_id ? "ok" : "missing",
                      has_mode ? "ok" : "missing",
                      has_status ? "ok" : "missing",
                      has_revision ? "ok" : "missing");
        return;
    }

    // 생명주기(status)와 일시정지(runtime_state)를 화면용 단일 상태로 정규화한다.
    const char *norm;
    if (strcmp(status, "in_progress") != 0)   norm = "ended";     // completed 등
    else if (strcmp(runtime, "paused") == 0)  norm = "paused";
    else                                      norm = "running";

    strlcpy(_focus_session_id, session_id, sizeof(_focus_session_id));
    _focus_revision = revision;
    if (_focus_command_pending && revision > _focus_command_revision)
        _focus_command_pending = false;

    strlcpy(_focus_in_mode, mode, sizeof(_focus_in_mode));
    strlcpy(_focus_in_state, norm, sizeof(_focus_in_state));
    strlcpy(_focus_in_session_id, session_id, sizeof(_focus_in_session_id));
    strlcpy(_focus_in_started_at, started_at, sizeof(_focus_in_started_at));
    strlcpy(_focus_in_paused_at, paused_at, sizeof(_focus_in_paused_at));
    _focus_in_planned_sec = planned_sec;
    _focus_in_total_pause_sec = total_pause_sec;
    _focus_state_pending = true;
    Serial.printf("[AWS WS] focus_state mode=%s status=%s runtime=%s → %s revision=%d\n",
                  mode, status, runtime[0] ? runtime : "-", norm, revision);
}

static void _aws_ws_event(WStype_t type, uint8_t *payload, size_t length) {
    switch (type) {
        case WStype_CONNECTED:
            _deskibot_ws_connected = true;
            _deskibot_auth_sent = false;
            Serial.println("[AWS WS] 연결됨");
            _aws_send_auth();
            break;
        case WStype_DISCONNECTED:
            _deskibot_ws_connected = false;
            _deskibot_auth_sent = false;
            Serial.println("[AWS WS] 연결 끊김 — 자동 재연결 대기");
            break;
        case WStype_TEXT: {
            String message((const char *)payload, length);
            FirebaseJson json;
            FirebaseJsonData value;
            json.setJsonData(message);
            if (json.get(value, "type") && value.success) {
                const String message_type = value.stringValue;
                if (message_type == "focus_state") {
                    _aws_receive_focus_state(message.c_str());
                } else if (message_type == "auth_ok" || message_type == "authenticated") {
                    Serial.println("[AWS WS] 인증 완료");
                } else if (message_type == "error") {
                    _focus_command_pending = false;
                    Serial.println("[AWS WS] 서버 오류 수신");
                }
            }
            break;
        }
        case WStype_ERROR:
            Serial.println("[AWS WS] 전송 오류");
            break;
        default:
            break;
    }
}

void aws_backend_init() {
    aws_token_load();   // NVS에서 device_token 로드
    char device_token[sizeof(_device_token)] = {};
    if (aws_get_device_token(device_token, sizeof(device_token))) {
        Serial.printf("[AWS WS] device_token 로드됨 (len=%u)\n",
                      (unsigned)strlen(device_token));
    } else {
        Serial.println("[AWS WS] device_token 없음 — 시리얼에 'token <값>' 입력 필요");
    }

    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[AWS WS] WiFi 미연결 — 초기화 스킵");
        return;
    }
    _deskibot_ws.beginSslWithCA(DESKIBOT_API_HOST, DESKIBOT_WS_PORT,
                                DESKIBOT_WS_PATH, DESKIBOT_ROOT_CA);
    _deskibot_ws.onEvent(_aws_ws_event);
    _deskibot_ws.setReconnectInterval(5000);
    _deskibot_ws.enableHeartbeat(15000, 3000, 2);
    Serial.println("[AWS WS] wss://api.deskibot.co.kr/ws/focus 연결 시작");
}

// 시리얼 `token <값>` 명령 처리 — NVS 저장 후 새 유저로 WS 재연결.
// 테스트 유저 전환용. 서버가 새 토큰으로 재인증하도록 연결을 끊고 다시 붙인다.
bool aws_set_device_token(const char *tok) {
    if (!tok || tok[0] == '\0') {
        Serial.println("[Token] 빈 토큰 무시");
        return false;
    }
    size_t token_len = strlen(tok);
    if (token_len >= sizeof(_device_token)) {
        Serial.printf("[Token] 저장 실패 — 최대 길이는 %u자\n",
                      (unsigned)(sizeof(_device_token) - 1));
        return false;
    }
    for (size_t i = 0; i < token_len; ++i) {
        if ((uint8_t)tok[i] <= 0x20 || (uint8_t)tok[i] == 0x7f) {
            Serial.println("[Token] 저장 실패 — 공백/제어 문자는 사용할 수 없음");
            return false;
        }
    }
    if (!aws_token_save(tok)) {
        Serial.println("[Token] NVS 저장 실패");
        return false;
    }
    Serial.printf("[Token] 저장됨 (len=%u) — WS 재연결\n",
                  (unsigned)token_len);

    _deskibot_auth_sent   = false;
    _deskibot_ws_connected = false;
    _deskibot_ws.disconnect();
    if (WiFi.status() == WL_CONNECTED) {
        _deskibot_ws.beginSslWithCA(DESKIBOT_API_HOST, DESKIBOT_WS_PORT,
                                    DESKIBOT_WS_PATH, DESKIBOT_ROOT_CA);
    }
    return true;
}

// firebase_handler.h가 Firestore TLS를 열기 전에 확인한다 — 집중 상태 왕복 우선.
bool aws_focus_command_pending() { return _focus_command_pending; }

void aws_backend_loop() {
    _deskibot_ws.loop();
    if (_deskibot_ws_connected && _deskibot_auth_sent &&
        millis() - _detection_retry_ms >= 1000) {
        _detection_retry_ms = millis();
        if (_drowsy_detection_dirty)
            aws_detection_send("drowsy", _drowsy_detection_state);
        if (_phone_detection_dirty)
            aws_detection_send("phone", _phone_detection_state);
    }
}

bool aws_focus_send(const char *mode, const char *action, int planned_duration_sec) {
    if (_focus_command_pending) {
        Serial.println("[AWS WS] 이전 집중 명령의 focus_state 대기 중");
        return false;
    }

    String message;
    if (strcmp(action, "start") == 0) {
        message = F("{\"type\":\"focus_start\",\"mode\":\"");
        message += mode;
        message += '"';
        if (strcmp(mode, "pomodoro") == 0) {
            message += F(",\"planned_duration_sec\":");
            message += planned_duration_sec;
        }
        message += '}';
        _focus_command_revision = -1;
    } else {
        if (!_focus_session_id[0] || _focus_revision < 0) {
            Serial.println("[AWS WS] session_id/revision 수신 전 — 명령 취소");
            return false;
        }
        message = F("{\"type\":\"focus_");
        message += action;
        message += F("\",\"session_id\":\"");
        message += _focus_session_id;
        message += F("\",\"revision\":");
        message += _focus_revision;
        message += '}';
        _focus_command_revision = _focus_revision;
    }

    if (!_aws_send_text(message)) return false;
    _focus_command_pending = true;
    Serial.printf("[AWS WS] focus_%s 전송\n", action);
    return true;
}

// 서버 브로드캐스트를 기존 화면 상태 머신에 적용한다.
void aws_focus_sync_ui() {
    if (!_focus_state_pending) return;

    // _focus_in_state는 파서에서 running/paused/ended 셋 중 하나로 정규화돼 있다.
    const char *state = _focus_in_state;
    char action[16] = {};
    if (strcmp(state, "running") == 0) {
        if (strcmp(_focus_in_mode, "stopwatch") == 0 && _sw_state == SW_PAUSED)
            strlcpy(action, "resume", sizeof(action));
        else
            strlcpy(action, "start", sizeof(action));
    } else if (strcmp(state, "paused") == 0) {
        strlcpy(action, "pause", sizeof(action));
    } else {
        strlcpy(action, "end", sizeof(action));
    }

    AppScreen target = strcmp(_focus_in_mode, "pomodoro") == 0
                           ? SCREEN_POMODORO : SCREEN_STOPWATCH;
    if (strcmp(action, "end") != 0 && current_screen != target) {
        if (_voice_state != VOICE_IDLE) return;  // 음성 태스크 완료 뒤 적용
        switch_screen(target);
    }
    _focus_state_pending = false;

    if (strcmp(_focus_in_mode, "pomodoro") == 0 && current_screen == SCREEN_POMODORO) {
        int planned_min = (_focus_in_planned_sec + 59) / 60;
        pomo_backend_sync(action, planned_min, _focus_in_started_at,
                          _focus_in_session_id);
    } else if (strcmp(_focus_in_mode, "stopwatch") == 0 &&
               current_screen == SCREEN_STOPWATCH) {
        sw_backend_sync(action, _focus_in_started_at, _focus_in_paused_at,
                        _focus_in_total_pause_sec, _focus_in_session_id);
    }
}

bool aws_detection_send(const char *kind, bool active) {
    bool *dirty = nullptr;
    if (strcmp(kind, "drowsy") == 0) {
        _drowsy_detection_state = active;
        dirty = &_drowsy_detection_dirty;
    } else if (strcmp(kind, "phone") == 0) {
        _phone_detection_state = active;
        dirty = &_phone_detection_dirty;
    } else {
        Serial.printf("[AWS WS] 지원하지 않는 detection kind=%s\n", kind);
        return false;
    }
    *dirty = true;

    String message = F("{\"type\":\"detection_");
    message += active ? "start" : "end";
    message += F("\",\"kind\":\"");
    message += kind;
    message += F("\"}");
    bool sent = _aws_send_text(message);
    if (sent) {
        *dirty = false;
        Serial.printf("[AWS WS] detection_%s kind=%s\n",
                      active ? "start" : "end", kind);
    }
    return sent;
}
