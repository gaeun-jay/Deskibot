#pragma once
#include <Arduino.h>
#include <lvgl.h>

// ─── UI 오브젝트 ─────────────────────────────────────────────────────────────
static lv_obj_t *dl_overlay  = nullptr;
static lv_obj_t *dl_symbol   = nullptr;
static lv_obj_t *dl_title    = nullptr;
static lv_obj_t *dl_time     = nullptr;
static lv_obj_t *dl_left     = nullptr;
static lv_obj_t *dl_btn_ok   = nullptr;

// ─── deadline 숨김 ───────────────────────────────────────────────────────────
void hide_deadline() {
    if (dl_overlay == nullptr) return;
    lv_obj_del(dl_overlay);
    dl_overlay = nullptr;
    dl_symbol  = nullptr;
    dl_title   = nullptr;
    dl_time    = nullptr;
    dl_left    = nullptr;
    dl_btn_ok  = nullptr;
    Serial.println("[Deadline] 닫힘");
}

// ─── OK 버튼 콜백 ────────────────────────────────────────────────────────────
static void _dl_ok_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    hide_deadline();
}

// ─── deadline 표시 ───────────────────────────────────────────────────────────
void show_deadline(const char *time_str, const char *title_str, const char *left_str) {
    if (dl_overlay) hide_deadline();

    // 원형 팝업 (320×320)
    dl_overlay = lv_obj_create(lv_layer_top());
    lv_obj_set_size(dl_overlay, 320, 320);
    lv_obj_align(dl_overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(dl_overlay, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(dl_overlay, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(dl_overlay, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_set_style_border_color(dl_overlay, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_border_width(dl_overlay, 3, LV_PART_MAIN);
    lv_obj_set_style_shadow_width(dl_overlay, 30, LV_PART_MAIN);
    lv_obj_set_style_shadow_color(dl_overlay, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_shadow_opa(dl_overlay, LV_OPA_30, LV_PART_MAIN);
    lv_obj_set_style_pad_all(dl_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(dl_overlay, LV_OBJ_FLAG_SCROLLABLE);

    // ── 벨 심볼 ──────────────────────────────────────────────────────────────
    dl_symbol = lv_label_create(dl_overlay);
    lv_label_set_text(dl_symbol, LV_SYMBOL_BELL);
    lv_obj_set_style_text_font(dl_symbol, &lv_font_montserrat_30, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_symbol, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_align(dl_symbol, LV_ALIGN_TOP_MID, 0, 28);

    // ── 할 일 제목 ────────────────────────────────────────────────────────────
    dl_title = lv_label_create(dl_overlay);
    lv_label_set_text(dl_title, title_str);
    lv_obj_set_style_text_font(dl_title, &nanum_korean_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_title, lv_color_black(), LV_PART_MAIN);
    lv_label_set_long_mode(dl_title, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(dl_title, 210);
    lv_obj_set_style_text_align(dl_title, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align(dl_title, LV_ALIGN_TOP_MID, 0, 85);

    // ── 마감 시각 ─────────────────────────────────────────────────────────────
    dl_time = lv_label_create(dl_overlay);
    lv_label_set_text(dl_time, time_str);
    lv_obj_set_style_text_font(dl_time, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_time, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_align(dl_time, LV_ALIGN_TOP_MID, 0, 160);

    // ── 남은 시간 ─────────────────────────────────────────────────────────────
    dl_left = lv_label_create(dl_overlay);
    char left_buf[48];
    snprintf(left_buf, sizeof(left_buf), "남은 시간 %s", left_str);
    lv_label_set_text(dl_left, left_buf);
    lv_obj_set_style_text_font(dl_left, &nanum_korean_22, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_left, lv_color_hex(0xAAAAAA), LV_PART_MAIN);
    lv_obj_align(dl_left, LV_ALIGN_TOP_MID, 0, 193);

    // ── 확인 버튼 ─────────────────────────────────────────────────────────────
    static lv_style_t style_ok;
    lv_style_init(&style_ok);
    lv_style_set_bg_color(&style_ok, lv_color_hex(0x1A6FE8));
    lv_style_set_bg_opa(&style_ok, LV_OPA_COVER);
    lv_style_set_radius(&style_ok, 20);
    lv_style_set_border_width(&style_ok, 0);
    lv_style_set_shadow_width(&style_ok, 0);

    static lv_style_t style_ok_pr;
    lv_style_init(&style_ok_pr);
    lv_style_set_bg_color(&style_ok_pr, lv_color_hex(0x1050B0));

    dl_btn_ok = lv_button_create(dl_overlay);
    lv_obj_add_style(dl_btn_ok, &style_ok, LV_STATE_DEFAULT);
    lv_obj_add_style(dl_btn_ok, &style_ok_pr, LV_STATE_PRESSED);
    lv_obj_set_size(dl_btn_ok, 140, 42);
    lv_obj_align(dl_btn_ok, LV_ALIGN_CENTER, 0, 70);
    lv_obj_t *lbl_ok = lv_label_create(dl_btn_ok);
    lv_label_set_text(lbl_ok, "확인");
    lv_obj_set_style_text_color(lbl_ok, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_ok, &nanum_korean_22, LV_PART_MAIN);
    lv_obj_center(lbl_ok);
    lv_obj_add_event_cb(dl_btn_ok, _dl_ok_cb, LV_EVENT_CLICKED, NULL);

    Serial.printf("[Deadline] %s | %s | left: %s\n", title_str, time_str, left_str);
}
