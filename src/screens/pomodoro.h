#pragma once
#include <Arduino.h>
#include <lvgl.h>

// ─── 토마토 이미지 선언 ───────────────────────────────────────────────────────
LV_IMAGE_DECLARE(tomato);

// ─── 뽀모도로 상태 ───────────────────────────────────────────────────────────
#define POMO_IDLE    0
#define POMO_RUNNING 1
#define POMO_DONE    2

int _pomo_state         = POMO_IDLE;
static uint32_t _pomo_totalSec  = 0;
static uint32_t _pomo_remainSec = 0;
static uint32_t _pomo_lastTick  = 0;

// ─── Alert 타입 ───────────────────────────────────────────────────────────────
#define ALERT_NONE   0
#define ALERT_DROWSY 1
#define ALERT_PHONE  2

static int _alert_type = ALERT_NONE;

// ─── firebase_handler.h 전방 선언 (나중에 include됨) ────────────────────────
void get_iso_now(char *buf, size_t len);
void gen_session_id(char *buf, size_t len);
void rtdb_send_state(const char *session_id, const char *type, const char *state,
                     int duration, const char *started_at,
                     const char *paused_at, int total_pause_sec);
void pomo_post_focus_session(const char *session_id,
                              const char *started_at, const char *ended_at,
                              int planned_min, int actual_min);

// ─── 세션 추적 변수 ──────────────────────────────────────────────────────────
static char _pomo_session_id[32] = {};
static char _pomo_started_at[32] = {};

// ─── UI 오브젝트 — 뽀모도로 ──────────────────────────────────────────────────
static lv_obj_t *pomo_img_tomato  = nullptr;
static lv_obj_t *pomo_label_timer = nullptr;
static lv_obj_t *pomo_label_done  = nullptr;
static lv_obj_t *pomo_btn_25      = nullptr;
static lv_obj_t *pomo_btn_50      = nullptr;
static lv_obj_t *pomo_btn_force   = nullptr;

// ─── UI 오브젝트 — Alert 오버레이 ────────────────────────────────────────────
static lv_obj_t *alert_overlay  = nullptr;
static lv_obj_t *alert_symbol   = nullptr;
static lv_obj_t *alert_label    = nullptr;
static lv_anim_t alert_anim_sym;
static lv_anim_t alert_anim_lbl;

static lv_anim_t pomo_anim;

#define POMO_TOMATO_BASE_Y  -50

// ─── 둥둥 애니메이션 ─────────────────────────────────────────────────────────
static void _pomo_start_anim(lv_coord_t base_y) {
    lv_anim_init(&pomo_anim);
    lv_anim_set_var(&pomo_anim, pomo_img_tomato);
    lv_anim_set_exec_cb(&pomo_anim, (lv_anim_exec_xcb_t)lv_obj_set_y);
    lv_anim_set_values(&pomo_anim, base_y - 10, base_y + 10);
    lv_anim_set_time(&pomo_anim, 1500);
    lv_anim_set_playback_time(&pomo_anim, 1500);
    lv_anim_set_repeat_count(&pomo_anim, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&pomo_anim, lv_anim_path_ease_in_out);
    lv_anim_start(&pomo_anim);
}

// ─── Alert pulse 애니메이션 ──────────────────────────────────────────────────
static void _alert_scale_sym_cb(void *obj, int32_t v) {
    lv_obj_set_style_text_font((lv_obj_t *)obj,
        v > 127 ? &lv_font_montserrat_48 : &lv_font_montserrat_40, LV_PART_MAIN);
}
static void _alert_scale_lbl_cb(void *obj, int32_t v) {
    lv_obj_set_style_text_font((lv_obj_t *)obj,
        v > 127 ? &nanum_korean_28 : &nanum_korean_22, LV_PART_MAIN);
}

