import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


# 요청마다 psycopg.connect() 를 부르면 매번 TCP 연결과 인증 핸드셰이크를 새로
# 치른다. 동시 요청이 몰리면 PostgreSQL 의 max_connections 도 밀어붙인다.
# hw 서버가 쓰는 것과 같은 구성으로 풀을 하나 두고 빌려 쓴다.
_db_env = {
    "host": os.environ["DB_HOST"],
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
    "connect_timeout": 5,
    "row_factory": dict_row,
    "application_name": "deskibot-sw",
}

# check: 빌려주기 전에 커넥션이 살아있는지 확인한다. 로봇이나 앱이 몇 시간
# 조용하면 놀던 커넥션이 서버 쪽에서 끊기는데, 이게 없으면 침묵 뒤 첫 요청만
# 503 으로 실패하고 그 다음부터 정상이 된다. hw 에서 실제로 겪었다.
# max_idle: 애초에 죽을 때까지 방치하지 않도록 5분마다 재활용한다.
_pool = ConnectionPool(
    conninfo="",
    kwargs=_db_env,
    min_size=1,
    max_size=5,
    open=True,
    check=ConnectionPool.check_connection,
    max_idle=300,
)


def get_db_connection():
    """풀에서 커넥션을 빌린다.

    호출부는 기존과 동일하게 ``with get_db_connection() as conn:`` 로 쓴다.
    블록을 나갈 때 커넥션을 닫는 대신 풀에 반납하는 것만 달라진다.
    """
    return _pool.connection()


def check_database() -> bool:
    with get_db_connection() as conn:
        row = conn.execute("SELECT 1 AS ok").fetchone()
        return row is not None and row["ok"] == 1
