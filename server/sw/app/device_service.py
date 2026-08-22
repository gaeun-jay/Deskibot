"""로봇 device token 인증. 규칙과 쿼리는 server/common/device_auth.py 에 있다.

예전에는 이 파일이 인증을 직접 구현했고, hw 쪽 구현과 토큰 길이 검증 규칙이
서로 달랐다. 지금은 양쪽이 같은 함수를 부른다.
"""

from app.db import get_pool
from common.device_auth import authenticate_device as _authenticate
from common.device_auth import hash_device_token  # 기존 import 경로 유지


def authenticate_device(token: str):
    """성공하면 {"device_uid": str, "user_id": str}, 실패하면 None.

    user_id 를 문자열로 돌려주던 기존 동작을 유지한다 — WS 인증이 그대로
    문자열로 쓴다.
    """
    device = _authenticate(get_pool(), token)
    if device is None:
        return None
    return {
        "device_uid": device["device_uid"],
        "user_id": str(device["user_id"]),
    }


__all__ = ["authenticate_device", "hash_device_token"]
