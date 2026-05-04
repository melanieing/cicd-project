# transfer service

핀테크 결제 플랫폼의 **이체(transfer)** 서비스. 이체 요청을 mock으로 처리하고,
처리 후 **알림(notification) 서비스의 `/send`를 호출**하여 mesh 토폴로지에서 의미 있는
의존성 엣지를 만든다 (Task 1.3 적용 완료).

코드 본체는 `services/_template/` 의 복사본에서 출발했으나, **`main.py` 가
notification 호출 로직과 함께 분기**되어 있다.
공통 사용법·문법 설명·로컬 실행 절차는 [`services/_template/README.md`](../_template/README.md) 참조.

## 엔드포인트

| Method | Path | 용도 |
|---|---|---|
| GET  | `/health`       | Liveness probe |
| GET  | `/health/ready` | Readiness probe |
| POST | `/transfer`     | 이체 mock + notification `/send` 호출 |

요구사항 매핑: **B3-M2**, **A1-M3** (Canary 라우팅 적용 대상), **A2-M1** (Kiali 토폴로지 핵심 노드)

## 동작 흐름

```
Client ──POST /transfer──▶ transfer
                              │
                              ├─ (mock) 이체 처리
                              │
                              └─ POST {NOTIFICATION_URL}/send ──▶ notification
                                                                       │
                              ◀── notification 메타데이터 포함 응답 ◀──
```

### graceful degrade
notification 호출이 **실패하거나 타임아웃**되어도 transfer 자체는 `200 OK` 로 응답한다.
응답의 `notification.status` 필드로 다음 3가지를 구분할 수 있다:

| `notification.status` | 의미 |
|---|---|
| `delivered` | 정상 호출 성공 (응답 본문은 `notification.response`) |
| `failed` | 호출 실패 (사유는 `notification.error`) |
| `skipped` | `NOTIFICATION_URL` 미설정으로 호출 안 함 |

이 설계는 EPIC 8의 **outlierDetection / Circuit Breaker** 시연에서
"비핵심 의존성만 자동 격리되고 메인 비즈니스 흐름은 끊기지 않음" 을 보이기 위함이다.

## 환경변수

| 변수 | 값 | 의미 |
|---|---|---|
| `SERVICE_NAME` | `transfer` | 식별자 |
| `DOMAIN_ACTION` | `transfer` | POST /transfer 라우트 |
| `DATABASE_URL` | `...transfer_db` | 분리된 DB |
| `NOTIFICATION_URL` | `http://...:8003` | 호출 대상 base URL |
| `NOTIFICATION_TIMEOUT` | `2.0` | 호출 타임아웃(초). 기본 2초 |

## 단위 테스트 (Task 1.5 검증)

pytest 는 DATABASE_URL="" / NOTIFICATION_URL="" 로 graceful skip 분기까지 검증.
postgres·notification 어느 쪽도 없어도 통과:

```bash
cd services/transfer
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
./.venv/bin/pytest
# 2 passed (test_health_returns_ok, test_transfer_action_skips_notification_when_url_unset)
```

> 다중 서비스 일괄 실행은 [`scripts/test-all.sh`](../../scripts/test-all.sh) 참조.

## 로컬 실행 (e2e)

3개 터미널 필요. postgres port-forward + notification + transfer.

```bash
# Terminal 0 — postgres port-forward (4 서비스 공통, 실행 중 유지)
kubectl -n payment-dev port-forward svc/postgres 5432:5432
```

```bash
# Terminal 1 — notification (포트 8003)
cd services/notification
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
export $(grep -v '^#' .env.example | xargs)
./.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8003 --reload
```

```bash
# Terminal 2 — transfer (포트 8002)
cd services/transfer
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
export $(grep -v '^#' .env.example | xargs)
./.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8002 --reload
```

> port-forward 없이 빠르게 보려면 두 터미널 모두 `unset DATABASE_URL` 후 실행.
> 관련 함정 기록: [`docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md`](../../docs/troubleshooting/2026-05-04-uvicorn-cannot-reach-localhost-postgres.md)

## 검증

```bash
# health
curl -s localhost:8002/health

# 정상 호출 (notification 떠 있을 때)
curl -s -X POST localhost:8002/transfer \
     -H 'content-type: application/json' \
     -d '{"payload":{"from":"a-1","to":"a-2","amount":5000}}' | jq

# 예상 응답:
# {
#   "service":"transfer", "action":"transfer", "status":"accepted",
#   "received":{"from":"a-1","to":"a-2","amount":5000},
#   "notification":{
#     "status":"delivered","http_status":200,
#     "response":{"service":"notification","action":"send","status":"accepted",...}
#   }
# }

# notification 다운 시뮬레이션 (Terminal 1 의 uvicorn Ctrl+C)
# transfer 응답은 여전히 200, 다만 notification.status=="failed"
```

## Canary 시연 (A1-M3, EPIC 6)

본 서비스는 Istio Canary 라우팅의 시연 대상이다.
`transfer:v1` / `transfer:v2` 두 버전 이미지를 빌드하여 `VirtualService` 로
20% → 50% → 100% 단계적 트래픽 전환을 보여준다.
