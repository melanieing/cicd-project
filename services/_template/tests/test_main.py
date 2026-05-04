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

  ## 왜 setdefault 가 아니라 직접 할당인가
  본래 setdefault 로 두면 "외부에서 주입된 값을 존중" 하는 유연성이 있다.
  그러나 본 테스트들은 셸 환경의 영향을 받지 않아야 한다 (격리·결정성).
  사용자가 e2e 검증을 위해 직전에 `export DATABASE_URL=...localhost:5432...` 를
  실행한 상태로 pytest 를 돌리면, setdefault 가 그 값을 보존해 lifespan 이
  닿지 않는 5432 에 connect 시도하다 timeout 으로 실패한다.
  따라서 모든 테스트 환경변수는 **직접 할당으로 강제 덮어쓰기**한다.
  실 사례 기록: docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md
"""

import os

# 테스트 격리를 위해 강제 할당. 셸에 어떤 값이 export 되어 있어도 무시.
os.environ["SERVICE_NAME"] = "template"
os.environ["DOMAIN_ACTION"] = "process"
os.environ["DATABASE_URL"] = ""

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
