"""transfer service - 이체 도메인 + notification 서비스 호출.

이 파일은 services/_template/main.py 의 복사본에서 출발하지만,
**Task 1.3 으로 인해 다음 점에서 달라진다:**
  1. NOTIFICATION_URL / NOTIFICATION_TIMEOUT 환경변수 추가
  2. lifespan 에 httpx.AsyncClient 생성·정리 추가 (모듈당 1개 재사용)
  3. POST /transfer 핸들러가 처리 후 notification 의 /send 를 호출
  4. ActionResponse 에 notification 필드 추가 (호출 결과 메타데이터)

이 호출은 Kiali 토폴로지에서 transfer -> notification 의존성 엣지를 만들고,
Canary 라우팅·Circuit Breaker 시연의 핵심 트래픽이 된다.

[graceful degrade — 의도적 설계]
notification 호출이 실패해도 transfer 자체는 성공으로 응답한다.
이는 의도적으로, EPIC 8 의 outlierDetection / Circuit Breaker 시연에서
"primary 비즈니스 흐름은 끊기지 않으면서 비핵심 의존성만 자동 격리됨"을
보이기 위함이다.

[Python 기초 메모 — 추가된 문법]
  - `httpx.AsyncClient` : asyncio 위에서 동작하는 HTTP 클라이언트.
    내부에 connection pool 을 보유하므로 매 요청마다 새로 만들지 않고
    lifespan 동안 1개를 재사용한다 (재사용하지 않으면 매 요청 TCP 핸드셰이크 발생).
  - `dict[str, Any] | None` : "dict 또는 None" union 타입. Pydantic v2 BaseModel
    필드의 default `= None` 과 결합하면 optional 필드가 된다.
  - `r.raise_for_status()` : HTTP 응답이 4xx/5xx 면 예외(HTTPStatusError) 발생.
    명시적으로 호출해야 하며, 호출하지 않으면 응답 객체만 반환되고 에러는 무시됨.
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from typing import Any

import asyncpg
import httpx  # 비동기 HTTP 클라이언트 (Task 1.3 추가)
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel


# ---------------------------------------------------------------------------
# 환경변수 로드
# ---------------------------------------------------------------------------

SERVICE_NAME: str = os.getenv("SERVICE_NAME", "transfer")
DATABASE_URL: str = os.getenv("DATABASE_URL", "")
DOMAIN_ACTION: str = os.getenv("DOMAIN_ACTION", "transfer")
DB_POOL_MIN: int = int(os.getenv("DB_POOL_MIN", "1"))
DB_POOL_MAX: int = int(os.getenv("DB_POOL_MAX", "5"))

# 본 서비스 인스턴스의 "버전 표지" — Canary 배포 (EPIC 6 Task 6.4-6.5) 시연용.
# 같은 코드/이미지를 두 Deployment 로 띄우되 stable 은 SERVICE_VERSION=stable,
# canary 는 SERVICE_VERSION=canary 로 환경변수만 다르게 설정한다.
# 그러면 /version 엔드포인트의 응답으로 "지금 트래픽이 어느 subset 으로 라우팅됐는지"
# 가 가시적으로 드러나, Istio VirtualService 의 weight 조정이 실제 동작함을 입증한다.
# 비어있으면 "unknown" 으로 폴백하여 mesh 미적용 환경 (단순 로컬 실행) 에서도 안전.
SERVICE_VERSION: str = os.getenv("SERVICE_VERSION", "unknown")

# 알림 서비스의 HTTP base URL.
# 빈 문자열이면 알림 호출을 스킵 (graceful skip — 로컬에서 transfer 단독 테스트 가능).
# K8s 환경 예: http://notification.payment-dev.svc.cluster.local:8000
NOTIFICATION_URL: str = os.getenv("NOTIFICATION_URL", "")

# 알림 호출 타임아웃(초).
# 너무 길면 transfer 응답이 느려져 사용자 경험 악화,
# 너무 짧으면 정상 호출도 실패. mesh 환경 일반값인 2초로 설정.
NOTIFICATION_TIMEOUT: float = float(os.getenv("NOTIFICATION_TIMEOUT", "2.0"))


# ---------------------------------------------------------------------------
# 로깅
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
log = logging.getLogger(SERVICE_NAME)


# ---------------------------------------------------------------------------
# 애플리케이션 상태
# DB pool + HTTP client 두 개의 long-lived 자원을 보관.
# ---------------------------------------------------------------------------
state: dict[str, Any] = {"db_pool": None, "http_client": None}


# ---------------------------------------------------------------------------
# Lifespan
#   - startup : DB 풀 + HTTP 클라이언트 생성
#   - shutdown: HTTP 클라이언트 close, DB 풀 close (생성 역순)
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    # === startup ===
    if DATABASE_URL:
        log.info("Initializing DB pool: min=%d max=%d", DB_POOL_MIN, DB_POOL_MAX)
        state["db_pool"] = await asyncpg.create_pool(
            DATABASE_URL, min_size=DB_POOL_MIN, max_size=DB_POOL_MAX
        )
    else:
        log.warning("DATABASE_URL is empty - readiness probe will fail")

    # httpx.AsyncClient 는 connection pool 을 내부 보유하므로
    # 모듈 시작 시 1번 생성해서 lifespan 내내 재사용.
    state["http_client"] = httpx.AsyncClient(timeout=NOTIFICATION_TIMEOUT)
    log.info("HTTP client initialized (timeout=%.1fs)", NOTIFICATION_TIMEOUT)

    yield  # ← 요청 받기 시작

    # === shutdown ===
    client = state["http_client"]
    if client is not None:
        await client.aclose()
        log.info("HTTP client closed")
    pool = state["db_pool"]
    if pool is not None:
        log.info("Closing DB pool")
        await pool.close()


app = FastAPI(title=f"{SERVICE_NAME}-service", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Liveness / Readiness
# (template 과 동일. 변경 시 양쪽 모두 일관 유지)
# ---------------------------------------------------------------------------
@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": SERVICE_NAME}


# ---------------------------------------------------------------------------
# Canary 시연용 — /version
#
# Istio 의 VirtualService 가중치 라우팅이 실제로 동작함을 눈으로 확인하기 위한
# 가벼운 readonly 엔드포인트. 응답은 단순히 본 인스턴스의 SERVICE_NAME +
# SERVICE_VERSION 을 JSON 으로 돌려준다.
#
# 운영 가정:
#   - 같은 image 를 두 Deployment (transfer-stable / transfer-canary) 로 띄움
#   - 두 Deployment 의 env SERVICE_VERSION 만 다르게 설정 (stable / canary)
#   - 두 pod 모두 같은 K8s Service `transfer` 의 endpoint 가 됨
#   - DestinationRule 이 version 라벨로 두 subset 을 나누고, VirtualService 가
#     weight (예: 80/20 → 50/50 → 0/100) 로 트래픽을 분배
#   - 클라이언트가 /version 을 N 회 호출 후 응답 분포를 보면 weight 비율과 일치해야 함
#
# 본 엔드포인트는 readiness 와 의도적으로 분리되어 있다 — readiness 는 DB 연결을
# 검사하지만 /version 은 그 의존성을 타지 않는다. canary 시연 중 DB 가 잠시
# 흔들려도 트래픽 분배 자체는 확인 가능해야 하기 때문.
# ---------------------------------------------------------------------------
@app.get("/version")
async def version() -> dict[str, str]:
    return {"service": SERVICE_NAME, "version": SERVICE_VERSION}


@app.get("/health/ready")
async def readiness() -> dict[str, str]:
    pool = state["db_pool"]
    if pool is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="DB pool not initialized",
        )
    try:
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
    except Exception as exc:
        log.error("Readiness check failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"DB unreachable: {exc}",
        )
    return {"status": "ready", "service": SERVICE_NAME}


# ---------------------------------------------------------------------------
# 요청/응답 모델
# transfer 전용으로 ActionResponse 에 notification 필드 추가.
# ---------------------------------------------------------------------------
class ActionRequest(BaseModel):
    payload: dict[str, Any]


class ActionResponse(BaseModel):
    service: str
    action: str
    status: str
    received: dict[str, Any]
    # transfer 전용: notification 호출 결과 메타데이터.
    # NOTIFICATION_URL 미설정 -> status="skipped"
    # HTTP 200 응답   -> status="delivered" + http_status + response
    # 실패            -> status="failed"    + error 문자열
    notification: dict[str, Any] | None = None


# ---------------------------------------------------------------------------
# notification 서비스 호출 헬퍼
# 어떤 예외가 발생해도 raise 하지 않고 메타데이터 dict 로 변환해 반환한다
# (graceful degrade — transfer 응답을 깨뜨리지 않기 위함).
# ---------------------------------------------------------------------------
async def call_notification(payload: dict[str, Any]) -> dict[str, Any]:
    client: httpx.AsyncClient | None = state["http_client"]
    if not NOTIFICATION_URL or client is None:
        return {"status": "skipped", "reason": "NOTIFICATION_URL not configured"}

    # 알림 서비스의 ActionRequest 스키마에 맞춰 payload 를 감싼다.
    # 실제 시스템에서는 채널/수신자/본문을 도메인 규칙에 따라 정교하게 구성.
    notif_payload = {
        "payload": {
            "channel": "system",
            "to": str(payload.get("to", "unknown")),
            "body": f"transfer-completed payload={payload}",
        }
    }
    try:
        r = await client.post(f"{NOTIFICATION_URL}/send", json=notif_payload)
        r.raise_for_status()  # 4xx/5xx 시 HTTPStatusError
        return {
            "status": "delivered",
            "http_status": r.status_code,
            "response": r.json(),
        }
    except httpx.HTTPError as exc:
        # httpx.HTTPError 는 timeout/connect-error/4xx/5xx 등 httpx 예외의 베이스 클래스.
        log.error("Notification call failed: %s", exc)
        return {"status": "failed", "error": str(exc)}


# ---------------------------------------------------------------------------
# 도메인 액션 — POST /transfer
# 1) (mock) 이체 처리 — 실제 시스템에서는 DB transaction 으로 출금/입금 처리
# 2) notification 호출 (graceful degrade)
# 3) 응답에 notification 메타데이터 포함
# ---------------------------------------------------------------------------
@app.post(f"/{DOMAIN_ACTION}", response_model=ActionResponse)
async def domain_action(req: ActionRequest) -> ActionResponse:
    log.info("Action %s received: %s", DOMAIN_ACTION, req.payload)

    # mock 이체 처리 자리. 실제 비즈니스 로직은 의도적으로 비워둠 (포트폴리오 정책).

    # 알림 호출 — 실패해도 transfer 응답은 정상 발급.
    notification_meta = await call_notification(req.payload)

    return ActionResponse(
        service=SERVICE_NAME,
        action=DOMAIN_ACTION,
        status="accepted",
        received=req.payload,
        notification=notification_meta,
    )
