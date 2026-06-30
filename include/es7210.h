#pragma once
#include <Arduino.h>
#include <Wire.h>

#define ES7210_I2C_ADDR  0x40

// ─── 헬퍼 ────────────────────────────────────────────────────────────────────
static bool es7210_write(uint8_t reg, uint8_t val) {
    Wire.beginTransmission(ES7210_I2C_ADDR);
    Wire.write(reg);
    Wire.write(val);
    uint8_t err = Wire.endTransmission();
    if (err) Serial.printf("[ES7210] Write 0x%02X=0x%02X FAIL(err=%d)\n", reg, val, err);
    return err == 0;
}

static int es7210_read(uint8_t reg) {
    Wire.beginTransmission(ES7210_I2C_ADDR);
    Wire.write(reg);
    if (Wire.endTransmission(false) != 0) return -1;
    if (Wire.requestFrom((uint8_t)ES7210_I2C_ADDR, (uint8_t)1) != 1) return -1;
    return Wire.read();
}

// ─── 레지스터 덤프 (디버그용) ─────────────────────────────────────────────────
static void es7210_dump() {
    Serial.println("[ES7210] ── 레지스터 덤프 ──");
    uint8_t key_regs[] = {0x00,0x01,0x08,0x09,0x0A,0x10,0x11,0x12,
                          0x18,0x19,0x40,0x41,0x43,0x44,0x47,0x48,0x4B,0x3D,0x3E};
    const char* names[] = {"RESET","CLK1","DS_TDM","ADC12","ADC34","FMT0","FMT1","FMT2",
                            "VOL1","VOL2","ANASYS","BIAS12","MIC1G","MIC2G","MIC1PW","MIC2PW","PWR","ID1","ID2"};
    for (int i = 0; i < 19; i++) {
        int v = es7210_read(key_regs[i]);
        Serial.printf("  0x%02X %-8s = 0x%02X\n", key_regs[i], names[i], (uint8_t)v);
    }
    Serial.println("[ES7210] ────────────────────");
}

// ─── I2C 확인 ────────────────────────────────────────────────────────────────
static bool es7210_check_i2c() {
    Wire.beginTransmission(ES7210_I2C_ADDR);
    if (Wire.endTransmission() != 0) {
        Serial.println("[ES7210] ❌ I2C 응답 없음 (주소 0x40)");
        return false;
    }
    int id1 = es7210_read(0x3D);
    int id2 = es7210_read(0x3E);
    Serial.printf("[ES7210] I2C OK | Chip ID: 0x%02X 0x%02X (기대: 0x72 0x10)\n", id1, id2);
    return (id1 == 0x72);
}

// ─── 초기화 — Waveshare 2.06 이슈 #20에서 검증된 레지스터 값 ─────────────────
// 출처: https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.06/issues/20
static bool es7210_init_regs() {
    Serial.println("[ES7210] 초기화 시작 (검증된 레지스터 값)...");

    // 1. 소프트 리셋
    es7210_write(0x00, 0xFF);   // 전체 리셋
    delay(10);
    es7210_write(0x00, 0x41);   // 노멀 모드 (0x32 아님! 0x41이 맞음)
    delay(100);                 // 충분한 안정화 대기

    // 2. 클럭 설정
    es7210_write(0x01, 0x00);   // CLK: MCLK 입력 활성, 분주 없음

    // 3. ADC 채널 설정 (2채널 스테레오)
    es7210_write(0x08, 0x00);   // TDM/DS: 2채널 모드
    es7210_write(0x09, 0x13);   // ADC1/2 활성
    es7210_write(0x0A, 0x13);   // ADC3/4 (사용 안 해도 같이 설정)

    // 4. I2S 포맷
    es7210_write(0x10, 0x00);   // 2 슬롯 스테레오
    es7210_write(0x11, 0x32);   // 16bit word, 16bit slot, I2S 표준 포맷
                                 // (0x32 = b0011_0010: I2S, 16bit slot, 16bit word)
    es7210_write(0x12, 0x01);   // LRCK 극성 등
    es7210_write(0x13, 0x00);

    // 5. 아날로그 시스템 설정
    es7210_write(0x40, 0x33);   // 아날로그 시스템 (MIC1/2 활성)
    es7210_write(0x41, 0x70);   // MIC1/2 BIAS 설정
    es7210_write(0x42, 0x70);   // MIC3/4 BIAS 설정

    // 6. MIC 게인 (최대 37.5dB)
    es7210_write(0x43, 0x1F);   // MIC1 게인 37.5dB
    es7210_write(0x44, 0x1F);   // MIC2 게인 37.5dB

    // 7. MIC 파워 설정
    es7210_write(0x47, 0x08);   // MIC1 파워 활성화
    es7210_write(0x48, 0x08);   // MIC2 파워 활성화
    es7210_write(0x4B, 0x10);   // MIC1/2 파워업

    // 8. ADC 디지털 볼륨 (0x00 = 0dB, 최대)
    es7210_write(0x18, 0x00);   // ADC1 볼륨
    es7210_write(0x19, 0x00);   // ADC2 볼륨

    delay(50);  // 안정화

    // 덤프로 실제 반영됐는지 확인
    es7210_dump();

    int id = es7210_read(0x3D);
    if (id == 0x72) {
        Serial.println("[ES7210] ✅ 초기화 완료");
        return true;
    }
    Serial.println("[ES7210] ❌ 초기화 후 ID 확인 실패");
    return false;
}