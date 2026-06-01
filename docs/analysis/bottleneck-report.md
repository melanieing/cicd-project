# P99 병목 분석 리포트 (EPIC 7 Task 7.6) [★ 포트폴리오 가산]

> **본 문서는 측정 템플릿이다.** 사용자가 EPIC 7.4 의 100% 샘플링 단계에서 Jaeger / Grafana 의
> 실측 데이터를 채워 완성한다. 빈 자리는 `<TBD>` 로 표시되어 있다.

본 리포트는 R-A2-O3 의 산출물로, 분산 트레이싱과 메트릭을 활용해 시스템의 P99 지연 hotspot 을
**정량적으로 식별** 하고, 그 hotspot 의 **원인을 가설로 분리** 한 뒤, **개선안 3 개를 제시 + 적용 후
재측정** 하는 SRE 식 분석 사이클을 그대로 따른다.

## 0. 분석 대상과 측정 환경

| 항목 | 값 |
|---|---|
| 측정 대상 서비스 | transfer (notification 호출 chain 의 시작점) |
| 측정 endpoint | `POST /transfer` |
| 부하 생성 도구 | `for i in $(seq 1 1000); do curl ...; done` 또는 `hey -n 1000 -c 10 ...` |
| 샘플링 정책 | 100% (`observability/jaeger/istio-tracing.yaml`) |
| 메트릭 source | Prometheus (kube-prometheus-stack), Jaeger (v2 All-In-One) |
| 측정 시점 | `<YYYY-MM-DD HH:MM KST>` |
| Cluster 사양 | kind 단일 호스트, K8s 1.33, 호스트 RAM 16 GiB, Intel i7-1165G7 |

## 1. 측정 — 기준선 (Baseline)

### 1-1. P50 / P95 / P99 latency

Prometheus 쿼리 (Grafana 의 Istio Service dashboard 에서 동등):

```promql
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{
    destination_service_name="transfer",
    destination_service_namespace="payment-dev"
  }[5m])) by (le)
)
```

| Quantile | 측정값 (ms) | 캡처 |
|---|---|---|
| P50 | `<TBD>` | `docs/screenshots/grafana-transfer-latency-baseline.png` |
| P95 | `<TBD>` | (동일) |
| P99 | `<TBD>` | (동일) |

### 1-2. 가장 느린 trace 1-3 건의 waterfall

Jaeger UI 의 trace 목록에서 latency 내림차순 정렬 → 상위 3 건 캡처.

| trace ID | 총 시간 (ms) | 가장 큰 span | 캡처 |
|---|---|---|---|
| `<id-1>` | `<TBD>` | `<service.operation>` | `docs/screenshots/jaeger-slow-trace-1.png` |
| `<id-2>` | `<TBD>` | `<service.operation>` | (동일) |
| `<id-3>` | `<TBD>` | `<service.operation>` | (동일) |

### 1-3. RED 메트릭 baseline

| 메트릭 | 값 |
|---|---|
| Request rate (req/s) | `<TBD>` |
| Error rate (5xx %) | `<TBD>` |
| Saturation (사이드카 CPU %) | `<TBD>` (Grafana Workload dashboard) |

## 2. Hotspot 식별 — 어디서 시간을 잡아먹는가

1-2 의 waterfall 분석:

| Span | 평균 시간 (ms) | P99 의 % 점유 | 가설 |
|---|---|---|---|
| `transfer.inbound (/transfer)` | `<TBD>` | `<TBD>%` | uvicorn 자체 처리 |
| `transfer.outbound (notification)` | `<TBD>` | `<TBD>%` | httpx 의 connection pool 초기화 또는 사이드카 routing |
| `notification.inbound (/send)` | `<TBD>` | `<TBD>%` | notification 의 처리 |
| `transfer.db_query` | `<TBD>` | `<TBD>%` | asyncpg ↔ postgres |
| (기타) | `<TBD>` | `<TBD>%` | |

→ **가장 큰 span 은 `<TBD>` 이고 P99 의 약 `<TBD>%` 를 차지** — 본 보고서의 hotspot.

## 3. 가설 3 개와 각각의 검증 방법

### 가설 A — `<예: notification 호출의 cold connection>`

- 의심 근거: `<TBD — 예: 첫 호출이 후속 호출보다 5 배 느림 (httpx connection 초기화)>`
- 검증 명령: `<TBD — 예: 1000 회 연속 호출 후 시간 분포 비교>`
- 검증 결과: `<TBD>`

