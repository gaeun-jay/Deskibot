#pragma once
#include <Arduino.h>
#include "ESP_I2S.h"
#include "esp_check.h"
#include "es8311.h"
#include "pin_config.h"
#include "drowsy_beep.h"
#include "phone_beep.h"

// ─── 설정 ────────────────────────────────────────────────────────────────────
#define SOUND_SAMPLE_RATE   16000
// ES8311 DAC 볼륨(레지스터 0x32). 드라이버가 reg32 = volume*256/100 - 1 로 바꾸고,
// reg32 191이 0dB, 한 스텝이 0.5dB다. 즉 45=-38dB, 60=-19.5dB, 70=-6.5dB, 75=0dB.
// 음성(TTS) 재생도 voice.h가 이 초기화를 그대로 쓰므로 알림음과 함께 바뀐다.
// 너무 올리면 스피커에서 깨지니 한 번에 크게 올리지 말 것.
#define SOUND_VOLUME        60
#define SOUND_MIC_GAIN      (es8311_mic_gain_t)(3)

// ─── 상태 ────────────────────────────────────────────────────────────────────
static I2SClass _sound_i2s;
static bool     _sound_initialized = false;
static bool     _sound_playing     = false;

static const unsigned char *_sound_pcm_data = nullptr;
static uint32_t             _sound_pcm_len  = 0;

// ─── 마감 알림음 (런타임 합성) ───────────────────────────────────────────────
// 기존 비프음은 헤더로 박아둔 PCM이라 각각 744KB/529KB를 차지한다. 플래시가
// 95%를 넘긴 상황이라 알림음까지 에셋으로 넣기는 어렵다. 두 음짜리 차임은
// 코드로 합성하면 플래시 비용이 0이고, 버퍼는 PSRAM에서 한 번만 만들어 재사용한다.
#define NOTIFY_TONE1_HZ    987.767f   // B5
#define NOTIFY_TONE2_HZ   1318.510f   // E6
#define NOTIFY_TONE1_MS    130
#define NOTIFY_GAP_MS       30
#define NOTIFY_TONE2_MS    280
#define NOTIFY_AMPLITUDE  11000       // 16비트 풀스케일의 약 1/3 — 경고음보다 부드럽게

static int16_t *_notify_pcm       = nullptr;
static uint32_t _notify_pcm_bytes = 0;

static bool _sound_build_notify() {
    if (_notify_pcm) return true;                 // 이미 만들어 뒀으면 재사용

    const uint32_t n1     = SOUND_SAMPLE_RATE * NOTIFY_TONE1_MS / 1000;
    const uint32_t ngap   = SOUND_SAMPLE_RATE * NOTIFY_GAP_MS   / 1000;
    const uint32_t n2     = SOUND_SAMPLE_RATE * NOTIFY_TONE2_MS / 1000;
    const uint32_t frames = n1 + ngap + n2;
    const size_t   bytes  = (size_t)frames * 2 * sizeof(int16_t);   // L/R 스테레오

    int16_t *buf = (int16_t *)heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!buf) buf = (int16_t *)malloc(bytes);     // PSRAM 없으면 내부 힙으로
    if (!buf) {
        Serial.println("[Sound] 알림음 버퍼 할당 실패");
        return false;
    }

    const uint32_t fade = SOUND_SAMPLE_RATE / 200;   // 5ms — 시작 클릭 방지
    for (uint32_t i = 0; i < frames; ++i) {
        float v = 0.0f;
        if (i < n1) {                                 // 첫 음
            v = sinf(2.0f * PI * NOTIFY_TONE1_HZ * i / SOUND_SAMPLE_RATE)
                * expf(-3.5f * (float)i / n1);
        } else if (i >= n1 + ngap) {                  // 둘째 음 (사이 짧은 무음)
            const uint32_t j = i - (n1 + ngap);
            v = sinf(2.0f * PI * NOTIFY_TONE2_HZ * j / SOUND_SAMPLE_RATE)
                * expf(-3.0f * (float)j / n2);
        }
        if (i < fade) v *= (float)i / fade;
        const int16_t s = (int16_t)(v * NOTIFY_AMPLITUDE);
        buf[i * 2]     = s;
        buf[i * 2 + 1] = s;
    }

    _notify_pcm       = buf;
    _notify_pcm_bytes = (uint32_t)bytes;
    Serial.printf("[Sound] 알림음 합성 완료 (%u bytes)\n", (unsigned)bytes);
    return true;
}

