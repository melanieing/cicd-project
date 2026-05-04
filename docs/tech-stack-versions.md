# 기술 스택 버전 (2026년 5월 기준)

> **⚠️ 본 문서는 2026-05-03 의사결정 시점의 스냅샷이다.**
> 그 이후 Dependabot 이 자동 업데이트 PR 을 만들어 머지된 버전이 있다.
> **실제 사용 중인 라이브 버전은 다음을 보라:**
> - Python 의존성: `services/*/requirements.txt`
> - Docker 베이스 이미지: `services/*/Dockerfile` 의 `FROM` 라인
> - GitHub Actions: `.github/workflows/*.yml` 의 `uses:` 라인 (EPIC 3 후)
>
> 본 표는 **선정 사유와 비교 근거** 를 보존하는 ADR 성격으로 유지된다.
> 신규 의존성 추가 시에는 같은 형식으로 1 행 추가 + 사유 명시.

본 문서는 본 프로젝트가 사용할 13개 핵심 컴포넌트의 **확정 버전**을 기록한다.
모든 버전은 `2026-05-03` 기준으로 공식 릴리스 페이지·릴리스 노트·GitHub Releases에서 직접 확인했다.

선정 원칙(`CLAUDE.md` A-2):
- 2026년 다수 기업이 실사용 중인 안정 버전 선택
- deprecated/EoL 임박 버전 배제
- 베타·RC·릴리스 직후(2주 미만) 버전 배제 — 단, 보안 이슈로 회피해야 하는 경우는 최신 패치 채택
- "최신"보다 "검증된 stable" 우선

---

## 요약 — 확정 버전 표

| # | 컴포넌트 | 확정 버전 | 릴리스 시점 | 비고 |
|---|---|---|---|---|
| 1 | **kind** | `v0.27.0` | 2025-02 | K8s 1.32.2 default; 안정 검증된 버전 |
| 2 | **Kubernetes** (kind 노드) | `v1.33.x` | 2025 | 지원 윈도우 내, kind 호환 |
| 3 | **Istio** | `1.29.2` | 2026-04-13 | 최신 minor, 본 사용 시점 3주 경과 |
| 4 | **ArgoCD Helm chart** | `9.5.11` | 2026-04 | 공식 argo-helm 최신 stable |
| 5 | **kube-prometheus-stack** | `84.5.0` | 2026-04 | Prometheus Community 최신 |
| 6 | **Kiali** | `v2.24.0` | 2026-03-30 | Istio 1.28~1.29 호환 검증 |
| 7 | **Jaeger** (all-in-one) | `2.17.0` | 2026-04-01 | OTel 기반 v2, 단일 컨테이너 데모 구성 |
| 8 | **Trivy** (CLI Docker image) | `aquasec/trivy:0.70.0` | 2026-04-17 | 사건 후 안전 채널. **GHA 에서 직접 호출**(아래 참조) |
| 8a | ~~`aquasecurity/trivy-action`~~ | **사용 안 함** | — | v0.36.0 미존재 + 2026-03 공급망 사건으로 wrapper 자체 회피. CLI Docker image 직접 사용. See: docs/troubleshooting/2026-05-04-ci-trivy-action-version-and-slack-payload.md |
| 9 | **Helm** | `3.20.x` | 2026 | v4는 출시 직후라 회피, v3 마지막 stable |
| 10 | **Python** (베이스 이미지) | `3.13-slim-bookworm` | 2026-04-07 (3.13.13) | FastAPI 호환, 3.14는 지나치게 최신 |
| 11 | **FastAPI** | `0.136.1` | 2026-04-23 | Uvicorn[standard] 최신과 함께 사용 |
| 12 | **PostgreSQL** | `17.9` | 2026-02-26 | 18은 너무 신규, 16은 17 출시로 위치 약화. 17이 2026년 메인스트림 |
| 13 | **GitHub Actions runner** | `ubuntu-24.04` (명시 핀) | LTS | `ubuntu-latest` 대신 명시 핀(재현성) |

