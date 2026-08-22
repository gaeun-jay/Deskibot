"""DB 커넥션. 실제 풀 설정은 server/common/db.py 에 hw 와 공유한다."""

from common.db import make_pool

_pool = make_pool("deskibot-sw")


def get_db_connection():
    """풀에서 커넥션을 빌린다.

    호출부는 기존과 동일하게 ``with get_db_connection() as conn:`` 로 쓴다.
    블록을 나갈 때 커넥션을 닫는 대신 풀에 반납하는 것만 달라진다.
    """
    return _pool.connection()


def get_pool():
    """풀 자체가 필요한 곳(공유 모듈 호출 등)에서 쓴다."""
    return _pool


def check_database() -> bool:
    with get_db_connection() as conn:
        row = conn.execute("SELECT 1 AS ok").fetchone()
        return row is not None and row["ok"] == 1
