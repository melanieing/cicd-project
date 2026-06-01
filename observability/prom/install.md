# kube-prometheus-stack 설치 가이드 (EPIC 7 Task 7.1)

본 가이드는 본 프로젝트의 kind 클러스터에 **kube-prometheus-stack 86.x** 를 설치하고,
EPIC 6.7 에서 임시로 띄웠던 sample Prometheus 를 정식 stack 으로 **무중단에 가깝게 교체** 하는
절차다.

## 0. 사전 조건

| 항목 | 확인 |
|---|---|
| EPIC 6 의 Istio + 사이드카 정상 | `istioctl proxy-status` 가 6 행 모두 SYNCED |
| EPIC 6.7 의 sample Prometheus + Kiali 가 떠있음 | `kubectl -n istio-system get pod \| grep -E "prometheus\|kiali"` |
| `observability` namespace 존재 | `kubectl get ns observability` (없으면 chart 가 `--create-namespace` 로 생성) |
| 호스트 가용 메모리 | 추가 **1.5 GiB** 이상 (Prometheus 700 MiB + Grafana 200 MiB + node-exporter 150 MiB + Alertmanager 50 MiB + kube-state-metrics 100 MiB + 헤드룸) |

호스트 메모리가 부족하면 `docs/setup/istio-install.md` § 7 (메모리 부족 대응) 참고.

## 1. Sample Prometheus 정리 (cutover 1 단계)

EPIC 6.7 에서 띄운 Istio sample Prometheus 를 먼저 제거. 같은 ServiceMonitor 자동 발견 메커니즘으로
새 stack 이 같은 메트릭을 수집하므로 메트릭 데이터의 종류는 변하지 않음 (히스토리는 끊김 — sample 의
PVC 없음, 새 stack 부터 5 일 보존).

```bash
kubectl delete -f ~/istio-1.29.2/samples/addons/prometheus.yaml
# 또는
# kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/prometheus.yaml
```

기대 출력:

```
service "prometheus" deleted
deployment.apps "prometheus" deleted
configmap "prometheus" deleted
serviceaccount "prometheus" deleted
clusterrole.rbac.authorization.k8s.io "prometheus" deleted
clusterrolebinding.rbac.authorization.k8s.io "prometheus" deleted
```

## 2. Helm repo + 설치

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# (선택) 최신 chart 버전 확인
helm search repo prometheus-community/kube-prometheus-stack | head -3
# 본 가이드는 86.0.0 을 기준으로 함. 더 최신이 보이면 그것을 써도 됨 (minor 호환).

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --version 86.0.0 \
  --namespace observability \
  --create-namespace \
  -f observability/prom/values.yaml \
  --wait --timeout 10m
```

소요 시간: 약 3-5 분 (CRD 설치 + 6 컴포넌트 ready 대기).

기대 종료:

```
NAME: prometheus
LAST DEPLOYED: ...
NAMESPACE: observability
STATUS: deployed
```

## 3. 설치 검증

### 3-1. 모든 pod 가 Running

```bash
kubectl -n observability get pods
```

기대:

```
NAME                                                     READY   STATUS    AGE
alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2     Running   2m
prometheus-grafana-xxxxxxxxxx-xxxxx                      3/3     Running   2m
prometheus-kube-prometheus-operator-xxxxxxxxxx-xxxxx     1/1     Running   2m
prometheus-kube-state-metrics-xxxxxxxxxx-xxxxx           1/1     Running   2m
prometheus-prometheus-kube-prometheus-prometheus-0       2/2     Running   2m
prometheus-prometheus-node-exporter-xxxxx                1/1     Running   2m  ← DaemonSet × N nodes
prometheus-prometheus-node-exporter-xxxxx                1/1     Running   2m
prometheus-prometheus-node-exporter-xxxxx                1/1     Running   2m
```

### 3-2. CRD 등록 확인

```bash
kubectl get crd | grep monitoring.coreos.com
```

기대 (8 개):

```
alertmanagerconfigs.monitoring.coreos.com
alertmanagers.monitoring.coreos.com
podmonitors.monitoring.coreos.com
probes.monitoring.coreos.com
prometheuses.monitoring.coreos.com
prometheusrules.monitoring.coreos.com
servicemonitors.monitoring.coreos.com
thanosrulers.monitoring.coreos.com
```

### 3-3. Prometheus UI 로 Istio targets 정상 수집 확인

```bash
kubectl -n observability port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
```

브라우저 → `http://localhost:9090/targets`

기대 — `Status: UP` 행에 다음 job 들이 있어야 함:

| Job | 의미 |
|---|---|
| `istiod` | Istio 컨트롤 플레인 (xDS 푸시 횟수, 워크로드 카운트 등) |
| `envoy-stats` 또는 `istio-proxy` | 사이드카가 노출한 트래픽 메트릭 (`istio_requests_total` 등) |
| `kubernetes-pods` | 일반 pod 메트릭 |
| `node-exporter` | 노드 OS 메트릭 |

Istio job 이 안 보이면 § 6 트러블슈팅 참조.

### 3-4. 핵심 Istio 메트릭이 실제 들어오는지

같은 UI 의 **Graph** 탭에서 다음 쿼리:

```promql
istio_requests_total
```

기대: payment-dev 의 4 서비스 간 호출 (transfer → notification 등) 의 카운트가 시간순으로 증가.
값이 0 이거나 메트릭 자체가 없으면 사이드카 → Prometheus 의 scrape path 점검.

## 4. Kiali 의 Prometheus URL 갱신 (cutover 2 단계)

EPIC 6.7 의 Kiali 는 sample Prometheus (`http://prometheus.istio-system:9090`) 를 가리키고 있다.
새 stack 의 service 로 재가리킴:

```bash
helm upgrade --install kiali-server kiali/kiali-server \
  --version 2.21.0 \
  --namespace istio-system \
  -f observability/kiali/values.yaml \
  --set external_services.prometheus.url="http://prometheus-kube-prometheus-prometheus.observability:9090" \
  --wait --timeout 5m
```

또는 `observability/kiali/values.yaml` 의 `external_services.prometheus.url` 을 위 URL 로 갱신한 뒤
`--set` 없이 helm upgrade. (영구 변경하려면 이 쪽이 더 깔끔 — git PR 로 관리)

### 검증

```bash
kubectl -n istio-system rollout status deploy/kiali --timeout=2m
# Kiali pod 가 새 URL 로 재기동 후 ready 가 됐는지

kubectl -n istio-system port-forward svc/kiali 20001:20001
```

브라우저 → `http://localhost:20001/kiali` → 좌측 **Graph** → namespace `payment-dev` 선택.
이제 트래픽이 새 Prometheus 에서 수집되어 그래프가 정상 표시되어야 함.

## 5. 정리 — 본 task 의 산출물

| 항목 | 위치 |
|---|---|
| Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics | `observability` namespace |
| 본 chart 의 override values | `observability/prom/values.yaml` |
| 본 설치 가이드 | 본 파일 (`observability/prom/install.md`) |
| Kiali 의 Prometheus URL 갱신 | `observability/kiali/values.yaml` (EPIC 6.7 파일을 § 4 절차로 update) |

## 6. 흔한 오류와 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| `helm install` 이 5 분 이상 hang | CRD 설치 + 6 컴포넌트 동시 기동 → 메모리 부족 | `kubectl -n observability get events` 로 OOMKilled / Pending 확인. § 0 의 메모리 헤드룸 점검 |
| Prometheus UI 의 `/targets` 에 istio job 부재 | Istio install 이 자체 ServiceMonitor 를 안 만든 환경 | Istio sample 에 있는 `samples/addons/extras/prometheus-operator.yaml` 의 ServiceMonitor 를 추가 apply |
| Prometheus pod 가 `Pending` 으로 멈춤 | PVC 가 storageClass 미할당 → kind 의 default storageClass 확인 | `kubectl get storageclass` 로 `(default)` 표시된 게 있는지. 없으면 `kubectl patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'` |
| Grafana 로그인 안 됨 | 비밀번호 잘못 (chart 가 random 생성) | `kubectl -n observability get secret prometheus-grafana -o jsonpath='{.data.admin-password}' \| base64 -d` 로 실제 값 확인 |
| Kiali 가 새 Prom URL 로 안 가리킴 | `helm upgrade` 시 `-f` 만 쓰고 `--set` 안 함 → values.yaml 안의 옛 URL 그대로 | `values.yaml` 직접 수정 + helm upgrade, 또는 `--set` 으로 한 번 더 override |

## 7. 다음 단계

본 § 3 의 4 단계 검증이 통과하면 다음 task 로 진행:

- **Task 7.2** — Grafana 의 Istio Envoy dashboard import (`observability/grafana-dashboards/`)
- **Task 7.4** — Jaeger v2 + Istio Telemetry 통합

## 8. 참고

- [kube-prometheus-stack chart README](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md)
- [Istio Prometheus 통합 docs](https://istio.io/latest/docs/ops/integrations/prometheus/)
- 본 프로젝트의 `observability/kiali/install.md` (EPIC 6.7 의 sample Prometheus 설치 + 본 가이드로의 교체 흐름)
