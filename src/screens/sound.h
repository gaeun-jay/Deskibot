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
#define SOUND_VOLUME        45
#define SOUND_MIC_GAIN      (es8311_mic_gain_t)(3)

// ─── 상태 ────────────────────────────────────────────────────────────────────
static I2SClass _sound_i2s;
static bool     _sound_initialized = false;
static bool     _sound_playing     = false;

static const unsigned char *_sound_pcm_data = nullptr;
static uint32_t             _sound_pcm_len  = 0;

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