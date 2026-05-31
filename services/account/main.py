"""서비스 템플릿 - payment-platform 프로젝트의 FastAPI 베이스 애플리케이션.

이 파일을 복사해서 4개 서비스(account, transfer, loan, notification)를 만든다.

이 파일이 시스템에서 하는 일:
  - HTTP 서버 1개를 띄운다 (Uvicorn 위에서 FastAPI 앱)
  - K8s가 호출할 헬스체크 2종(liveness/readiness)을 노출
  - 도메인 액션 1개(POST /<DOMAIN_ACTION>)를 mock으로 노출
  - PostgreSQL 커넥션 풀을 lifespan에 맞춰 생성/정리

[Python 기초 메모 — 이 파일에 쓰인 문법]
  - 트리플 쿼트 `\"\"\"...\"\"\"` : docstring (모듈/함수 설명문). help()으로 조회 가능
  - `from __future__ import annotations` : 타입 힌트를 "문자열로" 평가시켜 forward reference
    문제(아직 정의 안된 타입을 미리 참조)와 import 비용을 줄인다. Python 3.10+ 권장 패턴.
  - `async def` : 비동기 함수. 호출하면 즉시 실행되지 않고 코루틴 객체를 반환.
    `await`로 결과를 기다리거나 이벤트 루프(여기선 Uvicorn)가 스케줄링.
  - `@데코레이터` : 함수를 감싸는 함수. `@app.get("/x")`는 함수를 라우트에 등록.
  - `dict[str, Any]` : Python 3.9+ 부터 허용된 제네릭 타입 힌트. (옛 문법: `Dict[str, Any]`)
"""

# `__future__` import는 반드시 docstring 직후, 다른 import보다 먼저.
from __future__ import annotations

# --- 표준 라이브러리 ---
import logging  # 구조적 로그 출력 (print 대신 사용; 레벨/포맷 일괄 관리)
import os  # 환경변수 읽기 등 OS 인터페이스
from contextlib import asynccontextmanager  # async generator를 with 호환 객체로 변환하는 데코레이터
from typing import Any  # "어떤 타입이든 OK"를 표현하는 타입 힌트

# --- 외부 라이브러리 (requirements.txt 참고) ---
import asyncpg  # PostgreSQL의 비동기 드라이버 (asyncio 위에서 동작)
from fastapi import FastAPI, HTTPException, status  # 웹 프레임워크 + HTTP 상태 코드 enum
from pydantic import BaseModel  # 요청/응답 모델 자동 검증 + 직렬화


# ---------------------------------------------------------------------------
# 환경변수 로드
# 컨테이너로 배포될 때는 K8s ConfigMap/Secret이 환경변수로 주입된다.
# 로컬 실행 시에는 .env 파일에서 export하거나 직접 export 명령으로 설정.
# ---------------------------------------------------------------------------

# os.getenv("이름", "기본값") - 환경변수가 비어있으면 두 번째 인자가 기본값.
# 타입 힌트(`: str`)는 mypy/pyright 같은 정적 분석 도구에 의도를 알리는 용도.
# 런타임에서 강제되지 않는다 (Python은 동적 타입 언어).
SERVICE_NAME: str = os.getenv("SERVICE_NAME", "template")

# Postgres 접속 문자열. 형식: postgresql://user:password@host:port/dbname
# 빈 문자열이면 DB 풀 초기화를 스킵하고 readiness probe가 503을 반환한다.
DATABASE_URL: str = os.getenv("DATABASE_URL", "")

# 도메인 액션의 엔드포인트 경로명. 예: "transfer" → POST /transfer 노출.
DOMAIN_ACTION: str = os.getenv("DOMAIN_ACTION", "process")

# 환경변수는 항상 문자열로 들어오므로 int()로 명시 변환이 필요.
# pod 1개당 최소/최대 커넥션 수. HPA로 pod 수가 늘면 풀도 함께 확장된다.
DB_POOL_MIN: int = int(os.getenv("DB_POOL_MIN", "1"))
DB_POOL_MAX: int = int(os.getenv("DB_POOL_MAX", "5"))

