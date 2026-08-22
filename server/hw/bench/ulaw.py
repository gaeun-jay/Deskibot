#!/usr/bin/env python3
"""
G.711 µ-law 코덱 (표준 Sun 구현 포팅).

ESP가 16-bit PCM 대신 µ-law 8-bit로 보내면 업로드가 절반이 된다. 손실 압축이라
인식률이 떨어질 수 있어, 기존 90발화로 그 손실을 실측하기 위한 도구다.
파이썬 3.13에서 audioop이 표준 라이브러리에서 빠져 직접 구현했다.
"""
import struct

_BIAS = 0x84
_CLIP = 8159                                   # 14비트 스케일 기준
_SEG_UEND = [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]


def lin2ulaw(pcm: int) -> int:
    pcm >>= 2                                  # 16비트 → 14비트
    if pcm < 0:
        pcm, mask = -pcm, 0x7F
    else:
        mask = 0xFF
    if pcm > _CLIP:
        pcm = _CLIP
    pcm += _BIAS >> 2
    seg = 8
    for i, end in enumerate(_SEG_UEND):
        if pcm <= end:
            seg = i
            break
    if seg >= 8:
        return (0x7F ^ mask) & 0xFF
    return (((seg << 4) | ((pcm >> (seg + 1)) & 0x0F)) ^ mask) & 0xFF


def ulaw2lin(u: int) -> int:
    u = ~u & 0xFF
    t = ((u & 0x0F) << 3) + _BIAS
    t <<= (u & 0x70) >> 4
    return (_BIAS - t) if (u & 0x80) else (t - _BIAS)


# 샘플이 수천만 개라 테이블로 미리 계산해 둔다
_ENC = [lin2ulaw(s - 65536 if s >= 32768 else s) for s in range(65536)]
_DEC = [ulaw2lin(u) for u in range(256)]


def roundtrip(pcm: bytes) -> bytes:
    """PCM16 → µ-law → PCM16. ESP에서 인코딩했을 때의 손실을 그대로 재현한다."""
    n = len(pcm) // 2
    vals = struct.unpack("<%dh" % n, pcm[:n * 2])
    return struct.pack("<%dh" % n, *[_DEC[_ENC[v & 0xFFFF]] for v in vals])
