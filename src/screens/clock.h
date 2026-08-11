#pragma once
#include <Arduino.h>
#include <lvgl.h>

// ─── 배경 그라데이션 이미지 (디더링 적용, banding 방지) ──────────────────────
LV_IMAGE_DECLARE(bg_clock);

// ─── 시계 UI 오브젝트 (업데이트용) ──────────────────────────────────────────
static lv_obj_t *label_time   = nullptr;  // 시 (24시간제)
static lv_obj_t *label_minute = nullptr;  // 분
static lv_obj_t *label_date   = nullptr;
static lv_timer_t *clock_timer = nullptr;  // 타이머 핸들

static const char *const WEEKDAY_NAMES[7] = {
    "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"
};
static const char *const MONTH_NAMES[12] = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
};

// ─── 시계 업데이트 타이머 ────────────────────────────────────────────────────
// 예전에는 __DATE__/__TIME__(컴파일 시각)에 millis()를 더한 소프트 클럭이라
// NTP를 전혀 쓰지 않았다. 표시 시각이 "빌드 시각 + 부팅 후 경과"였고 날짜는
// 빌드 날짜로 고정돼 자정이 지나도 바뀌지 않았다. 이제 실제 시각을 쓴다.
static void clock_timer_cb(lv_timer_t *timer) {
    if (!label_time || !label_minute || !label_date) return;  // 화면 전환 후 보호

    time_t now;
    time(&now);
    if (now < 1000000L) {
        // NTP 미동기화 — 잘못된 시각을 보여주느니 자리표시자를 유지한다.
        // (WiFi가 붙으면 wifi_loop()이 NTP를 맞추고 다음 틱부터 정상 표시)
        lv_label_set_text(label_time,   "--");
        lv_label_set_text(label_minute, "--");
        lv_label_set_text(label_date,   "-- / --");
        return;
    }

    struct tm t;
    localtime_r(&now, &t);   // configTime(9h)로 KST 기준

    // 24시간제, 항상 0 채워서 2자리로 표시
    char hour_buf[4], min_buf[4];
    snprintf(hour_buf, sizeof(hour_buf), "%02d", t.tm_hour);
    snprintf(min_buf,  sizeof(min_buf),  "%02d", t.tm_min);
    lv_label_set_text(label_time, hour_buf);
    lv_label_set_text(label_minute, min_buf);

    char date_buf[32];
    snprintf(date_buf, sizeof(date_buf), "%s, %s %d",
             WEEKDAY_NAMES[t.tm_wday], MONTH_NAMES[t.tm_mon], t.tm_mday);
    lv_label_set_text(label_date, date_buf);
}

// ─── 시계 UI 정지 (화면 전환 시 호출) ───────────────────────────────────────
void stop_clock_ui() {
    if (clock_timer) {
        lv_timer_delete(clock_timer);
        clock_timer = nullptr;
    }
    label_time   = nullptr;
    label_minute = nullptr;
    label_date   = nullptr;
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
    lv_obj_set_style_text_color(label_date, lv_color_hex(0xE5F0FF), LV_PART_MAIN);
    lv_obj_set_style_text_font(label_date, &pretendard_regular_25, LV_PART_MAIN);
    lv_label_set_text(label_date, "-- / --");
    // 날짜 위치 조정
    lv_obj_align(label_date, LV_ALIGN_CENTER, -90, 125);

    // ── 시간 (시/분 세로 배열, 24시간제) ────────────────────────────────────
    label_time = lv_label_create(scr);
    lv_obj_set_style_text_color(label_time, lv_color_hex(0xE5F0FF), LV_PART_MAIN);
    lv_obj_set_style_text_font(label_time, &pretendard_bold_137, LV_PART_MAIN);
    lv_label_set_text(label_time, "--");
    lv_obj_align(label_time, LV_ALIGN_CENTER, -90, -70);

    label_minute = lv_label_create(scr);
    lv_obj_set_style_text_color(label_minute, lv_color_hex(0xE5F0FF), LV_PART_MAIN);
    lv_obj_set_style_text_font(label_minute, &pretendard_bold_137, LV_PART_MAIN);
    lv_label_set_text(label_minute, "--");
    lv_obj_align(label_minute, LV_ALIGN_CENTER, -90, 50);

    // ── 1초마다 시계 갱신 ────────────────────────────────────────────────────
    clock_timer = lv_timer_create(clock_timer_cb, 1000, NULL);
    clock_timer_cb(NULL);  // 즉시 한 번 호출
}