# 본 서비스 인스턴스의 "버전 표지" — Blue-Green 배포 (EPIC 6 Task 6.8) 시연용.
# 같은 코드/이미지를 두 Deployment (account-blue / account-green) 로 띄우되 환경변수만
# 다르게 설정한다. /version 엔드포인트의 응답으로 "지금 트래픽이 어느 색깔로 갔는지" 가
# 가시화되어, Istio VirtualService 의 즉시 100% 전환이 실제 동작함을 입증한다.
# 비어있으면 "unknown" — 메시 미적용 환경 (단순 로컬 실행) 에서도 안전.
SERVICE_VERSION: str = os.getenv("SERVICE_VERSION", "unknown")


# ---------------------------------------------------------------------------
# 로깅 설정
# basicConfig는 루트 로거 1회 설정. 이후 logging.getLogger(name)으로 자식 로거를 받는다.
# - level: DEBUG/INFO/WARNING/ERROR/CRITICAL 중 임계 레벨 (이 레벨 이상만 출력)
# - format: 시간 + 레벨 + 로거 이름 + 메시지
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
log = logging.getLogger(SERVICE_NAME)


# ---------------------------------------------------------------------------
# 애플리케이션 상태
# 전역 dict 1개에 long-lived 자원(DB 풀 등)을 모아둔다.
# 모듈 레벨 변수에 직접 할당하면 import 순서/순환 참조 문제가 있어
# dict 패턴이 fastapi 커뮤니티에서 흔히 쓰인다.
# ---------------------------------------------------------------------------
state: dict[str, Any] = {"db_pool": None}


# ---------------------------------------------------------------------------
# Lifespan 핸들러
# FastAPI 앱이 기동/종료될 때 실행되는 코드.
#   - yield 이전(startup): DB 풀 생성, 외부 서비스 connect 등
#   - yield 자체: 앱이 요청을 받기 시작
#   - yield 이후(shutdown): 자원 정리
#
# `@asynccontextmanager` 데코레이터가 async generator function을
# `async with` 호환 context manager로 변환한다. FastAPI가 내부적으로
# `async with lifespan(app):` 형태로 호출.
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    # === startup ===
    if DATABASE_URL:
        log.info("Initializing DB pool: min=%d max=%d", DB_POOL_MIN, DB_POOL_MAX)
        # `await`는 코루틴이 끝날 때까지 현재 함수의 실행을 일시 중단.
        # 그 동안 다른 코루틴이 이벤트 루프 위에서 실행될 수 있다.
        state["db_pool"] = await asyncpg.create_pool(
            DATABASE_URL, min_size=DB_POOL_MIN, max_size=DB_POOL_MAX
        )
    else:
        log.warning("DATABASE_URL is empty - readiness probe will fail")

    yield  # ← 이 시점에 FastAPI가 요청 받기 시작

    # === shutdown ===
    pool = state["db_pool"]
    if pool is not None:
        log.info("Closing DB pool")
        await pool.close()


