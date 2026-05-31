# Kiali 설치 가이드 (EPIC 6 Task 6.7)

본 가이드는 본 프로젝트의 kind 클러스터에 **Kiali 2.21.0** 을 설치하고 서비스 메시 토폴로지 +
mTLS 자물쇠 + Canary 트래픽 분배를 시각적으로 캡처하는 절차다.

## 0. 사전 조건

| 항목 | 확인 |
|---|---|
| Istio 1.29.2 설치 + 사이드카 정상 (EPIC 6 § 1-4 완료) | `istioctl proxy-status` 가 모든 사이드카 SYNCED |
| Canary 매니페스트 적용 (Task 6.4-6.5) | `kubectl -n payment-dev get vs,dr` 가 transfer 둘 다 보임 |
| mTLS STRICT (Task 6.6) | `kubectl get peerauthentications -A` 가 payment-dev/prod 양쪽 보임 |
| 호스트 가용 메모리 | 최소 **1.5 GiB** 추가 여유 (Kiali ~200 MiB + Prometheus ~300 MiB + 시연 트래픽 부하 헤드룸) |

호스트 메모리가 부족하면 `docs/setup/istio-install.md` § 7 (메모리 부족 대응) 참고.

## 1. 설치 흐름 — 두 단계

본 EPIC 6 의 시연을 위해 **(1) lightweight Prometheus** 를 먼저 띄우고 그 위에 **(2) Kiali** 를
설치한다.

| 단계 | 컴포넌트 | 메모리 (idle) | 출처 |
|---|---|---|---|
| 1 | Prometheus (Istio sample, 1 replica) | ~300 MiB | `istio-1.29.2/samples/addons/prometheus.yaml` |
| 2 | Kiali Server (helm) | ~200 MiB | `kiali/kiali-server` chart |

> **EPIC 7 으로의 전환 메모**: EPIC 7 의 Task 7.1 이 본 Prometheus 를 `kube-prometheus-stack`
> (Grafana + AlertManager 포함) 으로 교체한다. 본 EPIC 6 의 Prometheus 는 임시 설치이고, EPIC 7
> 진입 시점에 `kubectl delete -f istio-1.29.2/samples/addons/prometheus.yaml` 로 정리 후 본격 stack 설치.

## 2. Prometheus 임시 설치 (Istio sample addon)

Istio 의 공식 sample addon 묶음은 mesh 메트릭 수집에 최적화된 minimal Prometheus 설정을 그대로
제공한다. 본 시연용으로 충분하다.

```bash
# Istio install 시 다운받아 둔 디렉토리 안의 sample 사용
kubectl apply -f ~/istio-1.29.2/samples/addons/prometheus.yaml

# 또는 release 에서 직접
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/prometheus.yaml
```

**검증**:

```bash
kubectl -n istio-system get pods -l app=prometheus
```

기대 출력:

```
NAME                          READY   STATUS    RESTARTS   AGE
prometheus-xxxxxxxxxxx-xxxxx  2/2     Running   0          1m
```

`READY 2/2` — Prometheus 컨테이너 + 사이드카... 가 아니다. istio-system 은 사이드카 미주입이고,
Prometheus sample 매니페스트가 자체적으로 `configmap-reload` 라는 보조 컨테이너를 같이 띄워 2/2.

Prometheus 의 service 가 떴는지도 확인:

```bash
kubectl -n istio-system get svc prometheus
```

기대: ClusterIP 가 부여된 `prometheus` Service 가 9090 포트로 노출.

## 3. Kiali Helm chart 설치

### 3-1. Helm repo 추가

```bash
helm repo add kiali https://kiali.org/helm-charts
helm repo update
```

### 3-2. 본 프로젝트의 values 로 설치

```bash
helm upgrade --install kiali-server kiali/kiali-server \
  --version 2.21.0 \
  --namespace istio-system \
  -f observability/kiali/values.yaml \
  --wait --timeout 5m
```

**기대 종료**:

```
NAME: kiali-server
LAST DEPLOYED: ...
NAMESPACE: istio-system
STATUS: deployed
```

소요 시간: 약 1-2 분.

### 3-3. 설치 검증

```bash
kubectl -n istio-system get pods -l app=kiali
```

기대:

```
NAME                            READY   STATUS    RESTARTS   AGE
kiali-xxxxxxxxxxx-xxxxx         1/1     Running   0          1m
```

## 4. UI 접근

kind 의 외부 노출 layer 없이 `kubectl port-forward` 로 접근한다.

```bash
kubectl -n istio-system port-forward svc/kiali 20001:20001
```

브라우저에서 다음 URL 로 접근:

