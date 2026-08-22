#!/usr/bin/env python3
"""
4단계: 보고서용 그래프 5종.

  fig1_cer.png          조건별 CER + 95% 신뢰구간   ← 핵심 그림
  fig2_intent.png       intent 정확도               ← 채택 결정 근거
  fig3_latency.png      레이턴시 CDF (p50/p95 표시)
  fig4_paired.png       발화별 쌍 비교 산점도
  fig5_keyword.png      도메인 어휘 recall 히트맵

    python3 bench/plot.py
"""

import json, os, sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH_DIR)
from normalize import cer, keyword_hit
from adapters import PHRASE_HINTS
from score import load, cell_of, paired_bootstrap, percentile

RESULTS = os.path.join(BENCH_DIR, "results")
FIGS    = os.path.join(BENCH_DIR, "figs")

# 색은 엔진별로 고정한다. 그림마다 색이 바뀌면 보고서에서 읽기 어렵다.
COLORS = {"google_v1": "#4C78A8", "google_v2": "#72B7B2",
          "clova_csr": "#E45756", "clova_speech": "#F58518"}


def setup_font():
    """한글 폰트를 못 잡으면 라벨이 전부 네모로 깨진다."""
    have = {f.name for f in font_manager.fontManager.ttflist}
    for c in ("AppleGothic", "Apple SD Gothic Neo", "NanumGothic",
              "Malgun Gothic", "Noto Sans CJK KR", "Noto Sans KR"):
        if c in have:
            plt.rcParams["font.family"] = c
            plt.rcParams["axes.unicode_minus"] = False   # 마이너스 기호 깨짐 방지
            print(f"[plot] 한글 폰트: {c}")
            return
    print("[plot] ⚠️ 한글 폰트를 못 찾음 — 라벨이 깨집니다. "
          "리눅스면 `apt install fonts-nanum` 후 폰트 캐시를 지우세요.")


def color_of(cell):
    return COLORS.get(cell.rsplit(":", 1)[0], "#888888")


SHOW_HINT_SUFFIX = False   # 힌트 셀이 하나라도 있을 때만 라벨에 표시한다


def label_of(cell):
    eng, h = cell.rsplit(":", 1)
    if not SHOW_HINT_SUFFIX:
        return eng
    return f"{eng}\n(힌트 {'있음' if h == '1' else '없음'})"


def fig1_cer(trans):
    cells = defaultdict(list)
    for r in trans:
        if not r.get("error"):
            cells[cell_of(r)].append(cer(r["ref"], r["hyp"]))

    names = sorted(cells)
    means, los, his = [], [], []
    for c in names:
        vals = cells[c]
        m, lo, hi = paired_bootstrap([(v, 0.0) for v in vals])
        means.append(m); los.append(m - lo); his.append(hi - m)

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(range(len(names)), means, yerr=[los, his], capsize=6,
           color=[color_of(c) for c in names], edgecolor="none")
    for i, m in enumerate(means):
        ax.text(i, m + his[i] + 0.008, f"{m:.3f}", ha="center", fontsize=10)
    ax.set_xticks(range(len(names)))
    ax.set_xticklabels([label_of(c) for c in names], fontsize=9)
    ax.set_ylabel("CER (낮을수록 좋음)")
    ax.set_title("엔진별 문자 오류율 — 95% 부트스트랩 신뢰구간")
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig1_cer.png", dpi=160); plt.close(fig)


def fig2_intent(intents):
    cells = defaultdict(list)
    for r in intents:
        cells[cell_of(r)].append(bool(r["intent_ok"]))
    if not cells:
        print("[plot] intents.jsonl 없음 — fig2 건너뜀"); return

    names = sorted(cells)
    accs  = [sum(cells[c]) / len(cells[c]) for c in names]

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(range(len(names)), accs, color=[color_of(c) for c in names], edgecolor="none")
    for i, a in enumerate(accs):
        ax.text(i, a + 0.015, f"{a*100:.1f}%", ha="center", fontsize=10)
    ax.set_xticks(range(len(names)))
    ax.set_xticklabels([label_of(c) for c in names], fontsize=9)
    ax.set_ylim(0, 1.08)
    ax.set_ylabel("intent 정확도 (높을수록 좋음)")
    ax.set_title("명령 해석 정확도 — 채택 결정의 기준 지표")
    ax.grid(axis="y", alpha=0.3); ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig2_intent.png", dpi=160); plt.close(fig)


