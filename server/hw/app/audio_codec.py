#!/usr/bin/env python3
"""
G.711 µ-law 디코더.

ESP가 업로드를 절반으로 줄이려고 16-bit PCM 대신 µ-law 8-bit로 보낸다.
서버에서 PCM16으로 되돌린 뒤 STT에 넘기므로 엔진 선택과 무관하게 동작한다.

인식률 영향은 90발화로 실측했다 — Google −0.008, CLOVA +0.001로 양쪽 다
유의차 없음(bench/report_latency 참고). 원거리(1 m) 조건에서도 악화가 없었다.
"""
import struct

_BIAS = 0x84


def _ulaw2lin(u: int) -> int:
    u = ~u & 0xFF
    t = ((u & 0x0F) << 3) + _BIAS
    t <<= (u & 0x70) >> 4
    return (_BIAS - t) if (u & 0x80) else (t - _BIAS)


# 256개뿐이라 미리 펼쳐 둔다
_TABLE = [_ulaw2lin(u) for u in range(256)]
_PACK = struct.Struct("<h")
_BYTES = b"".join(_PACK.pack(v) for v in _TABLE)


def ulaw_to_pcm16(data: bytes) -> bytes:
    """µ-law 바이트열 → 16-bit little-endian PCM."""
    out = bytearray(len(data) * 2)
    for i, b in enumerate(data):
        out[i * 2:i * 2 + 2] = _BYTES[b * 2:b * 2 + 2]
    return bytes(out)
