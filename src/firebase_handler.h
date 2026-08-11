#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <time.h>
#include "esp_heap_caps.h"
#include "deskibot_tls.h"

// 오늘 할 일과 마감 알림은 AWS에서 읽는다. 인증된 device token의 user_id로만
// 조회되므로 시리얼 `token` 명령으로 사용자를 바꾸면 할 일도 함께 바뀐다.
// (기존 Firestore 경로는 FS_USER_ID가 컴파일 상수라 토큰을 바꿔도 남의 할 일을
//  계속 보여줄 수 있었고, 규칙 문제로 HTTP 403까지 나고 있었다.)
#define DESKIBOT_TODOS_URL  "https://api.deskibot.co.kr/hw/todos"

// aws_backend.h가 관리하는 NVS device token (정의는 나중에 include됨).
bool aws_get_device_token(char *out, size_t out_len);

// ─── 전역 SSL 직렬화 (동시 SSL 연결 방지) ────────────────────────────────────
static SemaphoreHandle_t _ssl_mutex;

// ─── ISO 타임스탬프 헬퍼 ──────────────────────────────────────────────────────
void get_iso_now(char *buf, size_t len) {
    time_t t; time(&t);
    if (t < 1000000UL) { buf[0] = '\0'; return; }
    strftime(buf, len, "%Y-%m-%dT%H:%M:%S", localtime(&t));  // KST (configTime UTC+9)
}

// ─── 알림 todo 추적 ───────────────────────────────────────────────────────────
struct NotifyTodo {
    char content[128];
    char date[11];
    char deadline_time[6];
    int  notify_before;
    bool shown;
};
static NotifyTodo _notify_todos[20] = {};
static int        _notify_todo_count = 0;

// popup.h의 show_deadline 전방 선언 (include 순서 의존 없이)
void show_deadline(const char *time_str, const char *title_str, const char *left_str);

// ─── UART 감지 상태 ──────────────────────────────────────────────────────────
static bool _last_drowsy = false;
static bool _last_phone  = false;
// ─── voice.h extern 전역 ─────────────────────────────────────────────────────
char fs_task_assignment[128] = {};  // 오늘 미완료 todos 요약 (음성 컨텍스트)
char fs_task_etc[128]        = {};
char fs_task_health[128]     = {};
volatile bool _fs_tasks_ready = false;

// ─── Firestore todos + 카테고리 페치 ─────────────────────────────────────────
// 집중 세션 WSS가 TLS 세션을 상시 물고 있으므로, Firestore가 두 번째 TLS를 열 때
// 내부 RAM이 모자라면 esp-aes 할당이 실패하고 핸드셰이크째로 죽는다.
// AES/SHA 하드웨어 버퍼는 PSRAM을 쓸 수 없어 반드시 내부 힙 기준으로 판단한다.
// (Todo REST가 AWS로 넘어가면 이 페치 자체가 사라진다)
#define FS_MIN_FREE_INTERNAL   50000    // 총 여유 내부 힙 하한
#define FS_MIN_BLOCK_INTERNAL  24000    // 연속 블록 하한 — 단편화 시 총량만으론 부족
#define FS_FETCH_INTERVAL_MS   60000
#define FS_BACKOFF_MAX_MS      900000   // 실패가 이어지면 최대 15분까지 간격을 벌린다

static uint32_t _tasks_last_fetch = 0;
static bool     _fs_fetching      = false;
static uint32_t _fs_retry_ms      = FS_FETCH_INTERVAL_MS;
static bool     _fs_disabled_boot = false;  // 401/403은 재시도로 안 풀림 → 부팅 동안 포기