```
http://localhost:20001/kiali
```

`anonymous` 인증 모드라 로그인 화면 없이 바로 dashboard 로 진입.

## 5. 시연 항목 — 캡처 대상

### 5-1. 토폴로지 + mTLS 자물쇠

UI 좌측 메뉴 → **Graph** 클릭. 다음 옵션 선택:

| 옵션 | 값 |
|---|---|
| Namespace | `payment-dev` |
| Graph Type | `Service graph` |
| Display | `Traffic Animation` (선택 가능, 그래프가 움직여 보임) |
| Edge Labels | `Security` (자물쇠 아이콘 표시 활성) |

기대 화면 — `transfer → notification` 같은 엣지 위에 **자물쇠 아이콘 🔒** 이 표시됨. 본 시연
화면을 캡처 → `docs/screenshots/kiali-mtls-lock.png` 로 저장.

### 5-2. Canary 트래픽 분배 시각화

Task 6.4-6.5 의 시연 트래픽이 흐르는 동안 같은 Graph 화면을 본다.

먼저 시연 트래픽을 일정 시간 (예: 30 초) 발생:

```bash
# 별도 터미널에서 트래픽 계속 발생
while true; do
  ./istio/canary/scripts/test-traffic-split.sh 10 >/dev/null 2>&1
  sleep 1
done
```

Kiali UI 의 Graph 에서 `transfer` 노드를 클릭하면 우측 패널에 트래픽 통계 표시. 이 패널의
**Workloads** 탭에서 stable / canary 두 workload 가 모두 보여야 한다. 각 workload 의 traffic
percentage 가 표시되며, VirtualService 의 weight (80/20 등) 와 일치해야 함.

캡처 → `docs/screenshots/kiali-canary-split.png`.

### 5-3. 정책 화면 — PeerAuthentication 확인

좌측 메뉴 → **Istio Config** → namespace 를 `payment-dev` 로 좁힘. 목록에서
`PeerAuthentication / default` 클릭. 우측 화면에서 `mtls.mode: STRICT` 가 표시됨.

캡처 → `docs/screenshots/kiali-peerauth-strict.png`.

## 6. 흔한 오류와 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| Graph 가 회색 (트래픽 0) | Prometheus 가 아직 메트릭 수집 시작 안 함 | 1-2 분 기다린 뒤 새로고침. `./istio/canary/scripts/test-traffic-split.sh 100` 으로 트래픽 생성 |
| Graph 의 엣지에 자물쇠가 안 나옴 | Edge Labels 옵션에 Security 가 안 켜져 있음 | 그래프 상단의 Display 드롭다운에서 Security 체크 |
| 자물쇠가 부분만 보임 (`50% mTLS`) | 일부 트래픽이 평문 (예: K8s readiness probe) | 정상. probe 는 kubelet 의 평문 호출이라 사이드카 정책에서 제외됨. **서비스 간 트래픽** 만 보면 100% mTLS |
| Kiali pod 가 CrashLoopBackOff | Prometheus URL 이 안 맞거나 Prometheus 자체가 없음 | § 2 의 Prometheus 설치 다시 확인. `kubectl -n istio-system logs deploy/kiali` 로 에러 확인 |
| Helm install 후 5 분이 지나도 pod 가 Ready 안 됨 | 메모리 부족 → istio-system 의 다른 pod 가 OOMKilled | `kubectl -n istio-system top pods` 로 확인. EPIC 7 의 단계적 기동 순서 참조 |

## 7. 정리 (EPIC 6 종료 후 다음 EPIC 진입 전)

본 EPIC 6 가 끝나고 EPIC 7 (관측성 정식 스택) 으로 넘어가기 직전:

```bash
# Kiali 는 그대로 둠 (EPIC 7 에서도 사용)
# Prometheus 만 sample 버전 제거 → kube-prometheus-stack 으로 교체 준비
kubectl delete -f ~/istio-1.29.2/samples/addons/prometheus.yaml
```

이후 EPIC 7 의 Task 7.1 으로 진행.

## 8. 참고

- [Kiali Installation Guide (공식)](https://kiali.io/docs/installation/installation-guide/)
- [Kiali Helm Chart Repository](https://github.com/kiali/helm-charts)
- [Istio Kiali 통합 docs](https://istio.io/latest/docs/ops/integrations/kiali/)
- 본 프로젝트의 `docs/setup/istio-install.md` (EPIC 6 § 1-4)
- 본 프로젝트의 `istio/canary/README.md` (Task 6.4-6.5)
- 본 프로젝트의 `istio/peerauth-verify.md` (Task 6.6 검증)
