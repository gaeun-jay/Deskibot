#!/usr/bin/env python3
"""
1단계: 같은 wav를 모든 엔진 × 힌트 셀에 통과시켜 전사 결과를 모은다.

    python3 bench/run_bench.py --engines google_v1,clova_csr --repeat 3

레이턴시는 네트워크 변동이 커서 --repeat로 여러 번 재고 중앙값을 쓴다.
결과는 results/transcripts.jsonl에 한 줄씩 append하며, 이미 끝난 조합은
건너뛴다(중간에 죽어도 이어서 돌릴 수 있다).
"""

import argparse, csv, json, os, sys, time, wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env"))

import adapters

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(BENCH_DIR, "results", "transcripts.jsonl")


def read_wav_pcm(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1,   f"{path}: 모노가 아님"
        assert w.getsampwidth() == 2,   f"{path}: 16-bit가 아님"
        assert w.getframerate() == 16000, f"{path}: 16 kHz가 아님"
        return w.readframes(w.getnframes())


def load_manifest(path):
    with open(path, encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r.get("id", "").strip()
                and not r["id"].lstrip().startswith("#")]
    for r in rows:
        if not os.path.isabs(r["wav"]):
            r["wav"] = os.path.join(BENCH_DIR, r["wav"])
    return rows


def done_keys(path):
    if not os.path.exists(path):
        return set()
    keys = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
                keys.add((d["id"], d["engine"], d["hints"]))
            except Exception:
                pass
    return keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(BENCH_DIR, "manifest.csv"))
    ap.add_argument("--engines", default="google_v1,google_v2,clova_csr,clova_speech")
    ap.add_argument("--repeat", type=int, default=3, help="레이턴시 측정 반복 횟수")
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help="결과 파일. 같은 id를 다른 조건으로 다시 돌릴 때는 반드시 분리할 것 —\n"
                         "기본 파일에 쓰면 '이미 완료'로 전부 건너뛴다.")
    ap.add_argument("--no-hints", action="store_true",
                    help="힌트 셀을 돌지 않는다. Clova CSR에는 부스팅이 없어서,\n                         맨몸 대 맨몸으로 비교하려면 이쪽이 맞다.")
    args = ap.parse_args()

    out_path = args.out
    rows = load_manifest(args.manifest)
    print(f"[bench] 발화 {len(rows)}건")
    engines = adapters.build(args.engines.split(","))
    if not engines:
        sys.exit("사용 가능한 엔진이 없습니다.")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    already = done_keys(out_path)

    with open(out_path, "a", encoding="utf-8") as out:
        for row in rows:
            try:
                pcm = read_wav_pcm(row["wav"])
            except Exception as e:
                print(f"[bench] ⚠️ {row['id']} 오디오 읽기 실패: {e}")
                continue

            for eng in engines:
                # 힌트를 지원하는 엔진만 on/off 두 셀을 돈다.
                cells = [False] if args.no_hints else (
                    [False, True] if eng.supports_hints else [False])
                for use_hints in cells:
                    key = (row["id"], eng.name, use_hints)
                    if key in already:
                        continue

                    text, lats, err = "", [], None
                    for i in range(args.repeat):
                        try:
                            t, dt = eng.transcribe(pcm, use_hints)
                            lats.append(dt)
                            if i == 0:
                                text = t
                        except Exception as e:
                            err = f"{type(e).__name__}: {e}"
                            break
                        time.sleep(0.2)   # 레이트리밋 여유

                    rec = {
                        "id": row["id"], "engine": eng.name, "hints": use_hints,
                        "hyp": text, "ref": row["ref_text"],
                        "latencies": lats,
                        "latency": sorted(lats)[len(lats)//2] if lats else None,
                        "category": row.get("category", ""),
                        "noise": row.get("noise", ""),
                        "distance": row.get("distance", ""),
                        "speaker": row.get("speaker", ""),
                        "error": err,
                    }
                    out.write(json.dumps(rec, ensure_ascii=False) + "\n")
                    out.flush()
                    tag = "❌" if err else ("⚠️ 빈결과" if not text else "✅")
                    print(f"  {tag} {row['id']:<8} {eng.name:<13} hints={int(use_hints)} "
                          f"{rec['latency'] or 0:.2f}s  \"{text[:40]}\"")

    print(f"\n[bench] 저장: {out_path}")


if __name__ == "__main__":
    main()
