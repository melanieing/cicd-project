# Backlog (4-Day Plan)

본 백로그는 `docs/requirements.md` 의 **모든 항목(필수+선택)을 [필수]로 승격**해 충족시키기 위한 실행 계획이다.
각 태스크는 **R-ID 역참조**를 통해 어떤 요구사항을 충족하는지 명시한다.

- 총 태스크: **62개**
- 일정: **4일 × 약 10h = 약 40h**
- 표기: `R-x.y` = 충족하는 요구사항 ID, `[★]` = 포트폴리오 가산 산출물

---

## EPIC 0 — 프로젝트 부트스트랩 (Day 1 오전)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 0.1 | 리포 디렉토리 골격 생성 (`services/`, `charts/`, `argocd/`, `istio/`, `observability/`, `docs/`, `scripts/`, `.github/`) ✅ | - | 디렉토리 트리 |
| 0.2 | `.gitignore`, `.editorconfig`, `LICENSE` 추가 ✅ | - | 파일 |
| 0.3 | **기술 스택 버전 검증** (kind, k8s, Istio, ArgoCD, Prom stack, Kiali, Jaeger, Trivy, Helm, Python, FastAPI, Postgres, GHA runner — 13종) ✅ | - | `docs/tech-stack-versions.md` |
| 0.4 | 로컬 도구 설치 가이드 (`docker`, `kind`, `kubectl`, `helm`, `istioctl`, `argocd` CLI) — Ubuntu 24.04 기준 ✅ | - | `docs/setup/local-tools.md` |
| 0.5 | kind 멀티노드 클러스터 부트스트랩 스크립트 ✅ | - | `scripts/bootstrap.sh`, `kind-config.yaml` |
| 0.6 | 네임스페이스 분리 (`payment-dev`, `payment-prod`, `argocd`, `istio-system`, `observability`) ✅ | - | `manifests/namespaces.yaml` |

## EPIC 1 — 애플리케이션 서비스 (얇게) (Day 1 오전)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 1.1 | FastAPI 템플릿 1개 작성 (`/health`, `/health/ready` DB ping, 도메인 액션 1개) ✅ | B3-M2 | `services/_template/` |
| 1.2 | 4개 서비스(`account`, `transfer`, `loan`, `notification`) 템플릿 복제 + 도메인 액션 식별자만 변경 ✅ | - | 각 서비스 디렉토리 |
| 1.3 | `transfer` → `notification` HTTP 호출 연결 (mesh 토폴로지에서 의미 있는 트래픽) ✅ | A2-M1 | `services/transfer/main.py` |
| 1.4 | PostgreSQL StatefulSet + DB 4개 (`account_db`, `transfer_db`, `loan_db`, `notification_db`) ✅ | B3-M2 | `charts/payment-platform/templates/postgres.yaml` |
| 1.5 | 각 서비스 pytest 단위 테스트 1~2개 (도메인 액션 + 헬스 검증) ✅ | B1-M2 | `services/*/tests/` |

## EPIC 2 — 컨테이너 이미지 (Day 1 오후)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 2.1 | 멀티스테이지 Dockerfile (builder/runtime 분리, 비루트 `appuser` UID 1001) ✅ | B2-M1 | `services/*/Dockerfile` |
| 2.2 | `.dockerignore` ✅ | - | `services/*/.dockerignore` |
| 2.3 | GHCR 레지스트리 4개 분리 + 이미지 명명 규칙 (`ghcr.io/<owner>/<service>:<git-sha>`) ✅ | B2-M2 | `docs/registry.md` |
| 2.4 | GHCR untagged 이미지 보존 정책 (자동 삭제) ✅ workflow + doc / 🟡 첫 수동 트리거 + 전후 스크린샷 (사용자 작업) | B2-O2 | `docs/registry.md`, `.github/workflows/ghcr-cleanup.yml`, 스크린샷 |
| 2.5 | Dependabot 베이스이미지 주간 PR 설정 + 첫 PR 캡처 ✅ | B2-O3 | `.github/dependabot.yml`, 스크린샷 |

