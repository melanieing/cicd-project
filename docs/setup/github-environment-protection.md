# GitHub Environment Protection — prod 승인 게이트 (Task 5.5)

본 문서는 R-B1-O2 (prod 배포 전 사람의 승인 강제) 를 만족시키는 GitHub UI 설정 절차다.
`production` 이라는 이름의 GitHub Environment 를 만들고, `required reviewers` 를 부여해서
워크플로의 `environment: production` 단계 진입 직전에 GitHub 가 승인 대기 화면을 띄우게 한다.

> **GitHub Environment 와 ArgoCD manual sync 의 역할 분리**
> - GitHub Environment: 코드(=git)가 prod 로 향하기 전 "사람이 봐도 되겠다" 결정.
>   `argocd/applications/payment-prod.yaml` 의 `imageTag` PR 머지 자체를 게이트할 수 있음.
> - ArgoCD manual sync: 머지된 매니페스트가 cluster 에 반영되는 시점을 또 한 번 사람이 트리거.
> 둘 다 있어야 "코드 머지 → cluster 반영" 의 두 시점을 모두 사람이 통제.

---

## 1. UI 절차

GitHub 의 본 repo `melanieing/cicd-project` 화면에서:

1. **Settings** 탭 클릭
2. 좌측 사이드바 → **Environments**
3. 우상단 **New environment** 클릭
4. Name: `production` 입력 → **Configure environment**
5. **Deployment protection rules** 섹션에서 **Required reviewers** 체크
   - 우측 입력창에 GitHub 핸들 입력 (자기 자신 가능 — 1인 프로젝트 시연 시 본인이 reviewer)
   - 최대 6명 까지 추가 가능. 본 데모는 1명.
6. (선택) **Wait timer** 0 분 유지 (즉시 승인 화면 뜨게)
7. **Deployment branches** 는 default (`All branches`) 또는 `Selected branches` 로 `main` 만 허용
8. **Save protection rules**

> Free plan 의 사용 한계: public repo 에서는 무제한, private repo 는 GitHub Pro/Team 이상 필요.
> 본 repo 는 portfolio 용 public 으로 가정.

## 2. 워크플로에서의 사용

`production` environment 를 사용하는 job 이 있어야 게이트가 작동한다.
EPIC 5 후속에서 deploy job 을 추가할 때의 패턴 (예시):

```yaml
# .github/workflows/cd.yml (EPIC 5 후속에서 신설 예정)
jobs:
  promote-to-prod:
    needs: [test, build]
    runs-on: ubuntu-24.04
    # ↓ 이 한 줄이 protection rule 을 작동시킴.
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Bump prod imageTag in argocd manifest
        run: |
          # values 에 새 sha 반영 후 PR/commit
          ...
```

`environment: production` 가 명시된 job 은 step 실행 직전 GitHub 가 reviewer 에게 알림을 보낸다.

## 3. 실제 동작 캡처 (R-B1-O2 의 산출물)

다음 스크린샷을 본 폴더에 저장:

| 스크린샷 | 캡처 내용 | 파일 | 상태 |
|---|---|---|---|
| Environments 설정 | Settings → Environments → production 의 Required reviewers + main branch 제한 화면 | `docs/screenshots/gh-env-config.png` | ✅ 완료 (1인 admin/reviewer 라 "Allow administrators to bypass" 체크는 본 데모에서는 효과 없음) |
| Pending approval 화면 | Actions 탭의 workflow run 페이지에서 "Review deployments" 버튼 + reviewers 목록 | `docs/screenshots/gh-env-pending.png` | ⬜ cd.yml 의 prod job 첫 실행 시 캡처 |
| 승인 후 진행 화면 | 같은 run 페이지의 promote-to-prod job 이 진행 → 완료 표시 | `docs/screenshots/gh-env-approved.png` | ⬜ 같은 run 의 승인 후 화면 |

> config 캡처는 environment 설정만 끝나면 바로 가능 (위 §1 절차로 완료).
> pending/approved 두 장은 `environment: production` 키를 사용하는 GitHub Actions job 이
> 실제로 실행되어야 화면이 만들어지므로, 본 EPIC 5 시점이 아니라
> cd.yml (또는 ci.yml 의 deploy job 추가) 도입 시점에 채운다.

## 4. 권한 이슈와 흔한 함정

| 증상 | 원인 | 대응 |
|---|---|---|
| Environments 메뉴가 안 보임 | 본 repo 에 admin 권한 없음 | repo owner 가 해야 함 |
| Required reviewers 추가 시 "User not found" | 입력한 핸들이 collaborator 가 아님 | Settings → Collaborators 로 먼저 초대 |
| 승인 화면이 안 뜸 | 워크플로 job 에 `environment:` 키 누락 | job 에 `environment: production` 명시 |
| 승인 후에도 job 실패 | secret 이 environment scope 가 아닌 repo scope 에만 등록됨 | Settings → Environments → production → **Environment secrets** 로 이동 |

## 5. EPIC 1.5 vs EPIC 5 의 관계

| EPIC | 산출물 | 게이트 시점 |
|---|---|---|
| EPIC 3 (CI) | test → build → push → Trivy → Slack | 머지 전 (PR review) |
| **EPIC 5.5 (본 문서)** | GitHub Environment protection | **머지 후, prod 워크플로 step 직전** |
| EPIC 5.4 (manual sync) | ArgoCD 의 prod Application | cluster apply 직전 |

3중 게이트가 정석. 본 프로젝트는 demo 라 1인이 모두 통과시키지만, 실 운영은 사람이 분리.
