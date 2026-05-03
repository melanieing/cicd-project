"""template 서비스 — 단위 테스트.

본 파일은 services/_template/main.py 의 행동을 in-memory 로 검증한다.
복사된 4개 서비스(account/transfer/loan/notification) 의 tests/test_main.py 도
동일한 패턴을 따르므로 본 파일이 베이스다.

[Python/pytest 기초 메모]
  - `from fastapi.testclient import TestClient` :
      FastAPI 앱을 in-memory 로 실행하면서 실제 HTTP 요청처럼 호출 가능.
      내부적으로 httpx 와 ASGI 스택을 사용.
  - `with TestClient(app) as client:` :
      context manager 형태로 사용하면 FastAPI 의 lifespan 핸들러
      (startup -> yield -> shutdown) 가 정상적으로 호출된다.
      이 형태가 아니면 lifespan 코드가 실행되지 않아 자원 누수 가능.
  - `def test_xxx():` :
      pytest 는 `test_` 로 시작하는 함수를 자동으로 테스트로 인식.
      클래스 기반(`TestXxx`) 도 가능하지만 본 프로젝트는 함수 스타일.
  - `assert ...` :
      pytest 는 일반 assert 문을 가로채 실패 시 풍부한 비교 정보 출력.

[테스트 환경 변수 처리]
  main.py 는 모듈 import 시점에 환경변수를 읽어 모듈 레벨 상수로 박는다.
  따라서 `from main import app` 보다 먼저 환경변수를 설정해야 한다.
  os.environ.setdefault 는 이미 설정된 값을 덮어쓰지 않는 안전한 형태
  (CI 에서 외부 주입된 값을 존중).

  DATABASE_URL="" 로 두면 lifespan 이 DB 풀 생성을 스킵해 postgres 없이도 테스트 가능.
"""

import os

os.environ.setdefault("SERVICE_NAME", "template")
os.environ.setdefault("DOMAIN_ACTION", "process")
os.environ.setdefault("DATABASE_URL", "")

# 환경변수 설정 후 main.py 를 import. 순서가 바뀌면 기본값으로 모듈이 초기화됨.
from fastapi.testclient import TestClient  # noqa: E402  (intentional late import)
from main import app  # noqa: E402


def test_health_returns_ok() -> None:
    """liveness probe 가 200 + 표준 페이로드를 반환하는지 검증."""
    with TestClient(app) as client:
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok", "service": "template"}


def test_readiness_returns_503_without_db() -> None:
    """DB 미설정 시 readiness 가 503 으로 graceful failure 한다."""
    with TestClient(app) as client:
        r = client.get("/health/ready")
        # readiness 가 lifespan 에서 DB 풀이 None 인 것을 보고 503 반환
        assert r.status_code == 503


def test_domain_action_echoes_payload() -> None:
    """POST /process 가 payload 를 echo + 표준 응답을 반환."""
    payload = {"payload": {"hello": "world", "n": 42}}
    with TestClient(app) as client:
        r = client.post("/process", json=payload)
        assert r.status_code == 200
        body = r.json()
        assert body["service"] == "template"
        assert body["action"] == "process"
        assert body["status"] == "accepted"
        assert body["received"] == payload["payload"]
