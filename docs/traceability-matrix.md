# Traceability Matrix

요구사항(`docs/requirements.md`) ↔ 백로그 태스크(`docs/BACKLOG.md`) ↔ 실제 산출물 경로의 양방향 추적표.

태스크 진행 시 "산출물 경로" 컬럼을 실제 파일 경로로 채워나간다. 빈칸은 미완료를 의미한다.

---

## 기본 프로젝트 (B)

### B1. CI/CD

| R-ID | 분류 | 요약 | Backlog Task | 산출물 경로 | 상태 |
|---|---|---|---|---|---|
| B1-M1 | [필] | Jenkins vs GHA ADR | 9.1 | `docs/adr/0001-ci-tool-jenkins-vs-gha.md` | ⬜ |
| B1-M2 | [필] | GHA pipeline (test→build→push→deploy) + path filter | 1.5, 3.0, 3.1, 3.3 | `services/*/tests/`, `.github/workflows/ci.yml` | ⬜ |
| B1-M3 | [필] | Slack `#deploy-status` 알림 | 3.6 | `.github/workflows/ci.yml` | ⬜ |
| B1-O1 | [선→필] | 4서비스 병렬 + 시간 측정 | 3.2 | `docs/metrics/ci-parallelization.md` | ⬜ |
| B1-O2 | [선→필] | prod GitHub Environment Protection | 5.5 | `docs/setup/github-environment-protection.md` (가이드 ✅) + `docs/screenshots/gh-env-config.png` (config 1/3 ✅) + pending/approved 캡처 2/3 (cd.yml 도입 후) | 🟡 |

### B2. 컨테이너/레지스트리

| R-ID | 분류 | 요약 | Backlog Task | 산출물 경로 | 상태 |
|---|---|---|---|---|---|
| B2-M1 | [필] | 멀티스테이지 + 비루트 UID 1001 | 2.1 | `services/*/Dockerfile` | ⬜ |
| B2-M2 | [필] | 레지스트리 분리 + git-sha 태그 (GHCR 치환) | 2.3, 3.3, 9.2 | `docs/registry.md`, `docs/adr/0002-*.md` | ⬜ |
| B2-M3 | [필] | Trivy HIGH/CRITICAL 차단 | 3.4 | `.github/workflows/ci.yml` | ⬜ |
| B2-O1 | [선→필] | Trivy PR 코멘트 | 3.5 | 워크플로 + PR 캡처 | ⬜ |
| B2-O2 | [선→필] | untagged 자동 삭제 | 2.4 | `docs/registry.md` + 캡처 | ⬜ |
| B2-O3 | [선→필] | Dependabot 주간 PR | 2.5 | `.github/dependabot.yml` + 캡처 | ⬜ |

### B3. K8s 배포

| R-ID | 분류 | 요약 | Backlog Task | 산출물 경로 | 상태 |
|---|---|---|---|---|---|
| B3-M1 | [필] | HPA CPU 70%, 2~10 | 4.3 | `charts/payment-platform/templates/hpa.yaml` | ⬜ |
| B3-M2 | [필] | Readiness/Liveness | 1.1, 1.4, 4.4 | Deployment 템플릿 | ⬜ |
| B3-M3 | [필] | Helm + RollingUpdate | 4.1, 4.2, 4.6 | `charts/payment-platform/` | ⬜ |
| B3-O1 | [선→필] | ArgoCD GitOps 사이클 | 5.1, 5.2, 5.3, 5.4 | `argocd/values.yaml`, `argocd/install.md`, `argocd/root-app.yaml`, `argocd/applications/payment-{dev,prod}.yaml`, `argocd/projects/payment-platform.yaml` (kind cluster 에서 3개 Application 모두 Synced/Healthy 확인) | ✅ |
| B3-O2 | [선→필] | dev/prod values + ArgoCD App | 4.5, 5.2 | `charts/payment-platform/values-{dev,prod}.yaml`, `argocd/applications/payment-{dev,prod}.yaml` (양쪽 namespace 에 helm 렌더링 + 동기화 확인) | ✅ |
| B3-O3 | [선→필] | transfer Canary 20→100 | 6.5 | `istio/canary/` | ⬜ |

---

## 심화 프로젝트 (A)

### A1. 서비스 메시 전략