> 모든 버전 핀은 `charts/`, `Dockerfile`, `.github/workflows/`, `kind-config.yaml`에서 동일하게 사용한다.

---

## 1. kind — `v0.27.0`

- **출처**: [Releases · kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind/releases)
- **선정 근거**: v0.27.0부터 containerd 2.x로 이동, K8s 1.32.2 기본 노드 이미지. v0.28.0(2025-05-16)도 가능하나 v0.27.0이 충분히 검증되어 안정적.
- **노드 이미지**: `kindest/node:v1.33.0` (또는 v1.32.x) 명시 사용 예정 (2번 항목 참조)
- **설치 명령** (Ubuntu 24.04):
  ```bash
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
  chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
  kind version  # kind v0.27.0 ...
  ```

## 2. Kubernetes (kind 노드 이미지) — `v1.33.x`

- **출처**: [Kubernetes Releases](https://kubernetes.io/releases/), [endoflife.date/kubernetes](https://endoflife.date/kubernetes)
- **선정 근거**:
  - 2026-05 기준 stable: `1.35.2` (Dec 2025), `1.36` (Apr 22, 2026)
  - 1.36은 출시 2주차로 회피, 1.35는 안정적이지만 kind 기본 지원과의 정합성을 위해 1.33 채택
  - 1.33은 maintenance mode 진입(2026-04-28) 직후이지만 EoL은 2026-06-28까지로 본 프로젝트 작업 기간 내 안전
  - 본 프로젝트는 단기 시연용이라 LTS 의미가 약함. 호환성 우선
- **사용처**: kind cluster 생성 시 노드 이미지 지정
  ```yaml
  # kind-config.yaml
  nodes:
    - role: control-plane
      image: kindest/node:v1.33.0
    - role: worker
      image: kindest/node:v1.33.0
  ```

## 3. Istio — `1.29.2`

- **출처**: [Istio Release Announcements](https://istio.io/latest/news/releases/), [Releases · istio/istio](https://github.com/istio/istio/releases)
- **선정 근거**: 2026-04-13 릴리스로 본 사용 시점(2026-05-03)에 약 3주 경과. Istio 권장 "2~4주 후 업그레이드" 룰을 만족. 1.28.6보다 신규지만 시연 목적상 최신 기능 활용 가능.
- **profile**: `demo` (포트폴리오용 적정 리소스, mTLS·트레이싱·관측 기본 활성)
- **설치**:
  ```bash
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.29.2 sh -
  cd istio-1.29.2 && export PATH=$PWD/bin:$PATH
  istioctl install --set profile=demo -y
  ```

## 4. ArgoCD Helm chart — `9.5.11`

- **출처**: [argo-cd on Artifact Hub](https://artifacthub.io/packages/helm/argo/argo-cd), [Releases · argoproj/argo-helm](https://github.com/argoproj/argo-helm/releases)
- **선정 근거**: 공식 argo-helm 최신 stable. 9.x 시리즈는 2025-2026 메인스트림.
- **사용**:
  ```bash
  helm repo add argo https://argoproj.github.io/argo-helm
  helm install argocd argo/argo-cd --version 9.5.11 \
       -n argocd --create-namespace
  ```

## 5. kube-prometheus-stack — `84.5.0`

- **출처**: [kube-prometheus-stack on Artifact Hub](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack)
- **선정 근거**: Prometheus Community 공식 차트의 최신 stable. 본 프로젝트 메모리 압박 고려해 Alertmanager·Thanos는 비활성, Prometheus + Grafana + Operator만 사용 예정.
- **사용**:
  ```bash
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm install monitoring prometheus-community/kube-prometheus-stack \
       --version 84.5.0 -n observability --create-namespace
  ```

## 6. Kiali — `v2.24.0`

- **출처**: [Kiali Release Notes](https://kiali.io/news/release-notes/), [Prerequisites · Kiali](https://kiali.io/docs/installation/installation-guide/prerequisites/)
- **선정 근거**: 2026-03-30 sprint release. Istio 1.28~1.29와 호환 검증. v2.25(2026-04-17)는 최신이지만 출시 2주차라 v2.24를 안전하게 채택.
- **설치**: Kiali Operator 또는 Helm
  ```bash
  helm repo add kiali https://kiali.org/helm-charts
  helm install kiali-server kiali/kiali-server --version 2.24.0 \
       -n istio-system
  ```

## 7. Jaeger — `2.17.0` (all-in-one)

- **출처**: [Jaeger Releases](https://github.com/jaegertracing/jaeger/releases), [Jaeger Download](https://www.jaegertracing.io/download/)
- **선정 근거**:
  - Jaeger v1은 2025-12-31 EoL → 반드시 v2 사용
  - v2는 OpenTelemetry Collector 기반. 운영 환경에서는 OTel Operator 권장이지만 본 프로젝트는 **시연용 all-in-one** 컨테이너로 단순화하여 메모리 절약
- **사용 이미지**: `jaegertracing/all-in-one:2.17.0`
  ```yaml
  # observability/jaeger/jaeger.yaml
  image: jaegertracing/all-in-one:2.17.0
  env:
    - name: COLLECTOR_OTLP_ENABLED
      value: "true"
  ```

## 8. Trivy — `aquasec/trivy:0.70.0` Docker image (GHA action wrapper 미사용)

- **출처**: [Releases · aquasecurity/trivy](https://github.com/aquasecurity/trivy/releases)
- **보안 이력 (중요)**:
  - **2026-03-19**: `aquasecurity/trivy-action` 공급망 사건. 태그 `0.0.1`~`0.34.2` 12시간 동안 credential stealer 주입.
  - **2026 추가**: trivy CLI 의 `v0.69.4` 악성 릴리스 사건도 발생.
- **본 프로젝트의 결정 — action wrapper 자체 회피**:
  - 첫 시도: `aquasecurity/trivy-action@0.36.0` 핀했으나 그 태그가 실재하지 않아 CI 실패
  - 사후 분석: action 의 모든 기존 태그가 force-push 영향권. SHA 핀해도 검증 부담
  - **결정**: GHA 에서 `docker run --rm aquasec/trivy:0.70.0 image ...` 로 공식 CLI 직접 호출.
    Wrapper 제거 → 공급망 표면 축소, image tag 는 immutable, 호출 형태 명시적
  - 자세한 경위: `docs/troubleshooting/2026-05-04-ci-trivy-action-version-and-slack-payload.md`

## 9. Helm — `v3.20.x`

- **출처**: [Releases · helm/helm](https://github.com/helm/helm/releases), [Helm 4 Released](https://helm.sh/blog/helm-4-released/)
- **선정 근거**:
  - Helm 4는 출시 직후 (2026 출시), 베타 영역. 회피.
  - Helm 3은 버그 픽스 2026-07-08까지, 보안 픽스 2026-11-11까지 지원 → 본 프로젝트 작업 기간 안전
  - 3.21.0은 2026-05-13 출시 예정 → 현재(2026-05-03)는 3.20.x가 최신
- **설치**:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  helm version  # v3.20.x ...
  ```

## 10. Python — `3.13-slim-bookworm` (베이스 이미지)

- **출처**: [Status of Python versions](https://devguide.python.org/versions/), [python.org Downloads](https://www.python.org/downloads/)
- **선정 근거**:
  - 2026-04-07: 3.13.13 maintenance release
  - Python 3.14는 stable (2025-10 출시)이지만 FastAPI 공식 권장 baseline은 3.12. 3.13이 안정성·생태계·성능 균형
  - Docker 베이스: `python:3.13-slim-bookworm` (slim → 이미지 크기 < 150MB)
- **Dockerfile 예시**:
  ```dockerfile
  FROM python:3.13-slim-bookworm AS builder
  ...
  FROM python:3.13-slim-bookworm AS runtime
  ```

## 11. FastAPI — `0.136.1`

- **출처**: [Releases · fastapi/fastapi](https://github.com/fastapi/fastapi/releases), [fastapi · PyPI](https://pypi.org/project/fastapi/)
- **선정 근거**: 2026-04-23 릴리스, 2026 메인스트림. Netflix·Uber 등 프로덕션 사용. Python 3.10+ 호환.
- **requirements.txt**:
  ```text
  fastapi==0.136.1
  uvicorn[standard]==0.34.*
  asyncpg==0.30.*
  pydantic==2.*
  ```
  > Uvicorn은 0.34.x 시리즈가 2026년 stable. 마이너 패치는 자동 픽업하도록 `*` 사용.

## 12. PostgreSQL — `17.9`

- **출처**: [PostgreSQL Release Notes](https://www.postgresql.org/docs/release/), [PostgreSQL 18.3, 17.9, ... Released](https://www.postgresql.org/about/news/postgresql-183-179-1613-1517-and-1422-released-3246/)
- **선정 근거**:
  - 18은 출시 직후로 회피, 16은 17 등장으로 메인스트림 위치 약화
  - 17.9는 2026-02-26 패치 릴리스로 검증 충분
  - 5년 메이저 지원 정책에 따라 17은 2029까지 안전
- **이미지**: `postgres:17.9-alpine`
  ```yaml
  # charts/payment-platform/templates/postgres.yaml (StatefulSet 발췌)
  image: postgres:17.9-alpine
  ```

## 13. GitHub Actions Runner — `ubuntu-24.04`

- **출처**: [Ubuntu 24.04 - actions/runner-images](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
- **선정 근거**:
  - `ubuntu-latest` = `ubuntu-24.04` (2025-01-17부터)
  - `ubuntu-26.04`는 2026-04 출시로 GHA runner 미지원 → 회피
  - **`ubuntu-latest` 대신 `ubuntu-24.04`로 명시 핀**: 향후 GHA가 `ubuntu-latest`를 26.04로 전환할 때 빌드 깨짐 방지(재현성 확보)
- **워크플로 예시**:
  ```yaml
  jobs:
    build:
      runs-on: ubuntu-24.04
  ```

---

## 검증 절차 (변경 시 재실행)

본 표의 버전은 **분기 1회** 또는 **보안 사건 발생 시** 재검증한다. 절차:

```bash
# 1. 각 컴포넌트 최신 stable 확인
gh release list --repo kubernetes-sigs/kind --limit 5
gh release list --repo istio/istio --limit 5
gh release list --repo argoproj/argo-helm --limit 5
# ... 등등

# 2. 본 문서 갱신
# 3. CLAUDE.md C 섹션 체크리스트의 "버전 검증 일자" 갱신
```

---

## 참조 (Sources)

- [Releases · kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind/releases)
- [Kubernetes Releases](https://kubernetes.io/releases/)
- [Kubernetes endoflife](https://endoflife.date/kubernetes)
- [Istio Release Announcements](https://istio.io/latest/news/releases/)
- [argo-cd Helm chart on Artifact Hub](https://artifacthub.io/packages/helm/argo/argo-cd)
- [kube-prometheus-stack on Artifact Hub](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack)
- [Kiali Release Notes](https://kiali.io/news/release-notes/)
- [Jaeger Releases](https://github.com/jaegertracing/jaeger/releases)
- [Releases · aquasecurity/trivy](https://github.com/aquasecurity/trivy/releases)
- [Trivy Compromised - StepSecurity](https://www.stepsecurity.io/blog/trivy-compromised-a-second-time---malicious-v0-69-4-release)
- [Releases · helm/helm](https://github.com/helm/helm/releases)
- [Status of Python versions](https://devguide.python.org/versions/)
- [FastAPI Releases](https://github.com/fastapi/fastapi/releases)
- [PostgreSQL 18.3, 17.9, ... Released](https://www.postgresql.org/about/news/postgresql-183-179-1613-1517-and-1422-released-3246/)
- [Ubuntu 24.04 runner image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
