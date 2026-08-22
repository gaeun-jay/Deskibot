#pragma once
#include <Arduino.h>
#include <lvgl.h>
#include "../iso_time.h"

// ─── 토마토 이미지 선언 ───────────────────────────────────────────────────────
LV_IMAGE_DECLARE(tomato);

// ─── 배경 이미지 선언 (선택/실행 화면 · 완료 화면) ────────────────────────────
LV_IMAGE_DECLARE(bg_pomodoro_start);
LV_IMAGE_DECLARE(bg_pomodoro_end);

// ─── 뽀모도로 상태 ───────────────────────────────────────────────────────────
#define POMO_IDLE    0
#define POMO_RUNNING 1
#define POMO_DONE    2
// 자리 비움으로 시스템이 강제 종료한 상태. 진행 화면 레이아웃을 그대로 둔 채
// 회색 스크림만 덮으므로 _pomo_update_ui()에서 별도 배치를 하지 않는다.
#define POMO_AWAY    3

int _pomo_state         = POMO_IDLE;
static uint32_t _pomo_totalSec  = 0;
static uint32_t _pomo_remainSec = 0;
static uint32_t _pomo_lastTick  = 0;

// ─── 백엔드/시간 헬퍼 전방 선언 (나중에 include됨) ──────────────────────────
void get_iso_now(char *buf, size_t len);
bool aws_focus_send(const char *mode, const char *action,
                    int planned_duration_sec, const char *outcome);
// popup.h는 이 파일 뒤에 include된다 — 자리 비움 스크림 제어만 미리 선언한다.
void show_away_notice();
void hide_away_notice();

// ─── 세션 추적 변수 ──────────────────────────────────────────────────────────
static char _pomo_session_id[64] = {};
static char _pomo_started_at[32] = {};

// ─── UI 오브젝트 — 뽀모도로 ──────────────────────────────────────────────────
static lv_obj_t *pomo_bg_start    = nullptr;
static lv_obj_t *pomo_bg_end      = nullptr;
static lv_obj_t *pomo_label_title = nullptr;
static lv_obj_t *pomo_img_tomato  = nullptr;
static lv_obj_t *pomo_label_timer = nullptr;
static lv_obj_t *pomo_label_done  = nullptr;
static lv_obj_t *pomo_btn_25      = nullptr;
static lv_obj_t *pomo_btn_50      = nullptr;
static lv_obj_t *pomo_touch_end   = nullptr;   // 진행 화면 전체를 덮는 투명 종료 영역

#define POMO_DOUBLE_TAP_MS  500
static uint32_t _pomo_last_tap_ms = 0;

static lv_anim_t pomo_anim;

// 시작 화면은 bg_pomodoro_start 아트에 맞춰진 위치라 그대로 두고,
// 진행 화면에서만 제목/토마토를 올린다 — 그대로 두면 제목이 타이머(77pt)와 겹친다.
#define POMO_TOMATO_BASE_Y  -88     // 시작 화면(IDLE)
#define POMO_TOMATO_RUN_Y  -100     // 진행 화면(RUNNING)
#define POMO_TITLE_Y         30     // 시작 화면(IDLE)
#define POMO_TITLE_RUN_Y     22     // 진행 화면(RUNNING)
// 타이머는 RUNNING에서만 보이므로 생성 시점에 한 번만 배치한다.
// 실측 line_height: 제목(bold_46)=35, 타이머(bold_77)=68 → 중심 기준 ±17.5 / ±34.
// 제목 22 → 4.5~39.5, 타이머 94 → 60~128 이므로 둘 사이 간격은 20.5px.
// 종료 버튼(y=160)이 빠지면서 생긴 아래 여백만큼 셋을 같이 30px 내렸다.
#define POMO_TIMER_RUN_Y     94

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

