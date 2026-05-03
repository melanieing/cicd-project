# account service

핀테크 결제 플랫폼의 **계좌(account)** 서비스. 계좌 개설을 mock으로 처리한다.

코드 본체는 `services/_template/` 의 복사본이며, 차이는 환경변수뿐이다.
공통 사용법·문법 설명·로컬 실행 절차는 [`services/_template/README.md`](../_template/README.md) 참조.

## 엔드포인트

| Method | Path | 용도 |
|---|---|---|
| GET  | `/health`       | Liveness probe (프로세스 생존) |
| GET  | `/health/ready` | Readiness probe (DB 연결 확인) |
| POST | `/open`         | 계좌 개설 mock (요청 echo) |

요구사항 매핑: **B3-M2** (Readiness/Liveness Probe)

## 환경변수

전체 목록은 [`.env.example`](./.env.example) 참조. 차별 포인트만 적시:

| 변수 | 값 | 의미 |
|---|---|---|
| `SERVICE_NAME` | `account` | 로그/응답에 표기 |
| `DOMAIN_ACTION` | `open` | POST /open 라우트 등록 |
| `DATABASE_URL` | `...account_db` | 서비스별 분리된 DB |

## 로컬 실행

```bash
cd services/account
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export $(grep -v '^#' .env.example | xargs)
uvicorn main:app --host 0.0.0.0 --port 8001 --reload
```

> 4개 서비스를 동시에 띄울 경우 포트 충돌을 피하려고 account=8001, transfer=8002, loan=8004, notification=8003 으로 분리 추천 (K8s에서는 각자 Service로 분리되어 충돌 없음).

검증:

```bash
curl -s localhost:8001/health
curl -s localhost:8001/health/ready
curl -s -X POST localhost:8001/open \
     -H 'content-type: application/json' \
     -d '{"payload":{"customer_id":"c-1","initial_deposit":10000}}'
```
