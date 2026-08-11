#include <Arduino.h>
#include <Wire.h>
#include <lvgl.h>
#include "mbedtls/platform.h"
#include "Arduino_GFX_Library.h"
#include "pin_config.h"
#include "TouchDrvCSTXXX.hpp"

#include "screens/clock.h"
#include "screens/stopwatch.h"
#include "screens/pomodoro.h"
#include "screens/popup.h"
#include "screens/sound.h"
#include "screens/voice.h"
// voice.h extern 변수 정의
volatile VoiceState _voice_state = VOICE_IDLE;
int16_t    *_rec_buf          = nullptr;
uint32_t    _rec_bytes        = 0;
TaskHandle_t _voice_task_handle = nullptr;
#include "screens/glass_test.h"

// ─── 디스플레이 드라이버 ─────────────────────────────────────────────────────
Arduino_DataBus *bus = new Arduino_ESP32QSPI(
    LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);

Arduino_CO5300 *gfx = new Arduino_CO5300(
    bus, LCD_RESET, 0, LCD_WIDTH, LCD_HEIGHT, 6, 0, 0, 0);

// ─── 터치 드라이버 ───────────────────────────────────────────────────────────
TouchDrvCST92xx touch;
volatile bool isPressed = false;
int16_t touch_x[5], touch_y[5];

// ─── LVGL 핸들 ───────────────────────────────────────────────────────────────
static lv_display_t *disp;
static lv_indev_t   *indev;

// ─── 앱 화면 상태 ────────────────────────────────────────────────────────────
enum AppScreen {
    SCREEN_CLOCK,
    SCREEN_POMODORO,
    SCREEN_VOICE,
    SCREEN_STOPWATCH
};
AppScreen current_screen = SCREEN_CLOCK;  // extern으로 firebase_handler.h에서 참조

// ─── WiFi + 백엔드 ───────────────────────────────────────────────────────────
#include "wifi_handler.h"
#include "firebase_handler.h"
#include "aws_backend.h"

// ─── RPi 감지 링크 (firebase_handler.h의 졸음/폰 플래그를 세움) ───────────────
#include "uart_rpi.h"

// ─── 화면 전환 함수 (전방 선언) ──────────────────────────────────────────────
void switch_screen(AppScreen screen);

// ─── 공통 전환 가드 ───────────────────────────────────────────────────────────
static bool can_switch() {
    if (_voice_state != VOICE_IDLE) {
        Serial.println("[App] 음성 처리 중 — 스와이프 무시");
        return false;
    }
    if (_pomo_state == POMO_RUNNING) {
        Serial.println("[App] 뽀모도로 진행 중 — 스와이프 무시");
        return false;
    }
    return true;
}

// ─── 홈(clock) 스와이프 ──────────────────────────────────────────────────────
// 배열: Stopwatch ← Pomodoro ← Home → Voice → Stopwatch (순환)
// LEFT(→←)→Pomodoro  RIGHT(←→)→Voice  TOP(↑)→없음
static void clock_swipe_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_GESTURE) return;
    if (!can_switch()) return;
    lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());
    if      (dir == LV_DIR_LEFT)   switch_screen(SCREEN_POMODORO);
    else if (dir == LV_DIR_RIGHT)  switch_screen(SCREEN_VOICE);
    else if (dir == LV_DIR_BOTTOM) switch_screen(SCREEN_STOPWATCH);
}

// ─── 뽀모도로 스와이프 ────────────────────────────────────────────────────────
// LEFT→stopwatch  RIGHT→홈  UP→홈
static void pomo_swipe_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_GESTURE) return;
    if (!can_switch()) return;
    lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());
    if      (dir == LV_DIR_LEFT)  switch_screen(SCREEN_STOPWATCH);
    else if (dir == LV_DIR_RIGHT) switch_screen(SCREEN_CLOCK);
    else if (dir == LV_DIR_TOP)   switch_screen(SCREEN_CLOCK);
}

// ─── 스톱워치 스와이프 ────────────────────────────────────────────────────────
// LEFT→voice  RIGHT→pomodoro  UP→홈 (스톱워치 진행 중이면 UP 무시)
static void stopwatch_swipe_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_GESTURE) return;
    lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());
    if (dir == LV_DIR_TOP) {
        if (_sw_state == SW_RUNNING) { Serial.println("[App] 스톱워치 진행 중 — 스와이프 무시"); return; }
        if (!can_switch()) return;
        switch_screen(SCREEN_CLOCK);
    } else {
        if (!can_switch()) return;
        if      (dir == LV_DIR_LEFT)  switch_screen(SCREEN_VOICE);
        else if (dir == LV_DIR_RIGHT) switch_screen(SCREEN_POMODORO);
    }
}

