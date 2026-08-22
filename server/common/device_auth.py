"""로봇 device token 인증. hw · sw 두 서버가 함께 쓴다.

예전에는 이 로직이 양쪽에 따로 있었고 검증 규칙마저 서로 달랐다.

    sw   len(token) < 32   이면 거부   →  10자 토큰을 막음
    hw   len(token) > 127  이면 거부   →  10자 토큰을 통과시킴

같은 토큰을 한쪽은 막고 한쪽은 통과시키는 상태였다. 둘 다 결국 DB 조회에서
실패해 실질 피해는 없었지만, 규칙이 한 번도 같았던 적이 없다는 뜻이다.
토큰 형식을 바꾸면 한쪽만 고치고 다른 쪽을 잊게 된다.

여기서 규칙을 하나로 합친다. 발급기(tools/register_test_device.py)가
secrets.token_urlsafe(32) 로 43자를 만들므로 32~127 이면 정상 토큰을 모두
받으면서 명백한 쓰레기 입력은 DB 조회 전에 걸러낸다.
"""

import hashlib
from typing import Any


TOKEN_MIN_LEN = 32
TOKEN_MAX_LEN = 127


def hash_device_token(token: str) -> str:
    """평문 토큰의 SHA-256 16진 문자열. DB 에는 이 값만 저장한다."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def authenticate_device(pool, token: str) -> dict[str, Any] | None:
    """토큰을 검증하고 연결된 기기 정보를 돌려준다. 실패하면 None.

    성공하면 {"device_uid": str, "user_id": UUID} 를 준다. user_id 만 필요한
    쪽은 결과에서 꺼내 쓴다.

    조회와 동시에 last_seen_at 을 갱신한다 — 한 번의 UPDATE ... RETURNING 으로
    끝나므로 인증 때문에 왕복이 늘지 않는다.

    pool 을 인자로 받는 이유: 두 서버가 각자 자기 풀을 만들어 쓰기 때문이다.
    이 모듈이 풀을 소유하면 import 만으로 커넥션이 생겨 테스트가 어려워진다.
    """
    if not isinstance(token, str):
        return None
    if not (TOKEN_MIN_LEN <= len(token) <= TOKEN_MAX_LEN):
        return None

    token_hash = hash_device_token(token)
    with pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE devices
                   SET last_seen_at = NOW()
                 WHERE token_hash = %s
                   AND user_id IS NOT NULL
                RETURNING device_uid, user_id
                """,
                (token_hash,),
            )
            row = cur.fetchone()

    if row is None:
        return None
    return {"device_uid": row["device_uid"], "user_id": row["user_id"]}
