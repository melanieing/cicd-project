# NetworkPolicy 차단/허용 매트릭스 (EPIC 8 Task 8.7)

본 문서는 `manifests/networkpolicy.yaml` 의 정책이 의도한 대로 동작함을 9 개 시나리오로 검증한다.
R-A3-O3 의 산출물.

## 0. 사전 조건

| 항목 | 확인 |
|---|---|
| CNI 가 NetworkPolicy 지원 | `kubectl get pods -n kube-system \| grep -E "calico\|cilium"` (kindnet 은 미지원 — § 6 의 마이그레이션) |
| `manifests/networkpolicy.yaml` 적용됨 | `kubectl -n payment-dev get networkpolicy` 가 8 개 정책 표시 |
| 4 서비스 + postgres 가 READY | `kubectl -n payment-dev get pods` |
| EPIC 7 의 observability 정상 | `kubectl -n observability get pods` |

## 1. 매트릭스 — 허용되어야 할 통신 (✅)

| # | from | to | port | 정책 근거 | 검증 명령 |
|---|---|---|---|---|---|
| 1 | payment-dev 의 transfer | payment-dev 의 notification | 8000/TCP | allow-intra-namespace | (§ 2-1) |
| 2 | payment-dev 의 transfer | payment-dev 의 postgres | 5432/TCP | allow-intra-namespace | (§ 2-2) |
| 3 | istio-system 의 ingressgateway | payment-dev 의 transfer | 8000/TCP | allow-from-istio-system | (§ 2-3) |
| 4 | observability 의 prometheus | payment-dev 의 사이드카 (15090) | 15090/TCP | allow-from-observability | (§ 2-4) |
| 5 | payment-dev 의 사이드카 | istio-system 의 istiod | 15012/TCP | allow-egress-to-istio-system | (§ 2-5) |
| 6 | payment-dev 의 사이드카 | observability 의 jaeger-collector | 4317/TCP | allow-egress-to-observability | (§ 2-6) |
| 7 | payment-dev 의 어느 pod | kube-system 의 CoreDNS | 53/UDP | allow-egress-dns | (§ 2-7) |

## 2. 매트릭스 — 차단되어야 할 통신 (❌)

| # | from | to | port | 차단 근거 | 검증 명령 |
|---|---|---|---|---|---|
| 8 | default ns 의 임의 pod | payment-dev 의 transfer | 8000/TCP | default-deny + default ns 에 allow 없음 | (§ 3-1) |
| 9 | payment-dev 의 사이드카 | 외부 임의 IP (예: 8.8.8.8) | 80/TCP | egress 화이트리스트에 외부 IP 없음 | (§ 3-2) |

본 두 시나리오가 차단되어야 정책이 진짜로 작동함이 입증된다.

## 3. 시나리오별 명령

### 2-1. payment-dev intra-namespace (✅)

```bash
kubectl -n payment-dev exec deploy/transfer -c transfer -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 \
  http://notification:8000/health
# 기대: 200
```

### 2-2. payment-dev → postgres (✅)

```bash
# transfer 가 postgres 5432 에 TCP connect 가능한지
kubectl -n payment-dev exec deploy/transfer -c transfer -- \
  python3 -c "
import socket
s = socket.socket()
s.settimeout(3)
try:
  s.connect(('postgres', 5432))
  print('CONNECT OK')
except Exception as e:
  print('FAIL', e)
finally:
  s.close()
"
# 기대: CONNECT OK
```

### 2-3. istio-ingressgateway → transfer (✅)

```bash
# ingressgateway pod 에서 transfer 의 internal Service 호출
INGRESS=$(kubectl -n istio-system get pod -l app=istio-ingressgateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n istio-system exec "$INGRESS" -c istio-proxy -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 \
  http://transfer.payment-dev.svc.cluster.local:8000/health
# 기대: 200
```

### 2-4. prometheus → 사이드카 메트릭 (✅)

```bash
# Prometheus 의 /targets 페이지에서 직접 확인이 가장 빠름:
kubectl -n observability port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
# 브라우저 → http://localhost:9090/targets → istio-proxy / envoy-stats job 들이 UP 상태
```

### 2-5. 사이드카 → istiod (✅)

```bash
# istioctl proxy-status 가 모든 사이드카를 SYNCED 로 표시하면 본 통신은 정상
istioctl proxy-status | grep payment-dev
# 기대: 5 행 모두 SUBSCRIBED 가 채워져 있음 (xDS 통신 정상)
```

### 2-6. 사이드카 → Jaeger (✅)

```bash
# transfer 호출 후 Jaeger UI 에 trace 가 도착하는지
./istio/canary/scripts/test-traffic-split.sh 10 >/dev/null
sleep 5
kubectl -n observability port-forward svc/jaeger-query 16686:16686
# 브라우저 → http://localhost:16686 → Service=transfer.payment-dev → Find Traces
# 기대: 최근 1 분 내 trace 가 보임 (네트워크 막혔으면 trace 0)
```

### 2-7. DNS (✅)

```bash
kubectl -n payment-dev exec deploy/transfer -c transfer -- \
  nslookup notification.payment-dev.svc.cluster.local
# 기대: 정상적인 IP 반환. SERVFAIL 또는 timeout 이면 DNS 차단됨
```

### 3-1. default ns → payment-dev (❌)

```bash
kubectl -n default run netpol-test --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --command -- sh -c "
    curl -s -o /dev/null -w 'http_code=%{http_code} time=%{time_total}\n' \
      --max-time 5 http://transfer.payment-dev.svc.cluster.local:8000/health || \
    echo 'CONNECTION TIMED OUT — NetworkPolicy worked'
  "
# 기대: 'CONNECTION TIMED OUT — NetworkPolicy worked' 또는 http_code=000 + time≥5
```

