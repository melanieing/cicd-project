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

## 단위 테스트 (Task 1.5 검증)

pytest 는 DB 없이도 통과 (lifespan 이 DATABASE_URL="" 분기로 스킵):

```bash
cd services/account
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
./.venv/bin/pytest
# 2 passed
```

> 다중 서비스 일괄 실행은 [`scripts/test-all.sh`](../../scripts/test-all.sh) 참조.

## 로컬 실행 (e2e)

uvicorn 으로 실제 서비스를 띄우면 **postgres 연결이 필요**하다. kind 의 postgres 를 host 로 노출:

```bash
# Terminal 0 — 별도 터미널에서 실행 중 유지
kubectl -n payment-dev port-forward svc/postgres 5432:5432
```

그 다음:

```bash
cd services/account
export $(grep -v '^#' .env.example | xargs)
./.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8001 --reload
```

> 4개 서비스를 동시에 띄울 경우 포트 충돌을 피하려고 account=8001, transfer=8002, notification=8003, loan=8004 으로 분리 추천 (K8s 에서는 각자 Service 로 분리되어 충돌 없음).

검증:

```bash
curl -s localhost:8001/health
curl -s localhost:8001/health/ready
curl -s -X POST localhost:8001/open \
     -H 'content-type: application/json' \
     -d '{"payload":{"customer_id":"c-1","initial_deposit":10000}}'
```

> port-forward 없이 빠르게 `/health` 만 보려면 `unset DATABASE_URL` 후 uvicorn 실행.
> 관련 함정 기록: [`docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md`](../../docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md)
