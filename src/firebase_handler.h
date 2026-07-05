#pragma once
#include <Arduino.h>
#include <Firebase_ESP_Client.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <time.h>
#include "secrets.h"
#define FIRESTORE_BASE_URL   "https://firestore.googleapis.com/v1/projects/" \
                             FIRESTORE_PROJECT_ID "/databases/(default)/documents"

// RTDB — 실시간 세션 상태 경로
#define RTDB_SESSION_PATH "/users/" FS_USER_ID "/status/current_state"

// Firestore — 완료 세션 서브컬렉션 (POST → auto-ID)
#define FS_SESSIONS_URL   FIRESTORE_BASE_URL "/users/" FS_USER_ID \
                          "/focus_sessions?key=" FIRESTORE_API_KEY

// Firestore — 유저 문서 읽기 (todos 맵 필드 + settings)
#define FS_USER_URL       FIRESTORE_BASE_URL "/users/" FS_USER_ID \
                          "?mask.fieldPaths=todos&mask.fieldPaths=settings" \
                          "&key=" FIRESTORE_API_KEY


// ─── 전역 SSL 직렬화 (동시 SSL 연결 방지) ────────────────────────────────────
// FirebaseData를 하나만 유지해 SSL 버퍼를 ~20KB로 고정.
// 모든 SSL 작업(RTDB setJSON/getJSON + Firestore HTTPClient)은 이 뮤텍스를 잡고 실행.
static FirebaseData      _g_rtdb_fbd;
static SemaphoreHandle_t _ssl_mutex;

