# ArgoCD GitOps (EPIC 5)

본 디렉토리는 R-B3-O1 (GitOps 기본 사이클), R-B3-O2 (dev/prod 분리) 의 산출물이다.

## 구조

```
argocd/
├── values.yaml                ArgoCD 자체 설치용 Helm override (5.1)
├── install.md                 설치 가이드 — 복붙 가능 (5.1)
├── root-app.yaml              App-of-Apps 진입점 (5.3) [★]
├── projects/
│   └── payment-platform.yaml  AppProject — sourceRepo / destination scope
└── applications/
    ├── payment-dev.yaml       dev — automated + selfHeal (5.2 + 5.4)
    └── payment-prod.yaml      prod — manual sync (5.2 + 5.4)
```

## 부트스트랩 순서 (1회)

```bash
# 1. ArgoCD 설치
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argocd argo/argo-cd --version 9.5.11 \
  -n argocd --create-namespace -f argocd/values.yaml --wait --timeout 5m

# 2. App-of-Apps root 1 회 apply → 나머지 자동 등록
kubectl apply -f argocd/root-app.yaml

# 3. 확인
kubectl -n argocd get applications.argoproj.io
# NAME           SYNC STATUS    HEALTH STATUS
# root           Synced         Healthy
# payment-dev    Synced         Healthy        ← 자동 sync
# payment-prod   OutOfSync      Healthy        ← 수동 sync 대기 (정상)
```

## 일상 운영 사이클

| 시나리오 | 동작 |
|---|---|
| 코드 변경 후 dev 배포 | PR 머지 → CI 가 새 sha 의 image 를 GHCR 에 push → `applications/payment-dev.yaml` 의 `global.imageTag` 를 그 sha 로 PR → 머지 → ArgoCD 가 자동 sync → payment-dev 에 새 버전 배포 |
| prod 승격 | dev 에서 N 시간 검증된 sha 를 `applications/payment-prod.yaml` 에 PR → 머지 → ArgoCD UI 에서 사람이 Sync 버튼 클릭 (또는 `argocd app sync payment-prod`) |
| cluster drift | 누군가 `kubectl edit deployment` 로 임의 수정 → dev 는 selfHeal 로 즉시 git 상태 복원, prod 는 OutOfSync 표시 (사람이 검토 후 sync) |
| 새 Application 추가 | `argocd/applications/<name>.yaml` 한 파일 commit → root 가 자동 발견 → 즉시 등록 |

## imageTag 의 한계와 EPIC 5 후속

현재 `applications/payment-{dev,prod}.yaml` 의 `parameters.global.imageTag` 는 사람이 PR 로 갱신한다.
이 작업은 곧 **ArgoCD image updater** 로 자동화된다 (EPIC 5 후속 또는 별도 epic):

- image updater 가 GHCR 의 새 sha 를 watch
- `argocd-image-updater.argoproj.io/<image>.update-strategy: digest` annotation 으로 정책 지정
- 새 sha 발견 시 image updater 가 본 매니페스트의 imageTag 필드를 자동 git commit
- ArgoCD 가 그 commit 을 자동 sync

도입 후 사용자 작업 = 0. 본 매니페스트의 `parameters` 자리에 image updater annotation 만 추가하면 된다.

## prod 승인 게이트 (R-B1-O2 / Task 5.5)

GitHub Actions 의 `deploy` job 이 `environment: production` 을 사용한다고 가정 시:

1. GitHub repo → Settings → Environments → New environment → `production`
2. **Required reviewers** 1 명 이상 지정 (자기 자신 포함 가능)
3. CI workflow 가 prod 배포 단계에 도달하면 GitHub UI 가 "Pending approval" 표시
4. 승인 후에만 prod sync 단계가 실행

상세 캡처 + 절차는 [`docs/setup/github-environment-protection.md`](../docs/setup/github-environment-protection.md) (Task 5.5 산출물).
