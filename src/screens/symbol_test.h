#pragma once
#include <Arduino.h>
#include <lvgl.h>
#include "pin_config.h"

// ─── 심볼 테스트 화면 ─────────────────────────────────────────────────────────
void create_symbol_test_ui() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // 스크롤 가능한 컨테이너
    lv_obj_t *cont = lv_obj_create(scr);
    lv_obj_set_size(cont, LCD_WIDTH, LCD_HEIGHT);
    lv_obj_align(cont, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_set_style_bg_color(cont, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_border_width(cont, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(cont, 8, LV_PART_MAIN);
    lv_obj_set_flex_flow(cont, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_flex_align(cont, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

    const char *symbols[] = {
        LV_SYMBOL_AUDIO,      LV_SYMBOL_VIDEO,
        LV_SYMBOL_CALL,       LV_SYMBOL_VOLUME_MAX,
        LV_SYMBOL_VOLUME_MID, LV_SYMBOL_MUTE,
        LV_SYMBOL_BELL,       LV_SYMBOL_SETTINGS,
        LV_SYMBOL_HOME,       LV_SYMBOL_WIFI,
        LV_SYMBOL_GPS,        LV_SYMBOL_BLUETOOTH,
        LV_SYMBOL_EYE_OPEN,   LV_SYMBOL_EYE_CLOSE,
        LV_SYMBOL_EDIT,       LV_SYMBOL_TRASH,
        LV_SYMBOL_PLAY,       LV_SYMBOL_PAUSE,
        LV_SYMBOL_STOP,       LV_SYMBOL_NEXT,
        LV_SYMBOL_PREV,       LV_SYMBOL_SHUFFLE,
        LV_SYMBOL_LOOP,       LV_SYMBOL_EJECT,
        LV_SYMBOL_CHARGE,     LV_SYMBOL_USB,
        LV_SYMBOL_SAVE,       LV_SYMBOL_FILE,
        LV_SYMBOL_UPLOAD,     LV_SYMBOL_DOWNLOAD,
        LV_SYMBOL_WARNING,    LV_SYMBOL_OK,
    };
    const char *names[] = {
        "AUDIO",    "VIDEO",
        "CALL",     "VOL_MAX",
        "VOL_MID",  "MUTE",
        "BELL",     "SETTINGS",
        "HOME",     "WIFI",
        "GPS",      "BLUETOTH",
        "EYE_OPEN", "EYE_CLSE",
        "EDIT",     "TRASH",
        "PLAY",     "PAUSE",
        "STOP",     "NEXT",
        "PREV",     "SHUFFLE",
        "LOOP",     "EJECT",
        "CHARGE",   "USB",
        "SAVE",     "FILE",
        "UPLOAD",   "DOWNLOAD",
        "WARNING",  "OK",
    };
    int count = 32;

    for (int i = 0; i < count; i++) {
        // 셀 컨테이너
        lv_obj_t *cell = lv_obj_create(cont);
        lv_obj_set_size(cell, 100, 80);
        lv_obj_set_style_bg_color(cell, lv_color_hex(0xF5F5F5), LV_PART_MAIN);
        lv_obj_set_style_border_width(cell, 0, LV_PART_MAIN);
        lv_obj_set_style_radius(cell, 8, LV_PART_MAIN);
        lv_obj_set_style_pad_all(cell, 4, LV_PART_MAIN);
        lv_obj_set_flex_flow(cell, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(cell, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

        // 심볼
        lv_obj_t *sym = lv_label_create(cell);
        lv_label_set_text(sym, symbols[i]);
        lv_obj_set_style_text_font(sym, &lv_font_montserrat_24, LV_PART_MAIN);
        lv_obj_set_style_text_color(sym, lv_color_hex(0x1A6FE8), LV_PART_MAIN);

        // 이름
        lv_obj_t *name = lv_label_create(cell);
        lv_label_set_text(name, names[i]);
        lv_obj_set_style_text_font(name, &lv_font_montserrat_10, LV_PART_MAIN);
        lv_obj_set_style_text_color(name, lv_color_hex(0x888888), LV_PART_MAIN);
    }
}