# loan service

핀테크 결제 플랫폼의 **대출(loan)** 서비스. 대출 신청을 mock으로 처리한다.

코드 본체는 `services/_template/` 의 복사본이며, 차이는 환경변수뿐이다.
공통 사용법·문법 설명·로컬 실행 절차는 [`services/_template/README.md`](../_template/README.md) 참조.

## 엔드포인트

| Method | Path | 용도 |
|---|---|---|
| GET  | `/health`       | Liveness probe |
| GET  | `/health/ready` | Readiness probe |
| POST | `/apply`        | 대출 신청 mock (요청 echo) |

요구사항 매핑: **B3-M2**

## 환경변수

| 변수 | 값 | 의미 |
|---|---|---|
| `SERVICE_NAME` | `loan` | 식별자 |
| `DOMAIN_ACTION` | `apply` | POST /apply 라우트 |
| `DATABASE_URL` | `...loan_db` | 분리된 DB |

## 로컬 실행

```bash
cd services/loan
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export $(grep -v '^#' .env.example | xargs)
uvicorn main:app --host 0.0.0.0 --port 8004 --reload
```

검증:

```bash
curl -s localhost:8004/health
curl -s -X POST localhost:8004/apply \
     -H 'content-type: application/json' \
     -d '{"payload":{"customer_id":"c-1","amount":1000000,"term_months":24}}'
```
