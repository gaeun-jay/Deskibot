#pragma once
#include <Arduino.h>
#include <lvgl.h>
#include <time.h>

// ─── 일시정지 이벤트 구조체 (firebase_handler.h의 _build_pause_json에서 사용) ─
struct PauseEvent {
    char paused_at[32];   // ISO 8601 — 일시정지 시작
    char resumed_at[32];  // ISO 8601 — 재개 / 종료 시
};

// ─── firebase_handler.h 전방 선언 (나중에 include됨) ────────────────────────
void get_iso_now(char *buf, size_t len);
void gen_session_id(char *buf, size_t len);
void rtdb_send_state(const char *session_id, const char *type, const char *state,
                     int duration, const char *started_at,
                     const char *paused_at, int total_pause_sec);
void sw_post_focus_session(const char *started_at, const char *ended_at,
                           int total_pause_sec, uint32_t elapsed_ms,
                           PauseEvent *events, int event_count);

// ─── 스톱워치 상태 ───────────────────────────────────────────────────────────
#define SW_IDLE    0
#define SW_RUNNING 1
#define SW_PAUSED  2

int _sw_state = SW_IDLE;
static uint32_t _sw_startMs   = 0;
static uint32_t _sw_elapsedMs = 0;

// ─── 세션 추적 변수 ──────────────────────────────────────────────────────────
static char     _sw_session_id[32]     = {};  // 세션 고유 ID (esp_ 접두사)
static char     _sw_started_at[32]     = {};  // 세션 시작 ISO
static char     _sw_paused_at[32]      = {};  // 현재 일시정지 시작 ISO (재개/종료 시 "")
static uint32_t _sw_pause_start_ms     = 0;   // 일시정지 시작 millis
static int      _sw_total_pause_sec    = 0;   // 누적 정지 시간(초)
static PauseEvent _sw_pause_events[10] = {};  // 일시정지 이벤트 배열
static int      _sw_pause_event_count  = 0;   // 배열 크기

// ─── UI 오브젝트 ─────────────────────────────────────────────────────────────
static lv_obj_t *sw_label_time = nullptr;
static lv_obj_t *sw_btn_play   = nullptr;
static lv_obj_t *sw_btn_pause  = nullptr;
static lv_obj_t *sw_btn_stop   = nullptr;

