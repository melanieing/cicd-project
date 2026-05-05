# Canary 배포 시연 — transfer 서비스 (EPIC 6 Task 6.4 + 6.5)

본 디렉토리는 R-A1-M3 (Canary 20→50→100) 의 산출물이다. transfer 서비스를 두 버전 (stable, canary)
으로 띄운 뒤 Istio VirtualService 의 weight 를 20→50→100 으로 단계적으로 올려 트래픽이
실제로 그 비율로 분배되는 것을 검증한다.

## 0. 사전 조건

| 항목 | 확인 명령 | 기대 |
|---|---|---|
| Istio 1.29.2 설치 | `istioctl version --remote=false` | `client version: 1.29.2` |
| payment-dev 사이드카 자동 주입 | `kubectl get ns payment-dev -L istio-injection` | `enabled` |
| 기존 transfer Deployment ready | `kubectl -n payment-dev get deploy transfer` | `READY 2/2` (또는 1/1) |
| ArgoCD 가 chart 의 새 변경 (version 라벨 + SERVICE_VERSION env) 을 sync 완료 | `kubectl -n payment-dev get pod -l app.kubernetes.io/component=transfer -o jsonpath='{.items[0].metadata.labels.version}'` | `stable` |

## 1. 시연 매니페스트 구성

```
istio/canary/
├── destinationrule.yaml     subset 정의 (stable / canary)
├── virtualservice.yaml      weight 라우팅 (초기 80/20)
├── transfer-canary.yaml     canary Deployment 1 개
├── README.md                본 문서
└── scripts/
    ├── set-canary-weight.sh    weight 빠른 변경 (시연용)
    └── test-traffic-split.sh   100 회 호출 후 분포 측정
```

각 매니페스트의 역할은 자체 파일 상단 주석에 자세히 기술.

## 2. 첫 적용 (stable 측은 chart, canary 측은 본 디렉토리)

stable 측은 ArgoCD 가 chart 로 이미 띄워둔 상태. canary 측만 본 디렉토리에서 적용한다.

### 2-1. transfer 의 현재 image sha 확인

canary Deployment 는 stable 과 **같은 image sha** 를 써야 한다 (코드는 같고 env 만 다른 시연이 핵심).

```bash
# stable Deployment 가 실제로 어떤 image 를 쓰고 있는지 확인
IMAGE_TAG=$(kubectl -n payment-dev get deploy transfer \
  -o jsonpath='{.spec.template.spec.containers[0].image}' \
  | awk -F: '{print $NF}')
echo "$IMAGE_TAG"
# 예시 출력: 9a222fc8242b99... (40자 git sha)
```

### 2-2. canary Deployment 의 ${IMAGE_TAG} 치환 후 apply

`transfer-canary.yaml` 의 image 필드에 `${IMAGE_TAG}` 자리표시자가 있다 (`ghcr.io/melanieing/transfer:${IMAGE_TAG}`).
이 자리표시자를 위에서 추출한 실제 sha 로 치환해서 적용:

```bash
envsubst < istio/canary/transfer-canary.yaml | kubectl apply -f -
# 또는 sed 로 치환
# sed "s|\${IMAGE_TAG}|$IMAGE_TAG|g" istio/canary/transfer-canary.yaml | kubectl apply -f -
```

`envsubst` 가 없으면 `apt install gettext-base` 로 설치 (Ubuntu 24.04 기본 미포함).

### 2-3. DestinationRule + VirtualService 적용

```bash
kubectl apply -f istio/canary/destinationrule.yaml
kubectl apply -f istio/canary/virtualservice.yaml
```

### 2-4. 적용 검증

```bash
# canary Deployment 가 ready
kubectl -n payment-dev get deploy transfer-canary
# 기대: READY 1/1

# 두 종류 pod 가 같은 K8s Service 의 endpoint 에 들어가 있는지
kubectl -n payment-dev get endpoints transfer
# 기대: ENDPOINTS 컬럼에 IP 가 3 개 이상 (stable 2 + canary 1)

# Istio 객체가 정상 등록됐는지
kubectl -n payment-dev get destinationrule,virtualservice
# 기대: 각각 1 개씩, AGE 가 방금 적용한 시간

# 사이드카가 새 라우팅 규칙을 받았는지 (RDS 카운트가 늘어야 함)
istioctl proxy-status
# 기대: 모든 사이드카의 SUBSCRIBED TYPES 가 4 (CDS,LDS,EDS,RDS)
```

## 3. 시연 흐름 — 20 → 50 → 100

### 3-1. 초기값 (80/20) 검증

`virtualservice.yaml` 의 초기 weight 는 stable=80, canary=20 이다.

```bash
./istio/canary/scripts/test-traffic-split.sh 100
```

기대 출력:

```
     80 stable
     20 canary
```

(±5 정도 편차는 정상 — 가중 라우팅은 확률적 라운드로빈이라 정확히 80/20 은 아님)

### 3-2. 50/50 으로 올림

```bash
./istio/canary/scripts/set-canary-weight.sh 50
sleep 3   # mesh 의 모든 사이드카에 새 RDS 가 전파될 시간
./istio/canary/scripts/test-traffic-split.sh 100
```

기대 출력:

```
     50 stable
     50 canary
```

### 3-3. 0/100 으로 완전 전환

```bash
./istio/canary/scripts/set-canary-weight.sh 100
sleep 3
./istio/canary/scripts/test-traffic-split.sh 100
```

기대 출력:

```
    100 canary
```

(stable 행이 안 보여야 정상 — weight 0 이라 절대 라우팅 안 됨)

### 3-4. 시연 종료 — 매니페스트를 git 의 80/20 상태로 복원

`set-canary-weight.sh` 가 만든 임시 변경을 git 의 정상 상태로 되돌린다.

```bash
kubectl apply -f istio/canary/virtualservice.yaml
# 또는 ArgoCD 가 본 디렉토리를 sync 한다면 UI 에서 Sync 클릭
```

## 4. Canary 시연 종료 — 정리

시연이 끝났고 transfer 의 canary 측이 더 이상 필요 없을 때:

```bash
kubectl delete -f istio/canary/transfer-canary.yaml
kubectl delete -f istio/canary/virtualservice.yaml
kubectl delete -f istio/canary/destinationrule.yaml
```

이 후 transfer 서비스는 chart 의 stable Deployment 만 남고 모든 트래픽은 자동으로 그쪽으로 간다 (
VirtualService 가 없으면 Istio 의 기본 라우팅 = 모든 endpoint 에 균등 분배 = 결과적으로 stable
2 pod 에만 분배).

## 5. 흔한 함정과 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| `transfer-canary` pod 가 `ImagePullBackOff` | `${IMAGE_TAG}` 가 치환 안 됨 (envsubst 안 돌림) | 위 § 2-2 절차 다시 — `envsubst < ... \| kubectl apply -f -` |
| 분포가 80/20 이 아니라 100/0 으로만 나옴 | DestinationRule 의 subset 라벨 (`version=canary`) 와 canary pod 의 라벨이 불일치 | `kubectl -n payment-dev get pod -l version=canary` 로 canary pod 가 보이는지 확인. 없으면 transfer-canary.yaml 의 라벨 점검 |
| 분포에 `unknown` 이 섞임 | stable 측 image 가 SERVICE_VERSION 을 안 읽는 옛 코드 | services/transfer/main.py 의 `/version` 엔드포인트가 새 image 에 들어갔는지 확인. CI 의 새 빌드 sha 를 사용 |
| set-canary-weight.sh 후 즉시 분포가 안 바뀜 | mesh 의 사이드카로 RDS 전파 시간 (보통 1-3 초) | sleep 3 후 다시 측정 |
| test-traffic-split.sh 가 hang / timeout | 임시 curl pod 의 사이드카 race | namespace 에 istio-injection 라벨이 정말 enabled 인지 확인. 없으면 사이드카가 안 들어가 transfer 호출이 라우팅 안 됨 |

## 6. 시연의 의미 (포트폴리오 관점)

본 시연은 **DevOps 면접에서 자주 나오는 질문** 들에 대한 답을 산출물로 제시한다.

- **Q. Canary 배포는 어떻게 운영했나?**
  - A. Istio VirtualService 의 weight 를 20 → 50 → 100 으로 단계적으로 올렸고, 각 단계에서 100 회 호출의 분포를 측정해 비율이 맞는지 검증. 가중치 변경 자체는 git PR + ArgoCD sync (운영 정석) 또는 시연 중에는 kubectl patch (빠름).
- **Q. 새 버전이 문제가 있을 때 롤백은?**
  - A. weight 를 0 으로 떨어뜨리면 즉시 모든 트래픽이 stable 로 돌아옴 — pod 재시작·재배포 없이 1-3 초 안에 트래픽 차단. 즉 본 시연의 흐름이 그대로 롤백 절차이기도 함 (역방향).
- **Q. stable 과 canary 가 같은 image 인 건 왜?**
  - A. 본 시연은 트래픽 분배 메커니즘 검증이 목적. 실제 운영에서는 두 image sha 가 다름 (canary 가 새 코드). 같은 image 를 쓰면서 응답을 다르게 만든 것은 SERVICE_VERSION env 한 줄 차이로, "code 는 같고 env 만 다른 두 인스턴스" 가 weight 라우팅으로 식별 가능함을 보이는 가장 단순한 방법.
- **Q. ArgoCD GitOps 와 어떻게 통합되나?**
  - A. virtualservice.yaml 의 weight 값을 git PR 로 변경 → ArgoCD 가 자동 sync → cluster 의 VirtualService 객체 갱신 → mesh 사이드카로 RDS 전파. 시연 시연용 set-canary-weight.sh 는 git 라운드트립을 우회하는 임시 도구이고, 시연 후에는 git 의 weight 값으로 복원 (위 § 3-4).

## 7. 다음 단계

본 시연이 통과하면 EPIC 6 의 다음 task 들로 진행:

- **Task 6.6** mTLS STRICT — mesh 안의 모든 서비스 간 통신을 mutual TLS 로 강제
- **Task 6.7** Kiali — 본 시연의 트래픽 분배를 시각적 토폴로지 + 라이브 차트로 캡처
- **Task 6.8** 블루-그린 — account 서비스에 즉시 100% 전환 패턴 적용
