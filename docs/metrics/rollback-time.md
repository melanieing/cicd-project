# 롤백 시간 실측 — 5 분 SLO 검증 (EPIC 9 Task 9.4)

본 문서는 R-A3-O2 의 "5 분 이내 자동 롤백" 목표가 본 프로젝트의 4 가지 strategy 에서 실제로
어떤 시간 안에 달성되는지 측정한 결과를 기록한다.

> **본 문서는 실측 템플릿이다.** 사용자가 `scripts/rollback.sh` 의 각 strategy 를 실행한 뒤
> 표의 `<TBD>` 칸을 실측값으로 채운다.

## 0. 측정 환경

| 항목 | 값 |
|---|---|
| 클러스터 | kind, K8s 1.33, 노드 3 개 (control-plane + worker × 2) |
| 호스트 | Intel i7-1165G7, RAM 16 GiB |
| 부하 상태 | 측정 직전 30 초간 50 req/s 시연 부하 발생 |
| 측정 도구 | `scripts/rollback.sh` 의 자동 elapsed 출력 |

## 1. Strategy 별 측정 결과

### 1-1. Canary (transfer)

`./scripts/rollback.sh transfer canary` — VS weight 100/0 → 0/100 으로 변경 (또는 0/N → 100/0 로 stable 복귀).

| 측정 회차 | elapsed | 비고 |
|---|---|---|
| 1 회차 | `<TBD>s` | cold (스크립트 첫 실행, `kubectl` cache 없음) |
| 2 회차 | `<TBD>s` | warm |
| 3 회차 | `<TBD>s` | warm |
| **평균** | **`<TBD>s`** | |

**예상 시간**: 5-10 초 (kubectl patch 1 회 + RDS 전파 3 초 + 50 회 검증 호출).

### 1-2. Blue-Green (account)

`./scripts/rollback.sh account blue-green` — switch-bluegreen.sh 1 회 호출.

| 측정 회차 | elapsed | 비고 |
|---|---|---|
| 1 회차 | `<TBD>s` | cold |
| 2 회차 | `<TBD>s` | warm |
| 3 회차 | `<TBD>s` | warm |
| **평균** | **`<TBD>s`** | |

**예상 시간**: 5-10 초 (canary 와 동일 메커니즘).

### 1-3. ArgoCD Application rollback

`./scripts/rollback.sh payment-dev argocd` — argocd CLI 의 history rollback + sync wait.

| 측정 회차 | elapsed | 비고 |
|---|---|---|
| 1 회차 | `<TBD>s` | chart 의 deployment N 개 rolling update 시간 포함 |
| 2 회차 | `<TBD>s` | |
| **평균** | **`<TBD>s`** | |

**예상 시간**: 60-180 초 (rolling update 가 모든 pod 를 회전하는 시간이 지배적).

### 1-4. K8s rollout undo

`./scripts/rollback.sh transfer k8s` — kubectl rollout undo + status wait.

| 측정 회차 | elapsed | 비고 |
|---|---|---|
| 1 회차 | `<TBD>s` | |
| 2 회차 | `<TBD>s` | |
| **평균** | **`<TBD>s`** | |

**예상 시간**: 30-90 초 (단일 deployment rolling update).

## 2. 종합 — SLO 5 분 (300 초) 달성

| Strategy | 평균 elapsed | 5 분 SLO 달성? | 가장 적합한 사고 유형 |
|---|---|---|---|
| Canary | `<TBD>s` | ✅ / ❌ | 최근 배포의 새 버전이 5xx |
| Blue-Green | `<TBD>s` | ✅ / ❌ | 환경 단위 전환 사고 |
| ArgoCD | `<TBD>s` | ✅ / ❌ | chart 단위 잘못된 배포 |
| K8s | `<TBD>s` | ✅ / ❌ | 단일 서비스만 회귀 |

> **본 표의 모든 strategy 가 ✅ 면 R-A3-O2 의 5 분 SLO 가 모든 시나리오에서 보장됨.**
> ❌ 가 있으면 그 strategy 의 병목 (예: ArgoCD 의 rolling update 시간) 을 분석하고 개선안 도출.

## 3. SLO 미달 시 개선안 (참고)

### ArgoCD rollback 이 3 분 초과한다면

- **rolling update 의 maxSurge / maxUnavailable 조정** — 현재 chart 의 values 는
  `maxSurge=1 / maxUnavailable=0` 으로 안전 우선. 응급 롤백에는 `maxSurge=50% / maxUnavailable=25%`
  같은 공격적 설정으로 변경 가능.
- **rollout 의 minReadySeconds 단축** — 새 pod 가 ready 표시 후 추가 대기 시간. default 0 이지만
  HPA 가 활성이면 ready 까지 시간이 더 들어남.

### K8s rollout undo 가 1 분 초과한다면

- **readinessProbe 의 initialDelaySeconds 단축** — 컨테이너 시작 후 첫 probe 까지의 대기. chart 의
  default 는 5 초 (적당함). 더 단축 시 false negative 위험.

## 4. 측정 절차 (사용자가 실행)

각 strategy 를 3 회씩, 측정 사이 30 초 부하 발생 후 측정.

```bash
# 1. 부하 발생 (background)
while true; do
  ./istio/canary/scripts/test-traffic-split.sh 50 >/dev/null 2>&1
  sleep 1
done &
LOAD_PID=$!

# 2. 30 초 대기 (메트릭이 안정화)
sleep 30

# 3. 측정 — strategy 별 3 회
for i in 1 2 3; do
  echo "=== run $i ==="
  ./scripts/rollback.sh transfer canary
  sleep 30
done

# 4. 부하 정리
kill $LOAD_PID 2>/dev/null

# 5. 본 문서의 1-1 표에 elapsed 값 3 개 기록
```

같은 방식으로 1-2 / 1-3 / 1-4 진행.

## 5. 본 측정의 한계

- **단일 호스트** — 16GB RAM 의 kind 클러스터는 production cluster 와 다름. 실제 production 의 rolling
  update 시간은 노드 수와 pod density 에 따라 더 길어질 가능성.
- **부하 패턴 한정** — 본 측정은 시연 부하 (50 req/s) 에서의 결과. real 환경의 100s req/s 부하에서는
  endpoint 변경 시 sticky session / connection drain 의 영향이 더 커짐.
- **단일 사고 유형** — 본 측정은 "성공한 롤백" 의 시간만 본다. 롤백 자체가 실패하는 시나리오 (예:
  옛 image 가 GHCR 에서 자동 삭제됨) 의 회복 시간은 본 측정 범위 밖.

## 6. 관련 산출물

- `scripts/rollback.sh` — 본 측정 대상 자동화 스크립트
- `docs/runbook/rollback.md` — 운영 절차서 (본 측정의 입력 시나리오)
- `istio/canary/scripts/set-canary-weight.sh` — canary 의 내부 구현
- `scripts/switch-bluegreen.sh` — blue-green 의 내부 구현