// ─── 버튼 표시/숨김 ──────────────────────────────────────────────────────────
static void _sw_update_buttons() {
    switch (_sw_state) {
        case SW_IDLE:
            lv_obj_clear_flag(sw_btn_play,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (sw_btn_pause, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (sw_btn_stop,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_align(sw_btn_play, LV_ALIGN_CENTER, 0, 90);
            break;
        case SW_RUNNING:
            lv_obj_add_flag  (sw_btn_play,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(sw_btn_pause, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (sw_btn_stop,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_align(sw_btn_pause, LV_ALIGN_CENTER, 0, 90);
            break;
        case SW_PAUSED:
            lv_obj_clear_flag(sw_btn_play, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (sw_btn_pause, LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(sw_btn_stop, LV_OBJ_FLAG_HIDDEN);
            lv_obj_align(sw_btn_play, LV_ALIGN_CENTER, -70, 90);
            lv_obj_align(sw_btn_stop, LV_ALIGN_CENTER,  70, 90);
            break;
    }
}

// ─── 타이머 텍스트 업데이트 ──────────────────────────────────────────────────
static void _sw_update_time() {
    uint32_t totalSec = _sw_elapsedMs / 1000;
    uint32_t centis   = (_sw_elapsedMs % 1000) / 10;
    uint32_t sec      = totalSec % 60;
    uint32_t min      = totalSec / 60;
    char buf[12];
    snprintf(buf, sizeof(buf), "%d:%02d.%02d", (int)min, (int)sec, (int)centis);
    lv_label_set_text(sw_label_time, buf);
}

// ─── LVGL 타이머 콜백 ────────────────────────────────────────────────────────
static void sw_timer_cb(lv_timer_t *timer) {
    if (_sw_state != SW_RUNNING) return;
    _sw_elapsedMs = millis() - _sw_startMs;
    _sw_update_time();
}

// ─── 버튼 콜백 ───────────────────────────────────────────────────────────────
static void sw_btn_play_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;

    if (_sw_state == SW_IDLE) {
        // ── start ────────────────────────────────────────────────────────────
        gen_session_id(_sw_session_id, sizeof(_sw_session_id));
        get_iso_now(_sw_started_at, sizeof(_sw_started_at));
        _sw_state              = SW_RUNNING;
        _sw_startMs            = millis();
        _sw_elapsedMs          = 0;
        _sw_total_pause_sec    = 0;
        _sw_pause_event_count  = 0;
        _sw_paused_at[0]       = '\0';
        rtdb_send_state(_sw_session_id, "stopwatch", "start",
                        0, _sw_started_at, "", 0);
        Serial.println("[SW] 시작");

    } else if (_sw_state == SW_PAUSED) {
        // ── resume ───────────────────────────────────────────────────────────
        int pause_sec = (int)((millis() - _sw_pause_start_ms) / 1000);
        _sw_total_pause_sec += pause_sec;

        // 마지막 일시정지 이벤트의 resumed_at 채우기
        if (_sw_pause_event_count < 10) {
            get_iso_now(_sw_pause_events[_sw_pause_event_count].resumed_at, 32);
            Serial.printf("[SW] 재개 — events[%d] 완료 paused=%s resumed=%s\n",
                          _sw_pause_event_count,
                          _sw_pause_events[_sw_pause_event_count].paused_at,
                          _sw_pause_events[_sw_pause_event_count].resumed_at);
            _sw_pause_event_count++;
        }
        _sw_paused_at[0] = '\0';
        _sw_state        = SW_RUNNING;
        _sw_startMs      = millis() - _sw_elapsedMs;
        rtdb_send_state(_sw_session_id, "stopwatch", "resume",
                        0, _sw_started_at, "", _sw_total_pause_sec);
    }
    _sw_update_buttons();
}

static void sw_btn_pause_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    if (_sw_state != SW_RUNNING) return;

    // ── pause ─────────────────────────────────────────────────────────────
    _sw_elapsedMs      = millis() - _sw_startMs;
    _sw_pause_start_ms = millis();
    _sw_state          = SW_PAUSED;
    get_iso_now(_sw_paused_at, sizeof(_sw_paused_at));

    // 일시정지 이벤트 시작 기록 (resumed_at은 재개 시 채움)
    if (_sw_pause_event_count < 10)
        strlcpy(_sw_pause_events[_sw_pause_event_count].paused_at, _sw_paused_at, 32);

    rtdb_send_state(_sw_session_id, "stopwatch", "pause",
                    0, _sw_started_at, _sw_paused_at, _sw_total_pause_sec);
    _sw_update_time();
    _sw_update_buttons();
    Serial.printf("[SW] 일시정지 — slot=%d paused_at=%s\n",
                  _sw_pause_event_count, _sw_paused_at);
}

static void sw_btn_stop_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;

    // ── end (일시정지 상태에서만 호출 가능) ──────────────────────────────────
    int last_pause_sec = (int)((millis() - _sw_pause_start_ms) / 1000);
    _sw_total_pause_sec += last_pause_sec;

    // 마지막 일시정지 이벤트 — resumed_at = 종료 시각
    char ended_at[32];
    get_iso_now(ended_at, sizeof(ended_at));
    if (_sw_pause_event_count < 10) {
        strlcpy(_sw_pause_events[_sw_pause_event_count].resumed_at, ended_at, 32);
        _sw_pause_event_count++;
    }

    Serial.printf("[SW] 종료 — total_events=%d elapsed=%ums pause_sec=%d\n",
                  _sw_pause_event_count, _sw_elapsedMs, _sw_total_pause_sec);
    rtdb_send_state(_sw_session_id, "stopwatch", "end",
                    0, _sw_started_at, "", _sw_total_pause_sec);
    sw_post_focus_session(_sw_session_id, _sw_started_at, ended_at, _sw_total_pause_sec,
                          _sw_elapsedMs, _sw_pause_events, _sw_pause_event_count);

    _sw_state             = SW_IDLE;
    _sw_elapsedMs         = 0;
    _sw_paused_at[0]      = '\0';
    _sw_total_pause_sec   = 0;
    _sw_pause_event_count = 0;
    _sw_started_at[0]     = '\0';
    _sw_session_id[0]     = '\0';
    _sw_update_time();
    _sw_update_buttons();
    Serial.println("[SW] 종료");
}

// ─── 앱→ESP 동기화 (firebase_sync_from_app에서 호출) ─────────────────────────
void sw_rtdb_sync(const char *state, const char *started_at, const char *paused_at,
                  int total_pause_sec, const char *session_id) {
    if (strcmp(state, "start") == 0 && _sw_state == SW_IDLE) {
        strlcpy(_sw_session_id,  session_id,  sizeof(_sw_session_id));
        strlcpy(_sw_started_at,  started_at,  sizeof(_sw_started_at));
        _sw_state             = SW_RUNNING;
        _sw_startMs           = millis();
        _sw_elapsedMs         = 0;
        _sw_total_pause_sec   = 0;
        _sw_pause_event_count = 0;
        _sw_paused_at[0]      = '\0';
        _sw_update_buttons();
        Serial.println("[SW] 앱 동기화: 시작");

    } else if (strcmp(state, "pause") == 0 && _sw_state == SW_RUNNING) {
        _sw_elapsedMs      = millis() - _sw_startMs;
        _sw_pause_start_ms = millis();
        _sw_state          = SW_PAUSED;
        strlcpy(_sw_paused_at, paused_at[0] ? paused_at : "", sizeof(_sw_paused_at));
        if (_sw_pause_event_count < 10)
            strlcpy(_sw_pause_events[_sw_pause_event_count].paused_at, _sw_paused_at, 32);
        _sw_update_time();
        _sw_update_buttons();
        Serial.println("[SW] 앱 동기화: 일시정지");

    } else if (strcmp(state, "resume") == 0 && _sw_state == SW_PAUSED) {
        int ps = (int)((millis() - _sw_pause_start_ms) / 1000);
        _sw_total_pause_sec += ps;
        if (_sw_pause_event_count < 10) {
            char now[32]; get_iso_now(now, sizeof(now));
            strlcpy(_sw_pause_events[_sw_pause_event_count].resumed_at, now, 32);
            _sw_pause_event_count++;
        }
        _sw_paused_at[0] = '\0';
        _sw_state        = SW_RUNNING;
        _sw_startMs      = millis() - _sw_elapsedMs;
        _sw_update_buttons();
        Serial.println("[SW] 앱 동기화: 재개");

    } else if (strcmp(state, "end") == 0 && _sw_state != SW_IDLE) {
        char ended_at[32]; get_iso_now(ended_at, sizeof(ended_at));
        if (_sw_state == SW_PAUSED) {
            _sw_total_pause_sec += (int)((millis() - _sw_pause_start_ms) / 1000);
            if (_sw_pause_event_count < 10) {
                strlcpy(_sw_pause_events[_sw_pause_event_count].resumed_at, ended_at, 32);
                _sw_pause_event_count++;
            }
        }
        sw_post_focus_session(_sw_started_at, ended_at, _sw_total_pause_sec,
                              _sw_elapsedMs, _sw_pause_events, _sw_pause_event_count);
        _sw_state             = SW_IDLE;
        _sw_elapsedMs         = 0;
        _sw_total_pause_sec   = 0;
        _sw_pause_event_count = 0;
        _sw_started_at[0]     = '\0';
        _sw_paused_at[0]      = '\0';
        _sw_session_id[0]     = '\0';
        _sw_update_time();
        _sw_update_buttons();
        Serial.println("[SW] 앱 동기화: 종료");
    }
}

// ─── 스톱워치 UI 생성 ────────────────────────────────────────────────────────
void create_stopwatch_ui() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // ── 타이머 텍스트 ────────────────────────────────────────────────────────
    sw_label_time = lv_label_create(scr);
    lv_obj_set_style_text_color(sw_label_time, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_text_font(sw_label_time, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_label_set_text(sw_label_time, "0:00.00");
    lv_obj_align(sw_label_time, LV_ALIGN_CENTER, 0, -40);

    // ── 버튼 스타일 ──────────────────────────────────────────────────────────
    static lv_style_t style_btn_blue;
    lv_style_init(&style_btn_blue);
    lv_style_set_bg_color(&style_btn_blue, lv_color_hex(0x1A6FE8));
    lv_style_set_bg_opa(&style_btn_blue, LV_OPA_COVER);
    lv_style_set_radius(&style_btn_blue, LV_RADIUS_CIRCLE);
    lv_style_set_border_width(&style_btn_blue, 0);
    lv_style_set_shadow_width(&style_btn_blue, 0);

    static lv_style_t style_btn_blue_pr;
    lv_style_init(&style_btn_blue_pr);
    lv_style_set_bg_color(&style_btn_blue_pr, lv_color_hex(0x1050B0));

    static lv_style_t style_btn_pale;
    lv_style_init(&style_btn_pale);
    lv_style_set_bg_color(&style_btn_pale, lv_color_hex(0xD0E4FF));
    lv_style_set_bg_opa(&style_btn_pale, LV_OPA_COVER);
    lv_style_set_radius(&style_btn_pale, LV_RADIUS_CIRCLE);
    lv_style_set_border_width(&style_btn_pale, 0);
    lv_style_set_shadow_width(&style_btn_pale, 0);

    static lv_style_t style_btn_pale_pr;
    lv_style_init(&style_btn_pale_pr);
    lv_style_set_bg_color(&style_btn_pale_pr, lv_color_hex(0xA0C8FF));

    const int BTN_SIZE = 90;

    // ── ▶ 재생/재개 버튼 ─────────────────────────────────────────────────────
    sw_btn_play = lv_button_create(scr);
    lv_obj_add_style(sw_btn_play, &style_btn_blue,    LV_STATE_DEFAULT);
    lv_obj_add_style(sw_btn_play, &style_btn_blue_pr, LV_STATE_PRESSED);
    lv_obj_set_size(sw_btn_play, BTN_SIZE, BTN_SIZE);
    lv_obj_t *lbl_play = lv_label_create(sw_btn_play);
    lv_label_set_text(lbl_play, LV_SYMBOL_PLAY);
    lv_obj_set_style_text_color(lbl_play, lv_color_white(), LV_PART_MAIN);
    lv_obj_center(lbl_play);
    lv_obj_add_event_cb(sw_btn_play, sw_btn_play_cb, LV_EVENT_CLICKED, NULL);

    // ── ⏸ 일시정지 버튼 ──────────────────────────────────────────────────────
    sw_btn_pause = lv_button_create(scr);
    lv_obj_add_style(sw_btn_pause, &style_btn_blue,    LV_STATE_DEFAULT);
    lv_obj_add_style(sw_btn_pause, &style_btn_blue_pr, LV_STATE_PRESSED);
    lv_obj_set_size(sw_btn_pause, BTN_SIZE, BTN_SIZE);
    lv_obj_t *lbl_pause = lv_label_create(sw_btn_pause);
    lv_label_set_text(lbl_pause, LV_SYMBOL_PAUSE);
    lv_obj_set_style_text_color(lbl_pause, lv_color_white(), LV_PART_MAIN);
    lv_obj_center(lbl_pause);
    lv_obj_add_event_cb(sw_btn_pause, sw_btn_pause_cb, LV_EVENT_CLICKED, NULL);

    // ── ⏹ 종료 버튼 ──────────────────────────────────────────────────────────
    sw_btn_stop = lv_button_create(scr);
    lv_obj_add_style(sw_btn_stop, &style_btn_pale,    LV_STATE_DEFAULT);
    lv_obj_add_style(sw_btn_stop, &style_btn_pale_pr, LV_STATE_PRESSED);
    lv_obj_set_size(sw_btn_stop, BTN_SIZE, BTN_SIZE);
    lv_obj_t *lbl_stop = lv_label_create(sw_btn_stop);
    lv_label_set_text(lbl_stop, LV_SYMBOL_STOP);
    lv_obj_set_style_text_color(lbl_stop, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_center(lbl_stop);
    lv_obj_add_event_cb(sw_btn_stop, sw_btn_stop_cb, LV_EVENT_CLICKED, NULL);

    // ── 현재 상태 복원 ───────────────────────────────────────────────────────
    if (_sw_state == SW_RUNNING)
        _sw_startMs = millis() - _sw_elapsedMs;
    _sw_update_time();
    _sw_update_buttons();

    lv_timer_create(sw_timer_cb, 200, NULL);
}
