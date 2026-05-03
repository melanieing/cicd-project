# transfer service

핀테크 결제 플랫폼의 **이체(transfer)** 서비스. 이체 요청을 mock으로 처리하고,
이후 알림(notification) 서비스를 호출하여 mesh 토폴로지에서 의미 있는 트래픽을 만든다.

코드 본체는 `services/_template/` 의 복사본이다. 단, **Task 1.3 에서 notification 호출 로직이
추가로 주입**될 예정 (현재는 템플릿 그대로).
공통 사용법·문법 설명·로컬 실행 절차는 [`services/_template/README.md`](../_template/README.md) 참조.

## 엔드포인트

| Method | Path | 용도 |
|---|---|---|
| GET  | `/health`       | Liveness probe |
| GET  | `/health/ready` | Readiness probe |
| POST | `/transfer`     | 이체 mock + (Task 1.3 이후) notification 호출 |

요구사항 매핑: **B3-M2**, **A1-M3** (Canary 라우팅 적용 대상), **A2-M1** (Kiali 토폴로지 핵심 노드)

## 환경변수

| 변수 | 값 | 의미 |
|---|---|---|
| `SERVICE_NAME` | `transfer` | 식별자 |
| `DOMAIN_ACTION` | `transfer` | POST /transfer 라우트 |
| `DATABASE_URL` | `...transfer_db` | 분리된 DB |
| `NOTIFICATION_URL` | `http://...:8003` | 호출 대상 (Task 1.3에서 사용) |

## 로컬 실행

```bash
cd services/transfer
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export $(grep -v '^#' .env.example | xargs)
uvicorn main:app --host 0.0.0.0 --port 8002 --reload
```

검증:

```bash
curl -s localhost:8002/health
curl -s -X POST localhost:8002/transfer \
     -H 'content-type: application/json' \
     -d '{"payload":{"from":"a-1","to":"a-2","amount":5000}}'
```

## Canary 시연 (A1-M3)

본 서비스는 Istio Canary 라우팅의 시연 대상이다.
EPIC 6 단계에서 `transfer:v1` / `transfer:v2` 두 버전 이미지를 빌드하여
`VirtualService`로 20% → 50% → 100% 단계적 트래픽 전환을 보여준다.