// ─── 보이스 스와이프 ──────────────────────────────────────────────────────────
// 배열상 Voice는 Home 오른쪽, Stopwatch 왼쪽
// LEFT(→←)→Home  RIGHT(←→)→Stopwatch  TOP(↑)→Home
static void voice_swipe_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_GESTURE) return;
    if (!can_switch()) return;
    lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());
    if      (dir == LV_DIR_LEFT)  switch_screen(SCREEN_CLOCK);
    else if (dir == LV_DIR_RIGHT) switch_screen(SCREEN_STOPWATCH);
    else if (dir == LV_DIR_TOP)   switch_screen(SCREEN_CLOCK);
}

// 화면의 모든 오브젝트(자식 포함)에서 스크롤 플래그 제거
// scroll_obj가 세팅되는 순간 indev_gesture()가 return해버리므로 반드시 필요
static void clear_scroll_recursive(lv_obj_t *obj) {
    lv_obj_clear_flag(obj, LV_OBJ_FLAG_SCROLLABLE);
    uint32_t n = lv_obj_get_child_count(obj);
    for (uint32_t i = 0; i < n; i++)
        clear_scroll_recursive(lv_obj_get_child(obj, i));
}

// ─── 화면 전환 ───────────────────────────────────────────────────────────────
void switch_screen(AppScreen screen) {
    if (current_screen == SCREEN_CLOCK) stop_clock_ui();

    lv_obj_t *scr = lv_scr_act();
    lv_obj_clean(scr);

    // 누적된 제스처 콜백 제거 (switch_screen 반복 호출 시 중복 방지)
    lv_obj_remove_event_cb(scr, clock_swipe_cb);
    lv_obj_remove_event_cb(scr, pomo_swipe_cb);
    lv_obj_remove_event_cb(scr, stopwatch_swipe_cb);
    lv_obj_remove_event_cb(scr, voice_swipe_cb);

    // 스크롤 모드가 되면 제스처 감지가 완전히 꺼짐 — 반드시 비활성화
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_GESTURE_BUBBLE);

    current_screen = screen;

    switch (screen) {
        case SCREEN_CLOCK:
            create_clock_ui();
            clear_scroll_recursive(scr);
            lv_obj_add_event_cb(scr, clock_swipe_cb, LV_EVENT_GESTURE, NULL);
            Serial.println("[App] → Clock");
            break;

        case SCREEN_POMODORO:
            create_pomodoro_ui();
            clear_scroll_recursive(scr);
            lv_obj_add_event_cb(scr, pomo_swipe_cb, LV_EVENT_GESTURE, NULL);
            Serial.println("[App] → Pomodoro");
            break;

        case SCREEN_VOICE:
            create_voice_ui();
            clear_scroll_recursive(scr);
            lv_obj_add_event_cb(scr, voice_swipe_cb, LV_EVENT_GESTURE, NULL);
            firebase_fetch_tasks();  // 화면 진입 시 즉시 태스크 로드 트리거
            Serial.println("[App] → Voice");
            break;

        case SCREEN_STOPWATCH:
            create_stopwatch_ui();
            clear_scroll_recursive(scr);
            lv_obj_add_event_cb(scr, stopwatch_swipe_cb, LV_EVENT_GESTURE, NULL);
            Serial.println("[App] → Stopwatch");
            break;
    }
}