// ─── 세션 종료 공통 처리 (타이머 완료 / 강제종료 공용) ───────────────────────
// outcome이 그대로 focus_sessions.status가 된다. 로그 분석에서 세 경우를
// 구분해야 하므로 종료 경로마다 다른 값을 넘긴다.
//   completed   — 타이머 만료
//   incomplete  — 사용자가 화면을 두 번 탭
//   interrupted — 자리 비움 5분으로 시스템이 종료
static void _pomo_finish_session(const char *ended_at, int actual_min,
                                 const char *outcome) {
    (void)ended_at;
    (void)actual_min;
    aws_focus_send("pomodoro", "end", 0, outcome);
}

// ─── 뽀모도로 상태 UI 업데이트 ───────────────────────────────────────────────
static void _pomo_update_ui() {
    switch (_pomo_state) {
        case POMO_IDLE:
            lv_obj_clear_flag(pomo_bg_start,     LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_bg_end,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_label_title,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_img_tomato,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_btn_25,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_btn_50,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_timer,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_done,   LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_touch_end,     LV_OBJ_FLAG_HIDDEN);
            lv_obj_align(pomo_label_title, LV_ALIGN_CENTER, 0, POMO_TITLE_Y);
            _pomo_start_anim(POMO_TOMATO_BASE_Y);
            break;

        case POMO_RUNNING:
            lv_obj_clear_flag(pomo_bg_start,     LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_bg_end,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_label_title,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_img_tomato,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_label_timer, LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(pomo_touch_end,   LV_OBJ_FLAG_HIDDEN);
            _pomo_last_tap_ms = 0;   // 이전 화면의 탭이 이어지지 않게
            lv_obj_add_flag  (pomo_btn_25,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_50,       LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_done,   LV_OBJ_FLAG_HIDDEN);
            lv_obj_align(pomo_label_title, LV_ALIGN_CENTER, 0, POMO_TITLE_RUN_Y);
            _pomo_start_anim(POMO_TOMATO_RUN_Y);
            break;

        case POMO_DONE:
            // 완료 배경 이미지에 "완료" 글씨가 포함되어 있어 제목/완료 라벨은 숨김
            lv_obj_clear_flag(pomo_bg_end,      LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_bg_start,    LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_title, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_done,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_img_tomato,  LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_label_timer, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_25,      LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_btn_50,      LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag  (pomo_touch_end,   LV_OBJ_FLAG_HIDDEN);
            lv_anim_delete(pomo_img_tomato, (lv_anim_exec_xcb_t)lv_obj_set_y);
            break;

        case POMO_AWAY:
            // 진행 화면을 그대로 남겨 두고 위에 회색 스크림만 덮는다.
            // 배치를 다시 잡으면 사라진 세션 화면이 깜빡이므로 아무것도 옮기지 않고,
            // 이미 종료된 세션이 두 번 탭으로 또 종료되지 않게 터치 영역만 걷는다.
            lv_obj_add_flag(pomo_touch_end, LV_OBJ_FLAG_HIDDEN);
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
        // 자연 완료 — actual = planned
        _pomo_finish_session(ended_at, planned_min, "completed");

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
    if (!aws_focus_send("pomodoro", "start", minutes * 60, nullptr)) return;
    _pomo_session_id[0] = '\0';  // focus_state에서 서버 ID를 받는다.
    get_iso_now(_pomo_started_at, sizeof(_pomo_started_at));
    _pomo_state          = POMO_RUNNING;
    _pomo_totalSec       = (uint32_t)(minutes * 60);
    _pomo_remainSec      = _pomo_totalSec;
    _pomo_lastTick       = millis();
    _pomo_update_timer_label();
    _pomo_update_ui();
    Serial.printf("[Pomo] %d분 시작 요청\n", minutes);
}

static void pomo_btn25_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    _pomo_start(25);
}

static void pomo_btn50_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    _pomo_start(50);
}

// 진행 중 세션의 실제 경과 분. 서버가 actual_duration_sec을 직접 계산하므로
// 로그용이지만, 두 종료 경로가 같은 값을 쓰도록 한 군데로 모은다.
static int _pomo_elapsed_min() {
    int elapsed_sec = (int)(_pomo_totalSec - _pomo_remainSec);
    return elapsed_sec > 0 ? (int)(elapsed_sec / 60) : 1;
}

// 사용자가 화면을 두 번 탭한 강제 종료 — DB에는 incomplete로 남는다.
static void _pomo_force_finish() {
    char ended_at[32];
    get_iso_now(ended_at, sizeof(ended_at));
    _pomo_finish_session(ended_at, _pomo_elapsed_min(), "incomplete");

    _pomo_remainSec = 0;
    _pomo_state     = POMO_DONE;
    _pomo_update_ui();
    Serial.println("[Pomo] 강제 종료 (사용자 두 번 탭) — outcome=incomplete");

    lv_timer_t *rt = lv_timer_create([](lv_timer_t *t) {
        _pomo_state = POMO_IDLE;
        _pomo_session_id[0] = '\0'; _pomo_started_at[0] = '\0';
        _pomo_update_ui();
        lv_timer_delete(t);
    }, 3000, NULL);
    lv_timer_set_repeat_count(rt, 1);
}

// ─── 자리 비움 강제 종료 (RPi가 5분 이상 no person을 보고했을 때) ────────────
// 사용자 조작이 아니라 시스템 종료라 DB에는 interrupted로 남긴다.
// 완료 화면(bg_pomodoro_end)으로 넘기지 않고 진행 화면 위에 스크림만 덮는다 —
// 자리를 비운 사람은 3초짜리 안내를 못 보므로, 돌아와서 탭할 때까지 유지한다.
void pomo_away_finish() {
    if (_pomo_state != POMO_RUNNING) return;
    char ended_at[32];
    get_iso_now(ended_at, sizeof(ended_at));
    _pomo_finish_session(ended_at, _pomo_elapsed_min(), "interrupted");

    _pomo_state = POMO_AWAY;
    _pomo_update_ui();
    show_away_notice();
    Serial.println("[Pomo] 자리 비움 강제 종료 — outcome=interrupted");
}

// 스크림 해제 — 사용자가 돌아와 탭했거나 RPi가 no person 해제를 알려온 경우.
void pomo_away_dismiss() {
    if (_pomo_state != POMO_AWAY) return;
    hide_away_notice();
    _pomo_state = POMO_IDLE;
    _pomo_remainSec = 0;
    _pomo_session_id[0] = '\0'; _pomo_started_at[0] = '\0';
    _pomo_update_ui();
    Serial.println("[Pomo] 자리 비움 안내 해제 → 대기 화면");
}

// 진행 화면을 두 번 연속 탭하면 종료. 버튼을 두지 않아 오탭으로 세션이 끊기면
// 안 되므로, 한 번만 누른 경우는 아무 일도 일어나지 않는다.
static void pomo_double_tap_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    if (_pomo_state != POMO_RUNNING) return;
    const uint32_t now = millis();
    if (_pomo_last_tap_ms && now - _pomo_last_tap_ms <= POMO_DOUBLE_TAP_MS) {
        _pomo_last_tap_ms = 0;
        Serial.println("[Pomo] 두 번 탭 — 종료");
        _pomo_force_finish();
    } else {
        _pomo_last_tap_ms = now;
    }
}

