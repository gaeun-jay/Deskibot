"""인증 REST 엔드포인트 + 다른 라우터가 쓰는 로그인 의존성.

    POST /api/auth/signup
    POST /api/auth/login
    GET  /api/auth/me

다른 API 모듈은 여기서 current_user_id 를 가져다 쓴다:

    from app.auth_api import current_user_id
    ...
    def list_todos(user_id: UUID = Depends(current_user_id)):
"""

import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict
from starlette.concurrency import run_in_threadpool

from app.auth_service import AuthError, get_user, log_in, sign_up, verify_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/auth", tags=["auth"])

_bearer = HTTPBearer(auto_error=False)

STATUS_BY_CODE = {
    "invalid_login_id": 400,
    "invalid_password": 400,
    "invalid_name": 400,
    "invalid_user_type": 400,
    "invalid_credentials": 401,
    "password_not_set": 401,
    "invalid_token": 401,
    "token_expired": 401,
    "user_not_found": 404,
    "login_id_taken": 409,
    # 서버 설정 누락은 클라이언트 잘못이 아니다.
    "missing_jwt_secret": 500,
}


def http_error(error: AuthError) -> HTTPException:
    status_code = STATUS_BY_CODE.get(error.code, 400)

    if error.code == "missing_jwt_secret":
        logger.error("JWT_SECRET is not configured")

        return HTTPException(
            status_code=500,
            detail={
                "code": "server_misconfigured",
                "message": "an internal server error occurred",
            },
        )

    headers = (
        {"WWW-Authenticate": "Bearer"} if status_code == 401 else None
    )

    return HTTPException(
        status_code=status_code,
        detail={"code": error.code, "message": error.message},
        headers=headers,
    )


# ─── 의존성 ──────────────────────────────────────────────────────────────────

async def current_user_id(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> UUID:
    if credentials is None:
        raise HTTPException(
            status_code=401,
            detail={
                "code": "missing_token",
                "message": "an authorization bearer token is required",
            },
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        return verify_token(credentials.credentials)
    except AuthError as error:
        raise http_error(error)


# ─── 요청 모델 ───────────────────────────────────────────────────────────────

class SignUpRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    login_id: str
    password: str
    name: str
    user_type: str


class LogInRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    login_id: str
    password: str


# ─── 엔드포인트 ──────────────────────────────────────────────────────────────

@router.post("/signup", status_code=201)
async def signup(body: SignUpRequest):
    try:
        return await run_in_threadpool(
            sign_up,
            body.login_id,
            body.password,
            body.name,
            body.user_type,
        )

    except AuthError as error:
        raise http_error(error)

    except Exception:
        logger.exception("Unexpected signup error")

        raise HTTPException(
            status_code=500,
            detail={
                "code": "internal_error",
                "message": "an internal server error occurred",
            },
        )


@router.post("/login")
async def login(body: LogInRequest):
    try:
        return await run_in_threadpool(log_in, body.login_id, body.password)

    except AuthError as error:
        raise http_error(error)

    except Exception:
        logger.exception("Unexpected login error")

        raise HTTPException(
            status_code=500,
            detail={
                "code": "internal_error",
                "message": "an internal server error occurred",
            },
        )


@router.get("/me")
async def me(user_id: UUID = Depends(current_user_id)):
    try:
        return await run_in_threadpool(get_user, user_id)

    except AuthError as error:
        raise http_error(error)