## EPIC 3 — CI 파이프라인 (Day 2 오전~오후)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 3.0 | 워크플로 `test` job 선행 배치 (pytest 실패 시 build 단계 차단) ✅ | B1-M2 | `.github/workflows/ci.yml` |
| 3.1 | path filter 기반 변경 감지 (`dorny/paths-filter`) ✅ | B1-M2 | 동일 워크플로 |
| 3.2 | 4잡 매트릭스 병렬 빌드/테스트 ✅ + **직렬 vs 병렬 시간 측정** ✅ (run #7/#8 데이터, 약 3× speedup) | B1-O1 | 동일 워크플로 / `docs/metrics/ci-parallelization.md` [★] |
| 3.3 | Docker Buildx + GHCR 푸시 (`git-sha` 태그) ✅ | B1-M2, B2-M2 | 동일 워크플로 |
| 3.4 | Trivy 이미지 스캔 (HIGH/CRITICAL 차단) ✅ | B2-M3 | 동일 워크플로 |
| 3.5 | Trivy 결과 PR 코멘트 자동 게시 ✅ + 실제 PR 캡처 ✅ | B2-O1 | 동일 워크플로, `docs/screenshots/trivy-pr-comment.png` |
| 3.6 | Slack `#deploy-status` 성공/실패 알림 ✅ + Webhook secret 등록 ✅ + 실제 알림 도착 확인 | B1-M3 | 동일 워크플로 + Repo Secret |

## EPIC 4 — Helm & K8s 배포 (Day 2 오후)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 4.1 | `payment-platform` umbrella Helm chart 골격 ✅ | B3-M3 | `charts/payment-platform/Chart.yaml`, `values.yaml`, `_helpers.tpl` |
| 4.2 | Deployment, Service, ConfigMap, Secret 템플릿 ✅ | B3-M3 | `templates/{deployment,service,configmap,postgres}.yaml` |
| 4.3 | HPA (CPU 70%, 2~10 replicas) ✅ | B3-M1 | `templates/hpa.yaml` |
| 4.4 | Readiness `/health/ready` (DB ping), Liveness `/health` ✅ | B3-M2 | `templates/deployment.yaml` |
| 4.5 | `values-dev.yaml`, `values-prod.yaml` 분리 ✅ | B3-O2 | `charts/payment-platform/values-{dev,prod}.yaml` |
| 4.6 | RollingUpdate 전략 명시 (maxSurge/maxUnavailable) ✅ | B3-M3 | `templates/deployment.yaml` |

## EPIC 5 — GitOps (ArgoCD) (Day 3 오전)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 5.1 | ArgoCD 설치 (Helm, namespace `argocd`) ✅ | B3-O1 | `argocd/install.md`, `argocd/values.yaml` |
| 5.2 | `Application` (dev), `Application` (prod) 매니페스트 ✅ | B3-O1, B3-O2 | `argocd/applications/payment-{dev,prod}.yaml`, `argocd/projects/payment-platform.yaml` |
| 5.3 | App-of-Apps 패턴 적용 [★] ✅ | B3-O1 | `argocd/root-app.yaml` |
| 5.4 | Auto-sync + self-heal (dev), 수동 sync (prod) ✅ | B3-O1 | Application spec (5.2 매니페스트 내 `syncPolicy`) |
| 5.5 | GitHub Environment Protection (prod 승인자 강제) ✅ 가이드 + ✅ config 화면 캡처 (1/3) / 🟡 cd.yml 도입 후 pending + approved 캡처 (2/3) | B1-O2 | `docs/setup/github-environment-protection.md`, `docs/screenshots/gh-env-config.png` (나머지 2 장 TBD) |

## EPIC 6 — 서비스 메시 (Istio) (Day 3 오후)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 6.1 | ✅ **ADR 0003: Istio vs Linkerd 비교** | A1-M1 | `docs/adr/0003-mesh-istio-vs-linkerd.md` |
| 6.2 | ✅ Istio 1.29.2 default profile 설치 (`istioctl install`) — 가이드 작성 + 사용자 클러스터 적용 (istiod + ingress gateway 모두 `1/1 Running`, `istioctl proxy-status` 에서 ingress gateway 가 SUBSCRIBED `3 (CDS,LDS,EDS)` 로 인지됨) | A1-M2 | `docs/setup/istio-install.md` |
| 6.3 | ✅ 사이드카 자동 주입 — `payment-dev` / `payment-prod` namespace 에 `istio-injection=enabled` 라벨 부여 + 기존 pod rolling restart → K8s 1.28+ **Native Sidecar mode** 로 사이드카가 `spec.initContainers[]` 의 `restartPolicy: Always` entry 로 자동 들어감 (시작 race 자동 해결). 모든 pod 가 `READY 2/2` + `proxy-status` 에서 SUBSCRIBED `4 (CDS,LDS,EDS,RDS)` 로 인지. chart 의 `holdApplicationUntilProxyStarts` annotation 은 K8s 1.27 이하 호환성용 방어 장치 (Native Sidecar 환경에서는 불필요하지만 무해) | A1-M2 | `docs/setup/istio-install.md` § 4, `charts/payment-platform/templates/deployment.yaml` |
| 6.4 | ✅ `transfer` 두 인스턴스 (stable / canary) 매니페스트 — chart 가 stable, `istio/canary/transfer-canary.yaml` 가 canary. 같은 image 에 `SERVICE_VERSION` env 만 다르게 + `/version` 엔드포인트로 응답 차이 가시화. / 🟡 사용자 클러스터에서 stable + canary 동시 기동 검증 (PR 머지 → CI 새 image → ArgoCD sync 후) | A1-M3 | `services/transfer/main.py`, `charts/payment-platform/templates/deployment.yaml`, `charts/payment-platform/values.yaml`, `istio/canary/transfer-canary.yaml` |
| 6.5 | ✅ VirtualService + DestinationRule (Canary 20→50→100) + 빠른 weight 변경 스크립트 + 100 회 분포 측정 스크립트 + 시연 절차 README. / 🟡 사용자 클러스터에서 weight 별 (80/20, 50/50, 0/100) 100 회 분포 측정 + 캡처 | A1-M3, B3-O3 | `istio/canary/destinationrule.yaml`, `istio/canary/virtualservice.yaml`, `istio/canary/scripts/set-canary-weight.sh`, `istio/canary/scripts/test-traffic-split.sh`, `istio/canary/README.md` |
| 6.6 | ✅ PeerAuthentication STRICT mTLS — payment-dev/payment-prod namespace level + 메시 외부 평문 거부 검증 절차 / 🟡 사용자 클러스터에서 외부 호출 거부 + 내부 호출 정상 + Kiali 자물쇠 캡처 | A1-O1 | `istio/peerauth.yaml`, `istio/peerauth-verify.md` |
| 6.7 | ✅ Kiali 2.21.0 설치 가이드 + Helm values (lightweight Prometheus sample 임시 사용, EPIC 7 에서 kube-prometheus-stack 으로 교체) / 🟡 사용자 클러스터에서 Graph 토폴로지 + mTLS 자물쇠 + Canary 분배 캡처 3 장 | A1-O1 | `observability/kiali/values.yaml`, `observability/kiali/install.md` |
| 6.8 | ✅ **블루-그린 라우팅** (`account` 서비스, `version=blue/green` 라벨, 100/0 즉시 전환) — account `/version` 엔드포인트 + chart 의 `services.account.version: blue` + `istio/blue-green/` 매니페스트 3 + 전환·검증 스크립트 + 시연 README / 🟡 사용자 클러스터에서 100% blue → 100% green → 100% blue 시연 캡처 | A1-O2 | `services/account/main.py`, `charts/payment-platform/values.yaml`, `istio/blue-green/{account-green,destinationrule,virtualservice}.yaml`, `scripts/{switch-bluegreen,test-bluegreen}.sh`, `istio/blue-green/README.md` |

## EPIC 7 — 관측성 스택 (Day 4 오전)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 7.1 | `kube-prometheus-stack` Helm 설치 | A2-M2 | `observability/prom/values.yaml` |
| 7.2 | Envoy CPU/Mem 패널 dashboard | A2-M2 | `observability/grafana-dashboards/*.json` |
| 7.3 | Kiali 설치 + Prometheus 연동 (서비스 토폴로지 캡처) | A2-M1 | `observability/kiali/values.yaml`, 스크린샷 |
| 7.4 | Jaeger 설치 + Istio tracing 연동 | A2-O1 | `observability/jaeger/` |
| 7.5 | 100% 샘플링 → P99 trace 캡처 → 운영용 1% 샘플링 변경 | A2-O1 | `docs/tracing-sampling.md`, 스크린샷 |
| 7.6 | **병목 구간 정량 분석 리포트** (Jaeger 기반 P99 hotspot 표 + 개선안 3개 + before/after 측정) | A2-O3 | `docs/analysis/bottleneck-report.md` [★] |

## EPIC 8 — 네트워크 & 복원력 (Day 4 오후)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 8.1 | NetworkPolicy 기본 (namespace 내부만 허용, 외부 차단) | A3-M1 | `manifests/networkpolicy.yaml` |
| 8.2 | DestinationRule connectionPool (Circuit Breaker 기본) | A2-M3 | `istio/destinationrule.yaml` |
| 8.3 | outlierDetection (5xx 5회 → 30s ejection) + ejection 발동 그래프 | A2-O2 | 동일 파일, Grafana 스크린샷 |
| 8.4 | 카오스 #1 — Pod 강제 종료 + Istio Retry 동작 확인 | A3-M2 | `scripts/chaos/pod-kill.sh` + 결과 로그 |
| 8.5 | 카오스 #2 — Istio fault injection 200ms delay | A3-O1 | `scripts/chaos/delay.sh` |
| 8.6 | 카오스 #3 — 503 강제 주입 → outlierDetection 검증 | A3-O1, A2-O2 | `scripts/chaos/abort.sh` |
| 8.7 | NetworkPolicy 차단/허용 매트릭스 시나리오 | A3-O3 | `docs/netpol-tests.md` |

## EPIC 9 — 문서·롤백·마감 (Day 1~4 분산, Day 4 마감)

| ID | 태스크 | R-ID | 산출물 |
|---|---|---|---|
| 9.1 | **ADR 0001: Jenkins vs GitHub Actions** | B1-M1 | `docs/adr/0001-ci-tool-jenkins-vs-gha.md` |
| 9.2 | **ADR 0002: KT Cloud Registry vs GHCR** (비용 제약 + 마이그 시나리오) | B2-M2 | `docs/adr/0002-registry-ktcloud-vs-ghcr.md` |
| 9.3 | Rollback Runbook (ArgoCD revision / VS weight 즉시 전환) | A3-M3 | `docs/runbook/rollback.md` |
| 9.4 | 자동 롤백 스크립트 (5분 이내 복구) + 실측 시간 표 | A3-O2 | `scripts/rollback.sh` + `docs/metrics/rollback-time.md` |
| 9.5 | README 작성 (Quickstart, 아키텍처 Mermaid, 결과 수치, 스크린샷 임베드) | - | `README.md` [★] |
| 9.6 | 데모 GIF 1개 (ArgoCD Sync → Canary → Kiali) | - | `docs/demo.gif` [★] |
| 9.7 | 최종 검증 — clean clone에서 `bootstrap.sh` 1회로 전체 기동 확인 | - | 검증 로그 [★] |

---

## 일자별 요약

| 일자 | 작업량 | 핵심 완료 기준 |
|---|---|---|
| **Day 1** | EPIC 0+1+2 (16 태스크) | kind 클러스터 + FastAPI×4 + pytest + Dockerfile + GHCR 정책 |
| **Day 2** | EPIC 3+4 (13 태스크) + ADR 0001/0002 시작 | 병렬 CI(test→Trivy→push→Slack) + Helm chart + Probes/HPA |
| **Day 3** | EPIC 5+6 (13 태스크) + ADR 0003 | ArgoCD GitOps + Istio Canary + Blue-Green + mTLS STRICT |
| **Day 4** | EPIC 7+8+9 (20 태스크) | Prom/Graf/Kiali/Jaeger + 병목 분석 + 카오스 3종 + Runbook + README + 데모 |

## 진행 추적 규칙

1. 태스크 완료 시 본 파일 해당 행에 `✅` 표기 후 커밋
2. 산출물 생성 시 `docs/traceability-matrix.md` 의 "산출물 경로" 컬럼 동시 갱신
3. 새로운 결정/변경은 ADR로 추가 (필요 시 R-ID 신설은 `requirements.md` 변경 후 본 파일 동기화)
