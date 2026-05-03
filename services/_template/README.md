# Service Template

본 디렉토리는 4개 서비스(`account`, `transfer`, `loan`, `notification`)의 **공통 베이스**다.
새 서비스를 만들 때는 이 디렉토리를 복사한 뒤 환경변수만 바꾸면 된다.

## 엔드포인트

| Method | Path | 용도 | Probe 매핑 |
|---|---|---|---|
| GET | `/health` | 프로세스 생존 확인 | Liveness |
| GET | `/health/ready` | DB 연결까지 확인 | Readiness |
| POST | `/<DOMAIN_ACTION>` | 도메인 액션 mock (요청 echo) | - |

요구사항 매핑: `B3-M2` (Readiness DB 연결 확인 / Liveness 프로세스 생존 확인)

## 환경변수

`.env.example` 참조. 필수:

| 변수 | 예시 | 설명 |
|---|---|---|
| `SERVICE_NAME` | `account` | 로그/응답에 표기되는 서비스 이름 |
| `DATABASE_URL` | `postgresql://...` | asyncpg connection string |
| `DOMAIN_ACTION` | `transfer` | POST 엔드포인트 경로명 |

## 4개 서비스 인스턴스화 매핑 (Task 1.2)

| 서비스 | `SERVICE_NAME` | `DOMAIN_ACTION` | 비고 |
|---|---|---|---|
| account | `account` | `open` | 계좌 개설 mock |
| transfer | `transfer` | `transfer` | 이체 mock. notification 호출(Task 1.3) |
| loan | `loan` | `apply` | 대출 신청 mock |
| notification | `notification` | `send` | 알림 발송 mock |

## 로컬 실행

```bash
cd services/_template
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Postgres가 로컬에 떠 있어야 readiness 통과
export $(grep -v '^#' .env.example | xargs)
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

검증:

```bash
curl -s localhost:8000/health         # {"status":"ok",...}
curl -s localhost:8000/health/ready   # 200 if DB up, 503 otherwise
curl -s -X POST localhost:8000/process \
     -H 'content-type: application/json' \
     -d '{"payload":{"hello":"world"}}'
```

## 다음 단계

- Task 1.2: `services/{account,transfer,loan,notification}` 4개로 복제
- Task 1.5: `tests/` 디렉토리에 pytest 추가 (B1-M2 충족)
- Task 2.1: `Dockerfile` 추가 (멀티스테이지 + 비루트, B2-M1 충족)
