#pragma once
#include <Arduino.h>
#include <lvgl.h>
#include "../iso_time.h"
#include <time.h>

// ─── 일시정지 이벤트 구조체 (firebase_handler.h의 _build_pause_json에서 사용) ─
struct PauseEvent {
    char paused_at[32];   // ISO 8601 — 일시정지 시작
    char resumed_at[32];  // ISO 8601 — 재개 / 종료 시
};

// ─── 백엔드/시간 헬퍼 전방 선언 (나중에 include됨) ──────────────────────────
void get_iso_now(char *buf, size_t len);
bool aws_focus_send(const char *mode, const char *action,
                    int planned_duration_sec);

// ─── 스톱워치 상태 ───────────────────────────────────────────────────────────
#define SW_IDLE    0
#define SW_RUNNING 1
#define SW_PAUSED  2

int _sw_state = SW_IDLE;
static uint32_t _sw_startMs   = 0;
static uint32_t _sw_elapsedMs = 0;

// ─── 세션 추적 변수 ──────────────────────────────────────────────────────────
static char     _sw_session_id[64]     = {};  // 서버가 focus_state로 반환한 ID
static char     _sw_started_at[32]     = {};  // 세션 시작 ISO
static char     _sw_paused_at[32]      = {};  // 현재 일시정지 시작 ISO (재개/종료 시 "")
static uint32_t _sw_pause_start_ms     = 0;   // 일시정지 시작 millis
static int      _sw_total_pause_sec    = 0;   // 누적 정지 시간(초)
static PauseEvent _sw_pause_events[10] = {};  // 일시정지 이벤트 배열
static int      _sw_pause_event_count  = 0;   // 배열 크기

// ─── UI 오브젝트 ─────────────────────────────────────────────────────────────
static lv_obj_t *sw_label_min   = nullptr;
static lv_obj_t *sw_label_colon = nullptr;
static lv_obj_t *sw_label_sec   = nullptr;
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
    uint32_t sec      = totalSec % 60;
    uint32_t min      = totalSec / 60;
    char min_buf[6], sec_buf[4];
    snprintf(min_buf, sizeof(min_buf), "%d", (int)min);
    snprintf(sec_buf, sizeof(sec_buf), "%02d", (int)sec);
    lv_label_set_text(sw_label_min, min_buf);
    lv_label_set_text(sw_label_sec, sec_buf);
    // 분 자릿수가 바뀌면 폭이 변하므로 콜론/초 위치를 매번 재정렬
    lv_obj_align_to(sw_label_colon, sw_label_min, LV_ALIGN_OUT_RIGHT_MID, 4, 2);
    lv_obj_align_to(sw_label_sec,   sw_label_colon, LV_ALIGN_OUT_RIGHT_MID, 4, -2);
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
        if (!aws_focus_send("stopwatch", "start", 0)) return;
        _sw_session_id[0] = '\0';  // focus_state에서 서버 ID를 받는다.
        get_iso_now(_sw_started_at, sizeof(_sw_started_at));
        _sw_state              = SW_RUNNING;
        _sw_startMs            = millis();
        _sw_elapsedMs          = 0;
        _sw_total_pause_sec    = 0;
        _sw_pause_event_count  = 0;
        _sw_paused_at[0]       = '\0';
        Serial.println("[SW] 시작 요청");

    } else if (_sw_state == SW_PAUSED) {
        // ── resume ───────────────────────────────────────────────────────────
        if (!aws_focus_send("stopwatch", "resume", 0)) return;
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
    }
    _sw_update_buttons();
}

static void sw_btn_pause_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    if (_sw_state != SW_RUNNING) return;
    if (!aws_focus_send("stopwatch", "pause", 0)) return;

    // ── pause ─────────────────────────────────────────────────────────────
    _sw_elapsedMs      = millis() - _sw_startMs;
    _sw_pause_start_ms = millis();
    _sw_state          = SW_PAUSED;
    get_iso_now(_sw_paused_at, sizeof(_sw_paused_at));

    // 일시정지 이벤트 시작 기록 (resumed_at은 재개 시 채움)
    if (_sw_pause_event_count < 10)
        strlcpy(_sw_pause_events[_sw_pause_event_count].paused_at, _sw_paused_at, 32);

    _sw_update_time();
    _sw_update_buttons();
    Serial.printf("[SW] 일시정지 — slot=%d paused_at=%s\n",
                  _sw_pause_event_count, _sw_paused_at);
}

static void sw_btn_stop_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    if (!aws_focus_send("stopwatch", "end", 0)) return;

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

