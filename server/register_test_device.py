#!/usr/bin/env python3
"""5인 테스트용 device token 등록. 토큰 평문은 출력하거나 DB에 저장하지 않는다."""

import argparse
import getpass
import hashlib
import os

import psycopg
from dotenv import load_dotenv


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("--device-uid", required=True)
    parser.add_argument("--user-id", required=True)
    args = parser.parse_args()

    db_config = {
        "host": os.environ.get("DB_HOST", ""),
        "port": os.environ.get("DB_PORT", ""),
        "dbname": os.environ.get("DB_NAME", ""),
        "user": os.environ.get("DB_USER", ""),
        "password": os.environ.get("DB_PASSWORD", ""),
    }
    missing = [name for name, value in db_config.items() if not value]
    if missing:
        raise SystemExit("missing PostgreSQL settings: " + ", ".join(missing))
    try:
        db_config["port"] = int(db_config["port"])
    except ValueError as exc:
        raise SystemExit("DB_PORT must be an integer") from exc

    token = getpass.getpass("사전 발급 device token: ")
    if not token or len(token) > 127 or any(ord(ch) <= 0x20 or ord(ch) == 0x7F for ch in token):
        raise SystemExit("token must be 1..127 printable non-space characters")
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()

    with psycopg.connect(**db_config) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO devices (device_uid, user_id, token_hash, paired_at)
                VALUES (%s, %s, %s, NOW())
                ON CONFLICT (device_uid) DO UPDATE
                   SET user_id = EXCLUDED.user_id,
                       token_hash = EXCLUDED.token_hash,
                       paired_at = NOW()
                """,
                (args.device_uid, args.user_id, token_hash),
            )
    print(f"등록 완료: device_uid={args.device_uid} (token은 출력하지 않음)")


if __name__ == "__main__":
    main()