static void _fs_fetch_task(void *) {
    xSemaphoreTake(_ssl_mutex, portMAX_DELAY);

    char device_token[128] = {};
    if (!aws_get_device_token(device_token, sizeof(device_token))) {
        Serial.println("[Fetch] device_token 미설정 — 건너뜀");
        xSemaphoreGive(_ssl_mutex);
        _tasks_last_fetch = millis();
        _fs_fetching = false;
        vTaskDelete(NULL);
        return;
    }

    WiFiClientSecure sc;
    sc.setCACert(DESKIBOT_ROOT_CA);      // setInsecure() 쓰지 않음
    HTTPClient http;
    http.begin(sc, DESKIBOT_TODOS_URL);
    http.addHeader("X-Device-Key", device_token);
    http.setTimeout(8000);
    int code = http.GET();
    if (code == 200) {
        // {"date":"2026-08-11","todos":[{"content":..,"deadline_time":"18:00",
        //                               "notify_before_min":30}, ...]}
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, http.getStream());
        if (err) {
            Serial.printf("[Fetch] JSON 파싱 실패: %s\n", err.c_str());
        } else {
            const char *today = doc["date"] | "";

            fs_task_assignment[0] = '\0';

            // 기존 notify shown 상태 보존 (fetch 주기마다 shown이 초기화되면
            // 같은 알림이 반복해서 뜬다)
            NotifyTodo old_notify[20];
            int old_notify_count = _notify_todo_count;
            memcpy(old_notify, _notify_todos, sizeof(old_notify));
            _notify_todo_count = 0;

            // 서버가 오늘·미완료만 내려주므로 ESP에서 다시 거를 필요가 없다.
            for (JsonObjectConst todo : doc["todos"].as<JsonArrayConst>()) {
                const char *content_val = todo["content"] | (const char *)nullptr;
                if (!content_val || !content_val[0]) continue;

                if (fs_task_assignment[0])
                    strlcat(fs_task_assignment, " / ", sizeof(fs_task_assignment));
                strlcat(fs_task_assignment, content_val, sizeof(fs_task_assignment));

                // 알림 필드는 서버가 notify가 켜진 항목에만 넣어준다.
                const char *dt = todo["deadline_time"] | (const char *)nullptr;
                if (!dt || strlen(dt) < 4 || _notify_todo_count >= 20) continue;
                if (!todo["notify_before_min"].is<int>()) continue;

                bool was_shown = false;
                for (int j = 0; j < old_notify_count; j++) {
                    if (strcmp(old_notify[j].content, content_val) == 0 &&
                        strcmp(old_notify[j].date, today) == 0) {
                        was_shown = old_notify[j].shown;
                        break;
                    }
                }
                strlcpy(_notify_todos[_notify_todo_count].content, content_val, 128);
                strlcpy(_notify_todos[_notify_todo_count].date, today, 11);
                strlcpy(_notify_todos[_notify_todo_count].deadline_time, dt, 6);
                _notify_todos[_notify_todo_count].notify_before =
                    todo["notify_before_min"].as<int>();
                _notify_todos[_notify_todo_count].shown = was_shown;
                _notify_todo_count++;
            }
            _fs_tasks_ready = true;
            _fs_retry_ms = FS_FETCH_INTERVAL_MS;   // 성공 → 백오프 원복
            Serial.printf("[Fetch] todos(%d건, 알림 %d건): %s\n",
                          (int)doc["todos"].size(), _notify_todo_count,
                          fs_task_assignment);
        }
    } else if (code == 401 || code == 403) {
        // 토큰이 틀렸다면 재시도해도 안 풀리고 그때마다 TLS 힙만 갉아먹는다.
        // 토큰을 다시 넣으면 aws_set_device_token()이 이 플래그를 푼다.
        _fs_disabled_boot = true;
        Serial.printf("[Fetch] HTTP %d — 인증 거부, 토큰 재설정 전까지 중단\n", code);
    } else {
        _fs_retry_ms = (_fs_retry_ms >= FS_BACKOFF_MAX_MS / 2)
                           ? FS_BACKOFF_MAX_MS : _fs_retry_ms * 2;
        Serial.printf("[Fetch] HTTP %d — %us 후 재시도\n", code, _fs_retry_ms / 1000);
    }
    http.end();
    xSemaphoreGive(_ssl_mutex);
    _tasks_last_fetch = millis();
    _fs_fetching = false;
    vTaskDelete(NULL);
}

// 시리얼 `token` 으로 사용자가 바뀌면 이전 사용자 기준으로 캐싱해 둔 할 일과
// 마감 알림을 반드시 버려야 한다. 안 그러면 남의 마감 팝업이 그대로 뜬다.
// 인증 거부로 막아둔 상태도 새 토큰에서는 다시 시도해야 하므로 함께 푼다.
void todos_reset_for_new_user() {
    _fs_disabled_boot     = false;
    _fs_retry_ms          = FS_FETCH_INTERVAL_MS;
    _tasks_last_fetch     = 0;
    _notify_todo_count    = 0;
    _fs_tasks_ready       = false;
    fs_task_assignment[0] = '\0';
}

// aws_backend.h에서 정의 — 집중 명령 왕복 중에는 두 번째 TLS를 열지 않는다.
bool aws_focus_command_pending();

void firebase_fetch_tasks() {
    if (_fs_disabled_boot) return;
    if (WiFi.status() != WL_CONNECTED) return;
    if (_fs_fetching) return;
    if (!_ssl_mutex) return;                       // firebase_init() 전 호출 방어
    // 녹음/서버 처리/TTS 재생 중에는 음성 HTTPS가 내부 힙을 이미 점유하고 있다.
    if (_voice_state != VOICE_IDLE) return;
    if (aws_focus_command_pending()) return;       // 집중 상태 왕복이 우선
    if (_tasks_last_fetch && millis() - _tasks_last_fetch < _fs_retry_ms) return;

    const size_t free_internal =
        heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    const size_t block_internal =
        heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (free_internal < FS_MIN_FREE_INTERNAL || block_internal < FS_MIN_BLOCK_INTERNAL) {
        _tasks_last_fetch = millis();              // 다음 주기까지 대기
        Serial.printf("[Fetch] 내부 힙 부족 — 건너뜀 (free=%u block=%u)\n",
                      (unsigned)free_internal, (unsigned)block_internal);
        return;
    }

    _fs_fetching = true;
    if (xTaskCreatePinnedToCore(_fs_fetch_task, "fs_fetch", 10240, NULL, 1, NULL, 1) != pdPASS) {
        // 실패를 삼키면 _fs_fetching이 영구히 true로 남아 페치가 완전히 멎는다.
        _fs_fetching = false;
        _tasks_last_fetch = millis();
        Serial.println("[Fetch] fetch 태스크 생성 실패 — 다음 주기 재시도");
    }
}

