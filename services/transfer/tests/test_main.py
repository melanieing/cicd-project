"""transfer 서비스 — 단위 테스트.

template 과 달리 transfer 는 notification 호출 로직(Task 1.3) 이 추가되어 있어
**graceful degrade 동작까지** 검증한다.

검증 포인트:
  1. /health 가 200 + service=transfer 반환
  2. /transfer 응답이 ActionResponse 스키마(notification 필드 포함) 를 따름
  3. NOTIFICATION_URL 미설정 시 notification.status == "skipped"
     - 이는 EPIC 8 의 outlierDetection 시연을 위한 graceful-degrade 정책의 핵심.

상세 패턴 설명은 services/_template/tests/test_main.py 헤더 참조.
"""

import os

# 테스트 격리를 위해 강제 할당. 자세한 근거는 _template/tests/test_main.py 헤더 참조.
os.environ["SERVICE_NAME"] = "transfer"
os.environ["DOMAIN_ACTION"] = "transfer"
os.environ["DATABASE_URL"] = ""
# 핵심: 빈 값으로 강제해 graceful "skipped" 분기를 검증 가능하게 함.
os.environ["NOTIFICATION_URL"] = ""
# Canary 시연용 SERVICE_VERSION (EPIC 6) — 테스트에서는 명시적 값으로 고정.
os.environ["SERVICE_VERSION"] = "test-stable"

from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402


def test_health_returns_ok() -> None:
    """liveness probe 가 200 + service=transfer 를 반환."""
    with TestClient(app) as client:
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok", "service": "transfer"}


def test_version_returns_service_and_version() -> None:
    """/version 엔드포인트가 SERVICE_VERSION env 값을 그대로 응답에 포함.

    Canary 시연에서 클라이언트가 응답을 보고 "이 요청이 stable 로 갔는지 canary 로
    갔는지" 를 식별하는 핵심 채널이라, env 값이 응답에 정확히 그대로 노출되어야 함.
    """
    with TestClient(app) as client:
        r = client.get("/version")
        assert r.status_code == 200
        assert r.json() == {"service": "transfer", "version": "test-stable"}


def test_transfer_action_skips_notification_when_url_unset() -> None:
    """NOTIFICATION_URL 미설정 시 transfer 는 200 응답 + notification.status='skipped'.

    이 테스트는 graceful degrade 의 first line 을 보장한다:
    "비핵심 의존성이 없어도 메인 비즈니스 흐름은 끊기지 않는다."
    """
    payload = {"payload": {"from": "a-1", "to": "a-2", "amount": 5000}}
    with TestClient(app) as client:
        r = client.post("/transfer", json=payload)
        assert r.status_code == 200

        body = r.json()
        # 표준 ActionResponse 필드
        assert body["service"] == "transfer"
        assert body["action"] == "transfer"
        assert body["status"] == "accepted"
        assert body["received"] == payload["payload"]

        # graceful skip 메타데이터
        notification = body["notification"]
        assert notification is not None
        assert notification["status"] == "skipped"
        # reason 문자열에 NOTIFICATION_URL 키가 포함되어 있어야 디버깅 용이
        assert "NOTIFICATION_URL" in notification.get("reason", "")