# FastAPI 인스턴스 생성. lifespan 인자로 위 함수를 전달하면
# 시작/종료 hook이 자동으로 연결된다.
app = FastAPI(title=f"{SERVICE_NAME}-service", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Liveness probe — GET /health
#
# K8s가 컨테이너의 프로세스가 살아있는지 주기적으로 확인.
# DB 같은 외부 의존성을 체크하면 안 된다. 외부 장애 시 pod가 무한 재시작될 수 있음.
# 200을 반환하면 "프로세스 OK", 실패(연결 거부 등)는 K8s가 컨테이너 재시작.
#
# `@app.get("/health")` : 데코레이터가 이 함수를 GET /health 라우트로 등록.
# `-> dict[str, str]` : 반환 타입 힌트. FastAPI가 이를 보고 OpenAPI 스키마 생성.
# ---------------------------------------------------------------------------
@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": SERVICE_NAME}


# ---------------------------------------------------------------------------
# Blue-Green 시연용 — /version
#
# Istio VirtualService 의 100% 즉시 전환이 실제로 동작함을 눈으로 보기 위한
# readonly 엔드포인트. 응답은 본 인스턴스의 SERVICE_NAME + SERVICE_VERSION (blue / green).
#
# 운영 가정:
#   - 같은 image 를 두 Deployment (account-blue / account-green) 로 띄움
#   - 두 Deployment 의 env SERVICE_VERSION 만 다름 (blue 또는 green)
#   - 두 pod 모두 같은 K8s Service `account` 의 endpoint
#   - DestinationRule 이 version 라벨로 두 subset 분류, VirtualService 가 100/0 또는 0/100
#   - 전환 후 클라이언트가 /version 을 N 회 호출하면 100% 한쪽 응답만 보여야 함
#
# /health 와 분리: /version 은 DB 의존성 없음. blue-green 전환 시점에 DB 가 잠시 흔들려도
# 트래픽 라우팅 자체는 검증 가능.
# ---------------------------------------------------------------------------
@app.get("/version")
async def version() -> dict[str, str]:
    return {"service": SERVICE_NAME, "version": SERVICE_VERSION}


# ---------------------------------------------------------------------------
# Readiness probe — GET /health/ready
#
# K8s가 트래픽을 보내기 전에 "이 pod이 요청 처리 준비됐냐"를 확인.
# DB가 죽으면 503을 반환해서 트래픽 차단 → Service의 endpoints에서 자동 제외.
# Liveness와 다르게 외부 의존성 체크가 정당하다 (트래픽 분리가 목적이므로).
# ---------------------------------------------------------------------------
@app.get("/health/ready")
async def readiness() -> dict[str, str]:
    pool = state["db_pool"]
    if pool is None:
        # 503 Service Unavailable. K8s는 503을 받으면 트래픽을 보내지 않는다.
        # `raise`는 예외를 발생시키는 키워드. FastAPI는 HTTPException을 잡아
        # 자동으로 해당 status_code의 HTTP 응답을 만들어 반환한다.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="DB pool not initialized",
        )
    try:
        # `async with` = 비동기 context manager.
        # 풀에서 커넥션 1개를 빌리고, with 블록을 나가면 자동 반환.
        async with pool.acquire() as conn:
            # `SELECT 1`은 connectivity 확인용 가장 가벼운 쿼리.
            # fetchval은 단일 스칼라 값을 반환.
            await conn.fetchval("SELECT 1")
    except Exception as exc:
        # 광범위 except는 일반적으로 안티패턴이지만,
        # readiness probe는 "어떤 이유로든 DB가 안 되면 503"이라는 의도라 정당.
        log.error("Readiness check failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"DB unreachable: {exc}",
        )
    return {"status": "ready", "service": SERVICE_NAME}


# ---------------------------------------------------------------------------
# 도메인 액션 (mock) — POST /<DOMAIN_ACTION>
#
# Pydantic BaseModel을 상속한 클래스는 자동으로:
#   - 요청 JSON을 클래스 인스턴스로 검증/변환 (잘못된 타입이면 422 응답 자동 생성)
#   - 응답 인스턴스를 자동 직렬화하여 JSON으로 변환
#   - OpenAPI(/docs) 스키마 자동 생성
# ---------------------------------------------------------------------------
class ActionRequest(BaseModel):
    # 클라이언트가 어떤 키든 자유롭게 보낼 수 있도록 dict 형태로 받는다.
    # 실제 도메인 로직이 들어가면 구체 필드(amount, account_id 등)로 교체.
    payload: dict[str, Any]


class ActionResponse(BaseModel):
    service: str
    action: str
    status: str
    received: dict[str, Any]


# f-string `f"/{DOMAIN_ACTION}"`은 환경변수 값을 경로에 삽입.
# 예: DOMAIN_ACTION=transfer → POST /transfer 라우트가 등록된다.
# response_model을 지정하면 FastAPI가 응답을 그 모델로 검증/필터링한다.
@app.post(f"/{DOMAIN_ACTION}", response_model=ActionResponse)
async def domain_action(req: ActionRequest) -> ActionResponse:
    log.info("Action %s received: %s", DOMAIN_ACTION, req.payload)
    return ActionResponse(
        service=SERVICE_NAME,
        action=DOMAIN_ACTION,
        status="accepted",
        received=req.payload,
    )
