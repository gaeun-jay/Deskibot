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
#include <HTTPClient.h>
#define VOICE_SERVER_IP     "10.242.4.133"
#define VOICE_SERVER_PORT   8000

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
enum VoiceState { VOICE_IDLE, VOICE_RECORDING, VOICE_PROCESSING, VOICE_PLAYING };

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

// ─── Firestore 태스크 전역 (firebase_handler.h에서 정의) ─────────────────────
extern char fs_task_assignment[];
extern char fs_task_etc[];
extern char fs_task_health[];
extern volatile bool _fs_tasks_ready;

// ─── UI 오브젝트 ──────────────────────────────────────────────────────────────
static lv_obj_t *voice_btn_mic = nullptr;
static lv_obj_t *voice_dot[4]  = {};   // [0]=재생버튼, [1]=상태라벨

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
static char  _voice_status_buf[64] = "데스키봇에게 요청해 보세요";
static volatile bool _voice_status_dirty = false;

// ─── 역질문 대기 상태 (ask_todo_details 수신 시 저장) ─────────────────────────
// 사용자가 시간/알림을 말하면 다음 요청에 X-Pending-* 헤더로 서버에 전달
static char _pending_todo_content[128] = {};
static char _pending_todo_date[16]     = {};

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

    // ⑧ MIC1/2 활성화 (6dB — 클리핑 방지)
    Serial.println("[ES7210] ⑧ MIC1/2 활성화 (18dB)...");
    _es7210_write(0x4B, 0xFF);
    _es7210_write(0x4C, 0xFF);
    _es7210_update_bit(0x01, 0x0B, 0x00);
    _es7210_write(0x4B, 0x00);
    _es7210_update_bit(0x43, 0x10, 0x10);
    _es7210_update_bit(0x43, 0x0F, 0x05);  // 18dB
    _es7210_update_bit(0x44, 0x10, 0x10);
    _es7210_update_bit(0x44, 0x0F, 0x05);  // 18dB
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
static bool _read_exact(WiFiClient *c, uint8_t *dst, uint32_t n) {
    uint32_t got = 0, deadline = millis() + 5000;
    while (got < n && millis() < deadline) {
        if (c->available()) got += c->readBytes(dst + got, n - got);
        else delay(5);
    }
    return got == n;
}