// ─── ISO 타임스탬프 헬퍼 ──────────────────────────────────────────────────────
void get_iso_now(char *buf, size_t len) {
    time_t t; time(&t);
    if (t < 1000000UL) { buf[0] = '\0'; return; }
    strftime(buf, len, "%Y-%m-%dT%H:%M:%S", localtime(&t));  // KST (configTime UTC+9)
}
void gen_session_id(char *buf, size_t len) {
    time_t t; time(&t);
    if (t > 1000000UL) snprintf(buf, len, "esp_%ld", (long)t);
    else                snprintf(buf, len, "esp_%lu", (unsigned long)millis());
}
static void _iso_date(const char *iso, char *out) {
    strncpy(out, iso, 10); out[10] = '\0';
}
static void _iso_hhmm(const char *iso, char *out) {
    if (strlen(iso) < 16) { out[0] = '\0'; return; }
    strncpy(out, iso + 11, 5); out[5] = '\0';
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

// ─── 상태 추적 변수 (_rtdb_write_task 에서 참조) ────────────────────────────
static bool _last_drowsy = false;
static bool _last_phone  = false;

// ─── RTDB 세션 상태 쓰기 (뽀모도로·스톱워치 공용) ────────────────────────────
struct _RtdbPayload {
    char session_id[32]; char type[16]; char state[16];
    int  duration;
    char started_at[32]; char paused_at[32];
    int  total_pause_sec;
};

static void _rtdb_write_task(void *param) {
    _RtdbPayload *p = (_RtdbPayload *)param;
    FirebaseJson json;
    json.set("session_id",        String(p->session_id));
    json.set("type",              String(p->type));
    json.set("state",             String(p->state));
    json.set("duration",          p->duration);
    json.set("started_at",        String(p->started_at));
    json.set("paused_at",         String(p->paused_at));
    json.set("total_pause_sec",   p->total_pause_sec);
    json.set("is_detecting_drowsy", _last_drowsy);
    json.set("is_detecting_phone",  _last_phone);
    xSemaphoreTake(_ssl_mutex, portMAX_DELAY);
    if (Firebase.RTDB.setJSON(&_g_rtdb_fbd, RTDB_SESSION_PATH, &json))
        Serial.printf("[RTDB] %s/%s ✅\n", p->type, p->state);
    else
        Serial.printf("[RTDB] 쓰기 실패: %s\n", _g_rtdb_fbd.errorReason().c_str());
    xSemaphoreGive(_ssl_mutex);
    delete p;
    vTaskDelete(NULL);
}

void rtdb_send_state(const char *session_id, const char *type, const char *state,
                     int duration, const char *started_at,
                     const char *paused_at, int total_pause_sec) {
    if (!Firebase.ready()) return;
    _RtdbPayload *p = new _RtdbPayload;
    strlcpy(p->session_id,    session_id,    sizeof(p->session_id));
    strlcpy(p->type,          type,          sizeof(p->type));
    strlcpy(p->state,         state,         sizeof(p->state));
    p->duration        = duration;
    strlcpy(p->started_at,    started_at,    sizeof(p->started_at));
    strlcpy(p->paused_at,     paused_at,     sizeof(p->paused_at));
    p->total_pause_sec = total_pause_sec;
    xTaskCreatePinnedToCore(_rtdb_write_task, "rtdb_write", 8192, p, 1, NULL, 1);
}

// ─── Firestore JSON 빌더 헬퍼 ─────────────────────────────────────────────────
// pause_events 배열 (PauseEvent는 stopwatch.h에서 정의됨)
static void _build_pause_json(char *buf, size_t len, PauseEvent *ev, int count) {
    if (count == 0) { strlcpy(buf, "{\"arrayValue\":{}}", len); return; }
    strlcpy(buf, "{\"arrayValue\":{\"values\":[", len);
    for (int i = 0; i < count; i++) {
        char pd[11], pt[6], rd[11], rt[6];
        _iso_date(ev[i].paused_at,  pd); _iso_hhmm(ev[i].paused_at,  pt);
        _iso_date(ev[i].resumed_at, rd); _iso_hhmm(ev[i].resumed_at, rt);
        char entry[256];
        snprintf(entry, sizeof(entry),
            "%s{\"mapValue\":{\"fields\":{"
            "\"paused_at_date\":{\"stringValue\":\"%s\"},"
            "\"paused_at_time\":{\"stringValue\":\"%s\"},"
            "\"resumed_at_date\":{\"stringValue\":\"%s\"},"
            "\"resumed_at_time\":{\"stringValue\":\"%s\"}}}}",
            i > 0 ? "," : "", pd, pt, rd, rt);
        strlcat(buf, entry, len);
    }
    strlcat(buf, "]}}", len);
}


// ─── Firestore 스톱워치 세션 POST ─────────────────────────────────────────────
struct _SwPostPayload {
    char session_id[32];
    char started_at[32]; char ended_at[32];
    int  total_pause_sec; uint32_t elapsed_ms;
    PauseEvent pause_events[10]; int pause_count;
};

static void _sw_post_task(void *param) {
    _SwPostPayload *p = (_SwPostPayload *)param;
    char sd[11], st[6], ed[11], et[6];
    _iso_date(p->started_at, sd); _iso_hhmm(p->started_at, st);
    _iso_date(p->ended_at,   ed); _iso_hhmm(p->ended_at,   et);
    int actual_min = (int)(p->elapsed_ms / 60000);
    int pause_min  = p->total_pause_sec / 60;

    char pause_json[2048];
    _build_pause_json(pause_json, sizeof(pause_json), p->pause_events, p->pause_count);

    char body[3072];
    snprintf(body, sizeof(body),
        "{\"fields\":{"
        "\"session_id\":{\"stringValue\":\"%s\"},"
        "\"type\":{\"stringValue\":\"stopwatch\"},"
        "\"title\":{\"stringValue\":\"스톱워치 세션\"},"
        "\"status\":{\"stringValue\":\"completed\"},"
        "\"date\":{\"stringValue\":\"%s\"},"
        "\"start_date\":{\"stringValue\":\"%s\"},"
        "\"start_time\":{\"stringValue\":\"%s\"},"
        "\"end_date\":{\"stringValue\":\"%s\"},"
        "\"end_time\":{\"stringValue\":\"%s\"},"
        "\"actual_duration\":{\"integerValue\":\"%d\"},"
        "\"total_pause_duration\":{\"integerValue\":\"%d\"},"
        "\"pause_events\":%s}}",
        p->session_id, sd, sd, st, ed, et, actual_min, pause_min, pause_json);

    xSemaphoreTake(_ssl_mutex, portMAX_DELAY);
    WiFiClientSecure sc; sc.setInsecure();
    HTTPClient http;
    http.begin(sc, FS_SESSIONS_URL);
    http.setTimeout(8000);
    http.addHeader("Content-Type", "application/json");
    int code = http.POST(body);
    if (code == 200 || code == 201) {
        String resp = http.getString();
        int ni = resp.indexOf("\"name\":\"");
        if (ni >= 0) {
            ni += 8;
            String path = resp.substring(ni, resp.indexOf('"', ni));
            Serial.printf("[SW] Firestore 문서 생성 ✅ ID=%s\n",
                          path.substring(path.lastIndexOf('/') + 1).c_str());
        } else {
            Serial.println("[SW] Firestore POST ✅");
        }
    } else {
        Serial.printf("[SW] Firestore POST 실패 HTTP %d\n", code);
        Serial.println(http.getString().substring(0, 200));
    }
    http.end();
    xSemaphoreGive(_ssl_mutex);
    delete p;
    vTaskDelete(NULL);
}

void sw_post_focus_session(const char *session_id,
                           const char *started_at, const char *ended_at,
                           int total_pause_sec, uint32_t elapsed_ms,
                           PauseEvent *events, int event_count) {
    if (WiFi.status() != WL_CONNECTED) return;
    _SwPostPayload *p = new _SwPostPayload;
    strlcpy(p->session_id, session_id, sizeof(p->session_id));
    strlcpy(p->started_at, started_at, sizeof(p->started_at));
    strlcpy(p->ended_at,   ended_at,   sizeof(p->ended_at));
    p->total_pause_sec = total_pause_sec;
    p->elapsed_ms      = elapsed_ms;
    p->pause_count     = (event_count > 10) ? 10 : event_count;
    if (events && p->pause_count > 0)
        memcpy(p->pause_events, events, p->pause_count * sizeof(PauseEvent));
    xTaskCreatePinnedToCore(_sw_post_task, "sw_fs_post", 16384, p, 1, NULL, 1);
}

// ─── Firestore 뽀모도로 세션 POST ─────────────────────────────────────────────
struct _PomoPostPayload {
    char session_id[32];
    char started_at[32]; char ended_at[32];
    int  planned_min; int actual_min;
};

static void _pomo_post_task(void *param) {
    _PomoPostPayload *p = (_PomoPostPayload *)param;
    char sd[11], st[6], ed[11], et[6];
    _iso_date(p->started_at, sd); _iso_hhmm(p->started_at, st);
    _iso_date(p->ended_at,   ed); _iso_hhmm(p->ended_at,   et);

    const char *status = (p->actual_min >= p->planned_min - 1) ? "completed" : "incomplete";
    char body[2048];
    snprintf(body, sizeof(body),
        "{\"fields\":{"
        "\"session_id\":{\"stringValue\":\"%s\"},"
        "\"type\":{\"stringValue\":\"pomodoro\"},"
        "\"title\":{\"stringValue\":\"뽀모도로 세션\"},"
        "\"status\":{\"stringValue\":\"%s\"},"
        "\"date\":{\"stringValue\":\"%s\"},"
        "\"start_date\":{\"stringValue\":\"%s\"},"
        "\"start_time\":{\"stringValue\":\"%s\"},"
        "\"end_date\":{\"stringValue\":\"%s\"},"
        "\"end_time\":{\"stringValue\":\"%s\"},"
        "\"planned_duration\":{\"integerValue\":\"%d\"},"
        "\"actual_duration\":{\"integerValue\":\"%d\"}}}",
        p->session_id, status, sd, sd, st, ed, et,
        p->planned_min, p->actual_min);

    xSemaphoreTake(_ssl_mutex, portMAX_DELAY);
    WiFiClientSecure sc; sc.setInsecure();
    HTTPClient http;
    http.begin(sc, FS_SESSIONS_URL);
    http.setTimeout(8000);
    http.addHeader("Content-Type", "application/json");
    int code = http.POST(body);
    if (code == 200 || code == 201) {
        String resp = http.getString();
        int ni = resp.indexOf("\"name\":\"");
        if (ni >= 0) {
            ni += 8;
            String path = resp.substring(ni, resp.indexOf('"', ni));
            Serial.printf("[Pomo] Firestore 문서 생성 ✅ ID=%s\n",
                          path.substring(path.lastIndexOf('/') + 1).c_str());
        } else {
            Serial.println("[Pomo] Firestore POST ✅");
        }
    } else {
        Serial.printf("[Pomo] Firestore POST 실패 HTTP %d\n", code);
        Serial.println(http.getString().substring(0, 200));
    }
    http.end();
    xSemaphoreGive(_ssl_mutex);
    delete p;
    vTaskDelete(NULL);
}

void pomo_post_focus_session(const char *session_id,
                              const char *started_at, const char *ended_at,
                              int planned_min, int actual_min) {
    if (WiFi.status() != WL_CONNECTED) return;
    _PomoPostPayload *p = new _PomoPostPayload;
    strlcpy(p->session_id, session_id, sizeof(p->session_id));
    strlcpy(p->started_at, started_at, sizeof(p->started_at));
    strlcpy(p->ended_at,   ended_at,   sizeof(p->ended_at));
    p->planned_min = planned_min;
    p->actual_min  = actual_min;
    xTaskCreatePinnedToCore(_pomo_post_task, "po_fs_post", 16384, p, 1, NULL, 1);
}


// ─── voice.h extern 전역 ─────────────────────────────────────────────────────
char fs_task_assignment[128] = {};  // 오늘 미완료 todos 요약 (음성 컨텍스트)
char fs_task_etc[128]        = {};
char fs_task_health[128]     = {};
volatile bool _fs_tasks_ready = false;

// ─── Firebase 객체 ───────────────────────────────────────────────────────────
FirebaseData   fbdo;
FirebaseAuth   fb_auth;
FirebaseConfig fb_config;

// ─── Firestore todos + 카테고리 페치 ─────────────────────────────────────────
static uint32_t _tasks_last_fetch = 0;
static bool     _fs_fetching     = false;

static void _fs_fetch_task(void *) {
    xSemaphoreTake(_ssl_mutex, portMAX_DELAY);
    WiFiClientSecure sc; sc.setInsecure();
    HTTPClient http;
    http.begin(sc, FS_USER_URL);
    http.setTimeout(8000);
    int code = http.GET();
    if (code == 200) {
        FirebaseJson json;
        FirebaseJsonData r;
        json.setJsonData(http.getString());

        // 오늘 날짜
        char today[11] = {};
        time_t t; time(&t);
        if (t > 1000000UL) strftime(today, sizeof(today), "%Y-%m-%d", localtime(&t));

        // 3. todos 파싱 — 오늘 날짜 + 미완료
        fs_task_assignment[0] = '\0';

        // 기존 notify shown 상태 보존 (fetch 주기 중에 shown 플래그 리셋 방지)
        NotifyTodo old_notify[20];
        int old_notify_count = _notify_todo_count;
        memcpy(old_notify, _notify_todos, sizeof(old_notify));
        _notify_todo_count = 0;

        if (json.get(r, "fields/todos/mapValue/fields")) {
            FirebaseJson todos_map;
            todos_map.setJsonData(r.stringValue);
            todos_map.iteratorBegin();
            String todo_id, todo_raw;
            int type = 0, idx = 0;
            while (todos_map.iteratorGet(idx++, type, todo_id, todo_raw)) {
                FirebaseJson ti; ti.setJsonData(todo_raw.c_str());
                FirebaseJsonData d;
                if (today[0]) {
                    if (!ti.get(d, "mapValue/fields/date/stringValue")) continue;
                    if (strcmp(d.stringValue.c_str(), today) != 0) continue;
                }
                if (ti.get(d, "mapValue/fields/is_done/booleanValue") && d.boolValue) continue;
                if (!ti.get(d, "mapValue/fields/content/stringValue")) continue;
                const char *content_val = d.stringValue.c_str();
                if (fs_task_assignment[0]) strlcat(fs_task_assignment, " / ", sizeof(fs_task_assignment));
                strlcat(fs_task_assignment, content_val, sizeof(fs_task_assignment));

                // notify 있는 항목만 추적
                FirebaseJsonData nd;
                bool has_notify = ti.get(nd, "mapValue/fields/notify/booleanValue") && nd.boolValue;
                if (has_notify && _notify_todo_count < 20) {
                    FirebaseJsonData nb, dt;
                    bool has_nb = ti.get(nb, "mapValue/fields/notify_before/integerValue");
                    bool has_dt = ti.get(dt, "mapValue/fields/deadline_time/stringValue") &&
                                  dt.stringValue.length() >= 4;
                    if (has_nb && has_dt) {
                        // 이전 shown 상태 승계 (같은 content + date 항목)
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
                        strlcpy(_notify_todos[_notify_todo_count].deadline_time, dt.stringValue.c_str(), 6);
                        _notify_todos[_notify_todo_count].notify_before = nb.intValue;
                        _notify_todos[_notify_todo_count].shown         = was_shown;
                        _notify_todo_count++;
                    }
                }
            }
            todos_map.iteratorEnd();
        }
        _fs_tasks_ready = true;
        Serial.printf("[Fetch] todos: %s\n", fs_task_assignment);
    } else {
        Serial.printf("[Fetch] HTTP %d\n", code);
    }
    http.end();
    xSemaphoreGive(_ssl_mutex);
    _tasks_last_fetch = millis();
    _fs_fetching = false;
    vTaskDelete(NULL);
}

void firebase_fetch_tasks() {
    if (WiFi.status() != WL_CONNECTED) return;
    if (_fs_fetching) return;
    if (_tasks_last_fetch && millis() - _tasks_last_fetch < 60000) return;
    _fs_fetching = true;
    xTaskCreatePinnedToCore(_fs_fetch_task, "fs_fetch", 10240, NULL, 1, NULL, 1);
}

// ─── 폴링 결과 → 메인 루프 전달용 volatile 변수 ───────────────────────────────
static volatile bool _drowsy_changed = false;
static volatile bool _phone_changed  = false;
static volatile bool _new_drowsy     = false;
static volatile bool _new_phone      = false;

// 앱→ESP 동기화용 (alert_poll_task에서 쓰고, 메인 루프에서 읽음)
static volatile bool _rtdb_app_sync_pending = false;
static char _rtdb_app_type[16]        = {};
static char _rtdb_app_state[16]       = {};
static int  _rtdb_app_duration        = 0;
static char _rtdb_app_session_id[32]  = {};
static char _rtdb_app_started_at[32]  = {};
static char _rtdb_app_paused_at[32]   = {};
static int  _rtdb_app_total_pause_sec = 0;
static char _last_polled_sess_id[32]  = {};
static char _last_polled_state[16]    = {};

// ─── current_state 폴링 태스크 (Core 0, 2초 간격) ────────────────────────────
// drowsy/phone 감지 + 앱→ESP 세션 동기화를 current_state 한 번의 GET으로 처리
static void _alert_poll_task(void *) {
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(4000));
        if (!Firebase.ready()) continue;

        if (xSemaphoreTake(_ssl_mutex, pdMS_TO_TICKS(5000)) != pdTRUE) continue;
        bool ok = Firebase.RTDB.getJSON(&_g_rtdb_fbd, RTDB_SESSION_PATH);
        if (!ok) { xSemaphoreGive(_ssl_mutex); continue; }

        // 파싱은 로컬 변수로 빠르게 복사 후 뮤텍스 해제
        FirebaseJson &csj = _g_rtdb_fbd.to<FirebaseJson>();
        FirebaseJsonData r;

        char sess_id[32] = {}, type[16] = {}, state[16] = {};
        char started_at[32] = {}, paused_at[32] = {};
        int  duration = 0, total_pause_sec = 0;
        bool drowsy = false, phone = false;

        if (csj.get(r, "session_id"))         strlcpy(sess_id,    r.stringValue.c_str(), sizeof(sess_id));
        if (csj.get(r, "type"))               strlcpy(type,       r.stringValue.c_str(), sizeof(type));
        if (csj.get(r, "state"))              strlcpy(state,      r.stringValue.c_str(), sizeof(state));
        if (csj.get(r, "duration"))           duration = r.intValue;
        if (csj.get(r, "started_at"))         strlcpy(started_at, r.stringValue.c_str(), sizeof(started_at));
        if (csj.get(r, "paused_at"))          strlcpy(paused_at,  r.stringValue.c_str(), sizeof(paused_at));
        if (csj.get(r, "total_pause_sec"))    total_pause_sec = r.intValue;
        if (csj.get(r, "is_detecting_drowsy")) drowsy = r.boolValue;
        if (csj.get(r, "is_detecting_phone"))  phone  = r.boolValue;
        xSemaphoreGive(_ssl_mutex);  // 로컬 복사 완료 → 즉시 해제

        // drowsy / phone 상태 변화 감지
        if (drowsy != _last_drowsy) { _last_drowsy = drowsy; _new_drowsy = drowsy; _drowsy_changed = true; }
        if (phone  != _last_phone)  { _last_phone  = phone;  _new_phone  = phone;  _phone_changed  = true; }

        // 앱이 쓴 세션만 동기화 (ESP가 쓴 건 "esp_" 접두사로 구분)
        if (!sess_id[0] || strncmp(sess_id, "esp_", 4) == 0) continue;

        bool changed = strcmp(sess_id, _last_polled_sess_id) != 0 ||
                       strcmp(state,   _last_polled_state)   != 0;
        if (!changed) continue;

        strlcpy(_rtdb_app_type,       type,       sizeof(_rtdb_app_type));
        strlcpy(_rtdb_app_state,      state,      sizeof(_rtdb_app_state));
        _rtdb_app_duration        = duration;
        strlcpy(_rtdb_app_session_id, sess_id,    sizeof(_rtdb_app_session_id));
        strlcpy(_rtdb_app_started_at, started_at, sizeof(_rtdb_app_started_at));
        strlcpy(_rtdb_app_paused_at,  paused_at,  sizeof(_rtdb_app_paused_at));
        _rtdb_app_total_pause_sec = total_pause_sec;
        _rtdb_app_sync_pending    = true;

        strlcpy(_last_polled_sess_id, sess_id, sizeof(_last_polled_sess_id));
        strlcpy(_last_polled_state,   state,   sizeof(_last_polled_state));
    }
}

