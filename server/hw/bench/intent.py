#!/usr/bin/env python3
"""
2단계: 전사 결과를 실제 시스템 프롬프트·도구 정의에 넣어 intent를 채점한다.

이 시스템에서 중요한 건 글자가 몇 개 틀렸느냐가 아니라 명령이 맞게
해석됐느냐다. CER 0.05라도 "뽀모도로"가 "포모도로"로 들리면 실패고,
CER 0.2라도 add_todo가 제대로 잡히면 성공이다.

주의: server.run_llm()은 _run_tool()로 실제 DB를 변경한다(add_todo는 INSERT).
그래서 여기서는 voice_prompt만 가져다 Claude 호출 한 번으로 도구 선택만 보고
도구 실행은 절대 하지 않는다. 읽기 전용이라 운영 DB에 아무 영향이 없다.

    python3 bench/intent.py
"""

import json, os, sys
from datetime import datetime
from zoneinfo import ZoneInfo

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH_DIR)
sys.path.insert(0, os.path.join(BENCH_DIR, ".."))

from dotenv import load_dotenv
load_dotenv(os.path.join(BENCH_DIR, "..", ".env"))

import anthropic
from voice_prompt import TOOLS, build_system_prompt
from normalize import normalize

CLAUDE_MODEL = "claude-haiku-4-5-20251001"
KST = ZoneInfo("Asia/Seoul")

# DB를 읽지 않고 고정 목록을 쓴다. 카테고리가 실행 시점마다 달라지면
# 같은 전사에도 결과가 흔들려 엔진 비교가 오염된다. 보고서에 명시할 것.
CATEGORIES = os.environ.get("BENCH_CATEGORIES", "공부, 운동, 생활, 기타")

# 발화 시각도 고정한다. "내일"이 며칠인지가 실행일에 따라 달라지면 안 된다.
FIXED_NOW = datetime(2026, 8, 19, 14, 30, tzinfo=KST)

_client = anthropic.Anthropic()


MAX_ROUNDS = 3   # "영어 숙제랑 헬스 지워줘"류는 도구를 2번 부른다


def predict_intent(text: str) -> list:
    """Claude가 고른 도구들을 순서대로 돌려준다. 도구는 실행하지 않는다.

    복합 발화("영어 숙제랑 수학 과제 추가해줘")는 도구를 두 번 부르는데,
    실제 서버는 한 번 실행한 결과를 돌려주고 다음 호출을 받는다. 그 흐름을
    흉내내려고 중립적인 가짜 tool_result를 넣어 몇 라운드 더 돌린다.
    DB는 건드리지 않으므로 운영 데이터에 영향이 없다.
    """
    if not text.strip():
        return []

    system = build_system_prompt(
        FIXED_NOW.strftime("%Y-%m-%d"), FIXED_NOW.strftime("%H:%M"), CATEGORIES
    )
    messages = [{"role": "user", "content": text}]
    picked = []

    for _ in range(MAX_ROUNDS):
        resp = _client.messages.create(
            model=CLAUDE_MODEL, max_tokens=400, system=system, tools=TOOLS,
            messages=messages,
        )
        calls = [b for b in resp.content if b.type == "tool_use"]
        if not calls:
            break

        assistant, results = [], []
        for b in resp.content:
            if b.type == "text":
                assistant.append({"type": "text", "text": b.text})
            elif b.type == "tool_use":
                args = b.input if isinstance(b.input, dict) else {}
                picked.append({"tool": b.name, "input": args})
                assistant.append({"type": "tool_use", "id": b.id, "name": b.name,
                                  "input": args})
                results.append({"type": "tool_result", "tool_use_id": b.id,
                                "content": "처리했습니다."})
        messages.append({"role": "assistant", "content": assistant})
        messages.append({"role": "user", "content": results})

    return picked