### 가설 B — `<예: postgres connection pool 부족>`

- 의심 근거: `<TBD>`
- 검증 명령: `<TBD>`
- 검증 결과: `<TBD>`

### 가설 C — `<예: Envoy 사이드카의 mTLS handshake overhead>`

- 의심 근거: `<TBD>`
- 검증 명령: `<TBD>`
- 검증 결과: `<TBD>`

## 4. 개선안 3 개와 적용 후 재측정

각 개선안의 코드 변경 → 재배포 → 같은 부하 → 같은 metric 측정.

### 개선안 1 — `<예: httpx AsyncClient 를 lifespan 의 startup 직후 한 번 warm-up>`

| 항목 | 값 |
|---|---|
| 변경 파일 | `<TBD — 예: services/transfer/main.py 의 lifespan>` |
| 변경 commit | `<sha>` |
| 적용 전 P99 | `<TBD ms>` |
| 적용 후 P99 | `<TBD ms>` |
| **개선폭** | `<TBD %>` |
| 캡처 | `docs/screenshots/grafana-transfer-p99-after-fix-1.png` |

### 개선안 2 — `<예: postgres pool min=5 (default 1) 로 증가>`

| 항목 | 값 |
|---|---|
| 변경 파일 | `<TBD — charts/.../values.yaml 의 global.env.DB_POOL_MIN>` |
| 변경 commit | `<sha>` |
| 적용 전 P99 | `<TBD>` |
| 적용 후 P99 | `<TBD>` |
| **개선폭** | `<TBD %>` |
| 캡처 | (동일) |

### 개선안 3 — `<예: Istio DestinationRule 의 connectionPool.http.maxRequestsPerConnection 상향>`

| 항목 | 값 |
|---|---|
| 변경 파일 | `<TBD — istio/.../destinationrule.yaml>` |
| 변경 commit | `<sha>` |
| 적용 전 P99 | `<TBD>` |
| 적용 후 P99 | `<TBD>` |
| **개선폭** | `<TBD %>` |

## 5. 종합 — Before / After

| 메트릭 | Baseline | After 1+2+3 | 개선폭 |
|---|---|---|---|
| P50 (ms) | `<TBD>` | `<TBD>` | `<TBD %>` |
| P95 (ms) | `<TBD>` | `<TBD>` | `<TBD %>` |
| **P99 (ms)** | **`<TBD>`** | **`<TBD>`** | **`<TBD %>`** |
| Error rate | `<TBD>` | `<TBD>` | - |
| 사이드카 CPU | `<TBD>` | `<TBD>` | - |

## 6. 학습된 교훈 (Lessons learned)

- `<TBD — 예: P99 의 hotspot 은 평균에서는 안 보임. histogram quantile 쿼리가 필수.>`
- `<TBD — 예: httpx 의 connection pool 은 처음 사용 시 cold start 가 큼. lifespan 의 warm-up 한 줄이 1 자릿수 ms → 한 자릿수 µs.>`
- `<TBD — 예: 인프라 변경 (connectionPool) 보다 애플리케이션 변경 (warm-up) 의 개선폭이 큰 경우가 일반적.>`

## 7. 후속 작업 backlog 후보

- Tail-based sampling 도입 (5xx + slow > P99 만 100% sample)
- Continuous profiling (parca / pyroscope) 으로 코드 레벨 hotspot 까지
- SLO 정의 + Burn rate alert (Sloth / Pyrra)

## 8. 측정 명령 reference

```bash
# 부하 생성 (1000 req, 동시성 10)
hey -n 1000 -c 10 -m POST -H "Content-Type: application/json" \
  -d '{"payload":{"from":"a1","to":"a2","amount":1000}}' \
  http://transfer.payment-dev.svc.cluster.local:8000/transfer

# 또는 임시 pod 안에서
kubectl -n payment-dev run loadgen --rm -i --restart=Never \
  --image=williamyeh/hey:latest -- \
  -n 1000 -c 10 -m POST \
  -H "Content-Type: application/json" \
  -d '{"payload":{"from":"a1","to":"a2","amount":1000}}' \
  http://transfer:8000/transfer

# Prometheus 에서 P99 직접 조회
kubectl -n observability port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
# 브라우저 → http://localhost:9090/graph
# 위의 § 1-1 쿼리 입력
```