static void _alert_start_pulse() {
    lv_anim_init(&alert_anim_sym);
    lv_anim_set_var(&alert_anim_sym, alert_symbol);
    lv_anim_set_exec_cb(&alert_anim_sym, _alert_scale_sym_cb);
    lv_anim_set_values(&alert_anim_sym, 0, 255);
    lv_anim_set_time(&alert_anim_sym, 600);
    lv_anim_set_playback_time(&alert_anim_sym, 600);
    lv_anim_set_repeat_count(&alert_anim_sym, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&alert_anim_sym, lv_anim_path_ease_in_out);
    lv_anim_start(&alert_anim_sym);

    lv_anim_init(&alert_anim_lbl);
    lv_anim_set_var(&alert_anim_lbl, alert_label);
    lv_anim_set_exec_cb(&alert_anim_lbl, _alert_scale_lbl_cb);
    lv_anim_set_values(&alert_anim_lbl, 0, 255);
    lv_anim_set_time(&alert_anim_lbl, 600);
    lv_anim_set_playback_time(&alert_anim_lbl, 600);
    lv_anim_set_repeat_count(&alert_anim_lbl, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&alert_anim_lbl, lv_anim_path_ease_in_out);
    lv_anim_start(&alert_anim_lbl);
}

static void _alert_stop_pulse() {
    if (alert_symbol) lv_anim_delete(alert_symbol, _alert_scale_sym_cb);
    if (alert_label)  lv_anim_delete(alert_label,  _alert_scale_lbl_cb);
}

