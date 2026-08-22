#pragma once
#include <Arduino.h>
#include <Wire.h>
#include <lvgl.h>
#include "ESP_I2S.h"
#include "driver/i2s_std.h"
#include "driver/gpio.h"
#include "esp_heap_caps.h"
#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include "deskibot_tls.h"

#define VOICE_SERVER_URL "https://api.deskibot.co.kr/hw/process"
// 스트리밍 업로드는 HTTPClient를 못 쓰고 TLS 소켓에 직접 쓰므로 분리해 둔다.
#define VOICE_SERVER_HOST "api.deskibot.co.kr"
#define VOICE_SERVER_PATH "/hw/process"

// 스트리밍 업로드. 기능은 동작하고 체감 지연을 8.6초까지 줄였지만, TLS 컨텍스트를
// 하나 더 잡는 바람에 내부 힙의 '연속 블록'이 24.5KB까지 말라 다른 TLS 연결
// (WebSocket·HTTPClient)이 실패했다. 메모리 여유가 생기기 전까지는 끈다.
// 0이면 관련 코드가 통째로 컴파일에서 빠져 정적 메모리도 반환된다.
#define VOICE_STREAM_UPLOAD 0

// aws_backend.h가 관리하는 NVS device token의 스레드 안전 복사 API.
bool aws_get_device_token(char *out, size_t out_len);

// ─── 핀 ──────────────────────────────────────────────────────────────────────
#define VOICE_PIN_MCLK  42
#define VOICE_PIN_BCLK   9
#define VOICE_PIN_WS    45
#define VOICE_PIN_DIN   10   // ES7210 → ESP32 (마이크)
#define VOICE_PIN_DOUT   8   // ESP32 → ES8311 (스피커)
#define VOICE_PIN_PA    46

// ─── 설정 ────────────────────────────────────────────────────────────────────
#define VOICE_SAMPLE_RATE   16000
#define VOICE_PLAY_RATE     16000  // 재생 샘플레이트 (하이톤이면 48000 시도)
#define VOICE_MAX_SECONDS   30
#define VOICE_BUF_SAMPLES   512   // 한 번에 읽을 32bit 샘플 수

// 최대 버퍼: 30초 * 16000Hz * 2ch * 2bytes
#define VOICE_MAX_BUF_BYTES (VOICE_MAX_SECONDS * VOICE_SAMPLE_RATE * sizeof(int16_t))

// ─── 디버그 설정 ──────────────────────────────────────────────────────────────
#define DBG_PEAK_INTERVAL_MS   500   // 녹음 중 피크 출력 간격
#define DBG_DUMP_SAMPLES       20    // 녹음 완료 후 출력할 샘플 수

// ─── 상태 ────────────────────────────────────────────────────────────────────
// VOICE_STOPPING은 "녹음 종료를 눌렀고 태스크가 아직 정리 중"인 구간이다.
// 예전에는 이때 IDLE로 되돌렸는데, loop()의 voice_check_state()가 그 IDLE을 보고
// 대기 화면(마이크 버튼)을 다시 그려서 "서버 전송 중" 직전에 버튼이 깜빡였다.
// 상태를 따로 두면 레이아웃이 계속 처리 중으로 남는다.
enum VoiceState { VOICE_IDLE, VOICE_RECORDING, VOICE_STOPPING, VOICE_PROCESSING, VOICE_PLAYING };

#ifdef __cplusplus
extern "C" {
#endif
    extern volatile VoiceState _voice_state;
    extern int16_t  *_rec_buf;
    extern uint32_t  _rec_bytes;
    extern TaskHandle_t _voice_task_handle;
    void create_voice_ui();
#ifdef __cplusplus
}
#endif

// ─── 오늘 할 일 요약 전역 (todo_alert_handler.h에서 정의) ────────────────────
extern char todo_summary[];
extern char todo_summary_etc[];
extern char todo_summary_health[];
extern volatile bool _todo_summary_ready;

// ─── 이미지 에셋 선언 (캐릭터 · 마이크 버튼) ─────────────────────────────────
LV_IMAGE_DECLARE(character_voice);
LV_IMAGE_DECLARE(btn_mic);
LV_IMAGE_DECLARE(voice_wave_dot);

// ─── UI 오브젝트 ──────────────────────────────────────────────────────────────
static lv_obj_t *voice_char      = nullptr;
static lv_obj_t *voice_btn_mic   = nullptr;
static lv_obj_t *voice_dot[4]    = {};   // [0]=재생버튼, [1]=상태라벨
static lv_obj_t *voice_dots_cont = nullptr;   // 파도타기 점 컨테이너
static lv_obj_t *voice_wave[4]   = {};        // 점 4개
static bool      _wave_running   = false;

// ─── 화면 요소 위치 (466x466 원형 기준 · 실기기에서 미세조정) ────────────────
#define VOICE_CHAR_Y_DEFAULT   -30   // 참고 시안의 문구·캐릭터·마이크 간격을 맞춘 기본 y
#define VOICE_CHAR_Y_REC       -30   // 녹음 중에도 동일한 캐릭터 비율과 위치 유지
#define VOICE_TEXT_Y_TOP      -148   // 캐릭터 위 텍스트 y (대기 문구를 조금 아래로)
#define VOICE_TEXT_Y_REC      -148   // 녹음 중에도 안내 문구는 캐릭터 위에 유지
#define VOICE_DOTS_Y           120   // 작은 파도 원을 캐릭터 아래에 배치
#define VOICE_WAVE_Y_BASE       13
#define VOICE_WAVE_Y_TOP         1

// 터치 히트 영역 확장(px). 원 4개 컨테이너는 162x52라 손가락으로 맞히기 어려웠다.
// 녹음 중에는 이 컨테이너 말고 눌리는 게 없으므로(캐릭터·문구는 CLICKABLE 아님)
// 히트 영역을 화면 대부분으로 넓혀서 아무 데나 눌러도 녹음이 끝나게 한다.
// 화면 전환 제스처는 can_switch()가 음성 처리 중 이미 막으므로 충돌하지 않는다.
#define VOICE_STOP_HIT_EXT     200
#define VOICE_MIC_HIT_EXT       40

// ES7210 아날로그 PGA (REG43/REG44 하위 4비트). 한 스텝이 약 3dB다.
// 0x05일 때 보통 목소리의 녹음 피크가 1004/32767 ≈ 3%(-30dBFS)까지밖에 안 올라
// STT 여유가 없었다. 0x0A로 약 +15dB 올려 피크를 15~20%대로 끌어올린다.
// 더 필요하면 한 스텝씩(+3dB) 올리되, 피크가 80%를 넘으면 클리핑이니 내릴 것.
// (녹음 로그의 "피크:" 값으로 확인 — 32767이 풀스케일)
#define ES7210_MIC_PGA        0x0A

// ─── I2S 마이크 핸들 ─────────────────────────────────────────────────────────
static i2s_chan_handle_t _voice_rx = NULL;
static uint32_t _pipeline_start_ms = 0;  // 녹음 종료 시각 (딜레이 측정용)
static uint32_t _rec_start_ms = 0;       // 터치 IC 이중 발화 방지용

// ─── 정적 태스크 스택 (런타임 heap 단편화 방지) ──────────────────────────────
// _record_task: 20KB (HTTP POST + I2S 루프)
static StackType_t  _rec_task_stack[5120];
static StaticTask_t _rec_task_tcb;
// _play_task: 32KB (I2S 재생 + ES8311 init)
static StackType_t  _play_task_stack[8192];
static StaticTask_t _play_task_tcb;

// ─── 스레드 안전 상태 버퍼 ───────────────────────────────────────────────────
// LVGL은 스레드 비안전 → _record_task/_play_task에서 직접 호출 금지
// 여기에 쓰고, loop()의 voice_check_state()에서 LVGL 업데이트
static char  _voice_status_buf[64] = "데스키봇에게\n요청해 보세요";
static volatile bool _voice_status_dirty = false;

// ─── 역질문 대기 상태 (ask_todo_details 수신 시 저장) ─────────────────────────
// 사용자가 시간/알림을 말하면 다음 요청에 X-Pending-* 헤더로 서버에 전달
static char _pending_todo_content[128] = {};
static char _pending_todo_date[16]     = {};

// 테스트 사용자 전환 시 이전 사용자의 역질문 컨텍스트가 섞이지 않게 지운다.
void voice_reset_user_context() {
    _pending_todo_content[0] = '\0';
    _pending_todo_date[0] = '\0';
}

// JSON 문자열에서 key의 string 값 추출 (단순 파싱 — 라이브러리 불필요)
static bool _json_str(const char *json, const char *key, char *out, size_t out_len) {
    char search[48];
    snprintf(search, sizeof(search), "\"%s\":\"", key);
    const char *p = strstr(json, search);
    if (!p) return false;
    p += strlen(search);
    const char *end = strchr(p, '"');
    if (!end) return false;
    size_t len = (size_t)(end - p);
    strlcpy(out, p, (len + 1 < out_len) ? len + 1 : out_len);
    return true;
}