// ─── 시리얼 파싱 (loop에서 호출) ─────────────────────────────────────────────
void handle_serial() {
    if (!Serial.available()) return;
    String input = Serial.readStringUntil('\n');
    input.trim();

    if (input == "popup drowsy") {
        show_alert(ALERT_DROWSY);
    } else if (input == "popup phone") {
        show_alert(ALERT_PHONE);
    } else if (input == "popup deadline") {
        show_deadline("09:00 PM", "알고리즘 과제", "30분");
    } else if (input.startsWith("deadline ")) {
        if (current_screen != SCREEN_CLOCK && current_screen != SCREEN_STOPWATCH) {
            Serial.println("[App] clock/stopwatch 화면이 아님 — deadline 무시");
            return;
        }
        String body = input.substring(9);
        int first_space = body.indexOf(' ');
        int second_space = body.indexOf(' ', first_space + 1);
        String time_str = body.substring(0, second_space);
        String rest = body.substring(second_space + 1);
        int last_space = rest.lastIndexOf(' ');
        String title_str = rest.substring(0, last_space);
        String left_str  = rest.substring(last_space + 1);
        show_deadline(time_str.c_str(), title_str.c_str(), left_str.c_str());
    } else if (input.startsWith("token ")) {
        // 테스트 유저 전환: NVS에 device_token 저장 + WS 재연결 (재플래싱 불필요)
        if (_voice_state != VOICE_IDLE) {
            Serial.println("[Token] 음성 처리 완료 후 다시 시도 필요");
            return;
        }
        String tok = input.substring(6);
        tok.trim();
        if (aws_set_device_token(tok.c_str())) {
            voice_reset_user_context();
            todos_reset_for_new_user();   // 이전 사용자의 할 일·마감 알림 폐기
        }
    } else {
        // 토큰 오타 입력이 평문 로그에 남지 않도록 원문은 출력하지 않는다.
        Serial.println("[App] 알 수 없는 시리얼 명령");
    }
}

// ─── LVGL 콜백 ───────────────────────────────────────────────────────────────
void my_disp_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map) {
    uint32_t w = area->x2 - area->x1 + 1;
    uint32_t h = area->y2 - area->y1 + 1;
    gfx->draw16bitRGBBitmap(area->x1, area->y1, (uint16_t *)px_map, w, h);
    lv_display_flush_ready(disp);
}

void my_invalidate_cb(lv_event_t *e) {
    lv_area_t *area = (lv_area_t *)lv_event_get_param(e);
    uint16_t x1 = area->x1;
    uint16_t x2 = area->x2;
    uint16_t y1 = area->y1;
    uint16_t y2 = area->y2;
    area->x1 = (x1 >> 1) << 1;
    area->y1 = (y1 >> 1) << 1;
    area->x2 = ((x2 >> 1) << 1) + 1;
    area->y2 = ((y2 >> 1) << 1) + 1;
}

static bool _tp_touching = false;  // 연속 폴링 추적

