"""회원가입 · 로그인 · JWT 발급/검증.

앱 lib/services/auth_service.dart 를 대체한다.

앱은 지금 SHA-256으로 해싱해서 Firestore에 넣지만, 여기서는 평문을 HTTPS로
받아 서버에서 Argon2id로 해싱한다 (스키마 주석이 요구하는 방식).
"""

import os
import re
from datetime import datetime, timedelta, timezone
from uuid import UUID

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHash, VerificationError, VerifyMismatchError
from psycopg.errors import UniqueViolation

from app.db import get_db_connection


ALGORITHM = "HS256"
TOKEN_TTL_DAYS = 30

USER_TYPES = {"student", "worker"}

LOGIN_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{4,32}$")
MIN_PASSWORD_LENGTH = 8

# 앱 auth_service.dart 가 가입 시 만들던 기본 카테고리와 동일하게 맞춘다.
# todos.category_id 가 NOT NULL 이라 가입 직후 최소 하나는 있어야 한다.
DEFAULT_CATEGORIES = [
    ("공부", "#4472C4"),
    ("업무", "#ED7D31"),
    ("운동", "#70AD47"),
]

_hasher = PasswordHasher()


class AuthError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _jwt_secret() -> str:
    secret = os.environ.get("JWT_SECRET", "")

    if len(secret) < 32:
        raise AuthError(
            "missing_jwt_secret",
            "JWT_SECRET is not configured",
        )

    return secret


# ─── 토큰 ────────────────────────────────────────────────────────────────────

def issue_token(user_id: UUID) -> dict:
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(days=TOKEN_TTL_DAYS)

    token = jwt.encode(
        {
            "sub": str(user_id),
            "iat": int(now.timestamp()),
            "exp": int(expires_at.timestamp()),
        },
        _jwt_secret(),
        algorithm=ALGORITHM,
    )

    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_at": expires_at.isoformat(),
    }


def verify_token(token: str) -> UUID:
    try:
        payload = jwt.decode(
            token,
            _jwt_secret(),
            algorithms=[ALGORITHM],
        )
    except jwt.ExpiredSignatureError:
        raise AuthError("token_expired", "the token has expired")
    except jwt.InvalidTokenError:
        raise AuthError("invalid_token", "the token is invalid")

    try:
        return UUID(payload["sub"])
    except (KeyError, TypeError, ValueError):
        raise AuthError("invalid_token", "the token subject is invalid")


# ─── 입력 검증 ───────────────────────────────────────────────────────────────

def _validate_signup(login_id: str, password: str, name: str, user_type: str):
    login_id = (login_id or "").strip()
    name = (name or "").strip()

    if not LOGIN_ID_PATTERN.match(login_id):
        raise AuthError(
            "invalid_login_id",
            "login_id must be 4-32 characters of letters, digits, . _ or -",
        )

    if not isinstance(password, str) or len(password) < MIN_PASSWORD_LENGTH:
        raise AuthError(
            "invalid_password",
            f"password must be at least {MIN_PASSWORD_LENGTH} characters",
        )

    if not name:
        raise AuthError("invalid_name", "name must not be empty")

    if user_type not in USER_TYPES:
        raise AuthError(
            "invalid_user_type",
            "user_type must be student or worker",
        )

    return login_id, name


# ─── 회원가입 / 로그인 ───────────────────────────────────────────────────────

def serialize_user(row):
    if row is None:
        return None

    return {
        "user_id": str(row["id"]),
        "login_id": row["login_id"],
        "name": row["name"],
        "user_type": row["user_type"],
        "analysis_started_date": (
            row["analysis_started_date"].isoformat()
            if row["analysis_started_date"]
            else None
        ),
        "created_at": row["created_at"].isoformat(),
    }


def sign_up(login_id: str, password: str, name: str, user_type: str):
    login_id, name = _validate_signup(login_id, password, name, user_type)
    password_hash = _hasher.hash(password)

    try:
        with get_db_connection() as conn:
            user = conn.execute(
                """
                INSERT INTO users (
                    login_id,
                    password_hash,
                    name,
                    user_type
                )
                VALUES (%s, %s, %s, %s)
                RETURNING *
                """,
                (login_id, password_hash, name, user_type),
            ).fetchone()

            # 기본 카테고리. 같은 트랜잭션이라 하나라도 실패하면 가입 전체가 롤백된다.
            for sort_order, (category_name, color) in enumerate(
                DEFAULT_CATEGORIES
            ):
                conn.execute(
                    """
                    INSERT INTO categories (
                        user_id,
                        name,
                        color,
                        sort_order
                    )
                    VALUES (%s, %s, %s, %s)
                    """,
                    (user["id"], category_name, color, sort_order),
                )

    except UniqueViolation:
        raise AuthError("login_id_taken", "that login_id is already in use")

    return {
        "user": serialize_user(user),
        **issue_token(user["id"]),
    }


def log_in(login_id: str, password: str):
    login_id = (login_id or "").strip()

    if not login_id or not isinstance(password, str) or not password:
        raise AuthError("invalid_credentials", "login_id or password is wrong")

    with get_db_connection() as conn:
        user = conn.execute(
            "SELECT * FROM users WHERE login_id = %s",
            (login_id,),
        ).fetchone()

    # 존재하지 않는 아이디와 틀린 비밀번호를 같은 응답으로 처리해
    # 아이디 존재 여부가 새어나가지 않게 한다.
    if user is None:
        _hasher.hash(password)  # 응답 시간을 맞추기 위한 더미 해싱
        raise AuthError("invalid_credentials", "login_id or password is wrong")

    try:
        _hasher.verify(user["password_hash"], password)
    except VerifyMismatchError:
        raise AuthError("invalid_credentials", "login_id or password is wrong")
    except (InvalidHash, VerificationError):
        # 시드로 넣은 TEST_ACCOUNT 처럼 Argon2 형식이 아닌 값이 들어 있는 경우.
        raise AuthError(
            "password_not_set",
            "this account has no usable password; sign up again",
        )

    return {
        "user": serialize_user(user),
        **issue_token(user["id"]),
    }


def get_user(user_id: UUID):
    with get_db_connection() as conn:
        user = conn.execute(
            "SELECT * FROM users WHERE id = %s",
            (user_id,),
        ).fetchone()

    if user is None:
        raise AuthError("user_not_found", "the user does not exist")

    return serialize_user(user)