def slots_match(ref_slots: dict, got: dict) -> bool:
    """ref_slots에 적힌 키만 본다. 값은 정규화 후 포함 관계까지 허용한다."""
    for k, want in ref_slots.items():
        have = got.get(k)
        if have is None:
            return False
        w, h = normalize(str(want)), normalize(str(have))
        if w != h and w not in h and h not in w:
            return False
    return True


def match_calls(ref_tools: list, ref_slots: list, picked: list):
    """정답 도구 호출들과 예측을 짝지어 (도구일치, 도구+슬롯일치)를 낸다.

    말한 순서와 도구 호출 순서가 늘 같지는 않아서 순서는 보지 않는다.
    같은 도구가 두 번 나오는 경우(추가 2건)를 위해 한 번 쓴 예측은 소비한다.
    """
    if not ref_tools:                       # 정답이 "도구 없음"
        return (len(picked) == 0,) * 2

    remaining = list(picked)
    tool_hits = slot_hits = 0
    for want_tool, want_slots in zip(ref_tools, ref_slots):
        cand = [p for p in remaining if p["tool"] == want_tool]
        if not cand:
            continue
        tool_hits += 1
        # 슬롯까지 맞는 후보를 우선 소비한다
        best = next((p for p in cand if slots_match(want_slots, p["input"])), None)
        if best is not None:
            slot_hits += 1
        else:
            best = cand[0]
        remaining.remove(best)

    exact_n = len(picked) == len(ref_tools)   # 과잉 호출도 실패로 본다
    return (tool_hits == len(ref_tools) and exact_n,
            slot_hits == len(ref_tools) and exact_n)


def main():
    src = os.path.join(BENCH_DIR, "results", "transcripts.jsonl")
    dst = os.path.join(BENCH_DIR, "results", "intents.jsonl")

    import csv
    refs = {}
    with open(os.path.join(BENCH_DIR, "manifest.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r.get("id", "").strip() and not r["id"].lstrip().startswith("#"):
                refs[r["id"]] = r

    done = set()
    if os.path.exists(dst):
        with open(dst, encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                    done.add((d["id"], d["engine"], d["hints"]))
                except Exception:
                    pass

    # 같은 전사 텍스트는 결과가 같으므로 LLM 호출을 재사용한다(비용·시간 절감).
    cache = {}

    with open(src, encoding="utf-8") as f, open(dst, "a", encoding="utf-8") as out:
        for line in f:
            rec = json.loads(line)
            key = (rec["id"], rec["engine"], rec["hints"])
            if key in done:
                continue
            ref = refs.get(rec["id"])
            if not ref:
                continue

            hyp = rec["hyp"]
            if hyp not in cache:
                cache[hyp] = predict_intent(hyp)
            pred = cache[hyp]

            raw_tools = (ref.get("ref_tool") or "none").strip()
            ref_tools = [] if raw_tools == "none" else raw_tools.split(",")
            ref_slots = json.loads(ref.get("ref_slots") or "[]")
            if isinstance(ref_slots, dict):        # 예전 스키마 호환
                ref_slots = [ref_slots]
            ref_slots = (ref_slots + [{}] * len(ref_tools))[:len(ref_tools)]

            tool_ok, slot_ok = match_calls(ref_tools, ref_slots, pred)

            out.write(json.dumps({
                **{k: rec[k] for k in ("id", "engine", "hints", "category", "noise", "distance")},
                "hyp": hyp, "pred": pred,
                "ref_tool": ref_tools, "ref_slots": ref_slots,
                "tool_ok": tool_ok, "intent_ok": slot_ok,
            }, ensure_ascii=False) + "\n")
            out.flush()
            got = ",".join(p["tool"] for p in pred) or "none"
            print(f"  {'✅' if slot_ok else '❌'} {rec['id']:<8} {rec['engine']:<13} "
                  f"hints={int(rec['hints'])} {raw_tools} → {got}")

    print(f"\n[bench] 저장: {dst}")


if __name__ == "__main__":
    main()