// ─── 서버 전송 → STT/LLM/TTS 수신 ───────────────────────────────────────────
static void _send_to_server() {
    _voice_set_status("서버 전송 중...");
    Serial.printf("\n[Server] POST http://%s:%d/process (%d bytes, %.1f초)\n",
                  VOICE_SERVER_IP, VOICE_SERVER_PORT,
                  _rec_bytes, (float)_rec_bytes / (VOICE_SAMPLE_RATE * 2));

    WiFiClient  wifi_client;
    HTTPClient  http;
    char url_buf[64];
    snprintf(url_buf, sizeof(url_buf), "http://%s:%d/process", VOICE_SERVER_IP, VOICE_SERVER_PORT);
    http.begin(wifi_client, url_buf);
    http.addHeader("Content-Type", "application/octet-stream");
    if (_pending_todo_content[0]) {
        http.addHeader("X-Pending-Content", _pending_todo_content);
        http.addHeader("X-Pending-Date",    _pending_todo_date);
        Serial.printf("[Voice] 역질문 컨텍스트 전송: '%s' / %s\n",
                      _pending_todo_content, _pending_todo_date);
    }
    http.setTimeout(30000);

    uint32_t t0   = millis();
    int      code = http.POST((uint8_t *)_rec_buf, _rec_bytes);
    Serial.printf("[Server] HTTP %d (%.1fs)\n", code, (millis() - t0) / 1000.0f);

    if (code != 200) {
        Serial.printf("[Server] ❌ 실패 (code=%d)\n", code);
        http.end();
        _rec_bytes = 0;
        return;
    }

    int resp_total = http.getSize();
    WiFiClient *wifi_stream = http.getStreamPtr();
    _voice_set_status("응답 처리 중...");

    // 1. STT 결과
    uint32_t t_len = 0;
    if (!_read_exact(wifi_stream, (uint8_t *)&t_len, 4)) {
        Serial.println("[Server] ❌ STT 길이 수신 실패");
        http.end(); _rec_bytes = 0; return;
    }
    if (t_len > 0 && t_len < 512) {
        char *tbuf = (char *)malloc(t_len + 1);
        _read_exact(wifi_stream, (uint8_t *)tbuf, t_len);
        tbuf[t_len] = 0;
        Serial.printf("[STT] 결과: \"%s\"\n", tbuf);
        free(tbuf);
    }

    // 2. 명령 JSON (서버가 Firestore 처리 후 action 타입을 반환)
    uint32_t r_len = 0;
    if (!_read_exact(wifi_stream, (uint8_t *)&r_len, 4)) {
        Serial.println("[Server] ❌ CMD 길이 수신 실패");
        http.end(); _rec_bytes = 0; return;
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
            // 서버가 Firestore 처리 완료 → pending 클리어
            _pending_todo_content[0] = '\0';
            _pending_todo_date[0]    = '\0';
            Serial.println("[CMD] ✅ Firestore 처리 완료 — pending 클리어");
        }
        // action == "none" 이거나 get_schedule이면 pending 유지 없이 그냥 패스

        free(rbuf);
    }

    // 3. TTS PCM 오디오 → _rec_buf 재사용
    uint32_t audio_len = (resp_total >= 0) ? (resp_total - 4 - t_len - 4 - r_len) : 0;
    if (audio_len == 0 || audio_len > VOICE_MAX_BUF_BYTES) {
        Serial.printf("[Server] ❌ 오디오 길이 이상: %d\n", audio_len);
        http.end(); _rec_bytes = 0; return;
    }

    _voice_set_status("데스키봇이 말하고 있어요");
    uint8_t *dst      = (uint8_t *)_rec_buf;
    uint32_t received = 0, dl = millis() + 20000;
    while (received < audio_len && millis() < dl) {
        if (wifi_stream->available())
            received += wifi_stream->readBytes(dst + received,
                                          min(audio_len - received, (uint32_t)1024));
        else delay(10);
    }
    _rec_bytes = received;
    http.end();

    float dur = (float)_rec_bytes / (VOICE_SAMPLE_RATE * 2);
    Serial.printf("[TTS] %d bytes 수신 (%.1f초)\n", _rec_bytes, dur);
    _voice_set_status("데스키봇이 말하고 있어요");
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
            _voice_state = VOICE_IDLE;
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
            if (v > 10) signal_seen = true;
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
        _send_to_server();

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

// ─── loop()에서 재생 완료 감지 ───────────────────────────────────────────────
void voice_check_state() {
    // 타 태스크가 _voice_set_status()로 버퍼에 쓴 내용을 여기서 LVGL에 반영
    if (_voice_status_dirty) {
        if (voice_dot[1]) lv_label_set_text((lv_obj_t*)voice_dot[1], _voice_status_buf);
        _voice_status_dirty = false;
    }

    static int prev_state = VOICE_IDLE;
    if (prev_state != VOICE_IDLE && _voice_state == VOICE_IDLE) {
        // 재생/녹음 완료 → 버튼 색 복귀
        if (voice_btn_mic)
            lv_obj_set_style_bg_color(voice_btn_mic, lv_color_hex(0x1A6FE8), LV_STATE_DEFAULT);
        strlcpy(_voice_status_buf, "데스키봇에게 요청해 보세요", sizeof(_voice_status_buf));
        if (voice_dot[1]) lv_label_set_text((lv_obj_t*)voice_dot[1], _voice_status_buf);
    }
    prev_state = _voice_state;
}