// ─── 서버 focus_state 동기화 ─────────────────────────────────────────────────
void sw_backend_sync(const char *state, const char *started_at, const char *paused_at,
                     int total_pause_sec, const char *session_id) {
    if (session_id[0]) strlcpy(_sw_session_id, session_id, sizeof(_sw_session_id));

    // ── 재부팅·재연결 복원 ───────────────────────────────────────────────────
    // 아래 분기들은 상태 '전이'만 다뤄서 pause는 SW_RUNNING에서만 받는다. 그래서
    // 일시정지 중 재부팅하면 부팅 직후 SW_IDLE이라 복원이 통째로 무시됐고, 서버엔
    // 세션이 그대로 남아 새 집중을 시작하면 서버가 거부했다. 절대 상태로 복원한다.
    if (_sw_state == SW_IDLE && strcmp(state, "pause") == 0) {
        time_t started = 0, paused_epoch = 0, now = 0;
        if (!iso_to_epoch(started_at, started) || !iso_now_epoch(now)) {
            Serial.println("[SW] 서버 세션 복원 실패 — 시각 정보 없음");
            return;
        }
        if (!iso_to_epoch(paused_at, paused_epoch)) paused_epoch = now;

        long run = (long)paused_epoch - (long)started - total_pause_sec;
        if (run < 0) run = 0;

        strlcpy(_sw_started_at, started_at, sizeof(_sw_started_at));
        strlcpy(_sw_paused_at, paused_at[0] ? paused_at : "", sizeof(_sw_paused_at));
        _sw_state             = SW_PAUSED;
        _sw_elapsedMs         = (uint32_t)run * 1000u;
        _sw_total_pause_sec   = total_pause_sec;
        _sw_pause_event_count = 0;   // 지난 이벤트는 서버가 갖고 있다(로컬은 로그용)
        // 부팅 직후 millis()가 작아 언더플로가 나지만, 이후 millis() - _sw_pause_start_ms
        // 모듈러 연산으로 올바른 차이가 나온다(_sw_startMs와 같은 방식).
        _sw_pause_start_ms = millis() - (uint32_t)((long)now - (long)paused_epoch) * 1000u;
        _sw_update_time();
        _sw_update_buttons();
        Serial.printf("[SW] 서버 세션 복원: 일시정지 (경과 %lds, 누적정지 %ds)\n",
                      run, total_pause_sec);
        return;
    }

    if (strcmp(state, "start") == 0 && _sw_state == SW_IDLE) {
        // 로컬 버튼으로 시작하면 이미 SW_RUNNING이라 여기 오지 않는다.
        // 여기 오는 건 진행 중 세션을 복원하는 경우뿐이므로 경과 시간을 살려야 한다.
        long run = 0;
        time_t started = 0, now = 0;
        if (iso_to_epoch(started_at, started) && iso_now_epoch(now)) {
            run = (long)now - (long)started - total_pause_sec;
            if (run < 0) run = 0;
        }
        strlcpy(_sw_started_at,  started_at,  sizeof(_sw_started_at));
        _sw_state             = SW_RUNNING;
        _sw_elapsedMs         = (uint32_t)run * 1000u;
        _sw_startMs           = millis() - _sw_elapsedMs;
        _sw_total_pause_sec   = total_pause_sec;
        _sw_pause_event_count = 0;
        _sw_paused_at[0]      = '\0';
        _sw_update_time();
        _sw_update_buttons();
        Serial.printf("[SW] 서버 세션 복원: 진행중 (경과 %lds, 누적정지 %ds)\n",
                      run, total_pause_sec);

    } else if (strcmp(state, "pause") == 0 && _sw_state == SW_RUNNING) {
        _sw_elapsedMs      = millis() - _sw_startMs;
        _sw_pause_start_ms = millis();
        _sw_state          = SW_PAUSED;
        strlcpy(_sw_paused_at, paused_at[0] ? paused_at : "", sizeof(_sw_paused_at));
        if (_sw_pause_event_count < 10)
            strlcpy(_sw_pause_events[_sw_pause_event_count].paused_at, _sw_paused_at, 32);
        _sw_update_time();
        _sw_update_buttons();
        Serial.println("[SW] 서버 동기화: 일시정지");

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
        Serial.println("[SW] 서버 동기화: 재개");

    } else if (strcmp(state, "end") == 0 && _sw_state != SW_IDLE) {
        char ended_at[32]; get_iso_now(ended_at, sizeof(ended_at));
        if (_sw_state == SW_PAUSED) {
            _sw_total_pause_sec += (int)((millis() - _sw_pause_start_ms) / 1000);
            if (_sw_pause_event_count < 10) {
                strlcpy(_sw_pause_events[_sw_pause_event_count].resumed_at, ended_at, 32);
                _sw_pause_event_count++;
            }
        }
        _sw_state             = SW_IDLE;
        _sw_elapsedMs         = 0;
        _sw_total_pause_sec   = 0;
        _sw_pause_event_count = 0;
        _sw_started_at[0]     = '\0';
        _sw_paused_at[0]      = '\0';
        _sw_session_id[0]     = '\0';
        _sw_update_time();
        _sw_update_buttons();
        Serial.println("[SW] 서버 동기화: 종료");
    }
}

// ─── 스톱워치 UI 생성 ────────────────────────────────────────────────────────
void create_stopwatch_ui() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x112038), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // ── 제목 ─────────────────────────────────────────────────────────────────
    lv_obj_t *sw_label_title = lv_label_create(scr);
    lv_obj_set_style_text_color(sw_label_title, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(sw_label_title, &pretendard_medium_23, LV_PART_MAIN);
    lv_label_set_text(sw_label_title, "스톱워치");
    lv_obj_align(sw_label_title, LV_ALIGN_CENTER, 0, -160);

    // ── 타이머 텍스트 (분:초, 콜론만 큰 폰트) ──────────────────────────────────
    sw_label_min = lv_label_create(scr);
    lv_obj_set_style_text_color(sw_label_min, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(sw_label_min, &pretendard_semibold_81, LV_PART_MAIN);
    lv_label_set_text(sw_label_min, "0");
    lv_obj_align(sw_label_min, LV_ALIGN_CENTER, -60, -40);

    sw_label_colon = lv_label_create(scr);
    lv_obj_set_style_text_color(sw_label_colon, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(sw_label_colon, &pretendard_semibold_85, LV_PART_MAIN);
    lv_label_set_text(sw_label_colon, ":");
    lv_obj_align_to(sw_label_colon, sw_label_min, LV_ALIGN_OUT_RIGHT_MID, 4, 2);

    sw_label_sec = lv_label_create(scr);
    lv_obj_set_style_text_color(sw_label_sec, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(sw_label_sec, &pretendard_semibold_81, LV_PART_MAIN);
    lv_label_set_text(sw_label_sec, "00");
    lv_obj_align_to(sw_label_sec, sw_label_colon, LV_ALIGN_OUT_RIGHT_MID, 4, -2);

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