// ─── ES8311 초기화 ────────────────────────────────────────────────────────────
static esp_err_t _es8311_init() {
    es8311_handle_t es_handle = es8311_create(0, ES8311_ADDRRES_0);
    if (!es_handle) {
        Serial.println("[Sound] ES8311 create failed");
        return ESP_FAIL;
    }

    const es8311_clock_config_t es_clk = {
        .mclk_inverted      = false,
        .sclk_inverted      = false,
        .mclk_from_mclk_pin = true,
        .mclk_frequency     = SOUND_SAMPLE_RATE * 256,
        .sample_frequency   = SOUND_SAMPLE_RATE
    };

    esp_err_t ret;
    ret = es8311_init(es_handle, &es_clk, ES8311_RESOLUTION_16, ES8311_RESOLUTION_16);
    if (ret != ESP_OK) { Serial.println("[Sound] es8311_init failed"); return ret; }

    ret = es8311_sample_frequency_config(es_handle, es_clk.mclk_frequency, es_clk.sample_frequency);
    if (ret != ESP_OK) { Serial.println("[Sound] freq config failed"); return ret; }

    ret = es8311_microphone_config(es_handle, false);
    if (ret != ESP_OK) { Serial.println("[Sound] mic config failed"); return ret; }

    ret = es8311_voice_volume_set(es_handle, SOUND_VOLUME, NULL);
    if (ret != ESP_OK) { Serial.println("[Sound] volume set failed"); return ret; }

    ret = es8311_microphone_gain_set(es_handle, SOUND_MIC_GAIN);
    if (ret != ESP_OK) { Serial.println("[Sound] gain set failed"); return ret; }

    return ESP_OK;
}

// ─── 오디오 재생 태스크 ───────────────────────────────────────────────────────
static void _sound_task(void *param) {
    // I2S 초기화
    _sound_i2s.setPins(BCLKPIN, WSPIN, DIPIN, DOPIN, MCLKPIN);
    if (!_sound_i2s.begin(I2S_MODE_STD, SOUND_SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
        Serial.println("[Sound] I2S init failed!");
        _sound_playing = false;
        vTaskDelete(NULL);
        return;
    }
    Serial.println("[Sound] I2S OK");

    // ES8311 초기화 (Wire는 이미 setup에서 했으니 재호출 안 함)
    if (_es8311_init() != ESP_OK) {
        Serial.println("[Sound] ES8311 init failed!");
        _sound_i2s.end();
        _sound_playing = false;
        vTaskDelete(NULL);
        return;
    }
    Serial.println("[Sound] ES8311 OK");

    // PA 앰프 켜기 + 잠깐 대기
    digitalWrite(PA, HIGH);
    vTaskDelay(pdMS_TO_TICKS(100));

    // PCM 재생
    if (_sound_pcm_data && _sound_pcm_len > 0) {
        size_t written = _sound_i2s.write((uint8_t *)_sound_pcm_data, _sound_pcm_len);
        Serial.printf("[Sound] written: %d / %d bytes\n", written, _sound_pcm_len);
    }

    vTaskDelay(pdMS_TO_TICKS(100));

    // PA 앰프 끄기
    digitalWrite(PA, LOW);
    _sound_i2s.end();
    _sound_playing = false;
    Serial.println("[Sound] 재생 완료");
    vTaskDelete(NULL);
}

// ─── 소리 초기화 (setup에서 호출) ────────────────────────────────────────────
void sound_init() {
    pinMode(PA, OUTPUT);
    digitalWrite(PA, LOW);
    _sound_initialized = true;
    Serial.println("[Sound] 초기화 완료");
}

// ─── 소리 재생 ────────────────────────────────────────────────────────────────
void sound_play(int alert_type) {
    if (!_sound_initialized || _sound_playing) return;

    if (alert_type == ALERT_DROWSY) {
        _sound_pcm_data = drowsy_pcm;
        _sound_pcm_len  = drowsy_pcm_len;
        Serial.println("[Sound] Drowsy 비프음 재생");
    } else if (alert_type == ALERT_PHONE) {
        _sound_pcm_data = phone_pcm;
        _sound_pcm_len  = phone_pcm_len;
        Serial.println("[Sound] Phone 비프음 재생");
    } else if (alert_type == ALERT_DEADLINE) {
        if (!_sound_build_notify()) return;
        _sound_pcm_data = (const unsigned char *)_notify_pcm;
        _sound_pcm_len  = _notify_pcm_bytes;
        Serial.println("[Sound] 마감 알림음 재생");
    } else {
        return;
    }

    _sound_playing = true;
    xTaskCreatePinnedToCore(_sound_task, "sound_task", 8192, NULL, 1, NULL, 1);
}

// ─── 재생 중 여부 확인 ────────────────────────────────────────────────────────
bool sound_is_playing() {
    return _sound_playing;
}