> **주의**: § 3-1 의 결과가 `http_code=200` 이면 정책 적용 안 됨 — CNI 가 NetworkPolicy
> 미지원이거나 적용 누락. § 6 참조.

### 3-2. payment-dev → 외부 IP (❌)

```bash
# 8.8.8.8:80 같은 외부 IP 호출 → egress 화이트리스트에 없으므로 timeout
kubectl -n payment-dev exec deploy/transfer -c transfer -- \
  curl -s -o /dev/null -w 'http_code=%{http_code} time=%{time_total}\n' \
  --max-time 5 http://8.8.8.8:80/ || echo "EXTERNAL EGRESS BLOCKED"
# 기대: EXTERNAL EGRESS BLOCKED 또는 http_code=000 + time≥5
```

## 4. 매트릭스 시각화 (캡처 권장)

위 9 개 시나리오의 결과를 한 표로 정리해 캡처 → `docs/screenshots/netpol-matrix.png` 로 저장.

| # | 시나리오 | 기대 | 실제 결과 (사용자 채움) |
|---|---|---|---|
| 1 | intra-ns transfer→notification | 200 | `<TBD>` |
| 2 | transfer → postgres:5432 | CONNECT OK | `<TBD>` |
| 3 | ingress → transfer | 200 | `<TBD>` |
| 4 | Prometheus targets UP | 7 jobs | `<TBD>` |
| 5 | istioctl proxy-status | 모두 SYNCED | `<TBD>` |
| 6 | Jaeger trace 도착 | 1+ traces | `<TBD>` |
| 7 | DNS lookup | IP 반환 | `<TBD>` |
| 8 | default → payment-dev | TIMEOUT | `<TBD>` |
| 9 | payment-dev → 8.8.8.8 | TIMEOUT | `<TBD>` |

## 5. 흔한 함정

| 증상 | 원인 | 해결 |
|---|---|---|
| § 3-1 이 200 으로 통과 | CNI 가 NetworkPolicy 미지원 (kindnet) | § 6 의 Calico/Cilium 마이그레이션 |
| § 2-3 (ingress→service) 가 timeout | allow-from-istio-system 정책의 매칭 실패. ingressgateway namespace label 점검 | `kubectl get ns istio-system --show-labels` 에 `name=istio-system` 있는지 |
| § 2-5 의 proxy-status 가 STALE | 사이드카 → istiod 의 15012 차단 (egress 누락) | allow-egress-to-istio-system 정책이 apply 됐는지 |
| § 2-7 의 DNS 가 timeout | egress DNS 정책의 namespaceSelector mismatch | `kubectl get ns kube-system --show-labels` 에 `name=kube-system` 있는지. kind 기본은 없음 — `kubectl label ns kube-system name=kube-system` 으로 추가 |
| 모든 정책 무시되는 듯 | NetworkPolicy CRD 자체는 적용되지만 CNI 가 enforce 안 함 | `kubectl get pods -n kube-system \| grep cni` 로 CNI 확인 |

## 6. kindnet → Calico CNI 마이그레이션 (사전 필요)

kind 의 default CNI 인 kindnet 은 NetworkPolicy 를 **렌더링만 하고 enforce 안 함**. 본 시연을 위해
한 번 cluster 를 재생성 필요.

```bash
# 1. 기존 cluster 백업 / 데이터 export (필요 시)
kubectl get all -A -o yaml > /tmp/cluster-backup.yaml

# 2. cluster 삭제
kind delete cluster --name payment

# 3. kindnet 비활성화 + 새 cluster
cat > /tmp/kind-config-calico.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true        # kindnet 비활성
  podSubnet: "192.168.0.0/16"    # Calico default
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
kind create cluster --name payment --config /tmp/kind-config-calico.yaml

# 4. Calico 설치
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/calico.yaml

# 5. CoreDNS / Calico ready 까지 대기
kubectl -n kube-system wait pod --all --for=condition=Ready --timeout=5m

# 6. namespace 라벨 재부여 (cluster 재생성으로 다 날아감)
kubectl apply -f manifests/namespaces.yaml

# 7. ArgoCD / Istio / Helm chart 등 EPIC 0~5 전체 재설치
./scripts/bootstrap.sh
# ... 이하 docs/setup/argocd/install.md, docs/setup/istio-install.md, ...
```

본 마이그레이션은 약 30 분 작업이라 EPIC 8.1 진입 시점에 별도 결정 필요.
**현 데모 환경에서는 (kindnet 유지) NetworkPolicy 매니페스트만 적용 + 정책 자체 검증은 시연 캡처로 갈음** 도 가능.

## 7. 본 매트릭스의 포트폴리오 가치

채용 면접에서 "보안 정책을 어떻게 검증하셨나요?" 에 대한 답:

- "9 시나리오 매트릭스로 허용 7 + 차단 2 를 각각 명시적 명령으로 검증했고, 결과를 표로 정리했습니다."
- "단순 정책 작성에서 끝나지 않고 enforce 가 작동하는 CNI (Calico) 까지 갖춰 실제 동작을 입증했습니다."
- "허용해야 하는 cross-namespace 통신 (사이드카↔istiod, Prom scrape, Jaeger OTLP) 의 의존성을 사전에 매핑한 뒤 정책을 설계해, 사이드 효과로 mesh 가 망가지지 않게 했습니다."
