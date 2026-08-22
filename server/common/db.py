"""PostgreSQL 커넥션 풀. hw · sw 두 서버가 함께 쓴다.

프로세스가 따로 뜨므로 풀도 각자 하나씩 생긴다. 공유하는 것은 설정과 코드이지
커넥션 자체가 아니다.
"""

import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


def _env() -> dict:
    cfg = {
        "host": os.environ.get("DB_HOST", ""),
        "port": os.environ.get("DB_PORT", "5432"),
        "dbname": os.environ.get("DB_NAME", ""),
        "user": os.environ.get("DB_USER", ""),
        "password": os.environ.get("DB_PASSWORD", ""),
    }
    missing = [k for k, v in cfg.items() if not v]
    if missing:
        raise RuntimeError("missing PostgreSQL settings: " + ", ".join(missing))
    try:
        cfg["port"] = int(cfg["port"])
    except ValueError as exc:
        raise RuntimeError("DB_PORT must be an integer") from exc
    cfg["row_factory"] = dict_row
    return cfg


def make_pool(application_name: str) -> ConnectionPool:
    """풀을 만든다. application_name 은 pg_stat_activity 에서 서로를 구분하는 데 쓴다.

    check: 빌려주기 전에 커넥션이 살아있는지 확인한다. 로봇이나 앱이 몇 시간
    조용하면 놀던 커넥션이 서버 쪽에서 끊기는데, 이게 없으면 침묵 뒤 첫 요청만
    503 으로 실패하고 그 다음부터 정상이 된다. 시연에서 첫 호출만 튕기는
    형태로 나타나 원인을 찾기 어렵다. hw 에서 실제로 겪었다.

    max_idle: 애초에 죽을 때까지 방치하지 않도록 5분마다 재활용한다.
    """
    cfg = _env()
    cfg["application_name"] = application_name
    cfg.setdefault("connect_timeout", 5)
    return ConnectionPool(
        conninfo="",
        kwargs=cfg,
        min_size=1,
        max_size=5,
        open=True,
        check=ConnectionPool.check_connection,
        max_idle=300,
    )
