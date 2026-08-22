#!/usr/bin/env python3
"""
STT 출력 정규화. 세 엔진의 표기 습관이 서로 달라서, 정규화 없이 비교하면
엔진 성능이 아니라 표기 규칙 차이를 재게 된다.

- Google v1은 enable_automatic_punctuation=True라 마침표·쉼표가 붙는다.
- Clova는 기본적으로 문장부호를 덜 붙이고 숫자를 아라비아로 쓰는 경향이 있다.
- "세 시" / "3시", "삼십분" / "30분" 같은 표기는 의미가 같으므로 통일한다.

여기서 정한 규칙은 보고서에 그대로 실어야 재현이 된다.
"""

import re, unicodedata

_PUNCT = re.compile(r"[.,!?~…·\"'`\-—\(\)\[\]{}:;/]")

# 한국어 수사 → 아라비아 숫자. 시각·분 표현에서만 실질적으로 쓰인다.
_NUM_WORDS = [
    ("스물넷", "24"), ("스물셋", "23"), ("스물둘", "22"), ("스물하나", "21"), ("스물", "20"),
    ("열아홉", "19"), ("열여덟", "18"), ("열일곱", "17"), ("열여섯", "16"), ("열다섯", "15"),
    ("열넷", "14"), ("열셋", "13"), ("열둘", "12"), ("열하나", "11"), ("열", "10"),
    ("아홉", "9"), ("여덟", "8"), ("일곱", "7"), ("여섯", "6"), ("다섯", "5"),
    ("네", "4"), ("세", "3"), ("두", "2"), ("한", "1"),
    ("사십", "40"), ("삼십", "30"), ("이십", "20"), ("십", "10"),
]
_TIME_UNIT = re.compile(r"(시|분|초|개|시간)")


def normalize(text: str, *, drop_space: bool = True) -> str:
    """CER/WER 계산 전에 양쪽 텍스트에 똑같이 적용한다."""
    if not text:
        return ""
    s = unicodedata.normalize("NFC", text).strip().lower()
    s = _PUNCT.sub(" ", s)

    # 수사는 단위 앞에 붙었을 때만 숫자로 바꾼다("세 시" → "3시").
    # "세탁", "한글"처럼 무관한 단어를 건드리지 않기 위한 제한이다.
    for word, digit in _NUM_WORDS:
        s = re.sub(rf"{word}\s*(?={_TIME_UNIT.pattern})", digit, s)

    s = re.sub(r"\s+", " ", s).strip()
    return s.replace(" ", "") if drop_space else s


def cer(ref: str, hyp: str) -> float:
    """문자 오류율. 한국어는 띄어쓰기 변동이 커서 공백을 뺀 CER을 주지표로 쓴다."""
    r, h = normalize(ref), normalize(hyp)
    if not r:
        return 0.0 if not h else 1.0
    return _levenshtein(r, h) / len(r)


def wer(ref: str, hyp: str) -> float:
    """어절 오류율. 조사·띄어쓰기에 과민해서 보조 지표로만 쓴다."""
    r = normalize(ref, drop_space=False).split()
    h = normalize(hyp, drop_space=False).split()
    if not r:
        return 0.0 if not h else 1.0
    return _levenshtein(r, h) / len(r)


def _levenshtein(a, b) -> int:
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def keyword_hit(keyword: str, hyp: str) -> bool:
    """도메인 어휘가 인식 결과에 살아남았는지."""
    return normalize(keyword) in normalize(hyp)
