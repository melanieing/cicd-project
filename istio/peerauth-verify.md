# mTLS STRICT 모드 검증 절차 (EPIC 6 Task 6.6)

본 문서는 `istio/peerauth.yaml` 의 PeerAuthentication 정책이 실제로 의도대로 동작함을
검증하는 절차다. R-A1-O1 (mTLS STRICT) 의 산출물의 일부.

## 0. 사전 조건

| 항목 | 확인 |
|---|---|
| Istio 1.29.2 설치 | `istioctl version --remote=false` 가 1.29.2 |
| payment-dev 사이드카 자동 주입 활성 | `kubectl get ns payment-dev -L istio-injection` 이 `enabled` |
| 4 service + postgres pod 가 READY 2/2 | `kubectl -n payment-dev get pods` |
| (선택) Kiali 설치 완료 | EPIC 6 Task 6.7 이후 — Kiali UI 의 자물쇠 아이콘 검증을 위해 |

## 1. 적용

```bash
kubectl apply -f istio/peerauth.yaml
```

기대 출력:

```
peerauthentication.security.istio.io/default created
peerauthentication.security.istio.io/default created
```

적용 후 사이드카로 새 정책이 전파되는 시간 (보통 1-3 초) 을 기다린다.

## 2. 검증 — 메시 내부 통신은 정상

`payment-dev` namespace 안의 pod 끼리 호출하는 트래픽은 사이드카가 자동으로 mTLS 로 감싸므로
정상 동작해야 한다.

### 2-1. 사이드카가 자동 mTLS 를 활성화했는지 정책 정렬 확인

```bash
# transfer pod 의 모든 inbound policy 를 조회 — STRICT 가 반영됐는지
istioctl x authz-check $(kubectl -n payment-dev get pod \
  -l app.kubernetes.io/component=transfer \
  -o jsonpath='{.items[0].metadata.name}').payment-dev 2>&1 | head -30
```

기대 출력 일부:

```
LISTENER[Inbound]
    INBOUND ListenerName
    ...
    Authentication: STRICT mTLS required
```

또는 좀 더 직접적으로 `istioctl proxy-config secret` 으로 사이드카가 받은 인증서를 본다.

```bash
istioctl proxy-config secret $(kubectl -n payment-dev get pod \
  -l app.kubernetes.io/component=transfer \
  -o jsonpath='{.items[0].metadata.name}').payment-dev
```

기대: `ROOTCA` (root CA 인증서) 와 `default` (workload 의 client 인증서) 두 secret 이 모두 ACTIVE.

### 2-2. transfer → notification 호출이 정상

transfer 서비스의 POST /transfer 가 내부적으로 notification 호출 (1.3 의 graceful degrade).
mTLS STRICT 하에서도 정상이어야 함.

```bash
# transfer pod 안에서 transfer 자신을 호출 — 사이드카가 자동 mTLS 적용
TRANSFER_POD=$(kubectl -n payment-dev get pod \
  -l app.kubernetes.io/component=transfer \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n payment-dev exec "$TRANSFER_POD" -c transfer -- \
  curl -s -X POST http://transfer:8000/transfer \
  -H 'Content-Type: application/json' \
  -d '{"payload": {"from":"a1","to":"a2","amount":1000}}'
```

기대 응답:

```json
{
  "service": "transfer",
  "action": "transfer",
  "status": "accepted",
  "received": {...},
  "notification": {"status":"delivered", "http_status":200, ...}
}
```

`notification.status` 가 `delivered` 면 transfer → notification 호출이 mTLS 위에서 정상 동작.

## 3. 검증 — 메시 외부에서 평문 호출은 거부

본 검증이 핵심. STRICT 가 진짜로 강제되는지 보려면 사이드카가 없는 (= 메시 외부) 위치에서
호출해보고 거부되는지 확인해야 한다.

### 3-1. 임시 외부 pod 생성 (사이드카 없음)

`default` namespace 는 `istio-injection=enabled` 라벨이 없으므로 그 안에 띄우는 pod 는
사이드카가 안 들어간다. 이 pod 에서 payment-dev 의 transfer 를 평문으로 호출해보자.

```bash
kubectl -n default run mtls-test \
  --image=curlimages/curl:8.10.1 \
  --rm -i --restart=Never \
  -- curl -v --max-time 5 \
  http://transfer.payment-dev.svc.cluster.local:8000/version 2>&1
```

기대 결과 — **연결이 거부되거나 RST 가 발생**:

```
* Connected to transfer.payment-dev.svc.cluster.local (...) port 8000
* Empty reply from server
curl: (52) Empty reply from server
```

또는:

```
* Connection reset by peer
curl: (56) Recv failure: Connection reset by peer
```

이 결과가 나와야 STRICT mTLS 가 진짜로 동작 중이라는 증거. 사이드카가 평문 요청을 보자마자
TCP 단에서 RST 로 끊어버리는 모습.

> **주의**: `Empty reply from server` 가 정상 결과인 게 직관에 반할 수 있다. 본 시연에서는
> `HTTP 403` 같은 의미 있는 에러가 떨어지면 오히려 비정상 — 그건 사이드카가 받은 다음 거부한
> 것이라 응답 자체는 보내준 셈. STRICT mTLS 의 진짜 거부는 **TLS handshake 가 시작도 못 함**
> 이라 HTTP 응답 자체가 안 생긴다.

### 3-2. 같은 호출을 메시 안의 pod 에서 했을 때 정상인지 대조

`payment-dev` namespace 의 임시 pod (= 사이드카 자동 주입) 에서 같은 호출:

```bash
kubectl -n payment-dev run mtls-test-inside \
  --image=curlimages/curl:8.10.1 \
  --rm -i --restart=Never \
  -- curl -v --max-time 5 \
  http://transfer.payment-dev.svc.cluster.local:8000/version 2>&1 | head -30
```

기대 결과 — **정상 응답 (200 + JSON)**:

```
{"service":"transfer","version":"stable"}
```

두 시연을 나란히 보여주면 "STRICT 가 메시 외부는 막고, 메시 내부는 통과" 라는 게 확실히 입증된다.

## 4. Kiali 시각 검증 (Task 6.7 후)

Task 6.7 의 Kiali 가 설치된 다음, Kiali UI 의 **Graph** 탭에서 payment-dev namespace 를 선택하면
서비스 간 엣지 (예: `transfer → notification`) 위에 **자물쇠 아이콘 🔒** 이 표시된다. 자물쇠는
mTLS 가 그 엣지에 적용 중이라는 시각적 표지.

자물쇠가 안 보이면 (1) Kiali 가 Prometheus 에서 mTLS 메트릭을 못 받는 경우 또는 (2) 정책 적용이
누락된 경우. 보통 Prometheus 가 정상이면 (2) 의 가능성이 높으므로 본 가이드의 § 2-1 부터 다시
점검.

## 5. 흔한 함정과 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| § 3-1 의 외부 pod 호출이 정상 응답을 받음 | namespace `default` 에 잘못 istio-injection 라벨이 enabled 로 박혀있음 | `kubectl get ns default -L istio-injection` 확인. 라벨이 있으면 `kubectl label ns default istio-injection-` 으로 제거 |
| § 2-2 의 transfer 자기 호출이 timeout | 정책이 너무 강해 transfer 가 자기 자신 호출까지 막음 | 정책은 같은 namespace 내부는 허용하므로 이건 거의 발생 X. 발생 시 PeerAuthentication 의 selector 점검 |
| 사이드카에 인증서가 안 들어옴 (`ROOTCA` 가 보이지 않음) | istiod 에서 사이드카로 SDS 가 안 옴 | `kubectl -n istio-system logs deploy/istiod \| tail -50` 로 오류 확인. 흔히 ServiceAccount 권한 부재 |
| ArgoCD 의 `payment-dev` Application 이 OutOfSync 로 표시 | ArgoCD 가 본 매니페스트를 직접 sync 하는 경우. 본 매니페스트는 `argocd/applications/` 가 아니라 직접 apply 라 ArgoCD 입장에서는 외부 변경 | 정상. 본 매니페스트를 ArgoCD 가 관리하게 하려면 별도 Application 으로 등록하거나 chart 에 통합 (EPIC 9 의 마감 task) |

## 6. 시연 영상화 (포트폴리오용)

채용 담당자에게 보여줄 캡처:

1. `kubectl apply -f istio/peerauth.yaml` 출력
2. § 3-1 의 외부 pod 호출 결과 (거부됨)
3. § 3-2 의 메시 내부 pod 호출 결과 (정상)
4. (Task 6.7 후) Kiali Graph 의 자물쇠 아이콘 화면

위 4 개를 같은 README 또는 demo 문서에 정렬해 두면 "보안 정책이 의도대로 동작한다" 는 게
시각적으로 입증된다.