// ─── Alert 오버레이 표시 — 이벤트 시작 기록 ──────────────────────────────────
void show_alert(int type) {
    if (alert_overlay == nullptr) return;
    _alert_type = type;

    lv_color_t color = (type == ALERT_DROWSY)
        ? lv_color_hex(0xFFB800) : lv_color_hex(0xFF3B30);

    lv_label_set_text(alert_symbol, LV_SYMBOL_WARNING);
    lv_obj_set_style_text_color(alert_symbol, color, LV_PART_MAIN);
    lv_obj_set_style_text_font(alert_symbol, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_obj_set_style_text_color(alert_label, color, LV_PART_MAIN);
    lv_obj_set_style_text_font(alert_label, &nanum_korean_28, LV_PART_MAIN);
    lv_label_set_text(alert_label,
        type == ALERT_DROWSY ? "졸음 감지" : "핸드폰 감지");

    lv_obj_clear_flag(alert_overlay, LV_OBJ_FLAG_HIDDEN);
    _alert_start_pulse();
    Serial.printf("[Alert] %s\n", type == ALERT_DROWSY ? "Drowsy" : "Phone");
}

// ─── Alert 숨김 ──────────────────────────────────────────────────────────────
void hide_alert() {
    if (alert_overlay == nullptr) return;
    _alert_stop_pulse();
    lv_obj_add_flag(alert_overlay, LV_OBJ_FLAG_HIDDEN);
    _alert_type = ALERT_NONE;
    Serial.println("[Alert] 숨김 → 뽀모도로 복귀");
}

// ─── 세션 종료 공통 처리 (타이머 완료 / 강제종료 공용) ───────────────────────
static void _pomo_finish_session(const char *ended_at, int actual_min) {
    int planned_min = (int)(_pomo_totalSec / 60);
    pomo_post_focus_session(_pomo_session_id, _pomo_started_at, ended_at, planned_min, actual_min);
    rtdb_send_state(_pomo_session_id, "pomodoro", "end",
                    planned_min, _pomo_started_at, "", 0);
}

// ─── 뽀모도로 상태 UI 업데이트 ───────────────────────────────────────────────
static void _pomo_update_ui() {
    switch (_pomo_state) {
        case POMO_IDLE:
            lv_obj_clear_flag(pomo_img_tomato,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_btn_25,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_btn_50,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_timer,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_done,   LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_force,    LV_OBJ_FLAG_HIDDEN);
            _pomo_start_anim(POMO_TOMATO_BASE_Y);
            break;

        case POMO_RUNNING:
            lv_obj_clear_flag(pomo_img_tomato,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_label_timer, LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_btn_force,   LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_25,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_50,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_done,   LV_OBJ_FLAG_HIDDEN);
            _pomo_start_anim(POMO_TOMATO_BASE_Y);
            break;

        case POMO_DONE:
            lv_obj_clear_flag(pomo_label_done,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_img_tomato,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_timer, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_25,      LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_50,      LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_force,   LV_OBJ_FLAG_HIDDEN);
            lv_anim_delete(pomo_img_tomato, (lv_anim_exec_xcb_t)lv_obj_set_y);
            break;
    }
}

// ─── 타이머 텍스트 업데이트 ──────────────────────────────────────────────────
static void _pomo_update_timer_label() {
    int m = _pomo_remainSec / 60;
    int s = _pomo_remainSec % 60;
    char buf[8];
    snprintf(buf, sizeof(buf), "%d:%02d", m, s);
    lv_label_set_text(pomo_label_timer, buf);
}

// ─── LVGL 타이머 콜백 ────────────────────────────────────────────────────────
static void pomo_timer_cb(lv_timer_t *timer) {
    if (_pomo_state != POMO_RUNNING) return;
    uint32_t now = millis();
    if (now - _pomo_lastTick < 1000) return;
    _pomo_lastTick = now;
    if (_pomo_remainSec > 0) {
        _pomo_remainSec--;
        _pomo_update_timer_label();
    }
    if (_pomo_remainSec == 0) {
        char ended_at[32];
        get_iso_now(ended_at, sizeof(ended_at));
        int planned_min = (int)(_pomo_totalSec / 60);
        _pomo_finish_session(ended_at, planned_min);  // 자연 완료 — actual = planned

        _pomo_state = POMO_DONE;
        _pomo_update_ui();
        lv_timer_t *rt = lv_timer_create([](lv_timer_t *t) {
            _pomo_state = POMO_IDLE;
            _pomo_session_id[0] = '\0'; _pomo_started_at[0] = '\0';
            _pomo_update_ui();
            lv_timer_delete(t);
        }, 3000, NULL);
        lv_timer_set_repeat_count(rt, 1);
    }
}

// ─── 버튼 콜백 ───────────────────────────────────────────────────────────────
static void _pomo_start(int minutes) {
    gen_session_id(_pomo_session_id, sizeof(_pomo_session_id));
    get_iso_now(_pomo_started_at, sizeof(_pomo_started_at));
    _pomo_state          = POMO_RUNNING;
    _pomo_totalSec       = (uint32_t)(minutes * 60);
    _pomo_remainSec      = _pomo_totalSec;
    _pomo_lastTick       = millis();
    _pomo_update_timer_label();
    _pomo_update_ui();
    rtdb_send_state(_pomo_session_id, "pomodoro", "start",
                    minutes, _pomo_started_at, "", 0);
    Serial.printf("[Pomo] %d분 시작\n", minutes);
}

static void pomo_btn25_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    _pomo_start(25);
}

static void pomo_btn50_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    _pomo_start(50);
}

static void pomo_btn_force_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    char ended_at[32];
    get_iso_now(ended_at, sizeof(ended_at));
    int elapsed_sec = (int)(_pomo_totalSec - _pomo_remainSec);
    int actual_min  = elapsed_sec > 0 ? (int)(elapsed_sec / 60) : 1;
    _pomo_finish_session(ended_at, actual_min);

    _pomo_remainSec = 0;
    _pomo_state     = POMO_DONE;
    _pomo_update_ui();
    Serial.println("[Pomo] 강제 종료");

    lv_timer_t *rt = lv_timer_create([](lv_timer_t *t) {
        _pomo_state = POMO_IDLE;
        _pomo_session_id[0] = '\0'; _pomo_started_at[0] = '\0';
        _pomo_update_ui();
        lv_timer_delete(t);
    }, 3000, NULL);
    lv_timer_set_repeat_count(rt, 1);
}