// ─── 서버 focus_state 동기화 ─────────────────────────────────────────────────
void pomo_backend_sync(const char *state, int duration, const char *started_at,
                       const char *session_id) {
    if (session_id[0]) strlcpy(_pomo_session_id, session_id, sizeof(_pomo_session_id));
    if (strcmp(state, "start") == 0 && _pomo_state == POMO_IDLE) {
        // 로컬 버튼으로 시작한 경우는 이미 RUNNING이라 여기 오지 않는다.
        // 여기 오는 건 재부팅·재연결로 서버의 진행 중 세션을 복원하는 경우뿐이므로,
        // started_at 기준 경과 시간을 빼야 한다. 안 빼면 타이머가 처음부터 다시 돌아
        // 정전 복구가 사실상 리셋이 된다.
        strlcpy(_pomo_started_at, started_at,  sizeof(_pomo_started_at));
        _pomo_state          = POMO_RUNNING;
        _pomo_totalSec       = (uint32_t)(duration * 60);
        const uint32_t elapsed = iso_elapsed_sec(started_at);
        // 이미 계획 시간을 넘겼으면 0으로 두고, 다음 타이머 틱이 자연 완료 경로로
        // focus_end를 보내게 한다.
        _pomo_remainSec      = (elapsed >= _pomo_totalSec) ? 0
                                                          : _pomo_totalSec - elapsed;
        _pomo_lastTick       = millis();
        _pomo_update_timer_label();
        _pomo_update_ui();
        Serial.printf("[Pomo] 서버 세션 복원: %d분 중 %us 경과 → 남은 %us\n",
                      duration, (unsigned)elapsed, (unsigned)_pomo_remainSec);

    } else if (strcmp(state, "end") == 0 && _pomo_state == POMO_RUNNING) {
        // 앱이 먼저 종료 → ESP도 종료 (세션 기록은 서버가 담당)
        _pomo_state = POMO_DONE;
        _pomo_update_ui();
        lv_timer_t *rt = lv_timer_create([](lv_timer_t *t) {
            _pomo_state = POMO_IDLE;
            _pomo_session_id[0] = '\0'; _pomo_started_at[0] = '\0';
            _pomo_update_ui();
            lv_timer_delete(t);
        }, 3000, NULL);
        lv_timer_set_repeat_count(rt, 1);
        Serial.println("[Pomo] 서버 동기화: 종료");
    }
}

