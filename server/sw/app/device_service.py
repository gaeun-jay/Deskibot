import hashlib

from app.db import get_db_connection


def hash_device_token(token: str) -> str:
    return hashlib.sha256(
        token.encode("utf-8")
    ).hexdigest()


def authenticate_device(token: str):
    if not isinstance(token, str) or len(token) < 32:
        return None

    token_hash = hash_device_token(token)

    with get_db_connection() as conn:
        row = conn.execute(
            """
            UPDATE devices
            SET last_seen_at = NOW()
            WHERE
                token_hash = %s
                AND user_id IS NOT NULL
            RETURNING
                device_uid,
                user_id
            """,
            (token_hash,),
        ).fetchone()

    if row is None:
        return None

    return {
        "device_uid": row["device_uid"],
        "user_id": str(row["user_id"]),
    }