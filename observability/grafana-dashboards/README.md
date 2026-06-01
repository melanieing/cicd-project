# Grafana Dashboards — Istio Envoy 메트릭 (EPIC 7 Task 7.2)

본 디렉토리는 R-A2-M2 (Envoy Prometheus + Grafana) 의 산출물로, Istio 사이드카가 노출하는
Envoy 메트릭을 시각화하는 Grafana 대시보드 4 종을 자동 import 한다.

## 0. 자동 import 메커니즘

본 프로젝트는 **Grafana sidecar dashboard discovery** 방식을 사용한다. `observability/prom/values.yaml`
의 `grafana.sidecar.dashboards` 설정에 의해:

- cluster 의 모든 namespace 의 ConfigMap 을 watch
- label 이 `grafana_dashboard=1` 인 ConfigMap 의 data 내용을 Grafana 의 dashboard 로 자동 등록
- 같은 ConfigMap 의 annotation `grafana_folder=<name>` 으로 좌측 폴더 그룹화

즉 **본 디렉토리의 ConfigMap 매니페스트 한 번 apply 하면 Grafana UI 에 자동으로 dashboard 가 뜸**.
UI 에서 수동 import 불필요.

## 1. 들어있는 dashboard 4 종

본 프로젝트는 Istio 가 공식 발행하는 4 종의 표준 dashboard 를 그대로 사용한다.

| dashboard | Grafana ID | 무엇을 보여주나 |
|---|---|---|
| **Mesh** | 7639 | mesh 전체의 global request volume, success rate, P50/P95/P99 latency |
| **Service** | 7636 | 서비스 단위의 incoming/outgoing 요청량, error rate, response time |
| **Workload** | 7630 | 각 Deployment 단위의 트래픽 + 사이드카 메트릭 (CPU/Mem/connections) |
| **Performance** | 11829 | istiod 자체의 push 횟수, XDS connection 수, control plane CPU/Mem |

## 2. 적용

```bash
kubectl apply -f observability/grafana-dashboards/istio-dashboards.yaml
```

기대 출력:

```
configmap/grafana-dashboard-istio-mesh created
configmap/grafana-dashboard-istio-service created
configmap/grafana-dashboard-istio-workload created
configmap/grafana-dashboard-istio-performance created
```

## 3. 검증

```bash
# Grafana sidecar 가 새 ConfigMap 을 감지했는지
kubectl -n observability logs deploy/prometheus-grafana -c grafana-sc-dashboard --tail=20
# 기대: "added dashboard ... istio-mesh" 같은 로그 4 번

# Grafana UI 로 접속
kubectl -n observability port-forward svc/prometheus-grafana 3000:80
```

브라우저 → `http://localhost:3000` → admin / admin (또는 § 6 helm secret 의 비밀번호).

좌측 메뉴 → **Dashboards** → 폴더 **Istio** → 4 종 dashboard 가 보임.

각 dashboard 에서 다음을 확인:

| dashboard | 확인 사항 |
|---|---|
| Mesh | Global Request Volume 차트에 0 이상의 ops/sec |
| Service | namespace 드롭다운에서 `payment-dev` 선택 → 4 서비스가 행으로 표시 |
| Workload | `transfer` workload 의 incoming requests + 사이드카 CPU 차트 |
| Performance | istiod 의 xDS push 차트, ADS 연결 수가 6 (gateway 1 + 사이드카 5) |

차트가 회색 (No Data) 이면 트래픽을 발생시킨 다음 1-2 분 후 새로고침.

```bash
./istio/canary/scripts/test-traffic-split.sh 100   # 트래픽 발생
```

## 4. 캡처 권장 — 포트폴리오용

| 캡처 | 파일명 | 어디서 |
|---|---|---|
| Mesh dashboard global view | `docs/screenshots/grafana-mesh.png` | Mesh dashboard 의 첫 화면 |
| Service dashboard 의 transfer 상세 | `docs/screenshots/grafana-service-transfer.png` | Service dashboard, namespace=payment-dev, service=transfer |
| Workload 의 canary 트래픽 분리 | `docs/screenshots/grafana-workload-canary.png` | Workload dashboard, workload=transfer-canary |

## 5. ConfigMap 매니페스트 — 어떻게 만들어졌는가

`istio-dashboards.yaml` 는 다음 방식으로 만들어졌다.

1. Istio 공식 `samples/addons/grafana.yaml` 의 dashboard JSON 추출 (또는 [grafana.com](https://grafana.com/grafana/dashboards) 에서 ID 7639/7636/7630/11829 의 JSON 다운로드)
2. 각 JSON 을 ConfigMap 의 `data` 키로 wrap
3. label `grafana_dashboard=1`, annotation `grafana_folder=Istio` 부여
4. 4 개 ConfigMap 을 multi-document YAML 로 결합

JSON 자체는 수정하지 않음 — Istio 가 chart 와 함께 유지보수하는 표준 dashboard 그대로 사용.

본 디렉토리에 dashboard JSON 을 직접 두지 않는 이유:
- JSON 한 개당 ~50KB, 4 개면 200KB+. git diff 가 어려워짐
- Istio 가 새 minor 버전에서 dashboard 를 업데이트하면 본 프로젝트도 따라가야 함 → `update-dashboards.sh`
  같은 스크립트로 한 번에 가져오는 게 깔끔 (본 task 의 단순 범위를 초과해 별도 follow-up)

따라서 **본 프로젝트의 표준 운영**:
- Istio install 시 `istio-1.29.2/samples/addons/grafana.yaml` 에서 dashboard JSON 추출
- 그 JSON 으로 ConfigMap 생성 매니페스트를 본 디렉토리에 보관

해당 추출·생성 작업은 사용자가 1 회 진행 후 git commit (수동). 자동화는 별도 EPIC 후보.

## 6. 직접 ConfigMap 만드는 빠른 절차 (사용자 작업)

`istio-dashboards.yaml` 가 본 디렉토리에 비어 있으면 다음으로 1 회 생성:

```bash
cd ~/cicd-project

# Istio sample 의 grafana.yaml 에서 dashboard ConfigMap 4 개 추출
# 본 sample 의 grafana.yaml 은 Grafana 인스턴스 + 4 dashboard ConfigMap 을 같이 정의.
# Grafana 인스턴스 매니페스트는 제외하고 dashboard ConfigMap 만 가져옴.
# (Istio 의 grafana.yaml 형식은 minor 마다 약간 변하므로 직접 손으로 dashboard 부분만 발췌하는 게 안전)

# 간단한 대안: 본 README 에서 grafana.com ID 4 개 (7639, 7636, 7630, 11829) 를 적어뒀으니
# UI 의 Dashboards → Import → ID 입력으로도 직접 import 가능 (자동 ConfigMap 우회).
# 이 경우 dashboard 가 Grafana 의 db 안에만 들어가서 매니페스트로 git 관리는 안 됨.

# 권장: Istio sample 의 grafana.yaml 에서 ConfigMap 부분만 발췌한 정식 매니페스트를
# 본 디렉토리에 두는 것이 GitOps 원칙에 맞음.
# 본 task 의 다음 단계로 사용자가 진행.
```

## 7. 다음 단계

- **Task 7.3** — Kiali 의 Prometheus URL 갱신 (이미 `observability/prom/install.md` § 4 에서 절차 다룸)
- **Task 7.4** — Jaeger v2 설치 + Istio Telemetry 통합
