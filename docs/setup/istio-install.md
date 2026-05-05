# Istio 1.29.2 설치 + 사이드카 자동 주입 (Tasks 6.2, 6.3)

본 가이드는 kind 단일 노드 클러스터 위에 **Istio 1.29.2** 컨트롤 플레인을 올리고,
`payment-dev` / `payment-prod` 두 namespace 에 사이드카 (Envoy proxy) 자동 주입을
활성화하는 절차다. 본 절차의 마지막 검증을 통과하면 EPIC 6 의 다음 단계
(Task 6.4 — Canary 매니페스트 작성) 로 넘어갈 수 있다.

## 0. 사전 조건

본 가이드를 시작하기 전 다음이 모두 사실이어야 한다.

| 항목 | 확인 명령 | 기대 결과 |
|---|---|---|
| Ubuntu 24.04 셸 | `lsb_release -d` | `Description: Ubuntu 24.04 LTS` |
| kubectl 동작 | `kubectl get nodes` | `kind-control-plane Ready` 1 개 노드 |
| kind 클러스터 K8s 버전 | `kubectl version --short \| grep Server` | `Server Version: v1.33.x` |
| ArgoCD 가 이미 떠 있음 (EPIC 5) | `kubectl -n argocd get pods` | `argocd-server`, `argocd-repo-server` 등이 모두 `Running` |
| `payment-dev` / `payment-prod` 가 ArgoCD 에 의해 만들어진 상태 | `kubectl get ns payment-dev payment-prod` | 두 namespace 가 모두 `Active` |
| 호스트 가용 메모리 | `free -h \| awk '/Mem:/ {print $7}'` | 최소 **2.5 GiB** (istiod + ingress gateway + 8 개 사이드카 헤드룸) |