void my_touchpad_read(lv_indev_t *indev, lv_indev_data_t *data) {
    // 인터럽트가 왔거나, 직전 틱에 터치 중이었으면 IC를 폴링
    if (isPressed || _tp_touching) {
        uint8_t touched = touch.getPoint(touch_x, touch_y, touch.getSupportTouchPoint());
        isPressed = false;
        if (touched) {
            _tp_touching      = true;
            data->state       = LV_INDEV_STATE_PRESSED;
            data->point.x     = touch_x[0];
            data->point.y     = touch_y[0];
        } else {
            _tp_touching  = false;
            data->state   = LV_INDEV_STATE_RELEASED;
        }
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

#define LVGL_TICK_MS 2
void lvgl_tick_cb(void *) { lv_tick_inc(LVGL_TICK_MS); }

// ─── setup() ─────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    Wire.begin(IIC_SDA, IIC_SCL);


    // 1. 디스플레이 먼저 (WiFi/I2S와 독립 하드웨어)
    gfx->begin();
    gfx->fillScreen(RGB565_BLACK);
    gfx->setBrightness(200);

    lv_init();

    uint32_t buf_size = LCD_WIDTH * 20;  // 20라인 (466×20×2B×2 = 37KB, 1/4화면 212KB 대신)
    lv_color_t *buf1 = (lv_color_t *)heap_caps_malloc(buf_size * sizeof(lv_color_t), MALLOC_CAP_DMA);
    lv_color_t *buf2 = (lv_color_t *)heap_caps_malloc(buf_size * sizeof(lv_color_t), MALLOC_CAP_DMA);
    Serial.printf("[LVGL] DMA 버퍼: %d bytes × 2, 남은 DMA: %d bytes\n",
                  buf_size * sizeof(lv_color_t), heap_caps_get_free_size(MALLOC_CAP_DMA));
    if (!buf1 || !buf2) Serial.println("[LVGL] ❌ DMA 버퍼 할당 실패!");

    disp = lv_display_create(LCD_WIDTH, LCD_HEIGHT);
    lv_display_set_flush_cb(disp, my_disp_flush);
    lv_display_set_buffers(disp, buf1, buf2, buf_size * sizeof(lv_color_t), LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_add_event_cb(disp, my_invalidate_cb, LV_EVENT_INVALIDATE_AREA, NULL);

    indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, my_touchpad_read);
    lv_indev_set_gesture_min_velocity(indev, 0);    // 0 = 중간 리셋 없음 (sum 누적 유지)
    lv_indev_set_gesture_min_distance(indev, 40);   // 제스처 인식 최소 거리
    lv_timer_set_period(lv_indev_get_read_timer(indev), 10);  // 33ms → 10ms (샘플 3배)

    const esp_timer_create_args_t tick_timer_args = {
        .callback = &lvgl_tick_cb,
        .name     = "lvgl_tick"
    };
    esp_timer_handle_t tick_timer;
    esp_timer_create(&tick_timer_args, &tick_timer);
    esp_timer_start_periodic(tick_timer, LVGL_TICK_MS * 1000);

    // 2. 터치
    pinMode(TP_RESET, OUTPUT);
    digitalWrite(TP_RESET, LOW);  delay(30);
    digitalWrite(TP_RESET, HIGH); delay(50);

    touch.setPins(TP_RESET, TP_INT);
    if (!touch.begin(Wire, 0x5A, IIC_SDA, IIC_SCL)) {
        Serial.println("Touch init failed!");
    } else {
        touch.setMaxCoordinates(LCD_WIDTH, LCD_HEIGHT);
        touch.setMirrorXY(true, true);
        attachInterrupt(TP_INT, []() { isPressed = true; }, FALLING);
        Serial.println("Touch OK");
    }

    switch_screen(SCREEN_CLOCK);
    lv_timer_handler();  // WiFi 대기 전 초기 렌더

    // 3. WiFi + 백엔드 (디스플레이 이후, I2S 이전)
    // SSL 레코드 버퍼(≥4KB)만 PSRAM에 할당 → 내부 힙 단편화와 무관
    // AES/SHA 등 소형 암호 버퍼는 내부 RAM 유지 (AES HW DMA가 PSRAM 접근 불가)
    mbedtls_platform_set_calloc_free(
        [](size_t n, size_t size) -> void* {
            if (n * size >= 4096) {
                void *p = heap_caps_calloc(n, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
                if (p) return p;
            }
            return calloc(n, size);
        },
        heap_caps_free
    );
    wifi_init();
    firebase_init();               // Firestore ToDo REST만 임시 유지
    aws_backend_init();            // 집중 세션 WSS

    // RPi 감지 링크 — 졸음/폰은 UART로 들어온다
    rpi_uart_init();

    // 4. 오디오 (I2S DMA — 가장 마지막)
    sound_init();
    voice_audio_init();

    Serial.println("Ready!");
}

// ─── loop() ──────────────────────────────────────────────────────────────────
void loop() {
    static uint32_t _diag_tick = 0;
    if (millis() - _diag_tick > 5000) {
        _diag_tick = millis();
        // TLS 실패는 총 힙보다 '연속 내부 블록'이 먼저 마르면서 터진다 — 같이 찍는다.
        Serial.printf("[Diag] heap=%d | int_free=%u int_block=%u | touch=%s | screen=%d | RPi=%s\n",
            ESP.getFreeHeap(),
            (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
            (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
            touch.isPressed() ? "YES" : "no",
            (int)current_screen,
            rpi_uart_link_str());
    }

    handle_serial();
    voice_check_state();
    wifi_loop();                   // WiFi 끊김/부팅 시 미연결 복구 (WS 자동 시작의 전제)
    aws_backend_loop();            // WSS 수신/재연결 처리
    aws_focus_sync_ui();           // focus_state → 현재 집중 화면
    rpi_uart_poll();               // RPi 졸음/폰 감지 수신 (UART)
    firebase_check_alerts();       // 위 플래그 → 팝업·경고음
    firebase_check_deadlines();    // todo 마감 알림 (30초 간격)
    // 화면과 무관하게 주기적으로 가져온다. 음성 화면에서만 부르면 사용자가
    // 음성 기능을 안 쓸 때 마감 알림이 영영 뜨지 않는다.
    // 음성 상태·집중 명령·내부 힙 가드는 firebase_fetch_tasks() 안에 있다.
    firebase_fetch_tasks();
    lv_timer_handler();
    delay(5);
}
