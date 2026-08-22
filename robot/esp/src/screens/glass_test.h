#pragma once
#include <Arduino.h>
#include <lvgl.h>

// ─── Glass Effect 테스트 화면 ─────────────────────────────────────────────────
// 화면 1: 파란색 배경 + 투명 버튼
// 화면 2: 흰색 배경 + 하늘색 투명 버튼
// 스와이프 좌우로 전환

static int _glass_current = 0;  // 0: 파란 배경, 1: 흰색 배경

// ─── 스와이프 콜백 ───────────────────────────────────────────────────────────
static void _glass_swipe_cb(lv_event_t *e);

// ─── 화면 1: 파란색 배경 + 투명 흰색 버튼 ───────────────────────────────────
static void _create_glass_screen1() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // 파란색 배경
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // 배경 장식용 원 (glass 느낌 강화)
    lv_obj_t *circle1 = lv_obj_create(scr);
    lv_obj_set_size(circle1, 200, 200);
    lv_obj_align(circle1, LV_ALIGN_TOP_LEFT, -60, -60);
    lv_obj_set_style_bg_color(circle1, lv_color_hex(0x4A9FFF), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(circle1, LV_OPA_40, LV_PART_MAIN);
    lv_obj_set_style_border_width(circle1, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(circle1, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_clear_flag(circle1, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *circle2 = lv_obj_create(scr);
    lv_obj_set_size(circle2, 160, 160);
    lv_obj_align(circle2, LV_ALIGN_BOTTOM_RIGHT, 40, 40);
    lv_obj_set_style_bg_color(circle2, lv_color_hex(0x0050C0), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(circle2, LV_OPA_50, LV_PART_MAIN);
    lv_obj_set_style_border_width(circle2, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(circle2, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_clear_flag(circle2, LV_OBJ_FLAG_SCROLLABLE);

    // ── Glass 버튼 스타일 (투명 흰색) ────────────────────────────────────────
    static lv_style_t style_glass1;
    lv_style_init(&style_glass1);
    lv_style_set_bg_color(&style_glass1, lv_color_white());
    lv_style_set_bg_opa(&style_glass1, LV_OPA_20);
    lv_style_set_border_color(&style_glass1, lv_color_white());
    lv_style_set_border_width(&style_glass1, 1);
    lv_style_set_border_opa(&style_glass1, LV_OPA_60);
    lv_style_set_radius(&style_glass1, 20);
    lv_style_set_shadow_color(&style_glass1, lv_color_white());
    lv_style_set_shadow_width(&style_glass1, 12);
    lv_style_set_shadow_opa(&style_glass1, LV_OPA_20);

    static lv_style_t style_glass1_pr;
    lv_style_init(&style_glass1_pr);
    lv_style_set_bg_opa(&style_glass1_pr, LV_OPA_40);

    // ── 버튼 1 ────────────────────────────────────────────────────────────────
    lv_obj_t *btn1 = lv_button_create(scr);
    lv_obj_add_style(btn1, &style_glass1, LV_STATE_DEFAULT);
    lv_obj_add_style(btn1, &style_glass1_pr, LV_STATE_PRESSED);
    lv_obj_set_size(btn1, 200, 60);
    lv_obj_align(btn1, LV_ALIGN_CENTER, 0, -50);
    lv_obj_t *lbl1 = lv_label_create(btn1);
    lv_label_set_text(lbl1, "Glass Button 1");
    lv_obj_set_style_text_color(lbl1, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl1, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_center(lbl1);

    // ── 버튼 2 ────────────────────────────────────────────────────────────────
    lv_obj_t *btn2 = lv_button_create(scr);
    lv_obj_add_style(btn2, &style_glass1, LV_STATE_DEFAULT);
    lv_obj_add_style(btn2, &style_glass1_pr, LV_STATE_PRESSED);
    lv_obj_set_size(btn2, 200, 60);
    lv_obj_align(btn2, LV_ALIGN_CENTER, 0, 50);
    lv_obj_t *lbl2 = lv_label_create(btn2);
    lv_label_set_text(lbl2, "Glass Button 2");
    lv_obj_set_style_text_color(lbl2, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl2, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_center(lbl2);

    // 안내 텍스트
    lv_obj_t *hint = lv_label_create(scr);
    lv_label_set_text(hint, "← swipe →");
    lv_obj_set_style_text_color(hint, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_opa(hint, LV_OPA_50, LV_PART_MAIN);
    lv_obj_set_style_text_font(hint, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(hint, LV_ALIGN_BOTTOM_MID, 0, -20);

    // 스와이프 이벤트
    lv_obj_add_event_cb(scr, _glass_swipe_cb, LV_EVENT_GESTURE, NULL);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_GESTURE_BUBBLE);
}

// ─── 화면 2: 흰색 배경 + 하늘색 투명 버튼 ───────────────────────────────────
static void _create_glass_screen2() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // 흰색 배경
    lv_obj_set_style_bg_color(scr, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // 배경 장식용 원
    lv_obj_t *circle1 = lv_obj_create(scr);
    lv_obj_set_size(circle1, 220, 220);
    lv_obj_align(circle1, LV_ALIGN_TOP_RIGHT, 60, -60);
    lv_obj_set_style_bg_color(circle1, lv_color_hex(0xB8DEFF), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(circle1, LV_OPA_50, LV_PART_MAIN);
    lv_obj_set_style_border_width(circle1, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(circle1, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_clear_flag(circle1, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *circle2 = lv_obj_create(scr);
    lv_obj_set_size(circle2, 150, 150);
    lv_obj_align(circle2, LV_ALIGN_BOTTOM_LEFT, -30, 30);
    lv_obj_set_style_bg_color(circle2, lv_color_hex(0x87CEEB), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(circle2, LV_OPA_40, LV_PART_MAIN);
    lv_obj_set_style_border_width(circle2, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(circle2, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_clear_flag(circle2, LV_OBJ_FLAG_SCROLLABLE);

    // ── Glass 버튼 스타일 (하늘색 투명) ──────────────────────────────────────
    static lv_style_t style_glass2;
    lv_style_init(&style_glass2);
    lv_style_set_bg_color(&style_glass2, lv_color_hex(0x87CEEB));
    lv_style_set_bg_opa(&style_glass2, LV_OPA_30);
    lv_style_set_border_color(&style_glass2, lv_color_hex(0x87CEEB));
    lv_style_set_border_width(&style_glass2, 1);
    lv_style_set_border_opa(&style_glass2, LV_OPA_80);
    lv_style_set_radius(&style_glass2, 20);
    lv_style_set_shadow_color(&style_glass2, lv_color_hex(0x87CEEB));
    lv_style_set_shadow_width(&style_glass2, 12);
    lv_style_set_shadow_opa(&style_glass2, LV_OPA_30);

    static lv_style_t style_glass2_pr;
    lv_style_init(&style_glass2_pr);
    lv_style_set_bg_opa(&style_glass2_pr, LV_OPA_60);

    // ── 버튼 1 ────────────────────────────────────────────────────────────────
    lv_obj_t *btn1 = lv_button_create(scr);
    lv_obj_add_style(btn1, &style_glass2, LV_STATE_DEFAULT);
    lv_obj_add_style(btn1, &style_glass2_pr, LV_STATE_PRESSED);
    lv_obj_set_size(btn1, 200, 60);
    lv_obj_align(btn1, LV_ALIGN_CENTER, 0, -50);
    lv_obj_t *lbl1 = lv_label_create(btn1);
    lv_label_set_text(lbl1, "Glass Button 1");
    lv_obj_set_style_text_color(lbl1, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl1, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_center(lbl1);

    // ── 버튼 2 ────────────────────────────────────────────────────────────────
    lv_obj_t *btn2 = lv_button_create(scr);
    lv_obj_add_style(btn2, &style_glass2, LV_STATE_DEFAULT);
    lv_obj_add_style(btn2, &style_glass2_pr, LV_STATE_PRESSED);
    lv_obj_set_size(btn2, 200, 60);
    lv_obj_align(btn2, LV_ALIGN_CENTER, 0, 50);
    lv_obj_t *lbl2 = lv_label_create(btn2);
    lv_label_set_text(lbl2, "Glass Button 2");
    lv_obj_set_style_text_color(lbl2, lv_color_hex(0x1A6FE8), LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl2, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_center(lbl2);

    // 안내 텍스트
    lv_obj_t *hint = lv_label_create(scr);
    lv_label_set_text(hint, "← swipe →");
    lv_obj_set_style_text_color(hint, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_set_style_text_font(hint, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(hint, LV_ALIGN_BOTTOM_MID, 0, -20);

    // 스와이프 이벤트
    lv_obj_add_event_cb(scr, _glass_swipe_cb, LV_EVENT_GESTURE, NULL);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_GESTURE_BUBBLE);
}

// ─── 스와이프 콜백 ───────────────────────────────────────────────────────────
static void _glass_swipe_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_GESTURE) return;
    lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());
    if (dir != LV_DIR_LEFT && dir != LV_DIR_RIGHT) return;

    lv_obj_clean(lv_scr_act());
    _glass_current = (_glass_current == 0) ? 1 : 0;

    if (_glass_current == 0) _create_glass_screen1();
    else                     _create_glass_screen2();
}

// ─── 진입점 ──────────────────────────────────────────────────────────────────
void create_glass_test_ui() {
    _glass_current = 0;
    _create_glass_screen1();
}