호스트 가용 메모리가 부족하면 [§ 7. 메모리 부족 대응](#7-메모리-부족-대응) 을 참고한 뒤 다시 시작한다.

## 1. istioctl CLI 설치

`istioctl` 은 Istio 의 공식 설치/디버깅 CLI 다. 본 프로젝트는 사용자 home 의
`~/.local/bin` 에 두고 `~/.bashrc` 에 PATH 를 추가하는 방식으로 설치한다 (시스템 디렉토리
오염 회피, sudo 불필요).

### 1-1. 다운로드

```bash
# 본 프로젝트 루트에서 실행한다고 가정
mkdir -p ~/.local/bin

# Istio 1.29.2 의 공식 install 스크립트 — 환경변수로 버전 + 아키텍처 강제
ISTIO_VERSION=1.29.2 \
TARGET_ARCH=x86_64 \
curl -fsSL https://istio.io/downloadIstio | sh -

# 다운로드 결과 — 현재 디렉토리에 istio-1.29.2/ 가 만들어짐
ls istio-1.29.2/bin/
# 기대 출력: istioctl
```

> **주의**: `curl ... | sh` 패턴은 일반적으로 권장되지 않지만, Istio 의 install 스크립트는
> 공식 사이트 (istio.io) 가 직접 hosting 하며, 받는 내용은 단순 GitHub release 다운로드 wrapper 다.
> 안심하고 실행해도 된다. 의심스러우면 [공식 다운로드 페이지](https://github.com/istio/istio/releases/tag/1.29.2)
> 에서 tar.gz 를 직접 받아도 동일.

### 1-2. PATH 등록

```bash
# istioctl 바이너리를 ~/.local/bin 으로 이동
mv istio-1.29.2/bin/istioctl ~/.local/bin/

# ~/.bashrc 에 PATH 가 이미 있는지 확인하고 없으면 추가
grep -q 'HOME/.local/bin' ~/.bashrc \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# 현재 셸에 즉시 적용
export PATH="$HOME/.local/bin:$PATH"

# istio-1.29.2/ 자체는 manifests 가 들어 있어 일단 보존 (samples/ 가 디버깅에 유용)
# 나중에 정리하려면: rm -rf istio-1.29.2/
```

### 1-3. 버전 확인 — 성공 판정

```bash
istioctl version --remote=false
```

**기대 출력**:

```
client version: 1.29.2
```

`command not found` 가 뜨면 `~/.bashrc` 의 PATH 가 적용되지 않은 것 — 새 터미널을 열거나
`source ~/.bashrc` 후 다시 시도.

## 2. Istio 컨트롤 플레인 설치

### 2-1. profile 선택

`istioctl install` 은 사전 정의된 profile 로 컴포넌트 묶음을 설치한다.

| profile | 포함 컴포넌트 | 메모리 사용량 (idle) | 본 프로젝트 적합성 |
|---|---|---|---|
| `default` | istiod + istio-ingressgateway | 약 350 MiB | ✅ EPIC 6 의 모든 요구사항 커버 |
| `demo` | default + istio-egressgateway + tracing/grafana 등 | 약 800 MiB | 주소 |
| `minimal` | istiod 만 | 약 200 MiB | Canary 에 ingress gateway 필요해서 부적합 |

본 프로젝트는 **`default` 프로파일** 을 쓴다. `demo` 의 부가 컴포넌트는 EPIC 7 에서 정식
(Prometheus / Grafana / Kiali / Jaeger Helm chart) 으로 설치할 것이라 중복 회피.

### 2-2. 설치 명령

```bash
# kind 의 가벼움을 활용해 ingress gateway replicas=1, HPA 비활성화로 메모리 절약
istioctl install \
  --set profile=default \
  --set values.pilot.autoscaleEnabled=false \
  --set values.pilot.replicaCount=1 \
  --set values.gateways.istio-ingressgateway.autoscaleEnabled=false \
  --set values.gateways.istio-ingressgateway.replicaCount=1 \
  --skip-confirmation
```

**예상 동작**:
1. CRD 들 (VirtualService, DestinationRule, Gateway, PeerAuthentication 등) 이 cluster 에 적용됨
2. `istio-system` namespace 가 생성되고 그 안에 istiod + istio-ingressgateway 의 Deployment / Service 가 만들어짐
3. 모든 컴포넌트가 `Running` 상태로 갈 때까지 istioctl 이 자체 대기

**기대 출력**:

```
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete
Made this installation the default for cluster.
```

소요 시간: 메모리 여유에 따라 **30 초 ~ 2 분**. 끝나지 않고 5 분 이상 걸리면 §6 트러블슈팅 참조.

### 2-3. 설치 검증 (3 단계)

#### 2-3-1. pods 모두 Running

```bash
kubectl -n istio-system get pods
```

**기대**:

```
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-xxxxxxxxx-xxxxx    1/1     Running   0          1m
istiod-xxxxxxxxx-xxxxx                  1/1     Running   0          1m30s
```

`READY` 가 `1/1` 인 게 핵심. `0/1` 이면 아직 readiness probe 통과 전 — 30 초 더 기다린 뒤 재실행.

#### 2-3-2. CRD 등록 확인

```bash
kubectl get crd | grep istio.io | wc -l
```

**기대**: **숫자가 14 이상**. (1.29 기준 정확히 16 개 CRD — 분기마다 1-2 개 변동 가능)

대표적인 CRD:
- `virtualservices.networking.istio.io`
- `destinationrules.networking.istio.io`
- `gateways.networking.istio.io`
- `peerauthentications.security.istio.io`
- `authorizationpolicies.security.istio.io`

#### 2-3-3. 컨트롤 플레인이 cluster 의 사이드카를 인지

> **참고**: 이전 Istio 버전 (~1.22) 까지 있던 `istioctl verify-install` 명령은
> 1.23 부터 deprecated 되어 1.29 에는 완전히 제거됐다. 그 역할 (Istio 가 제대로
> 설치되었는지 확인) 은 이미 위의 § 2-3-1 (pods Running) + § 2-3-2 (CRD 등록)
> 와 본 § 2-3-3 의 `proxy-status` 조합으로 충분히 검증된다. 만약 cluster 의
> Istio 설정 자체에 문제가 있는지 분석이 필요하다면 `istioctl analyze` (옛
> verify-install 의 일부 기능을 흡수한 후속) 을 사용한다.

```bash
istioctl proxy-status
```

지금은 **`istio-ingressgateway` 한 행만 보이는 게 정상**. 기대 출력:

```
NAME                                                  CLUSTER     ISTIOD                     VERSION  SUBSCRIBED TYPES
istio-ingressgateway-xxxxxxxxx-xxxxx.istio-system     Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
```

> **왜 ingress gateway 가 보이는가**: `proxy-status` 는 istiod 가 알고 있는 **모든 Envoy proxy** 를 출력한다. 사이드카만이 아니라, ingress gateway 도 본질이 "단독으로 떠 있는 Envoy proxy" 이므로 같이 나온다. 즉:
> - 지금 (사이드카 주입 전) — ingress gateway 1 행
> - § 4 의 사이드카 주입 후 — ingress gateway 1 행 + payment-dev 의 5 사이드카 (account / transfer / loan / notification / postgres) = **총 6 행**
>
> `SUBSCRIBED TYPES` 컬럼의 `3 (CDS,LDS,EDS)` 는 이 proxy 가 istiod 로부터 세 가지 xDS 타입을 정상 구독 중이라는 뜻. CDS=cluster, LDS=listener, EDS=endpoint. 아직 RDS (route, VirtualService 가 만드는 것) 가 없는 이유는 본 시점에 VirtualService 매니페스트가 cluster 에 없기 때문 — Task 6.4 에서 Canary VirtualService 를 만들면 `4 (CDS,LDS,EDS,RDS)` 로 바뀐다.
>
> 옛 Istio (~1.23) 의 `proxy-status` 는 xDS 타입마다 컬럼을 따로 두고 `SYNCED` / `STALE` 을 표시하는 와이드 형식이었으나 1.24 부터 위처럼 `SUBSCRIBED TYPES` 한 컬럼으로 압축됐다. 정보량은 동일하다.

## 3. 컨트롤 플레인 자체 메모리 사용량 측정 (선택)

```bash
kubectl -n istio-system top pods --no-headers
```

**기대**:

```
istio-ingressgateway-xxxxx   2m    100Mi
istiod-xxxxx                 5m    180Mi
```

(metrics-server 없으면 `error: Metrics API not available` — kind 기본은 metrics-server 미포함)

metrics-server 가 없어도 본 가이드의 다음 단계 진행에는 무관하다. 메모리 측정이 필요하면
다음 한 줄로 metrics-server 만 추가:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# kind 의 self-signed cert 와 충돌 회피용 패치
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

## 4. 사이드카 자동 주입 활성화 (Task 6.3)

Istio 의 사이드카는 `MutatingWebhookConfiguration` 으로 동작한다. 특정 namespace 에
`istio-injection=enabled` 라벨이 붙으면 그 namespace 에서 새로 만들어지는 모든 pod 의
spec 에 webhook 이 `istio-proxy` 컨테이너를 자동으로 끼워 넣는다.

### 4-1. 라벨 부여

```bash
# dev 와 prod 두 namespace 에 동시에 라벨 부여
kubectl label namespace payment-dev  istio-injection=enabled --overwrite
kubectl label namespace payment-prod istio-injection=enabled --overwrite
```

**기대 출력**:

```
namespace/payment-dev labeled
namespace/payment-prod labeled
```

### 4-2. 라벨 확인

```bash
kubectl get ns -L istio-injection
```

**기대**:

```
NAME              STATUS   AGE   ISTIO-INJECTION
argocd            Active   2d
default           Active   3d
istio-system      Active   5m
kube-system       Active   3d
payment-dev       Active   1d    enabled
payment-prod      Active   1d    enabled
```

### 4-3. 기존 pod 재시작 (중요)

`istio-injection=enabled` 라벨은 **새로 만들어지는 pod 에만** 적용된다. 이미 떠 있던
4 개 서비스 + postgres 는 사이드카 없는 상태로 계속 동작 → 본 EPIC 6 의 의의 (mTLS, Canary,
관측) 가 적용 안 됨. 강제로 재시작해야 한다.

```bash
# dev 네임스페이스의 모든 Deployment + StatefulSet 재시작
kubectl -n payment-dev rollout restart deployment
kubectl -n payment-dev rollout restart statefulset

# prod 네임스페이스도 동일
kubectl -n payment-prod rollout restart deployment
kubectl -n payment-prod rollout restart statefulset

# 재시작 완료 대기 (최대 5분)
kubectl -n payment-dev rollout status deployment --timeout=5m
kubectl -n payment-prod rollout status deployment --timeout=5m
```

> **주의**: postgres StatefulSet 도 재시작되므로 일시적으로 DB 연결이 끊긴다. dev/prod 데모
> 환경이라 데이터 손실 위험은 없지만, 만약 pod 가 재시작 안 되고 hang 하면 PVC 권한 문제일
> 가능성이 있으므로 §6 트러블슈팅 참조.

### 4-4. 사이드카 주입 검증

```bash
# 각 pod 의 컨테이너 수가 2 (앱 + istio-proxy) 인지 확인
kubectl -n payment-dev get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
```

**기대 출력**:

```
account-xxxxxxxxx-xxxxx           account          istio-proxy
loan-xxxxxxxxx-xxxxx              loan             istio-proxy
notification-xxxxxxxxx-xxxxx      notification     istio-proxy
postgres-0                         postgres         istio-proxy
transfer-xxxxxxxxx-xxxxx          transfer         istio-proxy
```

각 행에 `istio-proxy` 가 보이면 성공. 안 보이면 §6 트러블슈팅 참조.

> **용어 정리**: 본 가이드 도입부에서 사이드카를 "Envoy proxy" 라고 소개했는데, 위 출력의
> 두 번째 컨테이너 이름은 `istio-proxy` 로 보인다. 둘은 같은 것이다. Istio 는 데이터 플레인
> proxy 로 Envoy 를 그대로 사용하지만, K8s pod 안에서의 컨테이너 이름표만 `istio-proxy` 로
> 붙여놓는다 (이미지는 `docker.io/istio/proxyv2:<버전>` 으로 Envoy 를 자체 빌드한 것).
> 따라서 Istio 컨텍스트에서 "사이드카", "Envoy proxy", "istio-proxy 컨테이너" 는 모두 같은
> 대상을 가리킨다.

### 4-5. 컨트롤 플레인이 사이드카를 인지

```bash
istioctl proxy-status
```

§ 2-3-3 에서 봤던 ingress gateway 1 행에 더해, 이번에는 payment-dev 의 5 개 사이드카
(account / transfer / loan / notification / postgres) 행이 추가되어 **총 6 행** 이
출력되어야 한다.

**기대**:

```
NAME                                                  CLUSTER     ISTIOD                     VERSION  SUBSCRIBED TYPES
account-xxxxxxxxx-xxxxx.payment-dev                   Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
istio-ingressgateway-xxxxxxxxx-xxxxx.istio-system     Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
loan-xxxxxxxxx-xxxxx.payment-dev                      Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
notification-xxxxxxxxx-xxxxx.payment-dev              Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
postgres-0.payment-dev                                Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
transfer-xxxxxxxxx-xxxxx.payment-dev                  Kubernetes  istiod-xxxxxxxxx-xxxxx     1.29.2   3 (CDS,LDS,EDS)
```

**핵심 검증 포인트**:

1. **ISTIOD 컬럼이 모든 행에서 채워짐** — 비어있다면 그 사이드카는 istiod 와 통신을 못 하는 상태.
2. **VERSION 이 모든 행에서 같은 1.29.2** — 다른 버전이 섞여 있으면 사이드카 주입 시점이 컨트롤 플레인 업그레이드 사이에 걸린 것 (본 EPIC 6 에서는 발생할 일 없음).
3. **SUBSCRIBED TYPES 가 3 이상** — 최소 CDS / LDS / EDS 3 개가 보여야 함. 0 이거나 1-2 개에서 멈춰 있으면 xDS 동기화 실패. 30 초 기다린 뒤 재실행, 5 분 이상 그대로면 § 6 트러블슈팅의 `STALE` 항목 (1.29 에서는 비슷한 신호로 SUBSCRIBED TYPES 가 0 으로 나옴) 절차를 따른다.

prod 환경 (payment-prod) 의 사이드카는 본 시점에는 보이지 않는 것이 정상 — payment-prod 는
ArgoCD 의 manual sync 정책 (Task 5.4) 으로 cluster 에 아무 리소스도 배포 안 된 상태이기
때문. EPIC 6 후반에 prod 도 활성화하면 그때 추가 행이 나타난다.

## 5. ArgoCD 와의 상호작용 검증

ArgoCD 는 우리가 사이드카를 추가한 사실을 모른다. 하지만 사이드카 주입은 cluster 측
mutating webhook 이 처리한 것이라 git 의 chart 매니페스트는 변하지 않았다. ArgoCD 가
이를 drift 로 인식하지 않는지 확인.

```bash
kubectl -n argocd get applications.argoproj.io
```

**기대**:

```
NAME           SYNC STATUS    HEALTH STATUS
payment-dev    Synced         Healthy
payment-prod   Synced         Healthy
root           Synced         Healthy
```

만약 `OutOfSync` 가 뜬다면 ArgoCD 가 사이드카 주입을 drift 로 인식한 경우. 이 경우 양성
drift 라 `spec.ignoreDifferences` 로 처리할 수도 있고, 또는 ArgoCD 의 webhook 인지를 위해
[Istio sidecar 주입 보호 옵션](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#respect-ignore-difference-configs)
을 설정. 본 프로젝트는 1.29 의 default 동작에서 drift 가 발생하지 않음을 확인했다.

## 6. 흔한 오류와 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| `istioctl install` 이 5 분 이상 hang | istiod pod 가 OOMKilled | 호스트 메모리 부족 — §7 참조 |
| `istioctl install` 이 `webhook timeout` 으로 fail | API server 가 webhook 호출 timeout | `--set values.global.proxy.resources.limits.memory=512Mi` 로 재시도 |
| 사이드카 주입 후 pod 가 `Init:0/2` 에서 멈춤 | `istio-init` 컨테이너의 iptables 권한 부재 | `kubectl describe pod <name>` → events 에서 `failed to setup iptables` → kind 의 root user 권한 확인 |
| 사이드카 주입 후 pod 가 `CrashLoopBackOff` | 메인 컨테이너가 사이드카 readiness 전 시작해서 DB 연결 실패 | postgres pod template 의 annotation 에 `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'` 가 있는지 확인 (이미 chart 에 적용됨) |
| `proxy-status` 의 일부 행에서 `SUBSCRIBED TYPES` 가 0 이거나 ISTIOD 컬럼이 빈 칸 | 컨트롤 플레인과 사이드카 간 xDS 동기화 실패 (옛 버전의 STALE 에 해당) | `kubectl -n istio-system logs deploy/istiod \| tail -50` 로 에러 확인. 흔한 원인은 RBAC: ServiceAccount 에 권한 부여 |
| ArgoCD 가 사이드카 주입을 drift 로 표시 | container 배열의 server-side mutation | `spec.ignoreDifferences` 에 `/spec/template/spec/containers` 추가 |

## 7. 메모리 부족 대응

호스트 RAM 16 GB 환경에서 다음 우선순위로 정리.

1. **VS Code, 브라우저 등 호스트 앱 정리** — 1-2 GB 회수.
2. **kind 클러스터의 metrics-server 같은 부가 컴포넌트 제거**:
   ```bash
   kubectl -n kube-system delete deploy metrics-server  # 있을 경우
   ```
3. **Istio 설치 시 ingress gateway 의 메모리 limit 명시**:
   ```bash
   istioctl install --set profile=default \
     --set values.gateways.istio-ingressgateway.resources.limits.memory=128Mi \
     --set values.pilot.resources.limits.memory=512Mi \
     --skip-confirmation
   ```
4. **EPIC 7 진입 전까지 ArgoCD UI 의 port-forward 종료** — port-forward 자체는 가볍지만 background process 가
   누적되면 합산 부담.

여전히 부족하면 본 프로젝트의 **단계적 기동 순서** 를 따른다.

| 단계 | 동작 | 메모리 영향 |
|---|---|---|
| EPIC 5 끝 | postgres + 4 service + ArgoCD | 약 4-5 GiB |
| EPIC 6 § 1-3 | + Istio 컨트롤 플레인 | +500 MiB |
| EPIC 6 § 4 | + 사이드카 8 개 (dev 5 + prod 3, prod 는 hpa min=2 있는 서비스 1개 가정) | +500 MiB |
| EPIC 7 § Prometheus | + Prometheus + Grafana | +1 GiB |
| EPIC 7 § Kiali | + Kiali | +200 MiB |
| EPIC 7 § Jaeger | + Jaeger (collector + query) | +500 MiB |

위 표 기준 EPIC 7 끝까지 약 7-8 GiB 사용. 16 GB 호스트라면 OS + 사용자 앱과 합쳐도 여유.
다만 prod namespace 의 HPA 가 트래픽 증가로 4-5 replica 까지 올라가면 사이드카 합계가
1.5 GiB 까지 늘 수 있어, 부하 시연 시점에는 dev 환경을 일시 종료 (`kubectl scale deploy --all --replicas=0 -n payment-dev`) 하는 것을 권장.

## 8. 다음 단계

§ 4-5 의 `istioctl proxy-status` 가 6 행 (ingress gateway 1 + payment-dev 사이드카 5) 모두에서 ISTIOD 가 채워지고 SUBSCRIBED TYPES 가 3 이상이면 EPIC 6 의 다음 단계로 진행.

| Task | 산출물 | 다루는 요구사항 |
|---|---|---|
| 6.4 | `istio/canary/virtualservice.yaml`, `istio/canary/destinationrule.yaml` | R-A1-M3 Canary 가중치 |
| 6.5 | `transfer` Deployment 두 벌 (`stable` / `canary`) + 위 매니페스트 적용 | R-A1-M3 단계별 (20→50→100) 전환 |
| 6.6 | `istio/peerauth.yaml` (mTLS STRICT) | R-A1-O1 |
| 6.7 | Kiali 설치 + 토폴로지 캡처 | R-A1-O1, R-A2-M1 |

## 9. 참고

- [Istio 1.29.2 Release Announcement](https://istio.io/latest/news/releases/1.29.x/announcing-1.29/)
- [Istio Install Profiles](https://istio.io/latest/docs/setup/additional-setup/config-profiles/)
- [Istio Sidecar Injection](https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/)
- 본 프로젝트의 `docs/adr/0003-mesh-istio-vs-linkerd.md` (왜 Istio 인가)
