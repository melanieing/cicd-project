# notification service

핀테크 결제 플랫폼의 **알림(notification)** 서비스. 알림 발송을 mock으로 처리한다.
이체(transfer) 서비스가 Task 1.3 이후 본 서비스를 호출하여 mesh 트래픽 의존성을 형성한다.

코드 본체는 `services/_template/` 의 복사본이며, 차이는 환경변수뿐이다.
공통 사용법·문법 설명·로컬 실행 절차는 [`services/_template/README.md`](../_template/README.md) 참조.

## 엔드포인트

| Method | Path | 용도 |
|---|---|---|
| GET  | `/health`       | Liveness probe |
| GET  | `/health/ready` | Readiness probe |
| POST | `/send`         | 알림 발송 mock (요청 echo) |

요구사항 매핑: **B3-M2**, **A2-M1** (Kiali 토폴로지에서 transfer ← notification 호출 관계 시각화)

## 환경변수

| 변수 | 값 | 의미 |
|---|---|---|
| `SERVICE_NAME` | `notification` | 식별자 |
| `DOMAIN_ACTION` | `send` | POST /send 라우트 |
| `DATABASE_URL` | `...notification_db` | 분리된 DB |

## 단위 테스트 (Task 1.5 검증)

pytest 는 DB 없이도 통과:

```bash
cd services/notification
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pytest
# 2 passed
```

## 로컬 실행 (e2e)

postgres port-forward 가 먼저 필요:

```bash
# Terminal 0
kubectl -n payment-dev port-forward svc/postgres 5432:5432
```

```bash
cd services/notification
source .venv/bin/activate
export $(grep -v '^#' .env.example | xargs)
uvicorn main:app --host 0.0.0.0 --port 8003 --reload
```

> 포트 8003: transfer 서비스의 `NOTIFICATION_URL` 기본값과 일치.

검증:

```bash
curl -s localhost:8003/health
curl -s -X POST localhost:8003/send \
     -H 'content-type: application/json' \
     -d '{"payload":{"channel":"email","to":"u@example.com","body":"transfer-completed"}}'
```

> port-forward 없이 빠르게 `/health` 만 보려면 `unset DATABASE_URL` 후 uvicorn 실행.
> 관련 함정 기록: [`docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md`](../../docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md)
