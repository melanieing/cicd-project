# ADR 0003 — 서비스 메시: Istio 채택 (Linkerd 미채택)

- **Status**: Accepted
- **Date**: 2026-05-05
- **Deciders**: 본 프로젝트 단독 운영자 (DevOps 포트폴리오 시연 목적)
- **Related Requirements**: R-A1-M1, R-A1-M2, R-A1-M3, R-A1-O1, R-A1-O2, R-A2-M1, R-A2-M2, R-A2-M3, R-A2-O1, R-A2-O2, R-A2-O3
- **Related Backlog**: 6.1 ~ 6.8 (EPIC 6), 7.1 ~ 7.6 (EPIC 7)

## 1. Context — 어떤 결정을 내려야 하는가

본 프로젝트는 4 개 마이크로서비스 (`account` / `transfer` / `loan` / `notification`) 가 PostgreSQL 한 개를
공유하는 쿠버네티스 기반 결제 플랫폼이다. 이미 EPIC 4 에서 Helm 으로 묶이고 EPIC 5 에서 ArgoCD GitOps
사이클이 구축됐다. 이제 EPIC 6 에서 다음 운영 요구사항을 구현해야 한다.

| 요구사항 | 의미 |
|---|---|
| **R-A1-M3** | `transfer` 서비스에 Canary 배포 (트래픽 20% → 50% → 100% 단계적 증가) |
| **R-A1-O1** | 서비스 간 통신을 mTLS STRICT 모드로 강제 |
| **R-A1-O2** | 블루-그린 배포 패턴 + 관측성 강화 |
| **R-A2-M2** | Envoy 사이드카에서 Prometheus 메트릭 수집 → Grafana 대시보드 |
| **R-A2-M3** | DestinationRule 의 connectionPool 설정으로 회로 차단 (Circuit Breaker) |
| **R-A2-O1** | 분산 트레이싱 (Jaeger 등) + 샘플링 전략 |
| **R-A2-O2** | outlierDetection (5xx 응답 5회 / 30초) 기반 자동 격리 |

위 요구사항은 모두 **애플리케이션 코드 변경 없이 인프라 레벨에서 처리** 해야 한다는 공통점이 있다.
이를 가능하게 하는 표준 패턴이 "서비스 메시 (Service Mesh)" 이며, 후보는 **Istio** 와 **Linkerd**
두 가지가 사실상의 양강이다.

본 ADR 은 둘 중 하나를 선택하는 결정이다.

## 2. Decision — Istio 1.29.2 채택

쿠버네티스 1.33 위에 **Istio 1.29.2** (2026년 4월 13일 릴리스, 본 ADR 작성일 2026-05-05 기준 최신 stable)
를 설치한다. 사이드카 모드 (`istio-injection=enabled` 라벨 기반 자동 주입) 를 기본으로 사용하고,
`payment-dev` / `payment-prod` 두 namespace 에 사이드카를 자동 주입한다.

설치 프로파일은 메모리 절약을 위해 **`default` 프로파일** (istiod + ingress gateway 만 포함, egress
gateway 와 부가 컴포넌트 제외) 을 사용한다. 호스트 RAM 16GB 제약 (CLAUDE.md B-2) 을 고려해
Kiali / Prometheus / Grafana / Jaeger 는 EPIC 7 진입 시점에 단계적으로 추가한다.

## 3. Rationale — 왜 Istio 인가 (의사결정의 근거)

### 3.1 결정적 근거: Linkerd 의 라이선스 모델 변화

2024년 2월부터 **Linkerd 오픈소스 프로젝트는 "stable" 릴리스 산출물 생성을 중단** 했다.
2.15 버전 이후 오픈소스 코드베이스는 매주 발행되는 "edge" 빌드만 제공하며, 진짜 stable
릴리스 (분기마다, 보안 패치 백포팅 포함) 를 받으려면 상용 제품인 **Buoyant Enterprise for
Linkerd** 를 유료로 구독해야 한다.

본 프로젝트는 다음 두 제약이 있다.

- **CLAUDE.md A-2**: 추천 도구는 "2026년 현재 다수 기업이 실사용 중인 안정 버전" 이어야 한다.
  baby-edge 빌드는 stable 의 정의에 부합하지 않는다.
- **CLAUDE.md B-1**: 본 프로젝트는 $0 비용으로 운영되는 채용 포트폴리오. 유료 상용 제품 의존은
  채용 담당자가 재현하기 어려워 시연 가치를 낮춘다.

→ Linkerd 를 무료로 쓰면 edge 만 가능 → 운영 환경 전제와 맞지 않음 → **선택지에서 사실상 탈락.**

Istio 는 같은 시점에도 오픈소스 프로젝트가 분기 단위 stable 패치 (1.29.0 / 1.29.1 / 1.29.2 등)
를 무상 발행한다. 라이선스 동기 부담이 없다.

### 3.2 채용 포트폴리오 관점의 노출도

DevOps 직무 채용 공고와 면접에서 "서비스 메시 경험" 항목에 가장 많이 등장하는 도구는 Istio 이다.
이는 다음 사실로 뒷받침된다.

