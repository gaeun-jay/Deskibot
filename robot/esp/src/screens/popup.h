#pragma once
#include <Arduino.h>
#include <lvgl.h>

// 배경/아이콘은 이미지에 고정하고, 사용자별로 달라지는 문구와 버튼은
// LVGL 객체로 올린다. 세 배경은 팔레트 밴딩을 막기 위한 466x466 RGB565 포맷이다.
LV_IMAGE_DECLARE(popup_drowsy_bg);
LV_IMAGE_DECLARE(popup_phone_bg);
LV_IMAGE_DECLARE(popup_deadline_bg);

#define ALERT_NONE     0
#define ALERT_DROWSY   1
#define ALERT_PHONE    2
#define ALERT_DEADLINE 3   // 소리 종류 구분용 — 감지 팝업 상태(_alert_type)로는 쓰지 않는다

// sound.h가 popup.h 뒤에 include되므로 전방 선언한다.
void sound_play(int alert_type);

static int _alert_type = ALERT_NONE;

// ─── 공통 생성 헬퍼 ──────────────────────────────────────────────────────────
static lv_obj_t *_popup_create_overlay() {
    lv_obj_t *overlay = lv_obj_create(lv_layer_top());
    lv_obj_set_size(overlay, 466, 466);
    lv_obj_center(overlay);
    // 원본 PNG의 투명한 팝업 바깥 영역에만 보이는 단색 배경.
    lv_obj_set_style_bg_color(overlay, lv_color_hex(0x0A121E), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(overlay, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_border_width(overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(overlay, LV_OBJ_FLAG_SCROLLABLE);
    return overlay;
}

static lv_obj_t *_popup_add_background(lv_obj_t *overlay,
                                       const lv_image_dsc_t *source) {
    lv_obj_t *background = lv_image_create(overlay);
    lv_image_set_src(background, source);
    lv_obj_center(background);
    lv_obj_clear_flag(background, LV_OBJ_FLAG_CLICKABLE);
    return background;
}

static lv_obj_t *_popup_add_ok_button(lv_obj_t *parent, lv_event_cb_t callback,
                                      lv_color_t fill, int32_t y) {
    lv_obj_t *button = lv_button_create(parent);
    lv_obj_set_size(button, 140, 48);
    lv_obj_align(button, LV_ALIGN_CENTER, 0, y);
    lv_obj_set_style_radius(button, 24, LV_PART_MAIN);
    lv_obj_set_style_bg_color(button, fill, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(button, LV_OPA_40, LV_PART_MAIN);
    lv_obj_set_style_border_color(button, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_border_opa(button, LV_OPA_60, LV_PART_MAIN);
    lv_obj_set_style_border_width(button, 1, LV_PART_MAIN);
    lv_obj_set_style_shadow_width(button, 0, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(button, LV_OPA_60, LV_STATE_PRESSED);

    lv_obj_t *label = lv_label_create(button);
    lv_label_set_text(label, "확인");
    lv_obj_set_style_text_color(label, lv_color_white(), LV_PART_MAIN);
    // regular_28은 "확", "인" 두 글리프를 모두 포함한다.
    lv_obj_set_style_text_font(label, &pretendard_regular_28, LV_PART_MAIN);
    lv_obj_center(label);
    lv_obj_add_event_cb(button, callback, LV_EVENT_CLICKED, NULL);
    return button;
}

// ─── 졸음/스마트폰 감지 팝업 ─────────────────────────────────────────────────
static lv_obj_t *alert_overlay = nullptr;
static lv_obj_t *alert_bg      = nullptr;
static lv_obj_t *alert_message = nullptr;
static lv_obj_t *alert_btn_ok  = nullptr;

void hide_alert() {
    if (alert_overlay == nullptr) return;
    lv_obj_del(alert_overlay);
    alert_overlay = nullptr;
    alert_bg      = nullptr;
    alert_message = nullptr;
    alert_btn_ok  = nullptr;
    _alert_type = ALERT_NONE;
    Serial.println("[Alert] 숨김");
}

static void _alert_ok_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    hide_alert();
}

void show_alert(int type) {
    if (alert_overlay) hide_alert();
    if (type != ALERT_DROWSY && type != ALERT_PHONE) return;
    _alert_type = type;

    const bool drowsy = type == ALERT_DROWSY;
    const lv_image_dsc_t *background = drowsy
        ? &popup_drowsy_bg : &popup_phone_bg;
    const lv_color_t accent = drowsy
        ? lv_color_hex(0xFFB83E) : lv_color_hex(0xFF6470);

    alert_overlay = _popup_create_overlay();
    alert_bg = _popup_add_background(alert_overlay, background);

    alert_message = lv_label_create(alert_overlay);
    lv_label_set_text(alert_message,
        drowsy
            ? "Deskibot이 졸음을 감지했어요\n잠깐 물 한 잔 마셔보는 것이 어떨까요?"
            : "Deskibot이 스마트폰 사용을 감지했어요\n다시 책상으로 돌아가, 집중해볼까요?");
    lv_obj_set_width(alert_message, 330);
    lv_label_set_long_mode(alert_message, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(alert_message, &pretendard_regular_20, LV_PART_MAIN);
    // 두 줄 안내라 줄이 붙어 보인다 — 마감 팝업(한 줄)은 그대로 두고 여기만 띄운다.
    lv_obj_set_style_text_line_space(alert_message, 10, LV_PART_MAIN);
    lv_obj_set_style_text_color(alert_message, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_opa(alert_message, LV_OPA_90, LV_PART_MAIN);
    lv_obj_set_style_text_align(alert_message, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align(alert_message, LV_ALIGN_CENTER, 0, 30);

    alert_btn_ok = _popup_add_ok_button(alert_overlay, _alert_ok_cb, accent, 118);
    Serial.printf("[Alert] %s\n", drowsy ? "Drowsy" : "Phone");
}

// ─── 자리 비움 종료 안내 (진행 화면 위 회색 스크림) ──────────────────────────
// 감지 팝업과 달리 배경 이미지를 쓰지 않는다. 뒤의 뽀모도로 진행 화면이 비쳐
// 보여야 "이 세션이 끝났다"는 게 읽히기 때문에, 반투명 회색만 덮고 문구를 올린다.
// 문구는 pretendard_semibold_28로 — 전체 한글 + ASCII를 담고 있는 유일한 폰트다.
static lv_obj_t *away_overlay = nullptr;

// 자리를 비운 사람은 몇 초짜리 안내를 볼 수 없다. 그래서 자동으로 닫지 않고
// 돌아온 사람이 화면을 탭할 때까지 유지한다. 다만 LVGL 콜백 안에서 자기 자신을
// 삭제하면 안 되므로, 여기서는 요청만 세우고 실제 해제는 메인 루프에서 한다.
static volatile bool _away_dismiss_req = false;

void hide_away_notice() {
    if (away_overlay == nullptr) return;
    lv_obj_del(away_overlay);
    away_overlay = nullptr;
    _away_dismiss_req = false;
}

static void _away_tap_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    _away_dismiss_req = true;
}

void show_away_notice() {
    if (away_overlay) hide_away_notice();

    away_overlay = lv_obj_create(lv_layer_top());
    lv_obj_set_size(away_overlay, 466, 466);
    lv_obj_center(away_overlay);
    lv_obj_set_style_bg_color(away_overlay, lv_color_hex(0x11151C), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(away_overlay, LV_OPA_80, LV_PART_MAIN);
    lv_obj_set_style_border_width(away_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(away_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(away_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(away_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(away_overlay, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(away_overlay, _away_tap_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t *title = lv_label_create(away_overlay);
    lv_label_set_text(title, "자리 비움으로 종료");
    lv_obj_set_style_text_font(title, &pretendard_semibold_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(title, lv_color_white(), LV_PART_MAIN);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -18);

    lv_obj_t *sub = lv_label_create(away_overlay);
    lv_label_set_text(sub, "5분 이상 자리를 비웠어요");
    lv_obj_set_style_text_font(sub, &pretendard_semibold_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(sub, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_opa(sub, LV_OPA_60, LV_PART_MAIN);
    lv_obj_align(sub, LV_ALIGN_CENTER, 0, 24);

    Serial.println("[Away] 자리 비움 종료 안내 표시");
}

// ─── 할 일 마감 팝업 ─────────────────────────────────────────────────────────
static lv_obj_t *dl_overlay = nullptr;
static lv_obj_t *dl_bg      = nullptr;
static lv_obj_t *dl_title   = nullptr;
static lv_obj_t *dl_time    = nullptr;
static lv_obj_t *dl_left    = nullptr;
static lv_obj_t *dl_btn_ok  = nullptr;

void hide_deadline() {
    if (dl_overlay == nullptr) return;
    lv_obj_del(dl_overlay);
    dl_overlay = nullptr;
    dl_bg      = nullptr;
    dl_title   = nullptr;
    dl_time    = nullptr;
    dl_left    = nullptr;
    dl_btn_ok  = nullptr;
    Serial.println("[Deadline] 닫힘");
}

static void _dl_ok_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    hide_deadline();
}

void show_deadline(const char *time_str, const char *title_str,
                   const char *left_str) {
    if (dl_overlay) hide_deadline();

    dl_overlay = _popup_create_overlay();
    dl_bg = _popup_add_background(dl_overlay, &popup_deadline_bg);

    dl_title = lv_label_create(dl_overlay);
    lv_label_set_text(dl_title, title_str);
    lv_obj_set_width(dl_title, 310);
    lv_label_set_long_mode(dl_title, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(dl_title, &pretendard_semibold_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_title, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_align(dl_title, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align(dl_title, LV_ALIGN_CENTER, 0, -48);

    dl_time = lv_label_create(dl_overlay);
    lv_label_set_text(dl_time, time_str);
    lv_obj_set_style_text_font(dl_time, &pretendard_regular_20, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_time, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_opa(dl_time, LV_OPA_90, LV_PART_MAIN);
    lv_obj_align(dl_time, LV_ALIGN_CENTER, 0, 4);

    dl_left = lv_label_create(dl_overlay);
    char left_buf[64];
    snprintf(left_buf, sizeof(left_buf), "남은 시간 %s", left_str);
    lv_label_set_text(dl_left, left_buf);
    lv_obj_set_style_text_font(dl_left, &pretendard_regular_20, LV_PART_MAIN);
    lv_obj_set_style_text_color(dl_left, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_opa(dl_left, LV_OPA_60, LV_PART_MAIN);
    // 시각(y=4, 높이 21)과 확인 버튼(y=118, 높이 48 → 94~142) 사이 여백 안에서 내린다.
    lv_obj_align(dl_left, LV_ALIGN_CENTER, 0, 52);

    dl_btn_ok = _popup_add_ok_button(
        dl_overlay, _dl_ok_cb, lv_color_hex(0x17285F), 118);

    // 화면을 안 보고 있을 수 있으니 알림음도 함께 낸다. 감지 경고음과 달리
    // 반복하지 않고 1회만 울린다(마감은 상태가 아니라 시점 알림).
    sound_play(ALERT_DEADLINE);

    Serial.printf("[Deadline] %s | %s | left: %s\n",
                  title_str, time_str, left_str);
}