// ─── 앱→ESP 동기화 (firebase_sync_from_app에서 호출) ─────────────────────────
void pomo_rtdb_sync(const char *state, int duration, const char *started_at,
                    const char *session_id) {
    if (strcmp(state, "start") == 0 && _pomo_state == POMO_IDLE) {
        strlcpy(_pomo_session_id, session_id,  sizeof(_pomo_session_id));
        strlcpy(_pomo_started_at, started_at,  sizeof(_pomo_started_at));
        _pomo_state          = POMO_RUNNING;
        _pomo_totalSec       = (uint32_t)(duration * 60);
        _pomo_remainSec      = _pomo_totalSec;
        _pomo_lastTick       = millis();
        _pomo_update_timer_label();
        _pomo_update_ui();
        Serial.printf("[Pomo] 앱 동기화: %d분 시작\n", duration);

    } else if (strcmp(state, "end") == 0 && _pomo_state == POMO_RUNNING) {
        // 앱이 먼저 종료 → ESP도 종료 (Firestore 기록은 앱이 담당)
        _pomo_state = POMO_DONE;
        _pomo_update_ui();
        lv_timer_t *rt = lv_timer_create([](lv_timer_t *t) {
            _pomo_state = POMO_IDLE;
            _pomo_session_id[0] = '\0'; _pomo_started_at[0] = '\0';
            _pomo_update_ui();
            lv_timer_delete(t);
        }, 3000, NULL);
        lv_timer_set_repeat_count(rt, 1);
        Serial.println("[Pomo] 앱 동기화: 종료");
    }
}

