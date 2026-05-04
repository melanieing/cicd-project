# Container Registry 정책 (GHCR)

본 프로젝트가 사용하는 컨테이너 레지스트리의 명명·태그·수명·권한 정책을 정의한다.
원래 요구사항(`docs/requirements.md` R-B2-M2) 은 **KT클라우드 Container Registry** 였으나
0원 비용 제약으로 **GitHub Container Registry (GHCR)** 로 치환했다.
선택 근거 비교는 `docs/adr/0002-registry-ktcloud-vs-ghcr.md` (작성 예정) 에 별도로 기록한다.

| 요구사항 | 매핑 산출물 |
|---|---|
| R-B2-M2 (서비스별 저장소 분리 + git-sha 태그) | 본 문서 §1, §3 |
| R-B2-O2 (untagged 이미지 자동 삭제) | 본 문서 §5 |

---

## 1. 레지스트리 구조 — 서비스별 저장소 분리

GHCR 은 GitHub repo 에 종속적이지 않은 **독립 패키지 네임스페이스** 를 가진다.
4 개 서비스를 각각 독립 패키지로 분리해서:

```
ghcr.io/melanieing/account
ghcr.io/melanieing/transfer
ghcr.io/melanieing/loan
ghcr.io/melanieing/notification
```

분리 이유:
- **권한 분리 가능** — 미래에 transfer 만 외부 파트너가 pull 해야 한다면 그 패키지만 public 으로
- **수명 정책 분리 가능** — 트래픽 많은 서비스는 retention 길게, 적은 서비스는 짧게
- **검색·트리아지** — 각 서비스의 이미지 히스토리가 깔끔하게 분리되어 보임
- **vulnerability triage** — Trivy/GitHub Security 가 패키지별로 CVE 를 표시

> `_template` 은 4 서비스의 베이스 코드 디렉토리일 뿐, **별도 이미지를 만들지 않는다**.
> 4 서비스 이미지가 _template 코드에서 파생되어 빌드된다.

---

## 2. 이미지 시각화

```
┌──────────────────────────────────────────────────────────────────────┐
│ GitHub.com  (melanieing 계정)                                         │
│                                                                      │
│  Repository                  Packages (GHCR)                         │
│  ┌────────────────────┐     ┌───────────────────────────────────┐    │
│  │ cicd-project       │ ──> │ ghcr.io/melanieing/account        │    │
│  │   services/account │     │   tags: <git-sha-1>, <git-sha-2>… │    │
│  │   services/transfer│ ──> │ ghcr.io/melanieing/transfer       │    │
│  │   services/loan    │ ──> │ ghcr.io/melanieing/loan           │    │
│  │   services/notif…  │ ──> │ ghcr.io/melanieing/notification   │    │
│  └────────────────────┘     └───────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼  pull
                          ┌───────────────┐
                          │ kind cluster  │
                          │ payment-{dev, │
                          │      prod}    │
                          └───────────────┘
```

OCI label `org.opencontainers.image.source=https://github.com/melanieing/cicd-project`
가 Dockerfile 에 박혀 있어 GHCR UI 에서 각 패키지의 "Connected repository" 가
자동으로 cicd-project 로 연결된다.

---

## 3. 태그 정책

### 3.1 기본 태그: `<git-sha>` (immutable)

CI 가 push 하는 모든 이미지는 **commit SHA (40 hex)** 를 태그로 단다.

```
ghcr.io/melanieing/account:e9940ae...c0dec0
                          └────── git rev-parse HEAD ──────┘
```

이유:
- **재현성** — 동일 SHA 의 코드 → 동일 이미지. K8s rollout 시 정확히 어떤 코드가 떴는지 추적 가능.
- **Immutable** — 같은 SHA 로 두 번 push 해도 결과가 같아야 함. CI 가 같은 SHA 에 다른 이미지를 덮어쓰지 못하게 하는 보호 장치.
- **GitOps 친화** — ArgoCD 의 image updater 가 "최신 태그를 찾아 자동 commit" 할 때 `<git-sha>` 같은 immutable 태그가 안전하다.

### 3.2 사용 안 함: `latest`

`latest` 태그는 **의도적으로 사용하지 않는다**. 이유:
- mutable — 어제의 latest 와 오늘의 latest 가 다른 image
- 어떤 git commit 인지 즉시 알 수 없음
- K8s 가 `imagePullPolicy: Always` 가 아니면 캐시된 latest 를 그대로 쓰는 함정

### 3.3 부가 태그 (선택): `<short-sha>`, `v<x.y.z>`

- **short SHA (7 hex)**: 사람이 읽기 편한 보조 태그. CI 에서 함께 push 가능.
- **release tag** (`v1.0.0`): GitHub Release 가 만들어질 때 추가 push (EPIC 9 의 README polish 단계에서 검토).

본 프로젝트 EPIC 3 단계는 git-sha 만 사용. 부가 태그는 후속 작업.

---

## 4. 가시성 (Visibility) 와 풀 권한

### 4.1 정책: public 패키지

본 프로젝트의 4 패키지는 모두 **public**. 이유:
- K8s 의 imagePullSecret 설정 부담 제거 (kind cluster 에서 인증 없이 pull)
- 포트폴리오 — 채용 담당자가 GHCR UI 에서 이미지 자체를 볼 수 있어야 함
- 0원 비용 — public 패키지는 storage / bandwidth 무료

### 4.2 push 권한

CI workflow 가 `GITHUB_TOKEN` 으로 push. workflow yaml 에 다음 권한 부여 필요:

```yaml
permissions:
  contents: read
  packages: write   # ← GHCR push 권한
```

별도 PAT (Personal Access Token) 발급은 **불필요** — `GITHUB_TOKEN` 이 workflow 실행 동안만 유효한 자동 토큰이라 누출 위험 최소.

