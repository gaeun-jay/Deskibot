#!/usr/bin/env python3
"""
3단계: 지표 집계와 유의성 검정.

n이 60~100 정도면 "CER이 0.02 낮다"는 그냥 우연일 수 있다. 그래서
- CER 차이  → 발화별 쌍(paired) 부트스트랩 신뢰구간
- intent 정오 → McNemar 정확검정(불일치 쌍만 본다)
을 붙인다. "유의차 없음"도 정당한 결론이고, 그 경우 레이턴시·비용으로 고른다.

    python3 bench/score.py --baseline google_v1:1 --challenger clova_csr:0
"""

import argparse, json, math, os, random, sys
from collections import defaultdict

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH_DIR)
from normalize import cer, wer, keyword_hit
from adapters import PHRASE_HINTS

RESULTS = os.path.join(BENCH_DIR, "results")
SEED = 42


def load(name):
    p = os.path.join(RESULTS, name)
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def cell_of(rec):
    return f"{rec['engine']}:{int(rec['hints'])}"


def pct(x):
    return f"{100*x:5.1f}%"


def percentile(vals, q):
    if not vals:
        return float("nan")
    s = sorted(vals)
    k = (len(s) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def paired_bootstrap(pairs, n=10000):
    """pairs = [(a_i, b_i)]. a-b 차이의 평균과 95% CI."""
    if not pairs:
        return (float("nan"),) * 3
    rng = random.Random(SEED)
    diffs = [a - b for a, b in pairs]
    m = sum(diffs) / len(diffs)
    boots = []
    for _ in range(n):
        s = [diffs[rng.randrange(len(diffs))] for _ in range(len(diffs))]
        boots.append(sum(s) / len(s))
    boots.sort()
    return m, boots[int(0.025 * n)], boots[int(0.975 * n)]


def mcnemar(pairs):
    """pairs = [(a_ok, b_ok)]. 양측 정확검정 p값과 불일치 쌍 개수."""
    b = sum(1 for x, y in pairs if x and not y)
    c = sum(1 for x, y in pairs if y and not x)
    n = b + c
    if n == 0:
        return 1.0, b, c
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) * (0.5 ** n)
    return min(1.0, 2 * tail), b, c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default="google_v1:0", help="Google 맨몸(힌트 없음)")
    ap.add_argument("--challenger", default="clova_csr:0")
    args = ap.parse_args()

    trans  = load("transcripts.jsonl")
    intents = {(r["id"], r["engine"], r["hints"]): r for r in load("intents.jsonl")}
    if not trans:
        sys.exit("results/transcripts.jsonl이 없습니다. 먼저 run_bench.py를 돌리세요.")

    cells = defaultdict(list)
    for r in trans:
        cells[cell_of(r)].append(r)

    summary = {}
    for cell, recs in sorted(cells.items()):
        ok = [r for r in recs if not r.get("error")]
        cers = [cer(r["ref"], r["hyp"]) for r in ok]
        wers = [wer(r["ref"], r["hyp"]) for r in ok]
        lats = [r["latency"] for r in ok if r.get("latency")]
        empty = sum(1 for r in ok if not r["hyp"].strip())

        ints = [intents.get((r["id"], r["engine"], r["hints"])) for r in ok]
        ints = [i for i in ints if i]
        intent_acc = (sum(1 for i in ints if i["intent_ok"]) / len(ints)) if ints else None
        tool_acc   = (sum(1 for i in ints if i["tool_ok"]) / len(ints)) if ints else None

        kw = {}
        for k in PHRASE_HINTS:
            rel = [r for r in ok if keyword_hit(k, r["ref"])]
            kw[k] = (sum(1 for r in rel if keyword_hit(k, r["hyp"])) / len(rel)) if rel else None

        by_noise = {}
        for r in ok:
            by_noise.setdefault(r.get("noise") or "미지정", []).append(cer(r["ref"], r["hyp"]))
        by_noise = {k: sum(v) / len(v) for k, v in by_noise.items()}

        summary[cell] = {
            "n": len(recs), "errors": len(recs) - len(ok),
            "cer": sum(cers) / len(cers) if cers else None,
            "wer": sum(wers) / len(wers) if wers else None,
            "empty_rate": empty / len(ok) if ok else None,
            "latency_p50": percentile(lats, 0.50),
            "latency_p95": percentile(lats, 0.95),
            "intent_acc": intent_acc, "tool_acc": tool_acc,
            "keyword_recall": kw, "cer_by_noise": by_noise,
        }

    print(f"\n{'셀':<20}{'n':>4}{'CER':>9}{'WER':>9}{'빈결과':>8}{'intent':>9}{'p50':>8}{'p95':>8}")
    print("─" * 75)
    for cell, s in summary.items():
        print(f"{cell:<20}{s['n']:>4}"
              f"{(s['cer'] if s['cer'] is not None else float('nan')):>9.3f}"
              f"{(s['wer'] if s['wer'] is not None else float('nan')):>9.3f}"
              f"{pct(s['empty_rate']) if s['empty_rate'] is not None else '     -':>8}"
              f"{pct(s['intent_acc']) if s['intent_acc'] is not None else '     -':>9}"
              f"{s['latency_p50']:>8.2f}{s['latency_p95']:>8.2f}")

    # ─── 두 구성의 직접 비교 (같은 발화끼리 짝지어서) ───────────────────────
    def parse(cell):
        eng, h = cell.rsplit(":", 1)
        return eng, bool(int(h))

    def pick(cell):
        eng, h = parse(cell)
        return {r["id"]: r for r in trans
                if r["engine"] == eng and bool(r["hints"]) == h and not r.get("error")}

    base_eng, base_h = parse(args.baseline)
    chal_eng, chal_h = parse(args.challenger)
    A, B = pick(args.baseline), pick(args.challenger)
    common = sorted(set(A) & set(B))
    stats = {}
    if common:
        cer_pairs = [(cer(A[i]["ref"], A[i]["hyp"]), cer(B[i]["ref"], B[i]["hyp"])) for i in common]
        m, lo, hi = paired_bootstrap(cer_pairs)
        sig_cer = not (lo <= 0 <= hi)

        ip = []
        for i in common:
            a = intents.get((i, base_eng, base_h))
            b = intents.get((i, chal_eng, chal_h))
            if a and b:
                ip.append((a["intent_ok"], b["intent_ok"]))
        p, nb, nc = mcnemar(ip) if ip else (float("nan"), 0, 0)

        stats = {"n_paired": len(common), "cer_delta": m, "cer_ci": [lo, hi],
                 "cer_significant": sig_cer, "mcnemar_p": p,
                 "only_baseline_correct": nb, "only_challenger_correct": nc}

        print(f"\n── {args.baseline} vs {args.challenger} (짝지은 발화 {len(common)}건) ──")
        print(f"CER 차이(기준선-도전자): {m:+.4f}  95% CI [{lo:+.4f}, {hi:+.4f}]  "
              f"→ {'유의함' if sig_cer else '유의차 없음 (CI가 0을 포함)'}")
        if ip:
            print(f"intent McNemar p={p:.4f}  "
                  f"기준선만 정답 {nb}건 / 도전자만 정답 {nc}건  "
                  f"→ {'유의함' if p < 0.05 else '유의차 없음'}")
            if p >= 0.05:
                print("   ⚠️ 유의차가 없으면 정확도로는 교체 근거가 못 된다. "
                      "레이턴시·비용·운영 리스크로 결정할 것.")

    out = os.path.join(RESULTS, "metrics.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"cells": summary, "comparison": stats}, f, ensure_ascii=False, indent=2)
    print(f"\n[bench] 저장: {out}")


if __name__ == "__main__":
    main()
