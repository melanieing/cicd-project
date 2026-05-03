"""notification 서비스 — 단위 테스트.

상세 설명은 services/_template/tests/test_main.py 헤더 참조.
이 파일은 SERVICE_NAME=notification / DOMAIN_ACTION=send 외에는 템플릿과 동일.
"""

import os

os.environ.setdefault("SERVICE_NAME", "notification")
os.environ.setdefault("DOMAIN_ACTION", "send")
os.environ.setdefault("DATABASE_URL", "")

from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402


def test_health_returns_ok() -> None:
    """liveness probe 가 200 + service=notification 을 반환."""
    with TestClient(app) as client:
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok", "service": "notification"}


def test_send_action_echoes_payload() -> None:
    """POST /send 가 payload 를 echo + status=accepted 반환."""
    payload = {"payload": {"channel": "email", "to": "u@example.com", "body": "hello"}}
    with TestClient(app) as client:
        r = client.post("/send", json=payload)
        assert r.status_code == 200
        body = r.json()
        assert body["service"] == "notification"
        assert body["action"] == "send"
        assert body["status"] == "accepted"
        assert body["received"] == payload["payload"]
