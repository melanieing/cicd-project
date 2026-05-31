# Blue-Green 배포 시연 — account 서비스 (EPIC 6 Task 6.8)

본 디렉토리는 R-A1-O2 (블루-그린 + 관측성 강화) 의 산출물이다. account 서비스를 두 인스턴스
(blue / green) 로 띄운 뒤 Istio VirtualService 의 weight 를 100→0 으로 **즉시 뒤집어** 트래픽
전환이 한 번에 일어남을 검증한다.

## 0. Canary 와 Blue-Green 의 차이

| 항목 | Canary (Task 6.4-6.5) | Blue-Green (본 task) |
|---|---|---|
| 대상 서비스 | transfer | account |
| 트래픽 전환 방식 | 점진적 (20 → 50 → 100) | 즉시 (100 → 0 한 번에) |
| 새 버전 검증 시간 | 단계마다 사람이 모니터링 | 전환 전 별도 staging 으로 검증, 전환 자체는 빠름 |
| 문제 발생 시 영향 범위 | 일부 사용자만 | 전체 사용자 |
| 롤백 속도 | 빠름 (weight 0 으로) | **더 빠름** (한 번에 100→0) |
| 인프라 비용 | replicas 적게 (canary 1 + stable 2) | 두 환경이 동시 가동되어 잠시 2 배 |

선택 기준 — "**새 버전이 문제 있을 때 일부만 영향 받기 vs 전부 영향 받지만 즉시 롤백**" 의 trade-off.
보통 결제·은행 같은 high-stake 도메인은 Canary, A/B 테스팅·feature flag 영역은 Blue-Green.

## 1. 사전 조건

| 항목 | 확인 |
|---|---|
| Istio + 사이드카 (EPIC 6 § 1-4) | `istioctl proxy-status` 모든 사이드카 SYNCED |
| account 의 chart 에 `version: blue` 설정 | `kubectl -n payment-dev get pod -l app.kubernetes.io/component=account -o jsonpath='{.items[0].metadata.labels.version}'` 이 `blue` |
| account 의 새 `/version` 엔드포인트 작동 | `kubectl -n payment-dev exec deploy/account -c account -- curl -s localhost:8000/version` 가 `{"service":"account","version":"blue"}` |
| envsubst 설치 | `which envsubst` (없으면 `sudo apt install gettext-base`) |

## 2. 매니페스트 구성

```
istio/blue-green/
├── account-green.yaml       green Deployment (chart 의 blue 와 같은 image, env 만 다름)
├── destinationrule.yaml     subset 정의 (blue / green)
├── virtualservice.yaml      트래픽 분배 (초기 blue=100 / green=0)
└── README.md                본 문서

scripts/
├── switch-bluegreen.sh      weight 를 100↔0 으로 swap (시연 전환 + 롤백 동일 명령)
└── test-bluegreen.sh        100 회 호출로 분포 검증 (한쪽 100% 여야 정상)
```

## 3. 첫 적용

### 3-1. account 의 image sha 추출 (green 이 같은 sha 를 쓰도록)

```bash
IMAGE_TAG=$(kubectl -n payment-dev get deploy account \
  -o jsonpath='{.spec.template.spec.containers[0].image}' \
  | awk -F: '{print $NF}')
echo "$IMAGE_TAG"
```

### 3-2. green Deployment 의 ${IMAGE_TAG} 치환 후 apply

```bash
envsubst < istio/blue-green/account-green.yaml | kubectl apply -f -
# envsubst 없으면:
# sed "s|\${IMAGE_TAG}|$IMAGE_TAG|g" istio/blue-green/account-green.yaml | kubectl apply -f -
```

### 3-3. DestinationRule + VirtualService 적용

```bash
kubectl apply -f istio/blue-green/destinationrule.yaml
kubectl apply -f istio/blue-green/virtualservice.yaml
```

### 3-4. 적용 검증

```bash
# green 이 ready
kubectl -n payment-dev get deploy account-green
# 기대: READY 1/1

# 두 종류 pod 가 같은 Service 의 endpoint 에 들어감
kubectl -n payment-dev get endpoints account
# 기대: ENDPOINTS 컬럼에 IP 가 N+1 개 (blue HPA replicas + green 1)

# Istio 객체 등록
kubectl -n payment-dev get destinationrule,virtualservice -l epic=6
# 기대: account 의 DR + VS, transfer 의 DR + VS 같이 보임 (Canary 매니페스트도 있을 경우)
```

