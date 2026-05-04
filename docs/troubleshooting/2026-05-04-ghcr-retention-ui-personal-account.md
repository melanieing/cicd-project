# GHCR per-package retention UI 가 개인 계정에 없어 docs 안내가 어긋난 사례

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 낮음 (사용자가 docs 따라 했을 때 막힘 — 문서 결함) |
| **Affected** | `docs/registry.md` §5.1 의 GitHub UI 절차 안내 |
| **Tags** | `ghcr`, `retention`, `documentation`, `personal-account-vs-org` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

R-B2-O2 (untagged 자동 삭제) 적용을 위해 docs/registry.md §5.1 에 안내한 GitHub UI 절차를
사용자가 따라갔으나 **"Manage versions" / "Pruning policy" 섹션이 화면에 존재하지 않음**.
원인: 해당 UI 는 **organization 계정에서만 노출**되며 개인 계정(`melanieing`) 의 패키지 settings
페이지에는 Repository source / Manage Actions access / Manage Codespaces access / Inherited access
네 섹션만 존재. 작성 시 "GHCR retention 정책은 UI 에서 설정 가능" 이라는 일반 진술을 검증 없이 받아
적은 게 결함의 뿌리.

해결: 개인 계정에서 사실상 유일한 자동화 경로인 **GitHub Action `actions/delete-package-versions` 기반
cron workflow** 를 신설(`.github/workflows/ghcr-cleanup.yml`)하고 docs/registry.md §5 를 그 절차로 재작성.

---

## Symptom

사용자 화면 (`https://github.com/users/melanieing/packages/container/account/settings`):

```
Repository source         (org.opencontainers.image.source 값 표시)
Manage Actions access     (cicd-project 연결됨, ✓)
Manage Codespaces access  (cicd-project, Read 권한)
Inherited access          (Inherit access from source repository ✓)
```

기대했던 "Manage versions" / "Pruning policy" 섹션이 없음.

---

## Investigation & Root cause

### 1차 가설 (오답): UI 가 페이지 더 아래에 있을 것

스크롤 끝까지 확인. Inherited access 가 마지막. Pruning 관련 섹션 없음.

### 확정 원인

GitHub Container Registry 의 **per-package retention policy UI 는 organization 계정의 패키지에서만 노출**.
개인 사용자(personal account) 의 패키지 settings 페이지에는 retention 옵션이 제공되지 않는다 (2026-05 기준).

증거:
- GitHub Docs: "Configuring a packages access control and visibility" 페이지의 retention 섹션은 organization 컨텍스트 예시만 제공.
- `actions/delete-package-versions` 액션의 README 는 "현재 GitHub Packages 의 패키지 retention 정책을 수동·자동으로 정리하기 위한 도구" 로 자기 자신을 소개 — 즉 빌트인 retention 의 부재를 전제로 만들어진 액션.
- 사용자 스크린샷에 4 개 섹션만 있고 Manage versions 가 부재함을 직접 관찰.

### 메타 결함

`docs/registry.md` 작성 시 "GHCR retention UI" 의 존재를 organization 기준 GitHub Docs 로부터 일반화해
"개인 계정에도 동일하게 있을 것" 으로 추론. **검증 없이 추론을 사실로 기재한 결과**.

CLAUDE.md A-2 (기술 추천 검증) 와 A-5 (실제 실행 검증) 의 정신은 docs 에도 동일하게 적용되어야 한다는 교훈.

---

## Fix

### 즉시 — `docs/registry.md` §5 재작성 + cleanup workflow 신설

1. `docs/registry.md` §5 를 다음 구조로 재작성:
   - **5.1 권장·실제 채택**: GitHub Action 기반 cron workflow (`actions/delete-package-versions@v5`)
   - **5.2 수동 옵션**: 개별 버전 페이지에서 `Delete this version` 클릭 (1회용)
   - **5.3 organization 계정으로 옮길 경우**: orgs UI 에 Manage versions 섹션 노출 — 본 프로젝트는 개인 계정이라 5.1 사용
2. `.github/workflows/ghcr-cleanup.yml` 신설:
   - `cron: '0 1 * * 1'` (매주 월요일 01:00 UTC)
   - 4 패키지를 매트릭스로 병렬 정리
   - `min-versions-to-keep: 5`, `delete-only-untagged-versions: true` 로 안전 경계
   - `workflow_dispatch` 도 정의해 즉시 수동 실행 가능

### 검증 (sandbox, A-5)

- `actionlint` ghcr-cleanup.yml: clean (exit 0)
- jsonschema (github-workflow.json): pass
- `actions/delete-package-versions@v5` 실재 확인 (search → official action repo, v5 가 container package-type 지원하는 메이저)

---

## Lessons learned

1. **GitHub 의 기능은 personal vs organization 에서 가시성·옵션이 다르다.**
   docs 작성 시 화면 구성을 안내할 때는 어느 계정 종류 기준인지 명시하거나, 개인 계정 기준을 default 로 잡는 게 안전.
2. **빌트인 UI 가 없는 기능은 자동화 액션의 존재 자체가 증거다.**
   `actions/delete-package-versions` 같은 1st-party 액션이 GitHub 공식으로 존재한다는 사실은
   "그 기능이 UI 로 충분하지 않다" 는 신호. 액션 README 의 motivation 섹션을 한 번 읽어보면
   UI 의 한계를 빠르게 파악 가능.
3. **docs 의 "GitHub UI 클릭 절차" 는 기술 추천만큼이나 검증이 필요하다.**
   A-2 (기술 검증) 가 라이브러리 버전에만 적용되는 게 아니라, GitHub UI 의 메뉴 구조 같은
   "외부 시스템의 현재 상태" 도 같은 기준으로 검증 대상.
4. **Action 기반 retention 은 UI 보다 오히려 portfolio 측면에서 유리하다.**
   "왜 cron workflow 로 했나" 라는 질문에 "개인 계정의 GHCR UI 한계 + 코드로 정책을 표현하는 IaC 사고방식" 이라는
   양방향 답변이 가능. 면접 시 좋은 대화 소재.
