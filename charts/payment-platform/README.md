# Payment Platform Helm Chart

본 chart 는 EPIC 4 의 산출물로, 4 service (account / transfer / loan / notification) 와
공유 PostgreSQL StatefulSet 을 한 release 로 배포한다.

## 구조

```
charts/payment-platform/
├── Chart.yaml              메타데이터
├── values.yaml             기본값 (global / services / postgres)
├── values-dev.yaml         dev override (HPA off, replicas 1, slim resources)
├── values-prod.yaml        prod override (HPA on, replicas 2~10, beefier)
└── templates/
    ├── _helpers.tpl        name/labels/dbHost 헬퍼
    ├── deployment.yaml     range 로 4 Deployment 생성
    ├── service.yaml        range 로 4 Service 생성
    ├── configmap.yaml      range 로 4 ConfigMap 생성 (env 주입용)
    ├── hpa.yaml            global.hpa.enabled 시 4 HPA 생성
    └── postgres.yaml       Secret + ConfigMap + 2 Service + StatefulSet
```

## Quickstart

### Fresh install (kind cluster, dev)

```bash
helm install payment charts/payment-platform/ \
  -n payment-dev -f charts/payment-platform/values-dev.yaml

kubectl -n payment-dev wait --for=condition=ready pod/postgres-0 --timeout=180s
kubectl -n payment-dev get all
```

### 검증

```bash
# port-forward 로 service 의 /health 호출
kubectl -n payment-dev port-forward svc/account 8001:8000 &
curl -s localhost:8001/health         # {"status":"ok","service":"account"}
curl -s localhost:8001/health/ready   # {"status":"ready","service":"account"}
kill %1
```

## Task 1.4 → Helm 마이그레이션 (이 chart 도입 전 plain manifest 로 적용한 경우)

EPIC 1 단계에서 `kubectl apply -f charts/payment-platform/templates/postgres.yaml` 으로
postgres 를 띄운 적이 있다면, 그 리소스에는 Helm 의 ownership label/annotation 이 없다.
이 상태에서 `helm install` 을 시도하면 다음 에러가 발생한다:

```
Error: ... exists and cannot be imported into the current release:
invalid ownership metadata; missing key "app.kubernetes.io/managed-by"
```

마이그레이션 스크립트가 이를 자동 처리한다:

```bash
# clean: 기존 리소스 삭제 후 fresh install (postgres 데이터 손실)
./scripts/migrate-to-helm.sh

# adopt: --take-ownership 으로 기존 리소스 흡수 (데이터 보존, Helm 3.13+ 필요)
MODE=adopt ./scripts/migrate-to-helm.sh
```

자세한 경위와 함정 회피는 [`docs/troubleshooting/2026-05-04-helm-install-blocked-by-task1-4-resources.md`](../../docs/troubleshooting/2026-05-04-helm-install-blocked-by-task1-4-resources.md) 참조.

## values.yaml 의 주요 설정

`global` 아래의 공통 baseline 과 `services.<name>` 아래의 service 별 차이로 구성. 자세한 설명은 `values.yaml` 의 인라인 주석 참조.

| 영역 | 의미 |
|---|---|
| `global.imageRegistry` / `global.imageTag` | 4 service 공통 image prefix + tag |
| `global.replicaCount` | HPA off 일 때 사용. on 이면 HPA 가 관리 |
| `global.resources` | requests/limits |
| `global.rollingUpdate` | maxSurge=1 / maxUnavailable=0 (R-B3-M3) |
| `global.probes.{liveness,readiness}` | main.py 의 /health, /health/ready |
| `global.hpa.enabled` | values-dev=false, values-prod=true |
| `services.<name>.domainAction` | POST /<action> 라우트 |
| `services.<name>.db` | DATABASE_URL 의 dbname |
| `services.<name>.notificationUrl` | "from-template" 이면 cluster DNS 자동 합성, 아니면 그대로 |
| `postgres.databases` | init.sql 이 만들 DB 목록 |

## 검증 도구 — 변경 전후 항상 실행

```bash
# 1) Helm chart 정합성
helm lint charts/payment-platform/

# 2) Render → schema 검증 (kubeconform)
helm template payment charts/payment-platform/ -n payment-dev -f charts/payment-platform/values-dev.yaml \
  | kubeconform -summary -kubernetes-version 1.33.0

# 3) 같은 render 에 yamllint key-duplicates 적용 (실수로 같은 키 두 번 출력하지 않게)
helm template payment charts/payment-platform/ -n payment-dev -f charts/payment-platform/values-dev.yaml \
  | yamllint -d "{rules: {key-duplicates: enable, line-length: disable, document-start: disable, comments-indentation: disable, indentation: disable, empty-lines: disable, trailing-spaces: disable, comments: disable, truthy: disable, brackets: disable, new-line-at-end-of-file: disable}}" -

# 4) (가능하면) 실제 cluster 에 dry-run
helm template payment charts/payment-platform/ -n payment-dev -f charts/payment-platform/values-dev.yaml \
  | kubectl apply --dry-run=server -f -
```