// 전방 선언
static void _voice_set_status(const char *text);
static void _play_task(void *arg);

// ─── ES7210 헬퍼 ─────────────────────────────────────────────────────────────
#define ES7210_ADDR 0x40

static void _es7210_write(uint8_t reg, uint8_t val) {
    Wire.beginTransmission(ES7210_ADDR);
    Wire.write(reg); Wire.write(val);
    uint8_t err = Wire.endTransmission();
    if (err) Serial.printf("[ES7210] ❌ write REG 0x%02X=0x%02X 실패 (err=%d)\n", reg, val, err);
}
static uint8_t _es7210_read(uint8_t reg) {
    Wire.beginTransmission(ES7210_ADDR);
    Wire.write(reg); Wire.endTransmission(false);
    Wire.requestFrom((uint8_t)ES7210_ADDR, (uint8_t)1);
    return Wire.available() ? Wire.read() : 0xFF;
}
static void _es7210_update_bit(uint8_t reg, uint8_t mask, uint8_t val) {
    uint8_t old = _es7210_read(reg);
    uint8_t new_val = (old & ~mask) | (val & mask);
    _es7210_write(reg, new_val);
}

// ─── ES7210 초기화 ────────────────────────────────────────────────────────────
static void _es7210_init() {
    Serial.println("\n[ES7210] ====== 초기화 시작 ======");

    // ① 리셋
    Serial.println("[ES7210] ① 칩 리셋...");
    _es7210_write(0x00, 0xFF); delay(10);
    _es7210_write(0x00, 0x41);
    _es7210_write(0x01, 0x3F);
    Serial.printf("[ES7210]   REG00=0x%02X REG01=0x%02X\n",
                  _es7210_read(0x00), _es7210_read(0x01));

    // ② 타이밍
    Serial.println("[ES7210] ② 타이밍 설정...");
    _es7210_write(0x09, 0x30);
    _es7210_write(0x0A, 0x30);
    Serial.printf("[ES7210]   REG09=0x%02X REG0A=0x%02X\n",
                  _es7210_read(0x09), _es7210_read(0x0A));

    // ③ HPF
    Serial.println("[ES7210] ③ HPF 설정...");
    _es7210_write(0x23, 0x2A);
    _es7210_write(0x22, 0x0A);
    _es7210_write(0x20, 0x0A);
    _es7210_write(0x21, 0x2A);

    // ④ Slave 모드
    Serial.println("[ES7210] ④ Slave 모드 설정...");
    _es7210_update_bit(0x08, 0x01, 0x00);
    Serial.printf("[ES7210]   REG08=0x%02X (bit0=0이면 slave OK)\n", _es7210_read(0x08));

    // ⑤ 아날로그
    Serial.println("[ES7210] ⑤ 아날로그 전원 설정...");
    _es7210_write(0x40, 0x43);
    _es7210_write(0x41, 0x70);
    _es7210_write(0x42, 0x70);
    Serial.printf("[ES7210]   REG40=0x%02X(VMID) REG41=0x%02X REG42=0x%02X(MIC bias)\n",
                  _es7210_read(0x40), _es7210_read(0x41), _es7210_read(0x42));

    // ⑥ OSR / MCLK
    Serial.println("[ES7210] ⑥ OSR / MCLK 설정...");
    _es7210_write(0x07, 0x20);
    _es7210_write(0x02, 0xC1);
    Serial.printf("[ES7210]   REG07=0x%02X(OSR) REG02=0x%02X(MCLK)\n",
                  _es7210_read(0x07), _es7210_read(0x02));

    // ⑦ I2S 포맷: 32bit Philips
    Serial.println("[ES7210] ⑦ I2S 포맷 설정 (32bit Philips)...");
    _es7210_write(0x11, 0x80);
    _es7210_write(0x12, 0x00);
    Serial.printf("[ES7210]   REG11=0x%02X(포맷) REG12=0x%02X(TDM)\n",
                  _es7210_read(0x11), _es7210_read(0x12));
    if (_es7210_read(0x11) == 0x80)
        Serial.println("[ES7210]   ✅ 32bit I2S Philips 포맷 확인");
    else
        Serial.println("[ES7210]   ⚠️ 포맷 설정 불일치!");

    // ⑧ MIC1/2 활성화
    Serial.printf("[ES7210] ⑧ MIC1/2 활성화 (PGA 0x%02X)...\n", ES7210_MIC_PGA);
    _es7210_write(0x4B, 0xFF);
    _es7210_write(0x4C, 0xFF);
    _es7210_update_bit(0x01, 0x0B, 0x00);
    _es7210_write(0x4B, 0x00);
    _es7210_update_bit(0x43, 0x10, 0x10);
    _es7210_update_bit(0x43, 0x0F, ES7210_MIC_PGA);
    _es7210_update_bit(0x44, 0x10, 0x10);
    _es7210_update_bit(0x44, 0x0F, ES7210_MIC_PGA);
    Serial.printf("[ES7210]   REG43=0x%02X(MIC1 gain) REG44=0x%02X(MIC2 gain)\n",
                  _es7210_read(0x43), _es7210_read(0x44));
    Serial.printf("[ES7210]   REG4B=0x%02X(MIC12 power, 0x00=ON)\n", _es7210_read(0x4B));

    // ⑨ Start
    Serial.println("[ES7210] ⑨ 칩 Start...");
    _es7210_write(0x01, 0x00);
    _es7210_write(0x06, 0x00);
    _es7210_write(0x40, 0x43);
    _es7210_write(0x47, 0x08);
    _es7210_write(0x48, 0x08);
    _es7210_write(0x49, 0x08);
    _es7210_write(0x4A, 0x08);
    _es7210_write(0x40, 0x43);
    _es7210_write(0x00, 0x71);
    _es7210_write(0x00, 0x41);
    delay(50);

    // 최종 상태 덤프
    Serial.println("[ES7210] ====== 최종 레지스터 상태 ======");
    Serial.printf("[ES7210]   REG00=0x%02X  REG01=0x%02X  REG02=0x%02X\n",
                  _es7210_read(0x00), _es7210_read(0x01), _es7210_read(0x02));
    Serial.printf("[ES7210]   REG07=0x%02X  REG08=0x%02X  REG11=0x%02X\n",
                  _es7210_read(0x07), _es7210_read(0x08), _es7210_read(0x11));
    Serial.printf("[ES7210]   REG40=0x%02X  REG43=0x%02X  REG4B=0x%02X\n",
                  _es7210_read(0x40), _es7210_read(0x43), _es7210_read(0x4B));
    Serial.println("[ES7210] ====== 초기화 완료 ======\n");
}

