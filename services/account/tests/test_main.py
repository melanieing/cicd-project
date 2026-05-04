"""account 서비스 — 단위 테스트.

상세 설명은 services/_template/tests/test_main.py 헤더 참조.
이 파일은 SERVICE_NAME=account / DOMAIN_ACTION=open 외에는 템플릿과 동일.
"""

import os

# 테스트 격리를 위해 강제 할당. 셸에 어떤 값이 export 되어 있어도 무시.
# 자세한 근거는 services/_template/tests/test_main.py 헤더 참조.
os.environ["SERVICE_NAME"] = "account"
os.environ["DOMAIN_ACTION"] = "open"
os.environ["DATABASE_URL"] = ""

from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402


def test_health_returns_ok() -> None:
    """liveness probe 가 200 + service=account 를 반환."""
    with TestClient(app) as client:
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok", "service": "account"}


def test_open_action_echoes_payload() -> None:
    """POST /open 이 payload 를 echo + status=accepted 반환."""
    payload = {"payload": {"customer_id": "c-1", "initial_deposit": 10000}}
    with TestClient(app) as client:
        r = client.post("/open", json=payload)
        assert r.status_code == 200
        body = r.json()
        assert body["service"] == "account"
        assert body["action"] == "open"
        assert body["status"] == "accepted"
        assert body["received"] == payload["payload"]
