#pragma once
#include <Arduino.h>
#include <lvgl.h>

// ─── 배경 그라데이션 이미지 (디더링 적용, banding 방지) ──────────────────────
LV_IMAGE_DECLARE(bg_clock);

// ─── 시계 UI 오브젝트 (업데이트용) ──────────────────────────────────────────
static lv_obj_t *label_time  = nullptr;
static lv_obj_t *label_date  = nullptr;
static lv_obj_t *label_ampm  = nullptr;
static lv_timer_t *clock_timer = nullptr;  // 타이머 핸들

// ─── 빌드 시각 기반 소프트 클럭 ─────────────────────────────────────────────
static uint32_t _base_seconds = 0;
static uint32_t _base_millis  = 0;
static int _build_month = 1;
static int _build_day   = 1;
static int _build_wday  = 0;  // 0=SUN ... 6=SAT

static const char *const WEEKDAY_NAMES[7] = {
    "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"
};
static const char *const MONTH_NAMES[12] = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
};

static int _month_num_from_str(const char *m) {
    if (!strncmp(m, "Jan", 3)) return 1;
    if (!strncmp(m, "Feb", 3)) return 2;
    if (!strncmp(m, "Mar", 3)) return 3;
    if (!strncmp(m, "Apr", 3)) return 4;
    if (!strncmp(m, "May", 3)) return 5;
    if (!strncmp(m, "Jun", 3)) return 6;
    if (!strncmp(m, "Jul", 3)) return 7;
    if (!strncmp(m, "Aug", 3)) return 8;
    if (!strncmp(m, "Sep", 3)) return 9;
    if (!strncmp(m, "Oct", 3)) return 10;
    if (!strncmp(m, "Nov", 3)) return 11;
    return 12;
}

// Sakamoto's algorithm — 0=Sunday ... 6=Saturday
static int _day_of_week(int y, int m, int d) {
    static const int t[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    if (m < 3) y -= 1;
    return (y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7;
}

void init_clock() {
    char mon[4] = {__DATE__[0], __DATE__[1], __DATE__[2], 0};
    _build_month = _month_num_from_str(mon);
    _build_day   = atoi(__DATE__ + 4);
    int build_year = atoi(__DATE__ + 7);
    _build_wday  = _day_of_week(build_year, _build_month, _build_day);
    int h = (__TIME__[0]-'0')*10 + (__TIME__[1]-'0');
    int m = (__TIME__[3]-'0')*10 + (__TIME__[4]-'0');
    int s = (__TIME__[6]-'0')*10 + (__TIME__[7]-'0');
    _base_seconds = (uint32_t)h*3600UL + (uint32_t)m*60UL + s;
    _base_millis  = millis();
}

static uint32_t now_seconds() {
    return (_base_seconds + (millis() - _base_millis) / 1000UL) % 86400UL;
}

// ─── 시계 업데이트 타이머 ────────────────────────────────────────────────────
static void clock_timer_cb(lv_timer_t *timer) {
    if (!label_time || !label_date || !label_ampm) return;  // 화면 전환 후 보호
    uint32_t sec = now_seconds();
    int hour24   = sec / 3600UL;
    int minute   = (sec / 60UL) % 60;
    int hour12   = hour24 % 12;
    if (hour12 == 0) hour12 = 12;

    // 콜론 없이 시:분 사이 여백으로 구분 (139px 숫자 전용 폰트라 ':' 글리프 없음)
    char time_buf[10];
    snprintf(time_buf, sizeof(time_buf), "%d  %02d", hour12, minute);
    lv_label_set_text(label_time, time_buf);
    lv_label_set_text(label_ampm, hour24 >= 12 ? "PM" : "AM");

    char date_buf[32];
    snprintf(date_buf, sizeof(date_buf), "%s, %s %d",
             WEEKDAY_NAMES[_build_wday], MONTH_NAMES[_build_month - 1], _build_day);
    lv_label_set_text(label_date, date_buf);
}

// ─── 시계 UI 정지 (화면 전환 시 호출) ───────────────────────────────────────
void stop_clock_ui() {
    if (clock_timer) {
        lv_timer_delete(clock_timer);
        clock_timer = nullptr;
    }
    label_time = nullptr;
    label_date = nullptr;
    label_ampm = nullptr;
}

// ─── 시계 UI 생성 ────────────────────────────────────────────────────────────
void create_clock_ui() {
    lv_obj_t *scr = lv_scr_act();

    // 위(진한 남색) → 아래(거의 검정) 세로 그라데이션 배경 (디더링된 이미지 — banding 없음)
    lv_obj_t *bg = lv_image_create(scr);
    lv_image_set_src(bg, &bg_clock);
    lv_obj_align(bg, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_clear_flag(bg, LV_OBJ_FLAG_CLICKABLE);

    // ── 날짜 ─────────────────────────────────────────────────────────────────
    label_date = lv_label_create(scr);
    lv_obj_set_style_text_color(label_date, lv_color_hex(0xA0AAB8), LV_PART_MAIN);
    lv_obj_set_style_text_font(label_date, &pretendard_regular_23, LV_PART_MAIN);
    lv_label_set_text(label_date, "-- / --");
    // 날짜 위치 조정
    lv_obj_align(label_date, LV_ALIGN_CENTER, 0, -60);

    // ── 시간 ─────────────────────────────────────────────────────────────────
    label_time = lv_label_create(scr);
    lv_obj_set_style_text_color(label_time, lv_color_white(), LV_PART_MAIN);
    // 시간 폰트 설정
    lv_obj_set_style_text_font(label_time, &pretendard_bold_139, LV_PART_MAIN);
    lv_label_set_text(label_time, "--:--");
    // 시간 위치 조정
    lv_obj_align(label_time, LV_ALIGN_CENTER, -30, 40);

    // ── AM/PM ─────────────────────────────────────────────────────────────────
    label_ampm = lv_label_create(scr);
    lv_obj_set_style_text_color(label_ampm, lv_color_hex(0xA0AAB8), LV_PART_MAIN);
    // AM/PM 폰트 설정
    lv_obj_set_style_text_font(label_ampm, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_label_set_text(label_ampm, "--");
    // AM/PM 위치 조정 (시간 오른쪽 아래)
    lv_obj_align_to(label_ampm, label_time, LV_ALIGN_OUT_RIGHT_BOTTOM, 15, -10);

    // ── 1초마다 시계 갱신 ────────────────────────────────────────────────────
    clock_timer = lv_timer_create(clock_timer_cb, 1000, NULL);
    clock_timer_cb(NULL);  // 즉시 한 번 호출
}