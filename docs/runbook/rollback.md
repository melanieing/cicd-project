# 운영 Runbook — 롤백 절차 (EPIC 9 Task 9.3)

본 문서는 R-A3-M3 의 산출물로, **production 사고 발생 시 운영자가 따라가는 단계별 절차서** 다.
새벽 3 시에 알람을 받고 잠에서 깬 상태에서도 실행 가능한 수준의 구체성을 목표로 한다.

> **본 runbook 의 사용자**: 본 프로젝트의 운영자 (현재는 단독, 향후 on-call 엔지니어)
> **본 runbook 의 입력**: 알람 (Slack `#deploy-status` 또는 Alertmanager) 또는 사용자 신고
> **본 runbook 의 출력**: 사고 영향 최소화 + 사후 분석 자료

## 0. 의사결정 트리 — "지금 무엇을 해야 하는가"

```
                  알람 / 사고 신고 수신
                          │
                          ▼
        ┌─────────────────────────────────────┐
        │ 1. 사고 영향 범위 식별 (§ 1)        │
        │    - 어느 서비스?                    │
        │    - dev 인가 prod 인가?            │
        │    - 사용자가 영향 받는가?           │
        └────────────────┬────────────────────┘
                         │
                         ▼
        ┌─────────────────────────────────────┐
        │ 2. 사고 원인 추정 (§ 2)              │
        │    - 최근 배포가 있었나?             │
        │    - 인프라 변경이 있었나?           │
        │    - 외부 의존성 (DB, GHCR) 다운?    │
        └────────────────┬────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │ 최근 배포     │  인프라        │  외부 의존성
        │ 원인          │  원인          │  원인
        ▼                ▼                ▼
   § 3 롤백        § 4 인프라        § 5 외부 의존성
   (본 doc 의       복구             대응
   핵심)            (다른 runbook)    (다른 runbook)
                         │
                         ▼
        ┌─────────────────────────────────────┐
        │ 6. 사후 — postmortem + alert tuning │
        │    (§ 6)                            │
        └─────────────────────────────────────┘
```

본 runbook 의 본격적인 절차는 **§ 3 (최근 배포로 인한 사고 — 롤백)** 에 집중. 다른 원인 분류는
링크된 별도 runbook 에서 다룬다 (EPIC 9 의 후속 또는 외부 runbook).

## 1. 사고 영향 범위 식별 (목표 시간: 1 분)

### 1-1. Slack 알람 본문 확인

`#deploy-status` 또는 `#alerts` 채널의 첫 알람 메시지의 다음 필드 확인:

- `severity`: critical / warning / info
- `service`: 어느 서비스
- `namespace`: payment-dev / payment-prod
- `metric`: error_rate / latency_p99 / availability
- `value`: 임계치 대비 얼마나

### 1-2. Grafana 대시보드 1 차 확인

```bash
kubectl -n observability port-forward svc/prometheus-grafana 3000:80
# 브라우저 → http://localhost:3000 → Istio → Service dashboard
# 의심 서비스의 success rate / P99 latency 그래프 확인
```

### 1-3. 영향 사용자 추정

- **payment-prod 의 5xx 비율 > 1%**: prod 사용자 영향, P1 사고
- **payment-dev 의 5xx**: 내부 사고, P3 — 진단만 하고 다음 영업일 이내 처리
- **payment-prod 의 latency P99 > 500ms** : prod 사용자 경험 저하, P2

본 runbook 은 **P1 사고** 를 기준으로 진행. P2/P3 는 같은 절차이지만 § 6 의 사후 단계만 다름.

## 2. 사고 원인 추정 (목표 시간: 2 분)

### 2-1. 최근 배포 확인

```bash
# ArgoCD 의 sync 이력 — 최근 24 시간 안의 sync 가 있는지
kubectl -n argocd get applications.argoproj.io
kubectl -n argocd get application payment-prod -o jsonpath='{.status.history[-3:]}' | jq .

# 또는 cluster 의 deployment revision
kubectl -n payment-prod rollout history deployment
```