// ─── I2S_NUM_1 마이크 RX 초기화 ──────────────────────────────────────────────
static void _i2s_mic_init() {
    Serial.println("[I2S] I2S_NUM_1 RX 초기화 (32bit Philips, 16kHz stereo)...");
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
    esp_err_t err = i2s_new_channel(&chan_cfg, NULL, &_voice_rx);
    if (err != ESP_OK) {
        Serial.printf("[I2S] ❌ 채널 생성 실패: %s\n", esp_err_to_name(err));
        return;
    }
    i2s_std_config_t std_cfg = {
        .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(VOICE_SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(
                        I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = (gpio_num_t)VOICE_PIN_MCLK,
            .bclk = (gpio_num_t)VOICE_PIN_BCLK,
            .ws   = (gpio_num_t)VOICE_PIN_WS,
            .dout = I2S_GPIO_UNUSED,
            .din  = (gpio_num_t)VOICE_PIN_DIN,
            .invert_flags = { false, false, false },
        },
    };
    err = i2s_channel_init_std_mode(_voice_rx, &std_cfg);
    if (err != ESP_OK) {
        Serial.printf("[I2S] ❌ std 모드 설정 실패: %s\n", esp_err_to_name(err));
        return;
    }
    err = i2s_channel_enable(_voice_rx);
    if (err != ESP_OK) {
        Serial.printf("[I2S] ❌ 채널 enable 실패: %s\n", esp_err_to_name(err));
        return;
    }
    Serial.printf("[I2S] ✅ 채널 활성화 완료 (MCLK=GPIO%d BCLK=GPIO%d WS=GPIO%d DIN=GPIO%d)\n",
                  VOICE_PIN_MCLK, VOICE_PIN_BCLK, VOICE_PIN_WS, VOICE_PIN_DIN);
}

// ─── 오디오 초기화 ────────────────────────────────────────────────────────────
void voice_audio_init() {
    Serial.println("\n[Voice] ====== 오디오 초기화 시작 ======");

    pinMode(VOICE_PIN_PA, OUTPUT);
    digitalWrite(VOICE_PIN_PA, LOW);
    Serial.println("[Voice] PA 앰프 OFF 상태로 시작");

    size_t free_psram = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    Serial.printf("[Voice] PSRAM 여유 공간: %d bytes (%.1f MB)\n",
                  free_psram, free_psram / 1024.0f / 1024.0f);

    _rec_buf = (int16_t *)heap_caps_malloc(VOICE_MAX_BUF_BYTES, MALLOC_CAP_SPIRAM);
    if (!_rec_buf) {
        Serial.printf("[Voice] ❌ PSRAM 버퍼 할당 실패! (요청: %d bytes)\n", VOICE_MAX_BUF_BYTES);
        return;
    }
    Serial.printf("[Voice] ✅ PSRAM 버퍼 할당 OK: %d bytes (%.1f초 분량)\n",
                  VOICE_MAX_BUF_BYTES, (float)VOICE_MAX_SECONDS);

    _es7210_init();
    _i2s_mic_init();
    Serial.println("[Voice] ====== 오디오 초기화 완료 ======\n");
}

// ─── 스트림 정확히 N바이트 읽기 헬퍼 ─────────────────────────────────────────
static bool _read_exact(NetworkClient *c, uint8_t *dst, uint32_t n) {
    uint32_t got = 0, deadline = millis() + 5000;
    while (got < n && millis() < deadline) {
        if (c->available()) got += c->readBytes(dst + got, n - got);
        else delay(5);
    }
    return got == n;
}

// 녹음 태스크가 첫 발화를 감지하면 켠다. 업로더는 이걸 보고 전송을 시작해
// 앞쪽 무음을 건너뛴다(머리 트림).
static volatile bool     signal_seen_flag  = false;
// 신호가 처음 잡힌 지점(샘플 인덱스). 업로더가 연결하느라 늦게 깨어나도
// 여기서부터 보내야 발화 앞부분을 잃지 않는다.
static volatile uint32_t signal_first_sample = 0;

#if VOICE_STREAM_UPLOAD
// 아래 업로더가 쓰는 두 함수는 정의가 뒤에 있어 전방 선언한다.
static inline uint8_t _lin2ulaw(int16_t pcm);
static bool _recv_body(NetworkClient *wifi_stream, int resp_total);

// ─── 스트리밍 업로드 ─────────────────────────────────────────────────────────
// 녹음이 끝난 뒤 통째로 올리면 발화 길이만큼 대기가 생긴다(6.2초 발화 → 업로드
// 4.0초). 녹음과 동시에 흘려보내면 그 대기가 사라진다.
//
// 별도 태스크로 돌리는 이유: 4KB 청크 TLS 쓰기가 ~170ms 걸리는데, 녹음 루프
// 안에서 하면 그동안 i2s_channel_read를 못 해 DMA가 넘치고 오디오가 끊긴다.
// 녹음 태스크는 _rec_bytes만 늘리고, 업로더는 그 아래 구간만 읽는다 —
// 한쪽만 쓰고 한쪽만 읽으므로 뮤텍스가 필요 없다.
#define UP_CHUNK_SAMPLES    4096                      // µ-law 4KB / PCM 8KB
#define UP_PREROLL_SAMPLES  (VOICE_SAMPLE_RATE * 3 / 10)   // 머리 트림 여유 300ms

static WiFiClientSecure  _up_tls;
static volatile uint32_t _up_sent      = 0;      // 이미 보낸 샘플 수
static volatile bool     _up_open      = false;  // 연결·헤더 전송 완료
static volatile bool     _up_failed    = false;
static volatile bool     _up_finishing = false;  // 녹음 종료 — 잔량만 밀어내면 됨
static TaskHandle_t      _up_task      = nullptr;
static StaticTask_t      _up_task_tcb;
static StackType_t       _up_task_stack[8192];
static uint8_t           _up_chunk[UP_CHUNK_SAMPLES];

// 녹음 시작 시점에 연결과 헤더까지 끝내둔다. TLS 핸드셰이크(~0.5초)가 사용자가
// 말하기 시작하는 구간과 겹쳐서 체감에서 사라진다.
static bool _upload_open_conn() {
    char device_token[128] = {};
    if (!aws_get_device_token(device_token, sizeof(device_token))) {
        Serial.println("[UP] NVS device_token 미설정 — 스트리밍 취소");
        return false;
    }
    _up_tls.setCACert(DESKIBOT_ROOT_CA);
    _up_tls.setTimeout(30);
    if (!_up_tls.connect(VOICE_SERVER_HOST, 443)) {
        Serial.println("[UP] ❌ TLS 연결 실패");
        return false;
    }
    // 녹음이 끝나야 길이를 알 수 있으므로 chunked로 보낸다.
    _up_tls.printf("POST %s HTTP/1.1\r\n", VOICE_SERVER_PATH);
    _up_tls.printf("Host: %s\r\n", VOICE_SERVER_HOST);
    _up_tls.print("Content-Type: application/octet-stream\r\n");
    _up_tls.print("X-Audio-Encoding: mulaw\r\n");
    _up_tls.printf("X-Device-Key: %s\r\n", device_token);
    if (_pending_todo_content[0]) {
        _up_tls.printf("X-Pending-Content: %s\r\n", _pending_todo_content);
        _up_tls.printf("X-Pending-Date: %s\r\n",    _pending_todo_date);
    }
    _up_tls.print("Transfer-Encoding: chunked\r\n");
    _up_tls.print("Connection: close\r\n\r\n");
    return true;
}

// _rec_buf[from..to)를 µ-law로 인코딩해 청크 하나로 보낸다.
static bool _upload_send_range(uint32_t from, uint32_t to) {
    while (from < to) {
        uint32_t n = min((uint32_t)UP_CHUNK_SAMPLES, to - from);
        for (uint32_t i = 0; i < n; i++) _up_chunk[i] = _lin2ulaw(_rec_buf[from + i]);
        if (_up_tls.printf("%X\r\n", (unsigned)n) <= 0) return false;
        if (_up_tls.write(_up_chunk, n) != n)             return false;
        if (_up_tls.print("\r\n") <= 0)                  return false;
        from += n;
        _up_sent = from;
    }
    return true;
}

static void _upload_task(void *arg) {
    // TLS 핸드셰이크는 반드시 이 태스크(코어 0)에서 한다. 버튼 콜백에서 하면
    // UI 스레드가 0.5~1초 멈춰 터치가 씹힌다.
    if (!_upload_open_conn()) {
        _up_failed = true;
        _up_task = nullptr;
        vTaskDelete(NULL);
        return;
    }
    _up_open = true;

    // 머리 트림: 신호가 잡히기 전의 무음은 보내지 않는다. 꼬리 트림은 끝을 미리
    // 알 수 없어 포기한다 — 대신 전송이 녹음과 겹쳐서 총 시간은 더 짧다.
    while (!_up_failed && !signal_seen_flag && !_up_finishing) vTaskDelay(pdMS_TO_TICKS(20));

    // 지금 위치가 아니라 '신호가 처음 잡힌 위치'를 기준으로 삼는다. TLS 연결에
    // 수 초가 걸리는 동안 녹음된 발화를 무음으로 오인해 버리지 않기 위함이다.
    uint32_t first = signal_first_sample;
    _up_sent = (first > UP_PREROLL_SAMPLES) ? first - UP_PREROLL_SAMPLES : 0;
    Serial.printf("[UP] 전송 시작 (머리 %.2f초 건너뜀)\n",
                  (float)_up_sent / VOICE_SAMPLE_RATE);

    while (!_up_failed) {
        uint32_t avail = _rec_bytes / sizeof(int16_t);
        if (avail > _up_sent) {
            if (!_upload_send_range(_up_sent, avail)) {
                Serial.println("[UP] ❌ 청크 전송 실패");
                _up_failed = true;
                break;
            }
        } else if (_up_finishing) {
            break;                       // 녹음 끝 + 잔량 없음
        } else {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
    _up_task = nullptr;
    vTaskDelete(NULL);
}

// 태스크만 띄우고 즉시 돌아온다. 연결은 태스크가 알아서 한다.
static bool _upload_begin() {
    _up_sent = 0; _up_failed = false; _up_finishing = false; _up_open = false;
    signal_first_sample = 0;
    _up_task = xTaskCreateStaticPinnedToCore(
        _upload_task, "up", sizeof(_up_task_stack) / sizeof(StackType_t),
        NULL, 4, _up_task_stack, &_up_task_tcb, 0);   // 녹음(코어1)과 분리
    if (!_up_task) {
        Serial.println("[UP] ❌ 업로더 태스크 생성 실패");
        _up_tls.stop(); _up_failed = true; return false;
    }
    return true;
}

// 상태줄 + 헤더를 읽어 코드와 X-Server-Time을 뽑는다. HTTPClient를 못 쓰므로
// 직접 파싱한다.
static int _upload_read_head(float *srv_time, int *content_len) {
    *srv_time = 0; *content_len = -1;
    // Stream 타임아웃에 기대면 서버가 응답하기도 전에 빈 문자열을 받는다.
    // 서버 처리에 3~6초가 걸리므로 직접 기다린다.
    uint32_t dl = millis() + 40000;
    while (!_up_tls.available() && _up_tls.connected() && millis() < dl)
        vTaskDelay(pdMS_TO_TICKS(20));
    if (!_up_tls.available()) {
        Serial.println("[UP] ❌ 응답 없음 (타임아웃)");
        return -1;
    }
    String status = _up_tls.readStringUntil('\n');
    int sp = status.indexOf(' ');
    int code = (sp > 0) ? status.substring(sp + 1, sp + 4).toInt() : -1;
    while (true) {
        String line = _up_tls.readStringUntil('\n');
        line.trim();
        if (line.length() == 0) break;
        // HTTP 헤더 이름은 규격상 대소문자를 구분하지 않는다. 서버를 Flask에서
        // FastAPI로 옮기면서 표기가 "Content-Length"에서 "content-length"로
        // 바뀌었고, 그때 이 파싱이 통째로 조용히 실패했다. 응답은 200인데
        // content_len이 -1로 남아 본문 길이를 모르게 되는 형태라 원인을 찾기
        // 어렵다. 소문자로 맞춰 비교한다 — 값 추출 위치는 그대로다.
        String key = line;
        key.toLowerCase();
        if (key.startsWith("x-server-time:"))
            *srv_time = line.substring(14).toFloat();
        else if (key.startsWith("content-length:"))
            *content_len = line.substring(15).toInt();
        else if (key.startsWith("x-stage-times:"))
            Serial.printf("[LAT]   서버 단계  : %s\n", line.substring(14).c_str());
    }
    return code;
}


// 녹음 종료 후: 잔량을 밀어내고 종료 청크를 보낸 뒤 응답을 받는다.
// 실패하면 false를 돌려주고, 호출부가 기존 일괄 전송으로 되돌아간다.
// 반환값:
//   UP_OK          응답까지 정상 수신
//   UP_RETRY_SAFE  종료 청크 전에 끊김 — 서버가 실행했을 리 없으니 재전송 가능
//   UP_SPENT       요청은 이미 서버에 도달했고 응답만 못 받음 — 재전송 금지.
//                  다시 보내면 add_todo·delete_todo가 두 번 실행된다.
enum UploadResult { UP_OK, UP_RETRY_SAFE, UP_SPENT };

static UploadResult _upload_finish() {
    _up_finishing = true;
    uint32_t t_wait = millis();
    while (_up_task && millis() - t_wait < 20000) vTaskDelay(pdMS_TO_TICKS(10));

    if (_up_failed || !_up_open) { _up_tls.stop(); return UP_RETRY_SAFE; }

    _up_tls.print("0\r\n\r\n");                 // 종료 청크 — 이 시점부터 재전송 금지
    uint32_t sent_bytes = _up_sent;               // µ-law는 샘플당 1바이트
    Serial.printf("[UP] 전송 완료: %u bytes µ-law (%.1f초)\n",
                  sent_bytes, (float)sent_bytes / VOICE_SAMPLE_RATE);

    uint32_t t0 = millis();
    float srv_time; int content_len;
    int code = _upload_read_head(&srv_time, &content_len);
    uint32_t wait_ms = millis() - t0;

    if (code != 200) {
        Serial.printf("[UP] ❌ HTTP %d — 서버는 이미 처리했을 수 있어 재전송하지 않는다\n", code);
        _up_tls.stop();
        return UP_SPENT;
    }
    Serial.println("\n[LAT] ====== 구간별 소요 ======");
    Serial.printf("[LAT]   업로드      : 녹음과 동시 진행 (%u bytes)\n", sent_bytes);
    Serial.printf("[LAT]   응답 대기   : %.2fs (서버 처리 %.2fs)\n",
                  wait_ms / 1000.0f, srv_time);

    // 이후 본문 형식은 기존과 동일하다 — 같은 파서를 그대로 쓴다.
    uint32_t t_body = millis();
    if (!_recv_body(&_up_tls, content_len)) { _up_tls.stop(); return UP_SPENT; }
    Serial.printf("[LAT]   본문 수신   : %.2fs\n", (millis() - t_body) / 1000.0f);
    Serial.println("[LAT] ==============================\n");
    _up_tls.stop();
    return UP_OK;
}

#endif  // VOICE_STREAM_UPLOAD

// ─── 서버 전송 → STT/LLM/TTS 수신 ───────────────────────────────────────────
// ─── µ-law 인코딩 ────────────────────────────────────────────────────────────
// 업로드를 절반으로 줄인다(16-bit PCM 32KB/s → 8-bit µ-law 16KB/s). 손실 압축이라
// 90발화로 인식률 영향을 실측했고 Google −0.008 / CLOVA +0.001로 유의차가 없었다.
// 원거리(1 m) 조건에서도 악화가 없다 — µ-law는 로그 압신이라 작은 진폭에서도
// SNR을 유지한다.
static inline uint8_t _lin2ulaw(int16_t pcm) {
    static const int16_t SEG_UEND[8] =
        {0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF};
    int32_t v = pcm >> 2;                 // 16비트 → 14비트
    uint8_t mask;
    if (v < 0) { v = -v; mask = 0x7F; } else { mask = 0xFF; }
    if (v > 8159) v = 8159;
    v += 0x84 >> 2;
    int seg = 8;
    for (int i = 0; i < 8; i++) {
        if (v <= SEG_UEND[i]) { seg = i; break; }
    }
    if (seg >= 8) return (uint8_t)(0x7F ^ mask);
    return (uint8_t)((((seg << 4) | ((v >> (seg + 1)) & 0x0F)) ^ mask) & 0xFF);
}

// _rec_buf를 제자리에서 µ-law로 바꾼다. 출력이 입력의 절반이라 앞에서부터
// 덮어써도 아직 안 읽은 샘플을 건드리지 않는다. 원본 PCM은 전송 후 쓰지 않는다.
static uint32_t _encode_ulaw_inplace(uint32_t pcm_bytes) {
    const uint32_t n = pcm_bytes / sizeof(int16_t);
    uint8_t *dst = (uint8_t *)_rec_buf;
    for (uint32_t i = 0; i < n; i++) dst[i] = _lin2ulaw(_rec_buf[i]);
    return n;
}


// 응답 본문 파싱. 일괄 전송과 스트리밍 업로드가 같은 형식을 받으므로
// 두 경로가 이 함수를 공유한다.
static bool _recv_body(NetworkClient *wifi_stream, int resp_total) {
    // 1. STT 결과
    uint32_t t_len = 0;
    if (!_read_exact(wifi_stream, (uint8_t *)&t_len, 4)) {
        Serial.println("[Server] ❌ STT 길이 수신 실패");
        return false;
    }
    if (t_len > 0 && t_len < 512) {
        char *tbuf = (char *)malloc(t_len + 1);
        _read_exact(wifi_stream, (uint8_t *)tbuf, t_len);
        tbuf[t_len] = 0;
        Serial.printf("[STT] 결과: \"%s\"\n", tbuf);
        free(tbuf);
    }

    // 2. 명령 JSON (서버가 PostgreSQL 처리 후 action 타입을 반환)
    uint32_t r_len = 0;
    if (!_read_exact(wifi_stream, (uint8_t *)&r_len, 4)) {
        Serial.println("[Server] ❌ CMD 길이 수신 실패");
        return false;
    }
    if (r_len > 0 && r_len < 512) {
        char *rbuf = (char *)malloc(r_len + 1);
        _read_exact(wifi_stream, (uint8_t *)rbuf, r_len);
        rbuf[r_len] = 0;
        Serial.printf("[CMD] %s\n", rbuf);

        // action 추출
        char action[32] = {};
        _json_str(rbuf, "action", action, sizeof(action));

        if (strcmp(action, "ask_todo_details") == 0) {
            // 역질문 → 사용자 응답 대기 상태 진입
            _json_str(rbuf, "content", _pending_todo_content, sizeof(_pending_todo_content));
            _json_str(rbuf, "date",    _pending_todo_date,    sizeof(_pending_todo_date));
            Serial.printf("[CMD] 역질문 대기: '%s' / %s\n", _pending_todo_content, _pending_todo_date);

        } else if (strcmp(action, "add_todo") == 0 ||
                   strcmp(action, "complete_todo") == 0 ||
                   strcmp(action, "delete_todo") == 0) {
            // 서버가 할 일 변경 완료 → pending 클리어
            _pending_todo_content[0] = '\0';
            _pending_todo_date[0]    = '\0';
            Serial.println("[CMD] ✅ 할 일 처리 완료 — pending 클리어");
        }
        // action == "none" 이거나 get_schedule이면 pending 유지 없이 그냥 패스

        free(rbuf);
    }

    // 3. TTS PCM 오디오 → _rec_buf 재사용
    uint32_t audio_len = (resp_total >= 0) ? (resp_total - 4 - t_len - 4 - r_len) : 0;
    if (audio_len == 0 || audio_len > VOICE_MAX_BUF_BYTES) {
        Serial.printf("[Server] ❌ 오디오 길이 이상: %d\n", audio_len);
        return false;
    }

    _voice_set_status("데스키봇이\n말하고 있어요");
    uint8_t *dst      = (uint8_t *)_rec_buf;
    uint32_t received = 0, dl = millis() + 20000;
    while (received < audio_len && millis() < dl) {
        if (wifi_stream->available())
            received += wifi_stream->readBytes(dst + received,
                                          min(audio_len - received, (uint32_t)1024));
        else delay(10);
    }
    _rec_bytes = received;
    return true;
}

static void _send_to_server() {
    // 전송·수신을 한 문구로 묶는다. 단계를 나눠 보여줘도 사용자가 할 수 있는 게
    // 없고, 문구가 바뀌면 오히려 뭔가 잘못된 것처럼 보였다.
    // (문구를 바꿀 때는 pretendard_medium_25 서브셋에 글자가 있는지 반드시 확인)
    // 2번째 줄 앞 스페이스 4개는 오타가 아니라 광학 정렬용이다. 끝의 " ⋯"가
    // 25.9px를 차지해 중앙 계산에 들어가는 바람에 "데스키봇"이 12.9px 오른쪽으로
    // 치우쳐 보였다. 같은 폭을 왼쪽에 넣어 두 줄의 보이는 글자를 함께 중앙에 둔다.
    _voice_set_status("데스키봇\n    응답 준비중 ⋯");
    Serial.printf("\n[Server] POST %s (%d bytes, %.1f초)\n",
                  VOICE_SERVER_URL,
                  _rec_bytes, (float)_rec_bytes / (VOICE_SAMPLE_RATE * 2));

    char device_token[128] = {};
    if (!aws_get_device_token(device_token, sizeof(device_token))) {
        Serial.println("[Server] NVS device_token 미설정 — 음성 요청 취소");
        _rec_bytes = 0;
        return;
    }

    WiFiClientSecure wifi_client;
    wifi_client.setCACert(DESKIBOT_ROOT_CA);
    HTTPClient  http;
    http.begin(wifi_client, VOICE_SERVER_URL);
    http.addHeader("Content-Type", "application/octet-stream");
    http.addHeader("X-Device-Key", device_token);
    http.addHeader("X-Audio-Encoding", "mulaw");
    if (_pending_todo_content[0]) {
        http.addHeader("X-Pending-Content", _pending_todo_content);
        http.addHeader("X-Pending-Date",    _pending_todo_date);
        Serial.printf("[Voice] 역질문 컨텍스트 전송: '%s' / %s\n",
                      _pending_todo_content, _pending_todo_date);
    }
    http.setTimeout(30000);

    // 서버가 자기 처리 시간을 헤더로 알려준다. 왕복에서 그걸 빼면 순수 네트워크
    // 시간이 남는다 — 업로드가 병목인지 서버가 병목인지 이걸로 갈린다.
    const char *timing_hdrs[] = {"X-Server-Time", "X-Stage-Times"};
    http.collectHeaders(timing_hdrs, 2);

    // 보내기 직전에 µ-law로 줄인다. _rec_bytes는 응답 수신에 다시 쓰이므로
    // 인코딩 길이는 따로 들고 있는다.
    uint32_t t_enc  = millis();
    uint32_t ul_len = _encode_ulaw_inplace(_rec_bytes);
    Serial.printf("[µlaw] %u → %u bytes (%ums)\n",
                  _rec_bytes, ul_len, (unsigned)(millis() - t_enc));

    uint32_t t0   = millis();
    int      code = http.POST((uint8_t *)_rec_buf, ul_len);
    uint32_t rt_ms = millis() - t0;
    Serial.printf("[Server] HTTP %d (%.1fs)\n", code, rt_ms / 1000.0f);

    if (code != 200) {
        Serial.printf("[Server] ❌ 실패 (code=%d)\n", code);
        http.end();
        _rec_bytes = 0;
        return;
    }

    // ── 구간 계측 ────────────────────────────────────────────────────────────
    float srv_s = http.header("X-Server-Time").toFloat();
    float net_s = rt_ms / 1000.0f - srv_s;          // 업로드 + 왕복 지연 + 헤더
    Serial.println("\n[LAT] ====== 구간별 소요 ======");
    Serial.printf("[LAT]   업로드 크기 : %u bytes µ-law (%.1f초 오디오)\n",
                  ul_len, (float)ul_len / VOICE_SAMPLE_RATE);
    Serial.printf("[LAT]   POST 왕복   : %.2fs\n", rt_ms / 1000.0f);
    Serial.printf("[LAT]   ├ 서버 처리 : %.2fs  (%s)\n", srv_s,
                  http.header("X-Stage-Times").c_str());
    Serial.printf("[LAT]   └ 네트워크  : %.2fs  <- 업로드 병목 여부\n", net_s);

    uint32_t t_body = millis();
    int resp_total = http.getSize();
    NetworkClient *wifi_stream = http.getStreamPtr();
    // 2번째 줄 앞 스페이스 4개는 오타가 아니라 광학 정렬용이다. 끝의 " ⋯"가
    // 25.9px를 차지해 중앙 계산에 들어가는 바람에 "데스키봇"이 12.9px 오른쪽으로
    // 치우쳐 보였다. 같은 폭을 왼쪽에 넣어 두 줄의 보이는 글자를 함께 중앙에 둔다.
    _voice_set_status("데스키봇\n    응답 준비중 ⋯");

    if (!_recv_body(wifi_stream, resp_total)) {
        http.end(); _rec_bytes = 0; return;
    }
    Serial.printf("[LAT]   본문 수신   : %.2fs (%u bytes)\n",
                  (millis() - t_body) / 1000.0f, _rec_bytes);
    Serial.println("[LAT] ==============================\n");
    http.end();

    float dur = (float)_rec_bytes / (VOICE_SAMPLE_RATE * 2);
    Serial.printf("[TTS] %d bytes 수신 (%.1f초)\n", _rec_bytes, dur);
    _voice_set_status("데스키봇이\n말하고 있어요");
}

// ─── 앞뒤 무음 잘라내기 ──────────────────────────────────────────────────────
// 대기 시간의 대부분이 업로드다(274KB에 8.6초). 그런데 실제 발화 앞뒤로 붙는
// 무음이 절반을 넘는 경우가 많다 — 버튼 누르고 말 꺼내기까지, 말 끝내고 버튼
// 누르기까지. 보낼 구간만 남기면 왕복이 그만큼 짧아진다.
//
// 문턱값은 고정하지 않고 전체 피크에 비례시킨다. 마이크 게인(ES7210_MIC_PGA)을
// 바꿔도 따라가야 하기 때문이다. 앞뒤로 여유를 남겨 첫/끝 음절을 자르지 않는다.
#define TRIM_WINDOW_SAMPLES   (VOICE_SAMPLE_RATE / 50)      // 20ms 단위로 판정
#define TRIM_HEAD_MARGIN      (VOICE_SAMPLE_RATE * 3 / 10)  // 발화 앞 300ms 보존
#define TRIM_TAIL_MARGIN      (VOICE_SAMPLE_RATE / 2)       // 발화 뒤 500ms 보존
#define TRIM_MIN_SAMPLES      (VOICE_SAMPLE_RATE / 2)       // 0.5초 미만이면 손대지 않음
#define TRIM_ABS_FLOOR        600                           // 잡음만 있을 때의 하한

static uint32_t _trim_silence(int16_t *buf, uint32_t bytes) {
    const uint32_t total = bytes / sizeof(int16_t);
    if (!buf || total < TRIM_MIN_SAMPLES) return bytes;

    int32_t peak = 0;
    for (uint32_t i = 0; i < total; i++) {
        int32_t v = abs((int32_t)buf[i]);
        if (v > peak) peak = v;
    }
    const int32_t thr = max((int32_t)TRIM_ABS_FLOOR, peak / 12);

    uint32_t first = UINT32_MAX, last = 0;
    for (uint32_t s = 0; s + TRIM_WINDOW_SAMPLES <= total; s += TRIM_WINDOW_SAMPLES) {
        int32_t wpeak = 0;
        for (uint32_t i = s; i < s + TRIM_WINDOW_SAMPLES; i++) {
            int32_t v = abs((int32_t)buf[i]);
            if (v > wpeak) wpeak = v;
        }
        if (wpeak >= thr) {
            if (first == UINT32_MAX) first = s;
            last = s + TRIM_WINDOW_SAMPLES;
        }
    }
    if (first == UINT32_MAX) {
        Serial.println("[TRIM] 발화 구간을 못 찾음 — 원본 그대로 전송");
        return bytes;
    }

    const uint32_t start = (first > TRIM_HEAD_MARGIN) ? first - TRIM_HEAD_MARGIN : 0;
    const uint32_t end   = min(total, last + TRIM_TAIL_MARGIN);
    if (end <= start || (end - start) < TRIM_MIN_SAMPLES) return bytes;

    const uint32_t kept = end - start;
    if (start > 0) memmove(buf, buf + start, kept * sizeof(int16_t));

    Serial.printf("[TRIM] %.2f초 → %.2f초 (%.0f%% 절감, 문턱 %d/피크 %d)\n",
                  (float)total / VOICE_SAMPLE_RATE,
                  (float)kept  / VOICE_SAMPLE_RATE,
                  100.0f * (total - kept) / total, (int)thr, (int)peak);
    return kept * sizeof(int16_t);
}

// ─── 녹음 태스크 ─────────────────────────────────────────────────────────────
static void _record_task(void *arg) {
    static int32_t buf32[VOICE_BUF_SAMPLES];
    _rec_bytes = 0;
    size_t max_samples = VOICE_MAX_BUF_BYTES / sizeof(int16_t);

    uint32_t start_ms    = millis();
    uint32_t last_peak_ms = 0;
    int32_t  peak_max    = 0;   // 구간 피크
    int32_t  total_peak  = 0;   // 전체 피크
    uint32_t read_count  = 0;   // 읽기 성공 횟수
    uint32_t err_count   = 0;   // 읽기 실패 횟수
    bool     signal_seen = false;

    Serial.println("\n[REC] ====== 녹음 시작 ======");
    Serial.printf("[REC] 설정: %dHz, stereo, 최대 %d초\n",
                  VOICE_SAMPLE_RATE, VOICE_MAX_SECONDS);

    while (_voice_state == VOICE_RECORDING) {
        if (_rec_bytes / sizeof(int16_t) >= max_samples) {
            Serial.println("[REC] 최대 시간 도달 — 자동 종료");
            _voice_state = VOICE_STOPPING;
            break;
        }

        size_t bytes_read = 0;
        esp_err_t ret = i2s_channel_read(_voice_rx, buf32,
                                          VOICE_BUF_SAMPLES * sizeof(int32_t),
                                          &bytes_read, pdMS_TO_TICKS(100));
        if (ret != ESP_OK) {
            err_count++;
            if (err_count % 10 == 1)
                Serial.printf("[REC] ⚠️ i2s_read 실패 #%d: %s\n", err_count, esp_err_to_name(ret));
            continue;
        }
        if (bytes_read == 0) { err_count++; continue; }

        read_count++;
        int samples = bytes_read / sizeof(int32_t);

        // 피크 계산 + 신호 유무 확인
        for (int i = 0; i < samples; i++) {
            int32_t v = abs(buf32[i] >> 16);
            if (v > peak_max) peak_max = v;
            if (v > total_peak) total_peak = v;
            if (v > 10 && !signal_seen) {
                signal_seen = true;
                signal_first_sample = _rec_bytes / sizeof(int16_t);
                signal_seen_flag = true;
            }
        }

        // 버퍼에 저장
        if (_rec_bytes / sizeof(int16_t) + samples > max_samples)
            samples = max_samples - _rec_bytes / sizeof(int16_t);
        // stereo 32bit → mono 16bit 변환
        // ES7210 stereo: 짝수=L, 홀수=R (L채널만 추출)
        int16_t *dst = _rec_buf + _rec_bytes / sizeof(int16_t);
        int mono_samples = 0;
        for (int i = 0; i < samples; i += 2) {
            dst[mono_samples++] = (int16_t)(buf32[i] >> 16);  // L채널만 (24bit→16bit)
        }
        _rec_bytes += mono_samples * sizeof(int16_t);

        // DBG_PEAK_INTERVAL_MS마다 피크 레벨 출력
        uint32_t now = millis();
        if (now - last_peak_ms >= DBG_PEAK_INTERVAL_MS) {
            float elapsed = (now - start_ms) / 1000.0f;
            float rec_sec = (float)_rec_bytes / (VOICE_SAMPLE_RATE * sizeof(int16_t));

            // 레벨 바 (40칸)
            int bar = map(peak_max, 0, 32767, 0, 40);
            char bar_str[42] = {};
            for (int i = 0; i < bar && i < 40; i++) bar_str[i] = '#';

            Serial.printf("[REC] %.1fs | 저장: %.2fs | 피크: %5d | [%-40s] %s\n",
                          elapsed, rec_sec, peak_max, bar_str,
                          signal_seen ? "✅신호있음" : "❌무신호");
            peak_max = 0;
            last_peak_ms = now;
        }
    }

    // loop()에 UI 업데이트 기회 제공 (버튼색 복귀, 상태 갱신)
    vTaskDelay(pdMS_TO_TICKS(50));

    // 녹음 완료 통계
    float rec_sec = (float)_rec_bytes / (VOICE_SAMPLE_RATE * sizeof(int16_t));
    uint32_t elapsed = millis() - start_ms;

    Serial.println("\n[REC] ====== 녹음 완료 통계 ======");
    Serial.printf("[REC]   녹음 시간:    %.2f초\n", rec_sec);
    Serial.printf("[REC]   경과 시간:    %dms\n", elapsed);
    Serial.printf("[REC]   저장 크기:    %d bytes\n", _rec_bytes);
    Serial.printf("[REC]   읽기 성공:    %d회\n", read_count);
    Serial.printf("[REC]   읽기 실패:    %d회\n", err_count);
    Serial.printf("[REC]   전체 피크:    %d (%.1f%%)\n", total_peak, total_peak / 327.67f);
    Serial.printf("[REC]   신호 감지:    %s\n", signal_seen ? "✅ YES" : "❌ NO — 마이크 무신호!");

    if (!signal_seen)
        Serial.println("[REC]   → I2S/ES7210 초기화 문제 가능성. REG11, REG4B 확인 필요.");

    // 처음 샘플 덤프 (raw 32bit + 변환 16bit)
    Serial.printf("\n[REC] 처음 %d 샘플 덤프 (raw32 → 16bit):\n", DBG_DUMP_SAMPLES);
    Serial.println("[REC]   idx | raw32(hex)  | >>8(16bit)");
    Serial.println("[REC]   ----+-------------+-----------");
    int dump_n = min((int)(_rec_bytes / sizeof(int16_t)), DBG_DUMP_SAMPLES);
    // buf32는 이미 덮어써졌으니 _rec_buf에서 출력
    for (int i = 0; i < dump_n; i++) {
        Serial.printf("[REC]   %3d |     %-8d | %d\n", i, _rec_buf[i] << 8, _rec_buf[i]);
    }
    Serial.println("[REC] ============================\n");

    // ── 파이프라인: 서버 전송 → STT/LLM/TTS 수신 → 자동 재생 ─────────────────
    if (_rec_bytes > 0 && WiFi.status() == WL_CONNECTED) {
        _pipeline_start_ms = millis();  // 딜레이 측정 시작
        _voice_state = VOICE_PROCESSING;
#if VOICE_STREAM_UPLOAD
        // 스트리밍이 살아 있으면 잔량만 밀어내면 끝이다. 실패했으면 트림 후
        // 기존 일괄 전송으로 되돌아간다 — 오디오는 버퍼에 그대로 남아 있다.
        UploadResult ur = _upload_finish();
        if (ur == UP_RETRY_SAFE) {
            Serial.println("[UP] 미도달 — 일괄 전송으로 폴백");
            _rec_bytes = _trim_silence(_rec_buf, _rec_bytes);
            _send_to_server();
        } else if (ur == UP_SPENT) {
            // 서버가 이미 실행했을 수 있으므로 재전송하면 중복 실행이 된다.
            Serial.println("[UP] ❌ 응답 수신 실패 — 중복 실행 방지를 위해 재전송하지 않음");
            _rec_bytes = 0;
            _voice_set_status("응답을 받지 못했어요\n다시 시도해 주세요");
        }
#else
        _rec_bytes = _trim_silence(_rec_buf, _rec_bytes);
        _send_to_server();
#endif

        if (_rec_bytes > 0) {
            _voice_state = VOICE_PLAYING;
            // 정적 스택 사용 → 런타임 heap 단편화 무관
            _voice_task_handle = xTaskCreateStaticPinnedToCore(
                _play_task, "play",
                sizeof(_play_task_stack) / sizeof(StackType_t),
                NULL, 5, _play_task_stack, &_play_task_tcb, 1);
            if (!_voice_task_handle) {
                Serial.println("[PLAY] ❌ 태스크 생성 실패");
                _voice_state = VOICE_IDLE;
                _voice_set_status("재생 오류");
            }
        } else {
            Serial.println("[Server] 서버 응답 없음 — 재생 스킵");
            _voice_state = VOICE_IDLE;
        }
    } else {
        if (WiFi.status() != WL_CONNECTED)
            Serial.println("[Server] WiFi 미연결 — 서버 전송 스킵");
        _voice_state = VOICE_IDLE;
    }

    _voice_task_handle = NULL;
    vTaskDelete(NULL);
}

// ─── 재생 태스크 ─────────────────────────────────────────────────────────────
extern I2SClass _sound_i2s;

static void _play_task(void *arg) {
    float rec_sec = (float)_rec_bytes / (VOICE_SAMPLE_RATE * sizeof(int16_t));
    Serial.println("\n[PLAY] ====== 재생 시작 ======");
    Serial.printf("[PLAY]   재생할 데이터: %d bytes (%.2f초)\n", _rec_bytes, rec_sec);

    // 마이크 I2S(NUM_1, MASTER)가 GPIO9/45/42 클록을 계속 구동하면
    // 재생 I2S(NUM_0, MASTER)와 충돌 → ES8311 무음 원인
    if (_voice_rx) {
        i2s_channel_disable(_voice_rx);
        Serial.println("[PLAY]   mic RX 비활성화 (클록 충돌 방지)");
    }

    // I2S 열기
    _sound_i2s.setPins(VOICE_PIN_BCLK, VOICE_PIN_WS, VOICE_PIN_DOUT, VOICE_PIN_DIN, VOICE_PIN_MCLK);
    if (!_sound_i2s.begin(I2S_MODE_STD, VOICE_PLAY_RATE,
                           I2S_DATA_BIT_WIDTH_16BIT,
                           I2S_SLOT_MODE_STEREO,
                           I2S_STD_SLOT_BOTH)) {
        Serial.println("[PLAY] ❌ I2S begin 실패!");
        i2s_channel_enable(_voice_rx);  // mic 복구
        _voice_state = VOICE_IDLE;
        _voice_task_handle = NULL;
        vTaskDelete(NULL);
        return;
    }
    Serial.println("[PLAY]   I2S begin OK");

    // ES8311 초기화 (sound.h의 _es8311_init 재사용)
    if (_es8311_init() != ESP_OK) {
        Serial.println("[PLAY] ❌ ES8311 init 실패!");
        _sound_i2s.end();
        i2s_channel_enable(_voice_rx);  // mic 복구
        _voice_state = VOICE_IDLE;
        _voice_task_handle = NULL;
        vTaskDelete(NULL);
        return;
    }
    Serial.println("[PLAY]   ES8311 init OK");

    digitalWrite(VOICE_PIN_PA, HIGH);
    if (_pipeline_start_ms > 0) {
        float latency = (millis() - _pipeline_start_ms) / 1000.0f;
        Serial.printf("\n[LATENCY] ⏱ 녹음 종료 → 스피커 출력: %.2f초\n\n", latency);
        _pipeline_start_ms = 0;
    }
    Serial.println("[PLAY]   PA 앰프 ON");
    vTaskDelay(pdMS_TO_TICKS(100));

    const size_t CHUNK  = 512;   // mono 샘플 수
    size_t offset       = 0;
    uint32_t start_ms   = millis();
    uint32_t chunk_count = 0;
    static int16_t stereo_buf[CHUNK * 2];  // mono → stereo 확장 버퍼

    while (offset < _rec_bytes / sizeof(int16_t) && _voice_state == VOICE_PLAYING) {
        size_t to_read = min((size_t)CHUNK, (size_t)(_rec_bytes / sizeof(int16_t) - offset));
        // mono → stereo: L채널만, R채널은 0 (합산 방지)
        for (size_t i = 0; i < to_read; i++) {
            stereo_buf[i * 2]     = _rec_buf[offset + i];  // L
            stereo_buf[i * 2 + 1] = 0;                      // R=0 (합산 방지)
        }
        _sound_i2s.write((uint8_t *)stereo_buf, to_read * 2 * sizeof(int16_t));
        offset += to_read;
        chunk_count++;

        if (chunk_count % 20 == 0) {
            float progress = (float)offset / (_rec_bytes / sizeof(int16_t)) * 100.0f;
            float elapsed  = (millis() - start_ms) / 1000.0f;
            float rec_sec  = (float)_rec_bytes / (VOICE_SAMPLE_RATE * sizeof(int16_t));
            Serial.printf("[PLAY]   진행: %.1f%% (%.2f초 / %.2f초)\n",
                          progress, elapsed, rec_sec);
        }
    }

    bool completed = (offset >= _rec_bytes / sizeof(int16_t));
    float rec_sec_f = (float)_rec_bytes / (VOICE_SAMPLE_RATE * sizeof(int16_t));
    Serial.printf("[PLAY]   %s — %d청크, %dms / %.2f초\n",
                  completed ? "✅ 완료" : "⛔ 중단",
                  chunk_count, millis() - start_ms, rec_sec_f);

    vTaskDelay(pdMS_TO_TICKS(100));
    digitalWrite(VOICE_PIN_PA, LOW);
    Serial.println("[PLAY]   PA 앰프 OFF");
    _sound_i2s.end();

    // _sound_i2s.end()가 GPIO 매트릭스 라우팅을 리셋하므로
    // i2s_channel_enable만으로는 마이크 핀 연결이 복구되지 않음 → 채널 삭제 후 완전 재생성
    if (_voice_rx) {
        i2s_del_channel(_voice_rx);
        _voice_rx = NULL;
        Serial.println("[PLAY]   mic 채널 삭제");
    }
    _i2s_mic_init();
    Serial.println("[PLAY]   mic 채널 재생성 완료");
    Serial.println("[PLAY] ====== 재생 종료 ======\n");

    _voice_state = VOICE_IDLE;
    _voice_task_handle = NULL;
    vTaskDelete(NULL);
}

// ─── 상태 라벨 업데이트 ──────────────────────────────────────────────────────
// _record_task/_play_task에서 호출 시: 버퍼에만 씀 (LVGL 직접 호출 금지)
// loop()의 voice_check_state()에서 dirty 감지 후 실제 라벨 갱신
static void _voice_set_status(const char *text) {
    strlcpy(_voice_status_buf, text, sizeof(_voice_status_buf));
    _voice_status_dirty = true;
}

// ─── 파도타기 점 애니메이션 (순서대로 위아래로 물결) ─────────────────────────
static void _voice_wave_start() {
    if (_wave_running) return;
    _wave_running = true;
    for (int i = 0; i < 4; i++) {
        lv_anim_t a;
        lv_anim_init(&a);
        lv_anim_set_var(&a, voice_wave[i]);
        lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_y);
        lv_anim_set_values(&a, VOICE_WAVE_Y_BASE, VOICE_WAVE_Y_TOP);
        lv_anim_set_time(&a, 360);
        lv_anim_set_playback_time(&a, 360);
        lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
        lv_anim_set_delay(&a, i * 120);             // 원마다 시차 → 물결
        lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
        lv_anim_start(&a);
    }
}
static void _voice_wave_stop() {
    if (!_wave_running) return;
    _wave_running = false;
    for (int i = 0; i < 4; i++) {
        lv_anim_delete(voice_wave[i], (lv_anim_exec_xcb_t)lv_obj_set_y);
        lv_obj_set_y(voice_wave[i], VOICE_WAVE_Y_BASE);
    }
}

// ─── 상태별 레이아웃 (LVGL 스레드에서만 호출) ────────────────────────────────
static void _voice_apply_layout(VoiceState st) {
    bool recording = (st == VOICE_RECORDING);
    bool busy      = (st == VOICE_STOPPING || st == VOICE_PROCESSING || st == VOICE_PLAYING);

    // 캐릭터: 녹음 중엔 위로 올려 아래 텍스트 자리 확보
    lv_obj_align(voice_char, LV_ALIGN_CENTER, 0,
                 recording ? VOICE_CHAR_Y_REC : VOICE_CHAR_Y_DEFAULT);

    // 상태 텍스트: 녹음 중엔 캐릭터 아래, 그 외엔 캐릭터 위
    lv_obj_align((lv_obj_t*)voice_dot[1], LV_ALIGN_CENTER, 0,
                 recording ? VOICE_TEXT_Y_REC : VOICE_TEXT_Y_TOP);

    // 대기 중에만 마이크를 보이고, 녹음을 시작하면 파동 원으로 교체한다.
    if (st == VOICE_IDLE) lv_obj_clear_flag(voice_btn_mic, LV_OBJ_FLAG_HIDDEN);
    else                  lv_obj_add_flag  (voice_btn_mic, LV_OBJ_FLAG_HIDDEN);

    // 녹음·서버 처리·재생 동안 파도타기 원을 표시한다.
    // 녹음 중에는 원 영역을 다시 누르면 녹음이 종료된다.
    if (recording || busy) {
        lv_obj_clear_flag(voice_dots_cont, LV_OBJ_FLAG_HIDDEN);
        if (recording) lv_obj_add_flag  (voice_dots_cont, LV_OBJ_FLAG_CLICKABLE);
        else           lv_obj_clear_flag(voice_dots_cont, LV_OBJ_FLAG_CLICKABLE);
        _voice_wave_start();
    } else {
        lv_obj_add_flag(voice_dots_cont, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(voice_dots_cont, LV_OBJ_FLAG_CLICKABLE);
        _voice_wave_stop();
    }
}

// ─── loop()에서 상태 전환 감지 ───────────────────────────────────────────────
void voice_check_state() {
    // 타 태스크가 _voice_set_status()로 버퍼에 쓴 내용을 여기서 LVGL에 반영
    if (_voice_status_dirty) {
        if (voice_dot[1]) lv_label_set_text((lv_obj_t*)voice_dot[1], _voice_status_buf);
        _voice_status_dirty = false;
    }

    static VoiceState prev_state = VOICE_IDLE;
    VoiceState st = _voice_state;
    if (st != prev_state) {
        _voice_apply_layout(st);
        if (st == VOICE_IDLE) {
            // 대기 화면 복귀: 안내 문구 복원
            strlcpy(_voice_status_buf, "데스키봇에게\n요청해 보세요", sizeof(_voice_status_buf));
            if (voice_dot[1]) lv_label_set_text((lv_obj_t*)voice_dot[1], _voice_status_buf);
        }
        prev_state = st;
    }
}

// ─── 녹음 토글 ───────────────────────────────────────────────────────────────
// 마이크 버튼과 시리얼 `rec` 명령이 같은 경로를 타도록 콜백에서 분리했다.
// STT 벤치는 60발화 × 시작/종료로 120번을 눌러야 하는데, 터치가 한 번이라도
// 튀면 녹음 순서가 밀려 파일 이름이 전부 어긋난다.
void voice_toggle_record() {
    if (!_rec_buf) {
        Serial.println("[Voice] ❌ 버퍼 없음 — voice_audio_init 실패했을 가능성");
        return;
    }

    if (_voice_state == VOICE_IDLE) {
        Serial.println("[Voice] 🎙️ 녹음 버튼 눌림 → 녹음 시작");
        _voice_state = VOICE_RECORDING;
        _rec_start_ms = millis();
        signal_seen_flag = false;
#if VOICE_STREAM_UPLOAD
        // 녹음과 동시에 올린다. TLS 핸드셰이크(~0.5초)가 사용자가 말을 시작하는
        // 구간과 겹쳐 체감에서 사라진다. 실패하면 기존 일괄 전송으로 되돌아간다.
        if (WiFi.status() == WL_CONNECTED && !_upload_begin())
            Serial.println("[UP] 스트리밍 실패 — 일괄 전송으로 진행");
#endif
        _voice_set_status("사용자님의 음성을\n인식하고 있어요");
        _voice_task_handle = xTaskCreateStaticPinnedToCore(
            _record_task, "rec",
            sizeof(_rec_task_stack) / sizeof(StackType_t),
            NULL, 5, _rec_task_stack, &_rec_task_tcb, 1);
        if (!_voice_task_handle) {
            Serial.printf("[Voice] ❌ 녹음 태스크 생성 실패 (heap=%d)\n",
                          heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
            _voice_state = VOICE_IDLE;
            _voice_set_status("메모리 부족");
        }
    } else if (_voice_state == VOICE_RECORDING) {
        // 터치 IC가 탭 하나에 두 번 fired되는 경우 방지 (500ms 이내 종료 무시)
        if (millis() - _rec_start_ms < 500) {
            Serial.println("[Voice] ⚠️ 너무 빠른 종료 버튼 — 터치 중복으로 무시");
            return;
        }
        Serial.println("[Voice] ⏹️ 녹음 버튼 눌림 → 녹음 종료");
        _voice_state = VOICE_STOPPING;
        // 태스크가 STOPPING 감지 후 스스로 종료 — 완료 로그는 태스크에서 출력
    } else {
        Serial.printf("[Voice] 녹음 버튼 무시 (현재 상태: %d)\n", _voice_state);
    }
}


// ─── 버튼 콜백 ───────────────────────────────────────────────────────────────
static void _voice_btn_mic_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    voice_toggle_record();
}

// ─── UI 생성 ──────────────────────────────────────────────────────────────────
extern "C" void create_voice_ui() {
    lv_obj_t *scr = lv_scr_act();
    // 기존(0x112038)보다 더 어두운 배경
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0A121E), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // ── 상태 라벨 (캐릭터 상단, 2줄) ──────────────────────────────────────────
    voice_dot[1] = lv_label_create(scr);
    lv_label_set_text((lv_obj_t*)voice_dot[1], _voice_status_buf);
    lv_obj_set_style_text_color((lv_obj_t*)voice_dot[1], lv_color_hex(0xE5F0FF), LV_PART_MAIN);
    lv_obj_set_style_text_font((lv_obj_t*)voice_dot[1], &pretendard_medium_25, LV_PART_MAIN);
    // 2줄 안내라 줄이 붙어 보인다(팝업 메시지는 10px).
    lv_obj_set_style_text_line_space((lv_obj_t*)voice_dot[1], 8, LV_PART_MAIN);
    // 폭을 360으로 고정해 두면 두 줄 길이가 다를 때 짧은 줄이 크게 치우쳐 보였다
    // ("데스키봇" / "응답 준비중 ⋯"). 글자 폭에 맞춰 박스를 줄이고 박스 자체를
    // 화면 중앙에 두면, 줄 길이가 달라도 항상 가운데로 모인다.
    lv_label_set_long_mode((lv_obj_t*)voice_dot[1], LV_LABEL_LONG_WRAP);
    lv_obj_set_width((lv_obj_t*)voice_dot[1], LV_SIZE_CONTENT);
    lv_obj_set_style_text_align((lv_obj_t*)voice_dot[1], LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_set_style_pad_all((lv_obj_t*)voice_dot[1], 0, LV_PART_MAIN);
    lv_obj_align((lv_obj_t*)voice_dot[1], LV_ALIGN_CENTER, 0, VOICE_TEXT_Y_TOP);

    // ── 캐릭터 (가운데보다 살짝 위) ──────────────────────────────────────────
    voice_char = lv_image_create(scr);
    lv_image_set_src(voice_char, &character_voice);
    lv_image_set_scale(voice_char, 276);  // 210x207px -> 약 226x223px
    lv_obj_align(voice_char, LV_ALIGN_CENTER, 0, VOICE_CHAR_Y_DEFAULT);
    lv_obj_clear_flag(voice_char, LV_OBJ_FLAG_CLICKABLE);

    // ── 마이크 버튼 (캐릭터 아래) ────────────────────────────────────────────
    voice_btn_mic = lv_image_create(scr);
    lv_image_set_src(voice_btn_mic, &btn_mic);
    lv_image_set_scale(voice_btn_mic, 215);  // 120px -> 약 101px
    lv_obj_align(voice_btn_mic, LV_ALIGN_CENTER, 0, 145);
    lv_obj_add_flag(voice_btn_mic, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_ext_click_area(voice_btn_mic, VOICE_MIC_HIT_EXT);
    lv_obj_add_event_cb(voice_btn_mic, _voice_btn_mic_cb, LV_EVENT_CLICKED, NULL);

    // ── 파도타기 점 4개 (서버 처리~재생 중 표시, 기본 숨김) ──────────────────
    voice_dots_cont = lv_obj_create(scr);
    lv_obj_remove_style_all(voice_dots_cont);
    lv_obj_set_size(voice_dots_cont, 162, 52);
    lv_obj_align(voice_dots_cont, LV_ALIGN_CENTER, 0, VOICE_DOTS_Y);
    lv_obj_clear_flag(voice_dots_cont, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(voice_dots_cont, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_ext_click_area(voice_dots_cont, VOICE_STOP_HIT_EXT);
    lv_obj_add_event_cb(voice_dots_cont, _voice_btn_mic_cb, LV_EVENT_CLICKED, NULL);
    for (int i = 0; i < 4; i++) {
        voice_wave[i] = lv_image_create(voice_dots_cont);
        lv_image_set_src(voice_wave[i], &voice_wave_dot);
        lv_image_set_scale(voice_wave[i], 136);  // 48px -> 약 26px
        lv_obj_clear_flag(voice_wave[i], LV_OBJ_FLAG_CLICKABLE);
        lv_obj_set_pos(voice_wave[i], i * 38, VOICE_WAVE_Y_BASE);
    }

    Serial.println("[Voice] UI 생성 완료");
}