| R-ID | 분류 | 요약 | Backlog Task | 산출물 경로 | 상태 |
|---|---|---|---|---|---|
| A1-M1 | [필] | Istio vs Linkerd ADR | 6.1 | `docs/adr/0003-mesh-istio-vs-linkerd.md` | ✅ |
| A1-M2 | [필] | Istio 설치 + 사이드카 자동주입 | 6.2, 6.3 | `docs/setup/istio-install.md` (가이드 ✅) + 사용자 클러스터 설치 + 사이드카 주입 검증 (모든 사이드카 SUBSCRIBED `4 (CDS,LDS,EDS,RDS)` 확인) | ✅ |
| A1-M3 | [필] | VS+DR Canary 20→50→100 | 6.4, 6.5 | `istio/canary/destinationrule.yaml`, `istio/canary/virtualservice.yaml`, `istio/canary/transfer-canary.yaml`, `istio/canary/scripts/{set-canary-weight,test-traffic-split}.sh`, `istio/canary/README.md`, `services/transfer/main.py` (/version 엔드포인트), `charts/payment-platform/templates/deployment.yaml` (version 라벨 + SERVICE_VERSION env). 사용자 실제 시연 캡처 (TBD) | 🟡 |
| A1-O1 | [선→필] | mTLS STRICT + Kiali 확인 | 6.6, 6.7 | `istio/peerauth.yaml`, `istio/peerauth-verify.md`, `observability/kiali/values.yaml`, `observability/kiali/install.md`. 사용자 클러스터 적용 + Kiali 캡처 (TBD) | 🟡 |
| A1-O2 | [선→필] | 블루-그린 + 관측성 강화 | 6.8 | `services/account/main.py` (/version), `charts/payment-platform/values.yaml` (account.version=blue), `istio/blue-green/{account-green,destinationrule,virtualservice}.yaml`, `scripts/{switch-bluegreen,test-bluegreen}.sh`, `istio/blue-green/README.md`. 사용자 클러스터에서 100/0 전환 + 롤백 시연 캡처 (TBD) | 🟡 |

### A2. 메시 운영/모니터링

| R-ID | 분류 | 요약 | Backlog Task | 산출물 경로 | 상태 |
|---|---|---|---|---|---|
| A2-M1 | [필] | Kiali 토폴로지 | 1.3, 7.3 | `observability/kiali/{values.yaml,install.md}`, `observability/prom/install.md` § 4 (URL cutover). 사용자 cutover + Graph 캡처 (TBD) | 🟡 |
| A2-M2 | [필] | Envoy Prometheus + Grafana | 7.1, 7.2 | `observability/prom/{values.yaml,install.md}`, `observability/grafana-dashboards/README.md`. 사용자 적용 + dashboard 캡처 3 장 (TBD) | 🟡 |
| A2-M3 | [필] | DR connectionPool Circuit Breaker | 8.2 | `istio/destinationrule.yaml` | ⬜ |
| A2-O1 | [선→필] | Jaeger + 샘플링 전략 (P99) | 7.4, 7.5 | `observability/jaeger/{values.yaml,install.md,istio-tracing.yaml,sampling-1.yaml}`, `docs/tracing-sampling.md`. 사용자 적용 + trace waterfall 캡처 (TBD) | 🟡 |
| A2-O2 | [선→필] | outlierDetection 5xx 5회 30s + 검증 | 8.3, 8.6 | DR + 카오스 결과 | ⬜ |
| A2-O3 | [선→필] | 분산 트레이싱 병목 분석 + 개선안 | 7.6 | `docs/analysis/bottleneck-report.md` (측정 템플릿 ✅, 사용자 실측값 TBD) | 🟡 |

### A3. 네트워크 정책 / 장애 복구

| R-ID | 분류 | 요약 | Backlog Task | 산출물 경로 | 상태 |
|---|---|---|---|---|---|
| A3-M1 | [필] | NetworkPolicy 기본 | 8.1 | `manifests/networkpolicy.yaml` | ⬜ |
| A3-M2 | [필] | Pod kill + Retry 확인 | 8.4 | `scripts/chaos/pod-kill.sh` + 로그 | ⬜ |
| A3-M3 | [필] | 롤백 Runbook | 9.3 | `docs/runbook/rollback.md` | ⬜ |
| A3-O1 | [선→필] | 추가 카오스 2종+ (지연/다운) | 8.5, 8.6 | `scripts/chaos/*.sh` + 측정 | ⬜ |
| A3-O2 | [선→필] | 자동 롤백 5분 이내 | 9.4 | `scripts/rollback.sh`, `docs/metrics/rollback-time.md` | ⬜ |
| A3-O3 | [선→필] | NetworkPolicy 세분화 | 8.7 | `docs/netpol-tests.md` | ⬜ |

---

## 진행 통계

- 총 요구사항: **33개** (모두 필수로 다룸)
- 총 백로그 태스크: **62개**
- 완료: **0 / 33** (0%)

> 진행 중에는 Backlog 태스크 완료 시 본 표 "상태" 컬럼을 ⬜ → ✅ 로 갱신한다.