// ─── 뽀모도로 UI 생성 ────────────────────────────────────────────────────────
void create_pomodoro_ui() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // 배경 이미지 (선택/실행 화면 · 완료 화면) — 상태에 따라 토글
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x112038), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    pomo_bg_start = lv_image_create(scr);
    lv_image_set_src(pomo_bg_start, &bg_pomodoro_start);
    lv_obj_align(pomo_bg_start, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_clear_flag(pomo_bg_start, LV_OBJ_FLAG_CLICKABLE);

    pomo_bg_end = lv_image_create(scr);
    lv_image_set_src(pomo_bg_end, &bg_pomodoro_end);
    lv_obj_align(pomo_bg_end, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_clear_flag(pomo_bg_end, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(pomo_bg_end, LV_OBJ_FLAG_HIDDEN);

    // ── 제목 ─────────────────────────────────────────────────────────────────
    pomo_label_title = lv_label_create(scr);
    lv_obj_set_style_text_color(pomo_label_title, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(pomo_label_title, &pretendard_bold_46, LV_PART_MAIN);
    lv_label_set_text(pomo_label_title, "뽀모도로");
    lv_obj_align(pomo_label_title, LV_ALIGN_CENTER, 0, 30);

    // ── 토마토 이미지 ─────────────────────────────────────────────────────────
    pomo_img_tomato = lv_image_create(scr);
    lv_image_set_src(pomo_img_tomato, &tomato);
    lv_image_set_scale(pomo_img_tomato, 130);
    lv_obj_align(pomo_img_tomato, LV_ALIGN_CENTER, 0, -100);
    lv_obj_set_y(pomo_img_tomato, POMO_TOMATO_BASE_Y);

    // ── 타이머 텍스트 ─────────────────────────────────────────────────────────
    pomo_label_timer = lv_label_create(scr);
    lv_obj_set_style_text_color(pomo_label_timer, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(pomo_label_timer, &pretendard_bold_77, LV_PART_MAIN);
    lv_label_set_text(pomo_label_timer, "25:00");
    lv_obj_align(pomo_label_timer, LV_ALIGN_CENTER, 0, POMO_TIMER_RUN_Y);

    // ── 완료 메시지 ───────────────────────────────────────────────────────────
    pomo_label_done = lv_label_create(scr);
    lv_obj_set_style_text_color(pomo_label_done, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_text_font(pomo_label_done, &pretendard_bold_77, LV_PART_MAIN);
    lv_label_set_text(pomo_label_done, "완료!");
    lv_obj_align(pomo_label_done, LV_ALIGN_CENTER, 0, 0);

    // ── 버튼 스타일 ───────────────────────────────────────────────────────────
    static lv_style_t style_btn;
    lv_style_init(&style_btn);
    lv_style_set_bg_color(&style_btn, lv_color_hex(0x3A496B));
    lv_style_set_bg_opa(&style_btn, LV_OPA_COVER);
    lv_style_set_radius(&style_btn, LV_RADIUS_CIRCLE);  // 첨부 시안처럼 캡슐형 버튼
    lv_style_set_border_width(&style_btn, 0);
    lv_style_set_shadow_width(&style_btn, 0);

    static lv_style_t style_btn_pr;
    lv_style_init(&style_btn_pr);
    lv_style_set_bg_color(&style_btn_pr, lv_color_hex(0x2C3854));

    // ── 25분 버튼 ─────────────────────────────────────────────────────────────
    pomo_btn_25 = lv_button_create(scr);
    lv_obj_add_style(pomo_btn_25, &style_btn,    LV_STATE_DEFAULT);
    lv_obj_add_style(pomo_btn_25, &style_btn_pr, LV_STATE_PRESSED);
    lv_obj_set_size(pomo_btn_25, 126, 64);
    lv_obj_align(pomo_btn_25, LV_ALIGN_CENTER, -75, 110);
    lv_obj_t *lbl25 = lv_label_create(pomo_btn_25);
    lv_label_set_text(lbl25, "25분");
    lv_obj_set_style_text_color(lbl25, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl25, &pretendard_bold_35, LV_PART_MAIN);
    lv_obj_center(lbl25);
    lv_obj_add_event_cb(pomo_btn_25, pomo_btn25_cb, LV_EVENT_CLICKED, NULL);

    // ── 50분 버튼 ─────────────────────────────────────────────────────────────
    pomo_btn_50 = lv_button_create(scr);
    lv_obj_add_style(pomo_btn_50, &style_btn,    LV_STATE_DEFAULT);
    lv_obj_add_style(pomo_btn_50, &style_btn_pr, LV_STATE_PRESSED);
    lv_obj_set_size(pomo_btn_50, 126, 64);
    lv_obj_align(pomo_btn_50, LV_ALIGN_CENTER, 75, 110);
    lv_obj_t *lbl50 = lv_label_create(pomo_btn_50);
    lv_label_set_text(lbl50, "50분");
    lv_obj_set_style_text_color(lbl50, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl50, &pretendard_bold_35, LV_PART_MAIN);
    lv_obj_center(lbl50);
    lv_obj_add_event_cb(pomo_btn_50, pomo_btn50_cb, LV_EVENT_CLICKED, NULL);

    // ── 강제종료 버튼 (세션 진행 중에 표시) ──────────────────────────────────
    // 미관상 종료 버튼을 두지 않고, 진행 화면 전체를 두 번 탭하면 종료한다.
    // 화면 객체(scr)에 콜백을 직접 붙이면 switch_screen()의 lv_obj_clean()이 자식만
    // 지우고 콜백은 남겨 다른 화면에서도 동작하므로, 반드시 자식으로 만든다.
    pomo_touch_end = lv_obj_create(scr);
    lv_obj_remove_style_all(pomo_touch_end);
    lv_obj_set_size(pomo_touch_end, LV_PCT(100), LV_PCT(100));
    lv_obj_center(pomo_touch_end);
    lv_obj_add_flag(pomo_touch_end, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(pomo_touch_end, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(pomo_touch_end, pomo_double_tap_cb, LV_EVENT_CLICKED, NULL);

    // ── 초기 상태 적용 ───────────────────────────────────────────────────────
    _pomo_update_ui();
    lv_timer_create(pomo_timer_cb, 200, NULL);
}
