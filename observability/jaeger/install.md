# Jaeger v2 + Istio 분산 트레이싱 설치 가이드 (EPIC 7 Task 7.4 + 7.5)

본 가이드는 Jaeger v2 (All-In-One, OpenTelemetry Collector 기반) 를 설치하고 Istio 사이드카가
생성하는 trace span 을 OTLP 로 Jaeger 에 보내도록 mesh 를 설정한다.

## 0. 사전 조건

| 항목 | 확인 |
|---|---|
| EPIC 7.1 의 Prometheus 설치 완료 | `kubectl -n observability get pod -l app.kubernetes.io/name=prometheus` |
| Istio 1.29.2 + 사이드카 정상 | `istioctl proxy-status` 6 행 SYNCED |
| 호스트 가용 메모리 | 추가 **600 MiB** (Jaeger All-In-One ~500 MiB + 헤드룸) |

## 1. Jaeger Helm chart 설치

```bash
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update

# (선택) 최신 chart 버전 확인
helm search repo jaegertracing/jaeger | head -3
# 본 가이드는 4.2.0 기준 (Jaeger v2 지원)

helm upgrade --install jaeger jaegertracing/jaeger \
  --version 4.2.0 \
  --namespace observability \
  -f observability/jaeger/values.yaml \
  --wait --timeout 5m
```

기대 종료:

```
NAME: jaeger
LAST DEPLOYED: ...
NAMESPACE: observability
STATUS: deployed
```

## 2. Istio MeshConfig 에 Jaeger OTLP endpoint 등록

Istio 가 trace 를 어디로 보낼지 알아야 한다. Telemetry CRD 가 `providers[].name: jaeger` 를 가리키므로,
MeshConfig 의 `extensionProviders` 에 같은 이름으로 등록.

```bash
istioctl install --skip-confirmation \
  --set profile=default \
  --set values.pilot.autoscaleEnabled=false \
  --set values.pilot.replicaCount=1 \
  --set values.gateways.istio-ingressgateway.autoscaleEnabled=false \
  --set values.gateways.istio-ingressgateway.replicaCount=1 \
  --set 'meshConfig.extensionProviders[0].name=jaeger' \
  --set 'meshConfig.extensionProviders[0].opentelemetry.port=4317' \
  --set 'meshConfig.extensionProviders[0].opentelemetry.service=jaeger-collector.observability.svc.cluster.local'
```

기대 종료 — `Istio core installed / Istiod installed / Ingress gateways installed / Installation complete`.

### 주의: `istioctl install` 재실행은 멱등

옛 install 설정에 새 `extensionProviders` 만 추가되는 형태로 적용. CRD / 사이드카에는 영향 없음
(operator pattern 의 멱등성).

### 검증

```bash
kubectl -n istio-system get configmap istio -o jsonpath='{.data.mesh}' | grep -A 3 extensionProviders
```

기대:

```
extensionProviders:
- name: jaeger
  opentelemetry:
    service: jaeger-collector.observability.svc.cluster.local
    port: 4317
```

## 3. Telemetry 리소스로 payment-dev 의 트레이싱 활성화 (100% 샘플링 — 시연 1 단계)

```bash
kubectl apply -f observability/jaeger/istio-tracing.yaml
```

기대:

```
telemetry.telemetry.istio.io/default created
```

### 검증 — trace 가 실제로 Jaeger 까지 도달하는지

```bash
# 트래픽 생성
./istio/canary/scripts/test-traffic-split.sh 50

# Jaeger UI 접근
kubectl -n observability port-forward svc/jaeger-query 16686:16686
```

브라우저 → `http://localhost:16686` → 좌측 **Service** 드롭다운에서 `transfer.payment-dev` 선택 →
**Find Traces** 클릭.

기대: 최근 5 분 안의 trace 목록이 보임. 각 trace 를 클릭하면:

