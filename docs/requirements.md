# 프로젝트 상세 구현 기준 (Requirements)

본 문서는 본 프로젝트의 **진리의 원천(source of truth)** 이다.
모든 백로그(`docs/BACKLOG.md`)와 산출물(`docs/traceability-matrix.md`)은 본 문서의 R-ID를 역참조한다.

> **본 프로젝트의 정책**: 사용자 결정에 따라 **[선택] 항목도 모두 [필수]로 승격**되어 백로그에 포함된다. 본 문서는 원본 분류(`[필]`/`[선]`)를 그대로 보존하되, 백로그에서는 모두 필수로 다룬다.

> **레지스트리 치환**: 비용 제약(0원)으로 KT클라우드 Container Registry 대신 GHCR을 사용한다. 마이그레이션 시나리오는 `docs/adr/0002-registry-ktcloud-vs-ghcr.md` 참조.

---

## B. 기본 프로젝트 — 쿠버네티스 기반 애플리케이션 배포 자동화

서비스 도메인: 핀테크 결제 서비스 (계좌 / 이체 / 대출 / 알림)

### B1. CI/CD 파이프라인 설계

| R-ID | 분류 | 요구사항 |
|---|---|---|
| **B1-M1** | [필] | Jenkins와 GitHub Actions의 학습 비용·연동 용이성·병렬 처리 지원을 비교하고 선택 근거를 ADR 문서로 작성한다. |
| **B1-M2** | [필] | GitHub Actions로 서비스별 단위 테스트 → Docker 빌드 → Container Registry 푸시 → Kubernetes 배포 단계의 파이프라인을 구성한다. path filter를 적용하여 변경된 서비스만 빌드·배포되도록 한다. |
| **B1-M3** | [필] | 배포 성공·실패 결과를 Slack `#deploy-status` 채널에 자동 발송한다. |
| **B1-O1** | [선] | 4개 서비스의 빌드 Job을 병렬로 실행하여 전체 배포 시간을 단축하고 개선 수치를 측정한다. |
| **B1-O2** | [선] | prod 환경 배포는 GitHub Environment Protection Rule로 승인자 확인을 강제한다. |

### B2. 컨테이너 이미지 빌드 및 레지스트리

| R-ID | 분류 | 요구사항 |
|---|---|---|
| **B2-M1** | [필] | 각 서비스의 Dockerfile을 빌드 스테이지와 런타임 스테이지로 분리하는 멀티스테이지 빌드로 작성하고, 비루트 사용자(`appuser`, UID 1001) 실행으로 설정한다. |
| **B2-M2** | [필] | Container Registry(본 프로젝트는 GHCR로 치환)에 서비스별 저장소를 분리하고 이미지 태그를 `git-sha`로 관리한다. |
| **B2-M3** | [필] | Trivy를 CI 파이프라인에 통합하여 HIGH/CRITICAL CVE 발견 시 레지스트리 푸시를 차단한다. |
| **B2-O1** | [선] | Trivy 취약점 스캔 결과를 GitHub PR 코멘트로 자동 게시한다. |
| **B2-O2** | [선] | untagged 이미지 자동 삭제 수명 주기 정책을 레지스트리에 설정한다. |
| **B2-O3** | [선] | Dependabot으로 베이스 이미지 최신화 자동화 PR을 주간으로 생성한다. |

### B3. 쿠버네티스 배포 자동화

| R-ID | 분류 | 요구사항 |
|---|---|---|
| **B3-M1** | [필] | 각 서비스에 Deployment + HPA(CPU 70% 기준, 최소 2·최대 10 Replica)를 구성한다. |
| **B3-M2** | [필] | Readiness Probe(`/health/ready`, DB 연결 확인)와 Liveness Probe(`/health`, 프로세스 생존 확인)를 설정하여 배포 중 트래픽 단절이 없도록 한다. |
| **B3-M3** | [필] | Helm Chart로 서비스 배포 설정을 관리하고 Rolling Update 배포 전략을 적용한다. |
| **B3-O1** | [선] | ArgoCD를 클러스터에 배포하고 Helm Chart 저장소와 연결하여 기본 GitOps 사이클(Git 변경 → 자동 Sync)을 구성한다. |
| **B3-O2** | [선] | dev/prod 환경을 values 파일로 분리하고 ArgoCD Application으로 환경별 배포를 관리한다. |
| **B3-O3** | [선] | 이체 서비스에 Canary 배포(신규 버전 20% → 100%)를 추가로 구현한다. |