// ─── 폴링 결과 → 메인 루프 전달용 volatile 변수 ───────────────────────────────
static volatile bool _drowsy_changed = false;
static volatile bool _phone_changed  = false;
static volatile bool _new_drowsy     = false;
static volatile bool _new_phone      = false;

extern AppScreen current_screen;

// ─── todo 마감 알림 확인 (메인 루프에서 30초 간격 호출) ─────────────────────
void firebase_check_deadlines() {
    static uint32_t _last_check_ms = 0;
    if (millis() - _last_check_ms < 30000) return;
    _last_check_ms = millis();
    if (_notify_todo_count == 0) return;

    time_t now; time(&now);
    if (now < 1000000UL) return;  // NTP 미동기화
    struct tm *t = localtime(&now);
    char today[11];
    strftime(today, sizeof(today), "%Y-%m-%d", t);
    int now_min = t->tm_hour * 60 + t->tm_min;

    for (int i = 0; i < _notify_todo_count; i++) {
        if (_notify_todos[i].shown) continue;
        if (strcmp(_notify_todos[i].date, today) != 0) continue;

        int dl_h = 0, dl_m = 0;
        sscanf(_notify_todos[i].deadline_time, "%d:%d", &dl_h, &dl_m);
        int dl_min     = dl_h * 60 + dl_m;
        int notify_min = dl_min - _notify_todos[i].notify_before;

        // 알림 시각 ±2분 이내 (전원 ON 직후·30초 폴링 오차 흡수)
        if (now_min < notify_min || now_min > notify_min + 2) continue;

        int remaining = dl_min - now_min;
        char left_str[20];
        if      (remaining <= 0)   strlcpy(left_str, "지금!",         sizeof(left_str));
        else if (remaining < 60)   snprintf(left_str, sizeof(left_str), "%d분",    remaining);
        else                       snprintf(left_str, sizeof(left_str), "%d시간 %d분", remaining / 60, remaining % 60);

        char time_str[12];
        snprintf(time_str, sizeof(time_str), "%02d:%02d", dl_h, dl_m);

        show_deadline(time_str, _notify_todos[i].content, left_str);
        _notify_todos[i].shown = true;
        Serial.printf("[Deadline] 알림: '%s' → %s (남은 %s)\n",
                      _notify_todos[i].content, time_str, left_str);
        break;  // 한 번에 하나씩
    }
}

// ─── Firestore ToDo REST 초기화 ──────────────────────────────────────────────
void firebase_init() {
    // WiFi가 나중에 붙어도 페치가 동작해야 하므로 뮤텍스는 무조건 먼저 만든다.
    // (이전에는 부팅 시 WiFi가 없으면 NULL인 채로 남아 fetch 태스크가 죽었다)
    if (!_ssl_mutex) _ssl_mutex = xSemaphoreCreateMutex();
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[Firebase] WiFi 미연결 — 연결 후 페치 재시도"); return;
    }
    Serial.println("[Firestore] ToDo REST 초기화 완료");
}

// ─── 졸음/폰 알람 처리 (메인 루프에서 호출) ──────────────────────────────────
#define ALERT_REPEAT_MS 2000

static bool     _alert_sound_active  = false;
static int      _alert_sound_type    = ALERT_NONE;
static uint32_t _alert_sound_last_ms = 0;

void firebase_check_alerts() {
    if (_drowsy_changed) {
        _drowsy_changed = false;
        if (_new_drowsy) {
            if (_pomo_state == POMO_RUNNING) {
                show_alert(ALERT_DROWSY);
                sound_play(ALERT_DROWSY);
                _alert_sound_active  = true;
                _alert_sound_type    = ALERT_DROWSY;
                _alert_sound_last_ms = millis();
            }
        } else {
            if (current_screen == SCREEN_POMODORO) hide_alert();
            _alert_sound_active = false;
        }
    }
    if (_phone_changed) {
        _phone_changed = false;
        if (_new_phone) {
            if (_pomo_state == POMO_RUNNING) {
                show_alert(ALERT_PHONE);
                sound_play(ALERT_PHONE);
                _alert_sound_active  = true;
                _alert_sound_type    = ALERT_PHONE;
                _alert_sound_last_ms = millis();
            }
        } else {
            if (current_screen == SCREEN_POMODORO) hide_alert();
            _alert_sound_active = false;
        }
    }

    // true인 동안 2초마다 반복 재생
    if (_alert_sound_active && _pomo_state == POMO_RUNNING &&
        !sound_is_playing() &&
        millis() - _alert_sound_last_ms >= ALERT_REPEAT_MS) {
        sound_play(_alert_sound_type);
        _alert_sound_last_ms = millis();
    }
}