// ─── 버튼 콜백 ───────────────────────────────────────────────────────────────
static void _voice_btn_mic_cb(lv_event_t *e) {
    if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
    if (!_rec_buf) {
        Serial.println("[Voice] ❌ 버퍼 없음 — voice_audio_init 실패했을 가능성");
        return;
    }

    if (_voice_state == VOICE_IDLE) {
        Serial.println("[Voice] 🎙️ 녹음 버튼 눌림 → 녹음 시작");
        _voice_state = VOICE_RECORDING;
        _rec_start_ms = millis();
        _voice_set_status("사용자님의 음성을 인식하고 있어요");
        lv_obj_set_style_bg_color(voice_btn_mic, lv_color_hex(0xE83A1A), LV_STATE_DEFAULT);
        _voice_task_handle = xTaskCreateStaticPinnedToCore(
            _record_task, "rec",
            sizeof(_rec_task_stack) / sizeof(StackType_t),
            NULL, 5, _rec_task_stack, &_rec_task_tcb, 1);
        if (!_voice_task_handle) {
            Serial.printf("[Voice] ❌ 녹음 태스크 생성 실패 (heap=%d)\n",
                          heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
            _voice_state = VOICE_IDLE;
            lv_obj_set_style_bg_color(voice_btn_mic, lv_color_hex(0x1A6FE8), LV_STATE_DEFAULT);
            _voice_set_status("메모리 부족");
        }
    } else if (_voice_state == VOICE_RECORDING) {
        // 터치 IC가 탭 하나에 두 번 fired되는 경우 방지 (500ms 이내 종료 무시)
        if (millis() - _rec_start_ms < 500) {
            Serial.println("[Voice] ⚠️ 너무 빠른 종료 버튼 — 터치 중복으로 무시");
            return;
        }
        Serial.println("[Voice] ⏹️ 녹음 버튼 눌림 → 녹음 종료");
        _voice_state = VOICE_IDLE;
        lv_obj_set_style_bg_color(voice_btn_mic, lv_color_hex(0x1A6FE8), LV_STATE_DEFAULT);
        // 태스크가 IDLE 감지 후 스스로 종료 — 완료 로그는 태스크에서 출력
    } else {
        Serial.printf("[Voice] 녹음 버튼 무시 (현재 상태: %d)\n", _voice_state);
    }
}

// ─── UI 생성 ──────────────────────────────────────────────────────────────────
extern "C" void create_voice_ui() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x112038), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    static lv_style_t style_btn;
    lv_style_init(&style_btn);
    lv_style_set_radius(&style_btn, LV_RADIUS_CIRCLE);
    lv_style_set_border_width(&style_btn, 0);
    lv_style_set_shadow_width(&style_btn, 0);
    lv_style_set_text_color(&style_btn, lv_color_white());
    lv_style_set_text_font(&style_btn, &lv_font_montserrat_30);

    // 가운데: 녹음 버튼 (파란색 → 녹음 중 빨간색)
    voice_btn_mic = lv_button_create(scr);
    lv_obj_add_style(voice_btn_mic, &style_btn, LV_STATE_DEFAULT);
    lv_obj_set_style_bg_color(voice_btn_mic, lv_color_hex(0x1A6FE8), LV_STATE_DEFAULT);
    lv_obj_set_size(voice_btn_mic, 120, 120);
    lv_obj_align(voice_btn_mic, LV_ALIGN_CENTER, 0, 0);
    lv_obj_t *lbl_rec = lv_label_create(voice_btn_mic);
    lv_label_set_text(lbl_rec, LV_SYMBOL_AUDIO);
    lv_obj_center(lbl_rec);
    lv_obj_add_event_cb(voice_btn_mic, _voice_btn_mic_cb, LV_EVENT_CLICKED, NULL);

    // 상태 라벨
    voice_dot[1] = lv_label_create(scr);
    lv_label_set_text((lv_obj_t*)voice_dot[1], _voice_status_buf);
    lv_obj_set_style_text_color((lv_obj_t*)voice_dot[1], lv_color_hex(0xA0AAB8), LV_PART_MAIN);
    lv_obj_set_style_text_font((lv_obj_t*)voice_dot[1], &pretendard_medium_18, LV_PART_MAIN);
    lv_label_set_long_mode((lv_obj_t*)voice_dot[1], LV_LABEL_LONG_WRAP);
    lv_obj_set_width((lv_obj_t*)voice_dot[1], 320);
    lv_obj_set_style_text_align((lv_obj_t*)voice_dot[1], LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align((lv_obj_t*)voice_dot[1], LV_ALIGN_CENTER, 0, 90);

    Serial.println("[Voice] UI 생성 완료");
}