- `transfer` 의 inbound span → `transfer` 의 outbound span (notification 호출) → `notification` 의 inbound span
- 총 4-5 개 span 의 waterfall 그래프

이 그래프가 **transfer → notification 의 분산 호출 chain** 을 시각적으로 보여줌. 본 시연이 EPIC 7 의
가장 인상적인 항목 중 하나.

## 4. Task 7.5 — 100% → 1% 샘플링 전환

### 4-1. 100% 샘플링 상태에서 P99 hotspot 캡처

`docs/analysis/bottleneck-report.md` (Task 7.6) 에 측정값 기록. 캡처:

- Jaeger UI 의 trace 목록 — 가장 긴 trace 1-2 개의 waterfall (`docs/screenshots/jaeger-p99-trace.png`)
- 같은 trace 의 timeline 에서 어느 span 이 시간을 잡아먹는지 (P99 hotspot)

### 4-2. 운영용 1% 샘플링으로 변경

```bash
kubectl apply -f observability/jaeger/sampling-1.yaml
```

본 매니페스트는 같은 `Telemetry/default` 객체를 갱신 — `randomSamplingPercentage: 100.0 → 1.0`.

### 검증

```bash
# 트래픽 생성 (1000 회)
for i in $(seq 1 10); do
  ./istio/canary/scripts/test-traffic-split.sh 100 >/dev/null 2>&1
done

# Jaeger UI 의 trace 목록 — 약 10 건만 보여야 함 (1000 * 0.01 = 10)
```

대략 10 ± 5 건이면 1% 샘플링 정상 동작.

## 5. 정리

| 산출물 | 위치 |
|---|---|
| Jaeger Helm values | `observability/jaeger/values.yaml` |
| Istio Telemetry (100% — 시연용) | `observability/jaeger/istio-tracing.yaml` |
| Istio Telemetry (1% — 운영용) | `observability/jaeger/sampling-1.yaml` |
| 설치 가이드 | 본 파일 |
| 샘플링 정책 문서 | `docs/tracing-sampling.md` |
| 병목 분석 리포트 | `docs/analysis/bottleneck-report.md` (Task 7.6, 사용자 측정값 채움) |

## 6. 흔한 오류와 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| Jaeger UI 의 Service 드롭다운이 비어있음 | Telemetry 적용 전 또는 사이드카가 새 설정 미수신 | § 3 의 트래픽 생성 후 30 초 대기. `istioctl proxy-status` 가 SYNCED 여부 확인 |
| trace 가 4-5 span 이 아니라 1-2 span 만 보임 | transfer 의 httpx client 가 trace context 를 propagate 안 함 | services/transfer/main.py 의 httpx call 에 OpenTelemetry instrumentation 추가 필요 (별도 task — 본 시연 범위 밖) |
| Jaeger pod 가 OOMKilled | All-In-One 의 in-memory storage 가 trace 누적으로 메모리 한계 도달 | values.yaml 의 `MEMORY_MAX_TRACES` 를 50000 등으로 낮춤. 또는 resources.limits.memory 상향 |
| `istioctl install` 재실행 후 cluster 의 다른 매니페스트가 reset | 새 args 와 기존 설정의 conflict | `istioctl install` 은 멱등이지만 안전을 위해 `kubectl get istiooperator -n istio-system -o yaml` 로 install 전후 비교 |

## 7. 다음 단계

- **Task 7.5 의 샘플링 정책 문서** — `docs/tracing-sampling.md` 작성 (본 가이드의 § 4 의 근거를 별도 문서로)
- **Task 7.6** — Jaeger 의 100% trace 데이터를 바탕으로 P99 병목 분석 리포트 작성

## 8. 참고

- [Jaeger v2 release notes](https://www.jaegertracing.io/docs/2.10/)
- [Istio Telemetry API docs](https://istio.io/latest/docs/reference/config/telemetry/)
- [Istio Distributed Tracing 가이드](https://istio.io/latest/docs/tasks/observability/distributed-tracing/jaeger/)
