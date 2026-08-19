#!/usr/bin/env python3
"""
녹음 보조 도구.

  # 1) 이번에 녹음할 조건의 대본을 순서대로 출력
  python3 bench/label_audio.py --cond c1 --script

  # 2) 그 조건을 다 말한 뒤, 쌓인 wav에 이름 붙이기 (미리보기)
  python3 bench/label_audio.py --cond c1

  # 3) 맞으면 실제로 이름 변경
  python3 bench/label_audio.py --cond c1 --apply

조건 하나(20발화)를 녹음한 직후에 바로 이름을 붙이는 걸 권한다.
60개를 몰아서 붙이면 어디서 밀렸는지 찾기가 어렵다.
"""

import argparse, csv, os, re, sys

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
AUDIO_DIR = os.path.join(BENCH_DIR, "audio")
LABELED   = re.compile(r"^u\d{2}-c\d\.wav$")


def manifest_rows(cond=None):
    with open(os.path.join(BENCH_DIR, "manifest.csv"), encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r.get("id", "").strip()]
    if cond:
        rows = [r for r in rows if r["id"].endswith("-" + cond)]
    # 발화 번호 순으로 (u01, u02, …)
    return sorted(rows, key=lambda r: r["id"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cond", help="c1 | c2 | c3")
    ap.add_argument("--script", action="store_true", help="녹음 대본만 출력")
    ap.add_argument("--apply", action="store_true", help="실제로 이름 변경")
    args = ap.parse_args()

    rows = manifest_rows(args.cond)

    if args.script:
        cond_desc = {"c1": "조용 / 30cm", "c2": "생활소음 / 30cm", "c3": "조용 / 100cm"}
        print(f"\n■ 조건 {args.cond or '전체'} — {cond_desc.get(args.cond, '')}")
        print("  아래 순서대로, 한 번에 하나씩 또박또박 말하세요.")
        print("  잘못 말했으면 그 자리에서 한 번 더 말하고 메모해 두세요.\n")
        for i, r in enumerate(rows, 1):
            print(f"  {i:2d}. {r['ref_text']}")
        print(f"\n  총 {len(rows)}발화\n")
        return

    os.makedirs(AUDIO_DIR, exist_ok=True)
    # 타임스탬프 파일명이라 정렬 = 녹음 순서
    new_files = sorted(f for f in os.listdir(AUDIO_DIR)
                       if f.endswith(".wav") and not LABELED.match(f))
    todo = [r for r in rows if not os.path.exists(os.path.join(AUDIO_DIR, f"{r['id']}.wav"))]

    if not new_files:
        print("이름을 붙일 새 wav가 없습니다. (bench/audio/ 확인)")
        return

    print(f"\n새 녹음 {len(new_files)}개 / 이름 붙일 자리 {len(todo)}개")
    if len(new_files) != len(todo):
        print("⚠️  개수가 다릅니다. 재녹음이 섞였거나 빠뜨린 발화가 있습니다.")
        print("    잘못된 파일을 지우고 다시 실행하세요. 순서가 밀리면 전부 어긋납니다.\n")

    pairs = list(zip(new_files, todo))
    for src, r in pairs:
        print(f"  {src}  →  {r['id']}.wav   \"{r['ref_text']}\"")

    if not args.apply:
        print(f"\n미리보기입니다. 맞으면 --apply 를 붙여 다시 실행하세요.\n")
        return

    for src, r in pairs:
        os.rename(os.path.join(AUDIO_DIR, src),
                  os.path.join(AUDIO_DIR, f"{r['id']}.wav"))
    print(f"\n✅ {len(pairs)}개 이름 변경 완료\n")


if __name__ == "__main__":
    main()