---

## A. 심화 프로젝트 — 고급 네트워크 통합 및 서비스 메시 구현

기본 프로젝트의 서비스를 이어서 고도화한다.

### A1. 서비스 메시 도입 전략

| R-ID | 분류 | 요구사항 |
|---|---|---|
| **A1-M1** | [필] | Istio와 Linkerd의 기능·리소스 사용량·학습 난이도를 비교 분석하고 선택 근거를 ADR 문서로 작성한다. |
| **A1-M2** | [필] | Istio를 클러스터에 설치하고 서비스 Namespace에 사이드카 자동 주입을 활성화한다. |
| **A1-M3** | [필] | VirtualService와 DestinationRule을 정의하여 이체 서비스에 Canary 라우팅(신규 버전 20% → 50% → 100% 단계적 전환)을 적용한다. |
| **A1-O1** | [선] | PeerAuthentication으로 Namespace 전체에 mTLS STRICT 모드를 활성화하여 서비스 간 통신을 암호화하고 Kiali에서 mTLS 적용 현황을 시각적으로 확인한다. |
| **A1-O2** | [선] | 트래픽 라우팅(블루-그린, 카나리) 및 관찰성(Observability) 강화 설정을 추가로 구성한다. |

### A2. 서비스 메시 운영 및 모니터링

| R-ID | 분류 | 요구사항 |
|---|---|---|
| **A2-M1** | [필] | Kiali를 배포하여 서비스 토폴로지(서비스 간 트래픽 흐름, 에러율)를 시각화한다. |
| **A2-M2** | [필] | Istio 사이드카 프록시(Envoy)의 메모리·CPU 사용량을 Prometheus로 수집하고 Grafana에서 모니터링한다. |
| **A2-M3** | [필] | DestinationRule의 기본 Circuit Breaker(connectionPool 설정)를 구성하여 서비스 과부하를 방지한다. |
| **A2-O1** | [선] | Jaeger를 배포하고 Istio와 연동하여 서비스 간 요청의 분산 트레이싱을 수집한다. P99 응답 시간 초과 요청에 대한 Trace를 즉시 조회할 수 있도록 샘플링 전략을 설정한다. |
| **A2-O2** | [선] | outlierDetection으로 연속 5회 5xx 응답 시 Pod를 30초 ejection하는 Circuit Breaker를 구성하고 실제 장애 주입으로 동작을 검증한다. |
| **A2-O3** | [선] | 분산 트레이싱(Jaeger/Zipkin) 연동 후 서비스 간 병목 구간을 정량적으로 분석하고 개선 방안을 도출한다. |

### A3. 네트워크 정책 및 장애 복구

| R-ID | 분류 | 요구사항 |
|---|---|---|
| **A3-M1** | [필] | Kubernetes NetworkPolicy를 정의하여 Namespace 내부 서비스 간 통신만 허용하고 외부 직접 접근을 차단한다. |
| **A3-M2** | [필] | Pod 강제 종료 장애 시나리오 1가지를 수행하고 Istio Retry 정책의 동작을 확인한다. |
| **A3-M3** | [필] | 이전 버전으로의 롤백 절차(ArgoCD 이전 Revision 복원 또는 VirtualService 가중치 즉시 전환)를 Runbook으로 작성한다. |
| **A3-O1** | [선] | 네트워크 지연(200ms 주입, Istio fault injection)·서비스 다운 등 2가지 이상 추가 장애 시나리오를 수행하고 Istio Circuit Breaker 동작 결과를 측정·기록한다. |
| **A3-O2** | [선] | 장애 발생 시 롤백 절차를 자동화 스크립트로 구현하여 5분 이내 복구를 목표로 검증한다. |
| **A3-O3** | [선] | Pod 간 통신 차단·허용 시나리오를 NetworkPolicy로 세분화하여 테스트한다. |

---

## 통계

- 기본 프로젝트: 9 [필] + 8 [선] = 17 항목
- 심화 프로젝트: 9 [필] + 7 [선] = 16 항목
- **총 33 항목 (모두 본 프로젝트에서는 필수로 다룸)**
