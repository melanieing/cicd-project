# 분산 트레이싱 샘플링 정책 (EPIC 7 Task 7.5)

본 문서는 R-A2-O1 의 샘플링 정책 결정 근거 + 본 프로젝트의 시연 흐름을 기록한다.

## 1. 샘플링이란

분산 트레이싱에서 "들어오는 모든 요청의 100%" 를 trace 로 수집하면 다음 비용이 발생한다:

- **저장 공간** — trace 1 건당 보통 1-5 KB. 초당 1000 req 면 시간당 3-18 GB
- **네트워크 대역폭** — 사이드카가 trace 를 collector 로 전송
- **collector / storage 처리량** — Jaeger collector 가 받아 storage 에 indexing
- **앱 영향** — header propagation 의 미세한 overhead (보통 무시 가능)

운영 환경에서 100% 는 거의 비현실적. 그래서 일부만 추출 (= sampling) 한다.

## 2. 샘플링 모델 두 가지

| 모델 | 결정 시점 | 장점 | 단점 |
|---|---|---|---|
| **Head-based** | 요청이 시작될 때 미리 (예: random 1%) | 단순. propagation header 가 결정값을 들고 다님 | 비정상 요청 (5xx) 을 미리 알 수 없어 놓침 |
| **Tail-based** | 요청 완료 후 결과 보고 (예: 5xx 만 100%, 200 은 1%) | 비정상만 정확히 잡음 | collector 가 모든 trace 를 일시 보관 → 메모리 부담 ↑ |

본 프로젝트는 **head-based random sampling** 만 사용 (Istio Telemetry API 의
`randomSamplingPercentage` 가 정확히 이 모델). tail-based 는 OpenTelemetry Collector 의
별도 processor 가 필요 → 복잡도 ↑, 별도 EPIC 후보.

## 3. 본 프로젝트의 시연 흐름 — 100% → 1%

### 3-1. 100% 단계 (시연 초반)

```yaml
spec:
  tracing:
    - providers: [{name: jaeger}]
      randomSamplingPercentage: 100.0
```

`observability/jaeger/istio-tracing.yaml` 의 설정. 의도:

- 모든 요청을 trace 로 수집
- P99 hotspot 분석 (Task 7.6) 의 입력 데이터
- 시연 부하 수준 (시간당 수백 요청) 에서는 메모리 부담 작음

### 3-2. 1% 단계 (운영용)

```yaml
spec:
  tracing:
    - providers: [{name: jaeger}]
      randomSamplingPercentage: 1.0
```

`observability/jaeger/sampling-1.yaml` 의 설정. 의도:

- 운영 환경 정석 (after stabilization)
- trace 부담 100 분의 1 로 감소
- 빈약한 trace 의 한계는 RED metrics (Rate / Errors / Duration, Prometheus 가 모두 제공) 가 보완

## 4. 왜 1% 인가 — 일반 가이드라인

| 샘플링율 | 용도 |
|---|---|
| **100%** | 디버깅 / 비정상 트래픽 추적 / 신규 서비스 첫 배포 |
| **10%**  | 신규 서비스 안정화 기간 (몇 주) |
| **1%**   | 일반 운영 — trace 부담과 sampling bias 의 균형 |
| **0.1%** | 매우 고부하 시스템 (Netflix, Google 등 초당 수만 req) |

본 프로젝트의 시연 부하는 1% 면 사실상 trace 가 안 잡힐 수 있는 수준이지만, "**운영 환경의 정석 정책을
적용했다**" 는 시연 가치가 본질. 실 운영의 부하 수준 (시간당 수만 req+) 에서는 1% 가 적절함을 docs 에서 인용.

## 5. Sampling bias 와 보완 메커니즘

1% 만 trace 로 수집하면:

- 정상 (200) 요청은 100 건 중 1 건만 보임 — 통계적으로 충분
- 비정상 (5xx) 요청은 자주 발생 안 하므로 1% 만 잡으면 1 건도 안 잡힐 가능성 — bias 위험

**보완 전략** (본 프로젝트가 의도적으로 다음 EPIC 으로 미루는 항목):

1. **Tail-based sampling** — 모든 trace 를 일시 수집 후 5xx / slow > P99 만 영구 보존.
   OpenTelemetry Collector 의 `tail_sampling_processor` 가 표준 도구.
2. **RED 메트릭 기반 알람** — Prometheus + Alertmanager 가 error rate / latency 를 watch 하다가
   threshold 초과 시 알람. 알람 시점에 일시적으로 샘플링율 상향 (자동화).
3. **요청 단위 강제 sampling** — header (`x-trace-sample: true`) 가 있는 요청은 100% sampling.
   개발자가 디버깅 시 명시적으로 trigger.

본 프로젝트는 1% 정도로 매듭짓고, 위 3 가지는 follow-up backlog 후보로 남김.

## 6. 적용 방식 — git PR 흐름

샘플링율 변경은 git 의 매니페스트 변경 → ArgoCD sync (또는 본 시연에서는 `kubectl apply` 직접):

```bash
# 100% 적용
kubectl apply -f observability/jaeger/istio-tracing.yaml

# ↓ Task 7.6 의 P99 분석 후 ↓

# 1% 로 전환
kubectl apply -f observability/jaeger/sampling-1.yaml
```

ArgoCD 가 본 디렉토리를 sync 하는 경우 (별도 Application 등록 필요), git PR 머지로 동일한 변경.

## 7. 검증

```bash
# 1000 회 트래픽 발생
for i in $(seq 1 10); do
  ./istio/canary/scripts/test-traffic-split.sh 100 >/dev/null 2>&1
done

# Jaeger UI 에서 trace 수 확인
kubectl -n observability port-forward svc/jaeger-query 16686:16686
# 브라우저 → http://localhost:16686 → service=transfer.payment-dev → Find Traces

# 100% 샘플링 시: 약 1000 건
# 1%  샘플링 시: 약 10 건 (±5 통계 편차)
```

## 8. 참고

- [OpenTelemetry sampling 가이드](https://opentelemetry.io/docs/concepts/sampling/)
- [Istio Telemetry API — tracing](https://istio.io/latest/docs/reference/config/telemetry/#Tracing)
- [Jaeger tail-based sampling 디자인](https://www.jaegertracing.io/docs/latest/sampling/) — 향후 작업 reference
