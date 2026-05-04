"""loan 서비스 — 단위 테스트.

상세 설명은 services/_template/tests/test_main.py 헤더 참조.
이 파일은 SERVICE_NAME=loan / DOMAIN_ACTION=apply 외에는 템플릿과 동일.
"""

import os

# 테스트 격리를 위해 강제 할당. 자세한 근거는 _template/tests/test_main.py 헤더 참조.
os.environ["SERVICE_NAME"] = "loan"
os.environ["DOMAIN_ACTION"] = "apply"
os.environ["DATABASE_URL"] = ""

from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402


def test_health_returns_ok() -> None:
    """liveness probe 가 200 + service=loan 을 반환."""
    with TestClient(app) as client:
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok", "service": "loan"}


def test_apply_action_echoes_payload() -> None:
    """POST /apply 가 payload 를 echo + status=accepted 반환."""
    payload = {"payload": {"customer_id": "c-1", "amount": 1000000, "term_months": 24}}
    with TestClient(app) as client:
        r = client.post("/apply", json=payload)
        assert r.status_code == 200
        body = r.json()
        assert body["service"] == "loan"
        assert body["action"] == "apply"
        assert body["status"] == "accepted"
        assert body["received"] == payload["payload"]
