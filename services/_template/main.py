"""Service template for the payment-platform project.

This is the base FastAPI application that all four services
(account, transfer, loan, notification) are derived from.

Endpoints:
  GET  /health        - liveness probe (process alive)
  GET  /health/ready  - readiness probe (DB reachable)
  POST /<domain>      - domain action stub (mock business logic)

Configuration is via environment variables; see .env.example.
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from typing import Any

import asyncpg
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel

SERVICE_NAME: str = os.getenv("SERVICE_NAME", "template")
DATABASE_URL: str = os.getenv("DATABASE_URL", "")
DOMAIN_ACTION: str = os.getenv("DOMAIN_ACTION", "process")
DB_POOL_MIN: int = int(os.getenv("DB_POOL_MIN", "1"))
DB_POOL_MAX: int = int(os.getenv("DB_POOL_MAX", "5"))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
log = logging.getLogger(SERVICE_NAME)

state: dict[str, Any] = {"db_pool": None}


@asynccontextmanager
async def lifespan(app: FastAPI):
    if DATABASE_URL:
        log.info("Initializing DB pool: min=%d max=%d", DB_POOL_MIN, DB_POOL_MAX)
        state["db_pool"] = await asyncpg.create_pool(
            DATABASE_URL, min_size=DB_POOL_MIN, max_size=DB_POOL_MAX
        )
    else:
        log.warning("DATABASE_URL is empty - readiness probe will fail")
    yield
    pool = state["db_pool"]
    if pool is not None:
        log.info("Closing DB pool")
        await pool.close()


app = FastAPI(title=f"{SERVICE_NAME}-service", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": SERVICE_NAME}


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


class ActionRequest(BaseModel):
    payload: dict[str, Any]


class ActionResponse(BaseModel):
    service: str
    action: str
    status: str
    received: dict[str, Any]


@app.post(f"/{DOMAIN_ACTION}", response_model=ActionResponse)
async def domain_action(req: ActionRequest) -> ActionResponse:
    log.info("Action %s received: %s", DOMAIN_ACTION, req.payload)
    return ActionResponse(
        service=SERVICE_NAME,
        action=DOMAIN_ACTION,
        status="accepted",
        received=req.payload,
    )