def fig3_latency(trans):
    cells = defaultdict(list)
    for r in trans:
        if not r.get("error") and r.get("latency"):
            cells[cell_of(r)].append(r["latency"])

    fig, ax = plt.subplots(figsize=(8, 4.5))
    for c in sorted(cells):
        v = sorted(cells[c])
        ys = [(i + 1) / len(v) for i in range(len(v))]
        ax.step(v, ys, where="post", label=f"{c}  p95={percentile(v,0.95):.2f}s",
                color=color_of(c), lw=2)
    ax.axhline(0.95, ls="--", c="gray", lw=1)
    ax.text(ax.get_xlim()[1], 0.955, "p95", ha="right", fontsize=8, color="gray")
    ax.set_xlabel("STT 응답 시간 (초)")
    ax.set_ylabel("누적 비율")
    ax.set_title("레이턴시 분포 — 꼬리가 짧을수록 체감이 좋다")
    ax.legend(fontsize=8); ax.grid(alpha=0.3); ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig3_latency.png", dpi=160); plt.close(fig)


def fig4_paired(trans, baseline, challenger):
    def pick(cell):
        eng, h = cell.rsplit(":", 1)
        return {r["id"]: r for r in trans
                if r["engine"] == eng and bool(r["hints"]) == bool(int(h))
                and not r.get("error")}

    A, B = pick(baseline), pick(challenger)
    common = sorted(set(A) & set(B))
    if not common:
        print("[plot] 짝지을 발화가 없음 — fig4 건너뜀"); return

    xs = [cer(A[i]["ref"], A[i]["hyp"]) for i in common]
    ys = [cer(B[i]["ref"], B[i]["hyp"]) for i in common]

    fig, ax = plt.subplots(figsize=(5.5, 5.5))
    ax.scatter(xs, ys, s=34, alpha=0.65, color="#4C78A8", edgecolor="white", lw=0.6)
    hi = max(xs + ys + [0.05]) * 1.1
    ax.plot([0, hi], [0, hi], ls="--", c="gray", lw=1)
    ax.text(hi * 0.62, hi * 0.94, f"{baseline} 가 더 나쁨", fontsize=9, color="#555")
    ax.text(hi * 0.52, hi * 0.04, f"{challenger} 가 더 나쁨", fontsize=9, color="#555")
    ax.set_xlim(0, hi); ax.set_ylim(0, hi)
    ax.set_xlabel(f"{baseline} CER"); ax.set_ylabel(f"{challenger} CER")
    ax.set_title("발화별 쌍 비교\n평균이 같아도 어느 쪽이 크게 틀리는지 보인다", fontsize=11)
    ax.grid(alpha=0.3); ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig4_paired.png", dpi=160); plt.close(fig)


def fig5_keyword(trans):
    cells = sorted({cell_of(r) for r in trans if not r.get("error")})
    grid, kws = [], []
    for k in PHRASE_HINTS:
        row, any_rel = [], False
        for c in cells:
            rel = [r for r in trans if cell_of(r) == c and not r.get("error")
                   and keyword_hit(k, r["ref"])]
            if rel:
                any_rel = True
                row.append(sum(1 for r in rel if keyword_hit(k, r["hyp"])) / len(rel))
            else:
                row.append(float("nan"))
        if any_rel:
            grid.append(row); kws.append(k)

    if not grid:
        print("[plot] 도메인 어휘가 등장하는 발화가 없음 — fig5 건너뜀"); return

    fig, ax = plt.subplots(figsize=(1.6 * len(cells) + 3, 0.42 * len(kws) + 2))
    im = ax.imshow(grid, cmap="RdYlGn", vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(range(len(cells)))
    ax.set_xticklabels([label_of(c) for c in cells], fontsize=8)
    ax.set_yticks(range(len(kws))); ax.set_yticklabels(kws, fontsize=9)
    for i in range(len(kws)):
        for j in range(len(cells)):
            v = grid[i][j]
            if v == v:
                ax.text(j, i, f"{v*100:.0f}", ha="center", va="center", fontsize=8)
    ax.set_title("도메인 어휘 인식률 (%)")
    cb = fig.colorbar(im, ax=ax, fraction=0.03,
                      ticks=[0, 0.25, 0.5, 0.75, 1.0])
    cb.ax.set_yticklabels(["0", "25", "50", "75", "100"])
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig5_keyword.png", dpi=160); plt.close(fig)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default="google_v1:0")
    ap.add_argument("--challenger", default="clova_csr:0")
    args = ap.parse_args()

    setup_font()
    os.makedirs(FIGS, exist_ok=True)
    trans, intents = load("transcripts.jsonl"), load("intents.jsonl")

    global SHOW_HINT_SUFFIX
    SHOW_HINT_SUFFIX = any(r.get("hints") for r in trans)
    if not trans:
        sys.exit("results/transcripts.jsonl이 없습니다.")

    fig1_cer(trans)
    fig2_intent(intents)
    fig3_latency(trans)
    fig4_paired(trans, args.baseline, args.challenger)
    fig5_keyword(trans)
    print(f"[plot] 저장 위치: {FIGS}/")


if __name__ == "__main__":
    main()
