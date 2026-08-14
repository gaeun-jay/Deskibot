import os

import psycopg
from psycopg.rows import dict_row


def get_db_connection():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        row_factory=dict_row,
        application_name="deskibot-sw",
    )


def check_database() -> bool:
    with get_db_connection() as conn:
        row = conn.execute("SELECT 1 AS ok").fetchone()
        return row is not None and row["ok"] == 1