**최근 1 시간 안의 배포가 있고 그 시점부터 알람이 시작** 됐으면 **거의 확실히 배포 원인** → § 3
즉시 진행.

### 2-2. 인프라 변경 확인

- 최근 Istio / ArgoCD / Prometheus 매니페스트 변경?
- 노드 추가 / 제거?
- StorageClass / PVC 변경?

본 항목이 원인이면 § 4 (별도 runbook).

### 2-3. 외부 의존성 확인

- GHCR 의 image pull 실패?
- postgres 의 connection refused?
- DNS / NetworkPolicy 변경으로 인한 통신 차단?

본 항목이 원인이면 § 5 (별도 runbook). 단 NetworkPolicy 변경은 § 3 의 "최근 배포" 범주에 포함.

## 3. 롤백 (목표 시간: 5 분 안에 트래픽 복구)

본 runbook 의 핵심 단계. R-A3-O2 의 "5 분 이내 복구" 목표.

### 3-1. 롤백 도구 선택

| 사고 유형 | 도구 | 명령 |
|---|---|---|
| Canary 새 버전이 문제 (transfer) | VS weight 를 stable=100 으로 | `./istio/canary/scripts/set-canary-weight.sh 0` |
| Blue-Green 새 환경이 문제 (account) | switch 한 번 더 | `./scripts/switch-bluegreen.sh` |
| chart 전체 배포가 문제 | ArgoCD 이전 revision 으로 | § 3-3 |
| 단일 서비스의 deploy revision 만 | kubectl rollout undo | § 3-4 |

### 3-2. Canary / Blue-Green 즉시 전환 (최고 속도, ~30 초)

#### Canary 롤백 (transfer)

```bash
# canary 의 weight 를 0 으로 → 모든 트래픽이 stable 로
./istio/canary/scripts/set-canary-weight.sh 0

# 검증
./istio/canary/scripts/test-traffic-split.sh 50
# 기대: 50 stable, 0 canary
```

소요 시간: kubectl patch 1 회 (~1 초) + RDS 전파 (1-3 초) = **최대 4 초**.

#### Blue-Green 롤백 (account)

```bash
# 현재 라이브 측 (blue 또는 green) 의 반대로 즉시 전환
./scripts/switch-bluegreen.sh

# 검증
./scripts/test-bluegreen.sh 50
```

소요 시간: 동일하게 ~4 초.

### 3-3. ArgoCD revision 롤백 (chart 단위 ~3 분)

전체 chart 가 잘못 배포된 경우 (예: values.yaml 의 잘못된 변경).

```bash
# 1. ArgoCD 의 이전 revision 확인
kubectl -n argocd get application payment-prod -o jsonpath='{.status.history[*].revision}' | tr ' ' '\n' | tail -5

# 출력 예 (가장 최근부터):
# c63257d87c64040b82065e9d3f41875600e23995   ← 현재 (문제 있음)
# 8d037daxxxx                                  ← 이전 (안정)
# 9a222fcxxxx
# ...

PREV_REVISION="8d037daxxxxx"  # ← 위에서 두 번째 줄

# 2. argocd CLI 로 rollback
argocd app rollback payment-prod $(kubectl -n argocd get application payment-prod \
  -o jsonpath='{.status.history[?(@.revision=="'"$PREV_REVISION"'")].id}')

# 또는 UI 에서: Application 선택 → History 탭 → 이전 revision 의 Rollback 버튼

# 3. sync 확인
kubectl -n argocd get application payment-prod -w
# Sync status 가 OutOfSync → Synced 로 가는 것 확인 (~1-2 분)
```

### 3-4. K8s rollout undo (단일 deployment ~1 분)

서비스 한 개의 deploy revision 만 되돌리는 경우 (가장 fine-grained).

```bash
# 1. revision history 확인
kubectl -n payment-prod rollout history deployment transfer

# 2. 직전 revision 으로 undo (혹은 --to-revision=N 으로 특정 시점)
kubectl -n payment-prod rollout undo deployment transfer

# 3. 진행 모니터
kubectl -n payment-prod rollout status deployment transfer --timeout=2m

# 4. 검증
kubectl -n payment-prod exec deploy/transfer -c transfer -- curl -s localhost:8000/version
```