### 4.3 docker login 명령

CI 워크플로의 push 단계 (Task 3.3 에서 `.github/workflows/ci.yml` 에 들어간다):

```yaml
- name: Login to GHCR
  uses: docker/login-action@<sha-pin>
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

---

## 5. 수명 정책 (R-B2-O2 — Untagged 자동 삭제)

GHCR 의 **untagged 이미지** 는 가만히 두면 무한 누적된다.
같은 git-sha 로 빌드한 이미지가 같은 태그를 새로 받으면 이전 이미지가 untagged 가 되어 남는다.
또한 multi-platform 빌드의 manifest list 는 platform 별 sub-image 를 untagged 로 보유한다 (정상).

본 프로젝트는 **30 일 이상 untagged 상태인 이미지를 자동 삭제**하는 정책을 적용한다.

### 5.1 적용 절차 (수동, GitHub UI)

GHCR 의 retention policy 는 매니페스트화되어 있지 않아 GitHub UI 에서 설정해야 한다 (2026-05 기준).
4 패키지 각각에 동일 정책을 한 번씩 적용한다.

#### Step 1. 패키지 상세 페이지로 이동

```
https://github.com/users/melanieing/packages/container/account/settings
https://github.com/users/melanieing/packages/container/transfer/settings
https://github.com/users/melanieing/packages/container/loan/settings
https://github.com/users/melanieing/packages/container/notification/settings
```

> 각 패키지가 처음 push 된 후에야 위 URL 이 유효해진다.
> EPIC 3 의 ci.yml 이 첫 push 를 한 다음에야 이 단계가 의미 있어진다.

#### Step 2. "Manage Actions access" 영역 아래의 retention 설정

- "Manage Actions access" 를 cicd-project 리포로 연결 (CI 가 push 가능하도록)
- 페이지 하단의 **"Manage versions"** 또는 **"Pruning policy"** 영역에서:
  - `Untagged versions only`
  - `Older than: 30 days`
- `Save` 클릭

#### Step 3. 적용 전후 캡처

- 정책 적용 전: untagged 이미지 카운트 캡처 → `docs/screenshots/ghcr-retention-before.png`
- 정책 적용 후 (다음 주 동일 시각): 카운트 변화 캡처 → `docs/screenshots/ghcr-retention-after.png`

> **참고**: GitHub 의 retention 정책은 **즉시 발동하지 않는다.**
> 매일 1 회 정도 백그라운드 작업으로 정리되므로 즉각적인 카운트 감소를 기대하지 말 것.

### 5.2 자동화 가능성 (선택, EPIC 9 후보)

GHCR 의 패키지 삭제는 GitHub REST API 로 호출 가능:
```
DELETE /user/packages/container/<package>/versions/<version_id>
```

`actions/delete-package-versions` 액션을 사용하면 workflow 로 자동화 가능:

```yaml
- uses: actions/delete-package-versions@<sha-pin>
  with:
    package-name: account
    package-type: container
    min-versions-to-keep: 5
    delete-only-untagged-versions: true
```

CI workflow 에 일부로 넣으면 매 push 마다 정리 가능. 다만 본 프로젝트는 단순화를 위해
**UI 정책 + 캡처** 까지만 시연하고, 자동화 워크플로는 산출물에서 제외.

---

## 6. CI 가 push 하는 이미지 명명 규칙 (요약)

`.github/workflows/ci.yml` (EPIC 3 작성 예정) 의 push 단계는 다음 규칙을 따른다:

| 항목 | 값 |
|---|---|
| Registry | `ghcr.io` |
| Owner | `${{ github.repository_owner }}` (= `melanieing`) |
| Repository | `<service-name>` (예: `account`, `transfer`, `loan`, `notification`) |
| Tag (primary) | `${{ github.sha }}` (40-hex git-sha) |
| Tag (secondary) | `sha-${GITHUB_SHA::7}` (7-hex short-sha, 가독성용) |
| Pull policy | K8s Deployment 의 `imagePullPolicy: IfNotPresent` (sha 가 immutable 이라 캐시 안전) |

예시 push:
```bash
docker push ghcr.io/melanieing/account:e9940aef7c8d3c44d1e8ba3a2f3b0e1c0dec0aa1
docker push ghcr.io/melanieing/account:sha-e9940ae
```

---

## 7. KT 클라우드로 마이그레이션 시나리오

원 요구사항(R-B2-M2) 의 KT 클라우드 Container Registry 로 옮길 때의 절차를 짧게 기록한다
(상세는 ADR 0002 에서 다룬다).

1. KT 클라우드 콘솔에서 4 개 repo 생성: `account`, `transfer`, `loan`, `notification`
2. KT 클라우드 IAM 으로 push/pull 권한 토큰 발급
3. CI workflow 의 docker login 단계 변경:
   ```yaml
   registry: <kt-cloud-registry-url>
   username: ${{ secrets.KTCLOUD_USER }}
   password: ${{ secrets.KTCLOUD_TOKEN }}
   ```
4. 이미지 이름의 prefix 만 변경 (`ghcr.io/melanieing/` → `<kt-registry>/<project>/`).
5. K8s ImagePullSecret 추가 (KT 클라우드 레지스트리는 보통 인증 필요).
6. Helm chart 의 `image.repository` 값 교체.

코드 측면 변화는 5 라인 미만으로 끝나고, 나머지는 인프라 / 권한 설정. 본 프로젝트는 이 마이그레이션 자체를 데모하지는 않고 ADR 에 이행 가능성만 명시.

---

## 8. 참고

- [GHCR Documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [docker/login-action](https://github.com/docker/login-action)
- [actions/delete-package-versions](https://github.com/actions/delete-package-versions)
- [OCI Image Spec — annotations.image.source](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