- AWS App Mesh 가 2024년 사실상 deprecated 되면서, AWS EKS 의 메시 가이드도 Istio 로 이동.
- Azure AKS 의 매니지드 메시 애드온은 Istio 기반.
- Google GKE 의 Anthos Service Mesh 도 Istio 기반.
- CNCF 졸업 (graduated) 프로젝트 — 2023년 7월 졸업.

즉 채용 담당자가 본 프로젝트의 메시 산출물을 봤을 때 **"우리 회사 환경에서도 곧장 활용 가능"** 하다고
해석할 가능성이 가장 높은 도구가 Istio 이다.

### 3.3 본 프로젝트의 요구사항 용어가 Istio 의 CRD 용어와 일치

본 프로젝트의 요구사항 (`docs/requirements.md`) 은 **VirtualService**, **DestinationRule**,
**connectionPool** 같은 Istio 고유 CRD 이름으로 작성되어 있다. Linkerd 로 가면 동일 개념을
ServiceProfile + TrafficSplit (Linkerd 의 SMI 기반 모델) 로 다시 매핑해야 하는데, 이는
요구사항 문서와 산출물의 1:1 추적 (traceability) 을 흐리게 만든다.

| 요구 개념 | Istio CRD | Linkerd 등가 |
|---|---|---|
| 트래픽 가중치 (Canary) | VirtualService.http[].route[].weight | TrafficSplit (deprecated 예정) |
| 회로 차단 | DestinationRule.trafficPolicy.connectionPool | 자동 (수동 설정 불가) |
| outlier detection | DestinationRule.trafficPolicy.outlierDetection | 자동 (수동 설정 불가) |
| mTLS 강제 | PeerAuthentication.mtls.mode=STRICT | 자동 (default 가 mTLS) |
| 토폴로지 시각화 | Kiali | Linkerd Viz (별도) |

Linkerd 는 "convention over configuration" 철학으로 회로 차단·outlier·mTLS 같은 항목을 자동 처리하므로
**조작 가능 표면적 (knobs) 이 더 작다**. 학습·시연 관점에서 본 프로젝트는 그 knob 들을 직접
조정·검증하는 것이 핵심 가치이므로 Istio 의 명시적 CRD 모델이 더 적합하다.

### 3.4 자원 사용량은 16GB RAM 안에서 감당 가능

Istio 가 전통적으로 "무겁다" 는 평을 받지만, 1.29 기준 `default` 프로파일의 메모리 사용량은 다음과 같다.

| 컴포넌트 | 메모리 (idle) | 비고 |
|---|---|---|
| istiod (control plane) | 약 200 MiB | replica 1 (kind 단일 노드) |
| istio-ingressgateway | 약 100 MiB | replica 1 |
| 사이드카 (서비스당 1개) | 약 50-80 MiB | 4 service × 2 환경 = 최대 8 사이드카 ≈ 480 MiB |
| **소계** | **약 800-900 MiB** | |

호스트 RAM 16 GB 중 K8s + 4 서비스 + Postgres + ArgoCD 가 약 4-5 GB 사용 중이므로, Istio 추가는
부담스럽지만 가능. EPIC 7 의 Prometheus + Grafana + Kiali + Jaeger 동시 기동 시점에만 주의하면 된다
(이 부분은 EPIC 7 의 install 가이드에서 단계적 기동 순서로 다룬다).

## 4. Consequences — 결정의 결과

### 4.1 긍정적 결과

1. **EPIC 6 의 모든 요구사항을 코드 변경 없이 인프라 레벨에서 구현 가능.** transfer 서비스의 Canary
   배포는 Deployment 두 개 + VirtualService 한 개의 weight 필드 조정으로 끝남. 애플리케이션은
   "무엇이 카나리이고 무엇이 안정 버전인지" 모를 수 있다.
2. **EPIC 7 의 관측성 산출물이 자연스럽게 따라온다.** Envoy 사이드카가 Prometheus 형식으로 메트릭을
   기본 노출하므로 Grafana 대시보드는 표준 dashboard ID (예: 7630) 를 import 만 하면 된다. Kiali 는
   istiod 와 직접 통신하므로 별도 설정 없이 토폴로지 화면이 그려진다.
3. **채용 시 면접 질문 (예: "Canary 배포는 어떻게 운영했나요?") 에 대한 답이 표준 용어로 간결.**
   "Istio VirtualService 의 weight 를 ArgoCD 매니페스트에서 PR 로 갱신했고, 5 분 단위로 20%→50%→100%
   증가시켰습니다" 같은 답이 가능.

### 4.2 부정적 결과 (수용)

1. **Istio 의 학습 곡선이 가파르다.** VirtualService / DestinationRule / Gateway / PeerAuthentication
   의 4 개 CRD 만 처음에 다뤄도 개념이 많다. 본 프로젝트의 install 가이드 (docs/setup/istio-install.md
   예정) 에서 각 CRD 의 역할을 한 줄씩 설명한다.
