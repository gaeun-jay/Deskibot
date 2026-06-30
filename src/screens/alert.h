#pragma once
#include <Arduino.h>
#include <lvgl.h>

// ─── Alert 타입 ───────────────────────────────────────────────────────────────
#define ALERT_DROWSY   1
#define ALERT_PHONE    2

// ─── UI 오브젝트 ─────────────────────────────────────────────────────────────
lv_obj_t *alert_symbol = nullptr;
lv_obj_t *alert_label  = nullptr;
lv_anim_t alert_anim_sym;
lv_anim_t alert_anim_lbl;
int _alert_type = ALERT_DROWSY;

// ─── pulse 애니메이션 콜백 ───────────────────────────────────────────────────
static void _alert_scale_cb(void *obj, int32_t v) {
    lv_obj_set_style_text_font((lv_obj_t *)obj,
        v > 127 ? &lv_font_montserrat_48 : &lv_font_montserrat_40,
        LV_PART_MAIN);
}

static void _alert_scale_lbl_cb(void *obj, int32_t v) {
    lv_obj_set_style_text_font((lv_obj_t *)obj,
        v > 127 ? &lv_font_montserrat_28 : &lv_font_montserrat_22,
        LV_PART_MAIN);
}

// ─── pulse 애니메이션 중지 ───────────────────────────────────────────────────
void _alert_stop_pulse() {
    if (alert_symbol) {
        lv_anim_delete(alert_symbol, _alert_scale_cb);
        alert_symbol = nullptr;
    }
    if (alert_label) {
        lv_anim_delete(alert_label, _alert_scale_lbl_cb);
        alert_label = nullptr;
    }
}

// ─── pulse 애니메이션 시작 ───────────────────────────────────────────────────
static void _alert_start_pulse() {
    lv_anim_init(&alert_anim_sym);
    lv_anim_set_var(&alert_anim_sym, alert_symbol);
    lv_anim_set_exec_cb(&alert_anim_sym, _alert_scale_cb);
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

// ─── Alert 표시 ──────────────────────────────────────────────────────────────
void show_alert(int type) {
    _alert_type = type;

    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    lv_color_t alert_color = (type == ALERT_DROWSY)
        ? lv_color_hex(0xFFB800)
        : lv_color_hex(0xFF3B30);

    // ── WARNING 심볼 ──────────────────────────────────────────────────────────
    alert_symbol = lv_label_create(scr);
    lv_label_set_text(alert_symbol, LV_SYMBOL_WARNING);
    lv_obj_set_style_text_font(alert_symbol, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_obj_set_style_text_color(alert_symbol, alert_color, LV_PART_MAIN);
    lv_obj_align(alert_symbol, LV_ALIGN_CENTER, 0, -60);

    // ── 텍스트 ───────────────────────────────────────────────────────────────
    alert_label = lv_label_create(scr);
    lv_obj_set_style_text_font(alert_label, &lv_font_montserrat_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(alert_label, alert_color, LV_PART_MAIN);
    lv_label_set_long_mode(alert_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(alert_label, 300);
    lv_obj_set_style_text_align(alert_label, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align(alert_label, LV_ALIGN_CENTER, 0, 30);

    if (type == ALERT_DROWSY) {
        lv_label_set_text(alert_label, "Drowsy Detected");
        Serial.println("[Alert] Drowsy Detected");
    } else {
        lv_label_set_text(alert_label, "Phone Detected");
        Serial.println("[Alert] Phone Detected");
    }

    _alert_start_pulse();
}