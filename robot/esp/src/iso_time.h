#pragma once
#include <Arduino.h>
#include <time.h>

// 서버(deskibot-sw)는 timestamptz를 "2026-08-10T14:08:52.493323+00:00" 형태로 보낸다.
// ESP의 localtime은 KST라서 오프셋을 반영해 epoch로 맞춰야 재부팅 복원 시 경과
// 시간을 제대로 계산할 수 있다. 오프셋이 없는 문자열은 어느 기준인지 알 수 없으므로
// 거부한다(get_iso_now()가 만드는 로컬 문자열이 섞여 들어와도 오판하지 않도록).

static long iso_days_from_civil(long y, unsigned m, unsigned d) {
    y -= m <= 2;
    const long     era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153u * (m + (m > 2 ? -3u : 9u)) + 2u) / 5u + d - 1u;
    const unsigned doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
    return era * 146097L + (long)doe - 719468L;
}

static bool iso_to_epoch(const char *iso, time_t &out) {
    if (!iso || !iso[0]) return false;
    int Y, Mo, D, H, Mi, S;
    if (sscanf(iso, "%d-%d-%dT%d:%d:%d", &Y, &Mo, &D, &H, &Mi, &S) != 6) return false;
    if (Mo < 1 || Mo > 12 || D < 1 || D > 31) return false;

    const char *t = strchr(iso, 'T');
    if (!t) return false;

    int off_sec = 0;
    if (!strchr(t, 'Z')) {
        // 날짜부의 '-'와 헷갈리지 않도록 'T' 뒤에서만 오프셋 부호를 찾는다.
        const char *p = nullptr;
        for (const char *c = t; *c; ++c)
            if (*c == '+' || *c == '-') { p = c; break; }
        if (!p) return false;                       // 오프셋 없음 — 복원 포기
        int oh = 0, om = 0;
        if (strchr(p, ':')) {
            if (sscanf(p + 1, "%d:%d", &oh, &om) < 1) return false;
        } else {
            int v = 0;
            if (sscanf(p + 1, "%4d", &v) != 1) return false;
            oh = v / 100; om = v % 100;
        }
        off_sec = oh * 3600 + om * 60;
        if (*p == '-') off_sec = -off_sec;
    }

    out = (time_t)(iso_days_from_civil(Y, (unsigned)Mo, (unsigned)D) * 86400L
                   + H * 3600L + Mi * 60L + S - off_sec);
    return true;
}

// 현재 시각. NTP 미동기화면 false.
static bool iso_now_epoch(time_t &out) {
    time(&out);
    return out >= 1000000L;
}

// started_at 이후 흐른 초. 계산할 수 없으면 0.
static uint32_t iso_elapsed_sec(const char *started_at) {
    time_t started, now;
    if (!iso_to_epoch(started_at, started)) return 0;
    if (!iso_now_epoch(now)) return 0;
    if (now <= started) return 0;
    return (uint32_t)(now - started);
}