> **주의**: ArgoCD 가 본 deployment 를 watch 중이라 rollout undo 의 변경이 다음 sync 에서 git 상태로
> 되돌려질 수 있다. **ArgoCD sync 를 일시 정지** 하거나 git 의 manifest 도 같이 revert 해야 함.

```bash
# ArgoCD sync 일시 정지 (단일 Application)
kubectl -n argocd patch application payment-prod \
  -p '{"spec":{"syncPolicy":{"automated":null}}}' --type=merge
# (롤백 + 안정화 후 다시 켜기: 위 syncPolicy 를 원래 값으로 복원)
```

### 3-5. 자동 롤백 (목표 5 분 이내)

위 § 3-2 / 3-3 / 3-4 를 자동으로 실행하는 스크립트가 있음:

```bash
./scripts/rollback.sh <service> <type>
# 예시:
./scripts/rollback.sh transfer canary
./scripts/rollback.sh account  blue-green
./scripts/rollback.sh payment  argocd
```

자세한 사용법과 실측 시간은 `docs/metrics/rollback-time.md` (Task 9.4) 참고.

## 4. 인프라 사고 (별도 runbook)

본 runbook 의 범위 밖. 다음 runbook 참조:

- **노드 다운**: `docs/runbook/node-down.md` (TBD)
- **mesh 통신 마비**: `docs/runbook/mesh-recovery.md` (TBD)
- **storage 사고**: `docs/runbook/storage-recovery.md` (TBD)

(본 EPIC 9 의 범위 외. 향후 EPIC 으로 확장)

## 5. 외부 의존성 사고 (별도 runbook)

- **GHCR pull 실패**: imagePullSecret 점검, GHCR status 페이지 확인
- **postgres 다운**: postgres-0 pod 재시작, PVC 검증
- **DNS 차단**: NetworkPolicy 점검

(본 EPIC 9 의 범위 외)

## 6. 사후 (postmortem) — 사고 종료 후 24 시간 내

### 6-1. 사고 타임라인 정리

| 시각 | 이벤트 |
|---|---|
| `T0` | 알람 수신 |
| `T0 + 1m` | 영향 식별 |
| `T0 + 3m` | 원인 추정 (배포) |
| `T0 + 4m` | 롤백 실행 |
| `T0 + 5m` | 트래픽 복구 확인 |
| `T0 + 30m` | 사후 분석 시작 |

본 timeline 을 `docs/troubleshooting/<date>-incident-<slug>.md` 에 기록 (CLAUDE.md A-4 형식).

### 6-2. 근본 원인 분석 (5 Whys 또는 Fishbone)

- 왜 새 배포가 깨졌나?
- 왜 CI 의 테스트는 그것을 못 잡았나?
- 왜 staging 검증에서 안 보였나?
- 왜 prod 배포 전 게이트가 막지 못했나?
- 왜 알람이 사용자보다 늦었나?

### 6-3. 재발 방지 액션

- 테스트 추가 (회귀 방지)
- staging 환경 보강
- 알람 threshold 조정 (false negative 줄임)
- runbook 갱신 (본 사고의 패턴이 다음 사고에 빨리 인식되도록)

## 7. 본 runbook 의 유지보수

- 분기 1 회 (또는 신규 EPIC 진입 시) 점검
- 본 runbook 의 명령이 실제로 작동하는지 분기마다 dry-run
- 새 도구 도입 시 (예: ArgoCD Image Updater 도입) 본 runbook 의 § 3 갱신

## 8. 관련 산출물

- `scripts/rollback.sh` — § 3-5 의 자동 롤백 스크립트 (Task 9.4)
- `docs/metrics/rollback-time.md` — 실측 시간 데이터 (Task 9.4)
- `./istio/canary/scripts/set-canary-weight.sh` — Canary weight 변경 (EPIC 6.4)
- `./scripts/switch-bluegreen.sh` — Blue-green swap (EPIC 6.8)
- `docs/setup/github-environment-protection.md` — prod 승인 게이트 (EPIC 5.5)