// ─── 앱→ESP 동기화 처리 (메인 루프에서 호출) ─────────────────────────────────
// sw_rtdb_sync / pomo_rtdb_sync 는 stopwatch.h / pomodoro.h 에서 이미 정의됨
extern AppScreen current_screen;

void firebase_sync_from_app() {
    if (!_rtdb_app_sync_pending) return;
    _rtdb_app_sync_pending = false;
    const char *t = _rtdb_app_type;
    const char *s = _rtdb_app_state;
    if (strcmp(t, "pomodoro") == 0 && current_screen == SCREEN_POMODORO)
        pomo_rtdb_sync(s, _rtdb_app_duration, _rtdb_app_started_at, _rtdb_app_session_id);
    else if (strcmp(t, "stopwatch") == 0 && current_screen == SCREEN_STOPWATCH)
        sw_rtdb_sync(s, _rtdb_app_started_at, _rtdb_app_paused_at,
                     _rtdb_app_total_pause_sec, _rtdb_app_session_id);
}

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

// ─── Firebase 초기화 ─────────────────────────────────────────────────────────
void firebase_init() {
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[Firebase] WiFi 미연결 — 스킵"); return;
    }
    _ssl_mutex = xSemaphoreCreateMutex();
    fb_config.database_url               = "https://" FIREBASE_HOST "/";
    fb_config.signer.tokens.legacy_token = FIREBASE_AUTH;
    Firebase.begin(&fb_config, &fb_auth);
    Firebase.reconnectWiFi(true);
    xTaskCreatePinnedToCore(_alert_poll_task, "alert_poll", 10240, NULL, 1, NULL, 1);
    Serial.println("[Firebase] 초기화 완료");
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
