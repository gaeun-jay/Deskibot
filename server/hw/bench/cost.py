#!/usr/bin/env python3
"""
비용 비교. 실제 녹음 90건의 길이 분포를 그대로 쓴다.

핵심은 단가가 아니라 과금 단위다. 이 제품의 발화는 평균 4.78초인데
CLOVA는 15초 단위로 올림하므로 거의 모든 호출이 15초로 과금된다.
Google은 1초 단위 올림이라 실제 길이에 가깝게 나온다.

  python3 bench/cost.py --clova-per-15s 3.0 --calls-per-day 20
"""
import argparse, math, os, statistics, wave

BENCH = os.path.dirname(os.path.abspath(__file__))

# 2026-08 기준 공개 요금표 (cloud.google.com/speech-to-text/pricing)
GOOGLE_FREE_MIN   = 60      # 계정당 월 60분 무료
GOOGLE_USD_PER_MIN = 0.024  # 데이터 로깅 미동의 기준 (동의 시 0.016)


def durations():
    d = os.path.join(BENCH, "audio")
    out = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".wav"):
            with wave.open(os.path.join(d, f), "rb") as w:
                out.append(w.getnframes() / w.getframerate())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clova-per-15s", type=float, default=None,
                    help="CLOVA CSR 15초당 요금(원, VAT 별도). 콘솔 요금표에서 확인")
    ap.add_argument("--calls-per-day", type=int, default=20)
    ap.add_argument("--krw-per-usd", type=float, default=1350.0)
    args = ap.parse_args()

    durs = durations()
    n = len(durs)
    avg = statistics.mean(durs)
    g_sec = sum(math.ceil(x) for x in durs) / n          # 호출당 Google 과금초
    c_unit = sum(math.ceil(x / 15) for x in durs) / n    # 호출당 CLOVA 15초 단위 수

    calls_mo = args.calls_per_day * 30
    print(f"실측 발화 {n}건: 평균 {avg:.2f}초 (중앙값 {statistics.median(durs):.2f}초)")
    print(f"호출당 과금량 — Google {g_sec:.2f}초 / CLOVA {c_unit:.2f}×15초\n")
    print(f"가정: 하루 {args.calls_per_day}회 = 월 {calls_mo}회, 환율 {args.krw_per_usd:,.0f}원/USD\n")

    # Google
    g_min = calls_mo * g_sec / 60
    billable = max(0.0, g_min - GOOGLE_FREE_MIN)
    g_usd = billable * GOOGLE_USD_PER_MIN
    print(f"Google STT v1")
    print(f"  월 사용 {g_min:.1f}분 | 무료 {GOOGLE_FREE_MIN}분 | 과금 {billable:.1f}분")
    print(f"  월 ${g_usd:.2f} ≈ {g_usd*args.krw_per_usd:,.0f}원")
    free_calls = int(GOOGLE_FREE_MIN * 60 / g_sec)
    print(f"  → 월 {free_calls:,}회까지는 무료 (현재 가정의 {free_calls/calls_mo:.1f}배)")

    # CLOVA: 무료 구간 없음(유료 서비스), 15초 단위 과금
    units = calls_mo * c_unit
    print(f"\nCLOVA CSR")
    print(f"  월 {units:,.0f} × 15초 단위")
    if args.clova_per_15s is not None:
        c_krw = units * args.clova_per_15s
        print(f"  단가 {args.clova_per_15s}원/15초 → 월 {c_krw:,.0f}원 (VAT 별도)")
        print(f"\n판정: {'CLOVA' if c_krw < g_usd*args.krw_per_usd else 'Google'}가 저렴 "
              f"(차액 {abs(c_krw - g_usd*args.krw_per_usd):,.0f}원/월)")
    else:
        # 손익분기: CLOVA 총액 = Google 총액이 되는 15초당 단가
        be = (g_usd * args.krw_per_usd) / units if units else 0
        print(f"  단가 미입력 — 손익분기 계산만 제시")
        print(f"\n손익분기 단가: 15초당 {be:.3f}원")
        print(f"  이보다 비싸면 Google이 저렴, 싸면 CLOVA가 저렴")
        if billable == 0:
            print(f"  ※ 현재 사용량은 Google 무료 한도 안이라 Google이 0원이다.")
            print(f"    CLOVA는 유료 구간이 없으므로 단가가 얼마든 Google이 저렴하다.")


if __name__ == "__main__":
    main()