// ─── 뽀모도로 UI 생성 ────────────────────────────────────────────────────────
void create_pomodoro_ui() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // ── 토마토 이미지 ─────────────────────────────────────────────────────────
    pomo_img_tomato = lv_image_create(scr);
    lv_image_set_src(pomo_img_tomato, &tomato);
    lv_image_set_scale(pomo_img_tomato, 102);
    lv_obj_align(pomo_img_tomato, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_y(pomo_img_tomato, POMO_TOMATO_BASE_Y);

    // ── 타이머 텍스트 ─────────────────────────────────────────────────────────
    pomo_label_timer = lv_label_create(scr);
    lv_obj_set_style_text_color(pomo_label_timer, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_text_font(pomo_label_timer, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_label_set_text(pomo_label_timer, "25:00");
    lv_obj_align(pomo_label_timer, LV_ALIGN_CENTER, 0, 80);

    // ── 완료 메시지 ───────────────────────────────────────────────────────────
    pomo_label_done = lv_label_create(scr);
    lv_obj_set_style_text_color(pomo_label_done, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_text_font(pomo_label_done, &nanum_korean_30, LV_PART_MAIN);
    lv_label_set_text(pomo_label_done, "완료!");
    lv_obj_align(pomo_label_done, LV_ALIGN_CENTER, 0, 0);

    // ── 버튼 스타일 ───────────────────────────────────────────────────────────
    static lv_style_t style_btn;
    lv_style_init(&style_btn);
    lv_style_set_bg_color(&style_btn, lv_color_hex(0x1A6FE8));
    lv_style_set_bg_opa(&style_btn, LV_OPA_COVER);
    lv_style_set_radius(&style_btn, 16);
    lv_style_set_border_width(&style_btn, 0);
    lv_style_set_shadow_width(&style_btn, 0);

    static lv_style_t style_btn_pr;
    lv_style_init(&style_btn_pr);
    lv_style_set_bg_color(&style_btn_pr, lv_color_hex(0x1050B0));

    // ── 25분 버튼 ─────────────────────────────────────────────────────────────
    pomo_btn_25 = lv_button_create(scr);
    lv_obj_add_style(pomo_btn_25, &style_btn,    LV_STATE_DEFAULT);
    lv_obj_add_style(pomo_btn_25, &style_btn_pr, LV_STATE_PRESSED);
    lv_obj_set_size(pomo_btn_25, 120, 56);
    lv_obj_align(pomo_btn_25, LV_ALIGN_CENTER, -75, 100);
    lv_obj_t *lbl25 = lv_label_create(pomo_btn_25);
    lv_label_set_text(lbl25, "25");
    lv_obj_set_style_text_color(lbl25, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl25, &lv_font_montserrat_24, LV_PART_MAIN);
    lv_obj_center(lbl25);
    lv_obj_add_event_cb(pomo_btn_25, pomo_btn25_cb, LV_EVENT_CLICKED, NULL);

    // ── 50분 버튼 ─────────────────────────────────────────────────────────────
    pomo_btn_50 = lv_button_create(scr);
    lv_obj_add_style(pomo_btn_50, &style_btn,    LV_STATE_DEFAULT);
    lv_obj_add_style(pomo_btn_50, &style_btn_pr, LV_STATE_PRESSED);
    lv_obj_set_size(pomo_btn_50, 120, 56);
    lv_obj_align(pomo_btn_50, LV_ALIGN_CENTER, 75, 100);
    lv_obj_t *lbl50 = lv_label_create(pomo_btn_50);
    lv_label_set_text(lbl50, "50");
    lv_obj_set_style_text_color(lbl50, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl50, &lv_font_montserrat_24, LV_PART_MAIN);
    lv_obj_center(lbl50);
    lv_obj_add_event_cb(pomo_btn_50, pomo_btn50_cb, LV_EVENT_CLICKED, NULL);

    // ── 강제종료 버튼 (세션 진행 중에 표시) ──────────────────────────────────
    static lv_style_t style_btn_force;
    lv_style_init(&style_btn_force);
    lv_style_set_bg_color(&style_btn_force, lv_color_hex(0xFF6B6B));
    lv_style_set_bg_opa(&style_btn_force, LV_OPA_COVER);
    lv_style_set_radius(&style_btn_force, 12);
    lv_style_set_border_width(&style_btn_force, 0);
    lv_style_set_shadow_width(&style_btn_force, 0);

    pomo_btn_force = lv_button_create(scr);
    lv_obj_add_style(pomo_btn_force, &style_btn_force, LV_STATE_DEFAULT);
    lv_obj_set_size(pomo_btn_force, 120, 44);
    lv_obj_align(pomo_btn_force, LV_ALIGN_CENTER, 0, 160);
    lv_obj_t *lbl_force = lv_label_create(pomo_btn_force);
    lv_label_set_text(lbl_force, "Finish");
    lv_obj_set_style_text_color(lbl_force, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_force, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_center(lbl_force);
    lv_obj_add_event_cb(pomo_btn_force, pomo_btn_force_cb, LV_EVENT_CLICKED, NULL);

    // ── Alert 오버레이 ────────────────────────────────────────────────────────
    alert_overlay = lv_obj_create(scr);
    lv_obj_set_size(alert_overlay, LV_PCT(100), LV_PCT(100));
    lv_obj_align(alert_overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(alert_overlay, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(alert_overlay, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_border_width(alert_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(alert_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(alert_overlay, LV_OBJ_FLAG_SCROLLABLE);

    alert_symbol = lv_label_create(alert_overlay);
    lv_label_set_text(alert_symbol, LV_SYMBOL_WARNING);
    lv_obj_set_style_text_font(alert_symbol, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_obj_set_style_text_color(alert_symbol, lv_color_hex(0xFFB800), LV_PART_MAIN);
    lv_obj_align(alert_symbol, LV_ALIGN_CENTER, 0, -60);

    alert_label = lv_label_create(alert_overlay);
    lv_obj_set_style_text_font(alert_label, &nanum_korean_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(alert_label, lv_color_hex(0xFFB800), LV_PART_MAIN);
    lv_label_set_long_mode(alert_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(alert_label, 300);
    lv_obj_set_style_text_align(alert_label, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align(alert_label, LV_ALIGN_CENTER, 0, 30);
    lv_label_set_text(alert_label, "");

    lv_obj_add_flag(alert_overlay, LV_OBJ_FLAG_HIDDEN);

    // ── 초기 상태 적용 ───────────────────────────────────────────────────────
    _pomo_update_ui();
    lv_timer_create(pomo_timer_cb, 200, NULL);
}
