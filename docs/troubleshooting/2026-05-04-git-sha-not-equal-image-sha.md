# `git rev-parse origin/main` 가 GHCR image sha 와 같다고 가정한 instruction 의 결함

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (사용자가 helm upgrade 할 때마다 운에 의존) |
| **Affected** | `charts/payment-platform/README.md` 의 first-install 명령, `scripts/migrate-to-helm.sh` 의 default sha 선택 |
| **Tags** | `helm`, `image-tag`, `ghcr`, `path-filter`, `verification-scope`, `cli-instruction` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

내가 instruction 으로 "`--set global.imageTag=$(git rev-parse origin/main)`" 을 반복적으로 제시.
이 명령은 main 의 가장 최근 commit sha 를 출력. 그러나 **GHCR 에 존재하는 image 의 sha 는 CI 가 그 commit 에서 service 빌드를 트리거했을 때만** 같은 값을 가진다. 본 프로젝트의 path-filter 로직 때문에 다음 경우 main 의 sha 와 GHCR image 의 sha 가 다르다:
- main 의 가장 최근 commit 이 docs-only 인 경우 (CI 자체가 빌드 안 함)
- main 의 가장 최근 commit 이 한 service 만 변경한 경우 (다른 3 service 는 그 sha 의 image 없음)

수정: GHCR REST API 로 실제 존재하는 sha 를 조회하는 helper script (`scripts/latest-image-sha.sh`) 신설 + chart README 의 first-install 명령을 그 script 사용으로 변경 + GHCR UI 수동 fallback 도 명시.

---

## Symptom

사용자 지적:
> "git rev-parse origin/main 를 썼잖아. 근데 가장 최신 main 커밋 해시값이 반드시 GHCR 의 이미지 태그로 올라가있다는 보장이 있을까? 그러니까 해당 이미지가 없다고 자꾸 에러가 나지"

본 프로젝트의 CI 트리거 매트릭스 (path-filter):

| commit 변경 영역 | 빌드되는 service |
|---|---|
| `.github/workflows/**` 변경 | 4 service 전부 |
| `services/_template/**` 변경 | 4 service 전부 |
| 4 service 모두 변경 (e.g. dependabot pip 그룹) | 4 service 전부 |
| `workflow_dispatch` 수동 트리거 | 4 service 전부 |
| `services/<one>/**` 만 변경 | 그 service 만 |
| `docs/**` 만 변경 | **빌드 안 함** |

→ main 의 latest commit 이 위 표의 마지막 행이라면 그 sha 의 image 는 GHCR 에 없음.

---

## Investigation & Root cause

### 잘못된 가정

| 내가 가정 | 실제 |
|---|---|
| "main 의 latest sha 가 곧 GHCR 의 latest image sha" | **거짓**. CI 트리거에 종속. |
| "사용자가 PR 머지 사이클을 따른다 → 매 머지마다 빌드" | 부분적 사실. path-filter 로 인해 service 코드 변경이 없으면 빌드 안 됨 |

### 메타 결함

이번 case 도 직전 사건들과 같은 클래스 — **외부 시스템(GHCR) 의 실제 상태를 검증하지 않고 추정으로 instruction 만듦**.

24 시간 안에 같은 메타 결함의 5번째:
1. Task 1.4 ownership (cluster-state)
2. ImagePullBackOff `:latest` 부재 (registry-state)
3. self-inflicted `:latest` 정책 위반 (policy-state)
4. K8s env substitution ordering (k8s-runtime-state)
5. **이번 — git sha == image sha 가정 (registry-state, instruction-level)**

특히 4 번과 5 번은 같은 커밋의 instruction 안에서 **동시에** 발생. helm upgrade 명령 한 줄에 (a) `--set global.imageTag=$(git rev-parse origin/main)` 의 가정 결함, (b) 그 안의 chart 가 env ordering 결함 — 둘 다 사용자가 따라 했을 때 깨지는 형태.

### 옳은 접근

**GHCR REST API** 를 직접 조회해 패키지의 versions 목록에서 40-hex sha 태그를 가져온다:
```bash
gh api "/users/<owner>/packages/container/<svc>/versions" \
  | jq -r '.[].metadata.container.tags[]' \
  | grep -E '^[0-9a-f]{40}$' | head -1
```

이 결과가 "GHCR 에 실제 존재하는" sha. 4 service 가 같은 sha 를 가진다는 보장은 별개 문제 (위 표 참조)이지만, 적어도 한 service 의 sha 는 정확히 알 수 있다.

---

## Fix

### 즉시 — `scripts/latest-image-sha.sh` 신설

GHCR REST API 호출 → 40-hex 필터링 → 가장 최근 1 개 출력. gh CLI + jq 의존.
syntax check 통과 + error path (gh 미설치) 도 명확한 메시지 + exit 1.

사용:
```bash
SHA=$(./scripts/latest-image-sha.sh)
helm upgrade payment ... --set global.imageTag="$SHA"
```

### 즉시 — chart README 의 first-install 섹션 재작성

3 단계 우선순위로 명시:
1. **권장**: `scripts/latest-image-sha.sh` 결과 사용 (실제 GHCR 상태 기반)
2. **대안**: GHCR UI 에서 수동 복사 (script 의존 없음)
3. **마지막**: `git rev-parse origin/main` (불안정한 휴리스틱, 보장 없음)

### 장기 — ArgoCD image updater (EPIC 5)

EPIC 5 도입 후 image updater 가 새 sha 를 GHCR 에서 watch → values 파일에 자동 commit.
사용자가 imageTag 를 수동 지정할 일 자체가 사라진다.

### Sandbox 검증

- `bash -n scripts/latest-image-sha.sh`: clean
- script 실행 (gh 미설치 환경): 정확한 error 메시지 + exit 1
- chart README 의 새 섹션은 markdown render 만 검증 (실제 GHCR 호출은 사용자 환경)

---

## Lessons learned

1. **CLI instruction 의 모든 변수 substitution 은 명시적 검증.**
   `$(git ...)`, `$(kubectl ...)`, `$(curl ...)` 같은 substitution 결과가 사용 컨텍스트에 맞는지
   추론하지 말고 검증한다. 특히 외부 시스템과 매칭이 필요한 경우 직접 그 시스템에 질의.
2. **본 프로젝트의 path-filter 트리거 매트릭스를 README 어딘가에 박아두기.**
   "어떤 commit 이 어떤 service 를 빌드하나" 를 사용자가 즉시 알 수 있어야 한다.
   chart README 의 사전 점검 섹션에 추가 후보.
3. **A-5 의 검증 layer 분류표에 `instruction-state` 추가.**
   기존 layers (syntax / schema / cluster / registry / policy / k8s-runtime) 외에
   "내가 사용자에게 주는 명령의 substitution 결과가 실제로 옳은가" 도 검증 layer.
   이 layer 의 누락이 본 사건의 핵심.
4. **stateful 검증 누락의 빈도가 명백한 패턴.** 24 시간 안에 5번째.
   다음 chart-touching 작업 전 CLAUDE.md A-5 를 layer 별 명시 체크리스트로 정리해야 함 (별도 후속 commit).