## 4. 시연 흐름 — 100/0 → 0/100 → 100/0

### 4-1. 초기 상태 (blue=100) 검증

```bash
./scripts/test-bluegreen.sh 100
```

기대:

```
    100 blue
```

(`green` 행이 없어야 정상. blue 의 weight 100 이라 모든 트래픽이 blue 로만 감.)

### 4-2. green 으로 전환 (즉시 100% 이동)

```bash
./scripts/switch-bluegreen.sh
sleep 3   # RDS 전파 시간
./scripts/test-bluegreen.sh 100
```

기대:

```
    100 green
```

(`blue` 행이 없어야 정상. weight 가 한 번에 뒤집혀 모든 트래픽이 green 으로 감.)

### 4-3. 다시 blue 로 복귀 (= 인스턴트 롤백 시연)

같은 스크립트 한 번 더:

```bash
./scripts/switch-bluegreen.sh
sleep 3
./scripts/test-bluegreen.sh 100
```

기대:

```
    100 blue
```

**핵심 시연 포인트**: 같은 스크립트로 전환과 롤백이 모두 가능. 운영 사고 시점에 "어느 명령을
실행할지 고민할 필요 없음 — 그냥 같은 명령 한 번 더" 가 Blue-Green 의 운영 단순성.

## 5. 정리

시연이 끝나고 green 측이 더 이상 필요 없을 때:

```bash
kubectl delete -f istio/blue-green/destinationrule.yaml
kubectl delete -f istio/blue-green/virtualservice.yaml
kubectl delete -f istio/blue-green/account-green.yaml
```

이후 account 는 chart 의 blue Deployment 만 남고 정상 동작.

## 6. 흔한 함정과 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| switch 후 분포가 60:40 같은 중간값 | 사이드카의 RDS 전파 과도기 | sleep 3-5 후 재측정 |
| `unknown` 행이 보임 | image 가 옛 코드 (SERVICE_VERSION 안 읽음) | CI 새 image 빌드 + ArgoCD sync 후 재시도 |
| `account-green` pod 가 ImagePullBackOff | `${IMAGE_TAG}` 가 치환 안 됨 | envsubst 또는 sed 로 치환 후 apply |
| switch 후 분포가 여전히 100 blue | DestinationRule 없거나 라벨 매핑 잘못됨 | `kubectl -n payment-dev get dr account -o yaml` 점검. subset 의 라벨이 `version=blue/green` 인지 확인 |
| switch-bluegreen.sh 가 ERROR: blue weight 가 0 또는 100 이 아닙니다 | VirtualService 가 누군가에 의해 중간값 (예: 50/50) 으로 설정됨 | `kubectl -n payment-dev apply -f istio/blue-green/virtualservice.yaml` 로 초기 상태 (100/0) 복원 후 재시도 |

## 7. 시연의 면접 가치

| Q | A |
|---|---|
| Canary 와 Blue-Green 의 차이는? | Canary 는 점진적 (20→50→100), Blue-Green 은 즉시 (100↔0). Canary 는 문제 시 일부만 영향, Blue-Green 은 전체 영향이지만 롤백도 즉시. |
| 같은 namespace 에서 두 패턴을 같이 운영해도 되나? | 됨. 본 프로젝트가 정확히 그 형태 — transfer 가 Canary, account 가 Blue-Green. 각 서비스마다 자신에게 맞는 패턴 선택 가능. |
| Blue-Green 의 단점은? | (1) 두 환경 동시 가동으로 잠시 리소스 2 배, (2) 데이터베이스 마이그레이션이 동시 호환되어야 함 (DB 스키마가 blue/green 호환 필수), (3) 문제 발생 시 모든 사용자 영향 받음. |
| ArgoCD 와의 통합은? | `virtualservice.yaml` 의 weight 변경을 git PR → ArgoCD 자동 sync 하면 GitOps 정석. 시연용 switch-bluegreen.sh 는 git 라운드트립 우회 (임시), 시연 후 git 의 100/0 상태로 복원. |

## 8. 참고

- 본 프로젝트의 `istio/canary/README.md` — 점진적 Canary 의 같은 시연
- [Istio Traffic Management — VirtualService](https://istio.io/latest/docs/concepts/traffic-management/#virtual-services)
- [Argo Rollouts](https://argoproj.github.io/rollouts/) — Blue-Green / Canary 를 더 정교하게 자동화하는 후속 도구 (EPIC 9 의 follow-up 후보)