2. **사이드카가 추가되면서 pod 시작 시간이 길어진다.** 사이드카 컨테이너가 readiness 가 되기 전까지
   메인 컨테이너로 트래픽이 가지 않아야 하므로 `holdApplicationUntilProxyStarts: true` 를 사용한다.
   이 부분은 chart 의 postgres + 4 service 매니페스트에 이미 (또는 곧) 반영.
3. **Istio 자체의 보안 패치 추적 의무.** stable 한 stream 이긴 하지만 분기마다 minor 가 올라가므로
   1.29 → 1.30 → 1.31 업그레이드 절차를 운영자가 알아둬야 한다. 본 프로젝트는 데모 수명만 다루므로
   이 의무는 documented (`docs/runbook/istio-upgrade.md` — 추후 EPIC 9) 로만 남기고 실제 업그레이드는
   안 한다.

### 4.3 미채택 결정의 결과 (Linkerd 를 안 쓰는 비용)

Linkerd 의 강점인 "low-latency by Rust-based proxy (Linkerd2-proxy)" 는 본 프로젝트의 데모 수준
부하에서는 차이가 미미하다. mTLS 자동화도 Istio 의 PeerAuthentication.mtls.mode=STRICT 로 한 줄
설정으로 동등 효과를 얻을 수 있다. 따라서 미채택의 비용은 실질적으로 0 에 가깝다.

## 5. Alternatives Considered — 검토했지만 채택하지 않은 대안

### 5.1 Linkerd 2.x (edge)

- **장점**: Rust-based proxy 라 사이드카당 메모리 사용량이 약 30% 적음. mTLS 가 default. 운영
  knob 이 적어 실수 여지가 작음.
- **단점**: 2024년 2월 이후 오픈소스 stable 미발행. 본 프로젝트의 요구사항 문서가 Istio 용어로
  작성되어 매핑이 어색. Canary 가중치 조정이 SMI TrafficSplit (deprecated 예정) 에 의존.
- **결론**: 라이선스 모델 변화가 결정적 탈락 사유.

### 5.2 Cilium Service Mesh

- **장점**: eBPF 기반이라 사이드카 자체가 없음 → 메모리 사용량 가장 적음. CNI 와 통합되어 추가
  컴포넌트 최소.
- **단점**: 2026년 5월 현재 mTLS 강제·canary 가중치 같은 본 프로젝트 요구사항을 모두 커버하려면
  여전히 Envoy DaemonSet 을 같이 띄워야 함 (사실상 hybrid). 채용 시장 노출도가 Istio 대비 낮음.
- **결론**: 학습 가치는 있으나, 본 프로젝트의 용어·요구사항 매핑이 가장 거칠어짐.

### 5.3 메시 미사용 (NetworkPolicy + 애플리케이션 수준 retry)

- **장점**: 인프라 컴포넌트 추가 없음. 리소스 사용 최소.
- **단점**: Canary 가중치를 어떻게 구현할 건가? Service 두 개 + DNS round-robin 으로 흉내 낼 수
  있으나 weight 비율이 통제 불가. mTLS, outlierDetection, 분산 트레이싱은 모두 애플리케이션 코드에
  넣어야 함 → DevOps 시연이 아니라 application 작업이 되어버림.
- **결론**: 본 프로젝트의 핵심 시연 가치 (인프라 레벨 운영) 를 무너뜨림.

## 6. Verification — 본 결정이 작동함을 어떻게 확인하는가

본 ADR 의 결정이 실제로 운영에서 통하는지 다음 산출물로 검증한다.

| 검증 항목 | 어디서 | 무엇으로 |
|---|---|---|
| Istio 설치 자체 | `docs/setup/istio-install.md` (Task 6.2) | `istioctl verify-install` + `kubectl -n istio-system get pods` |
| 사이드카 자동 주입 | `payment-dev` / `payment-prod` namespace | `kubectl get pods -o jsonpath='{.items[*].spec.containers[*].name}'` 에 `istio-proxy` 포함 |
| Canary 가중치 | `istio/canary/virtualservice.yaml` (Task 6.4) | `for i in $(seq 1 100); do curl ...; done | sort | uniq -c` 로 비율 측정 |
| mTLS STRICT | `istio/peerauth.yaml` (Task 6.6) | `istioctl authn tls-check` 로 모든 서비스 간 통신이 STRICT 인지 검사 |
| Envoy 메트릭 (EPIC 7) | Prometheus | `istio_request_total` 메트릭이 4 서비스에서 모두 노출되는지 |

## 7. References

- [Istio Release Announcements](https://istio.io/latest/news/releases/) — 1.29.2 (2026-04-13)
- [Istio Supported Releases](https://istio.io/latest/docs/releases/supported-releases/) — K8s 1.31-1.35 호환
- [Linkerd 2.15 stable announcement clarifications (Buoyant blog, 2024)](https://www.buoyant.io/blog/clarifications-on-linkerd-2-15-stable-announcement) — 오픈소스 stable 중단 공지
- [CNCF Graduated Projects](https://www.cncf.io/projects/) — Istio 2023년 7월 졸업
- 본 프로젝트의 `docs/requirements.md` R-A1, R-A2 시리즈
