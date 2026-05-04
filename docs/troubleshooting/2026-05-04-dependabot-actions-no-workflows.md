# Dependabot github-actions ecosystem 이 workflows 부재로 매 스캔 fail 한 사례

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 낮음 (PR 생성 안 됨, 단지 Dependabot 잡 실패 로그 누적) |
| **Affected** | `.github/dependabot.yml` 의 `github-actions` ecosystem entry |
| **Tags** | `dependabot`, `github-actions`, `workflow`, `early-activation` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

Task 2.5 에서 Dependabot 에 3 개 ecosystem (docker / pip / github-actions) 를 동시 활성화했다.
docker 와 pip 는 의도대로 동작했지만 github-actions 는 매 스캔마다
"Dependabot couldn't find a <anything>.yml" 오류로 fail. 원인은 단순 — `.github/workflows/`
디렉토리는 만들었지만 실제 workflow 파일(`.yml`) 은 EPIC 3 에서 작성될 예정이라 아직 비어 있음.
ecosystem 을 일시적으로 주석 처리하고 EPIC 3 Task 3.1 (ci.yml 작성) 시 재활성화하기로 결정.

---

## Symptom

GitHub UI: `https://github.com/<owner>/cicd-project/network/updates`

```
actions                                 [Check for updates]

Recent jobs
  Version update XXXXXXXX
  Errored with the message "Dependabot couldn't find a <anything>.yml"
  No PRs affected         5 minutes ago         view logs
```

상세 로그:
> Dependabot requires a .yml to evaluate your GitHub Actions dependencies.
> It had expected to find one at the path: /action.yml or /.github/workflows/<anything>.yml.

---

## Investigation & Root cause

### 1차 가설: 권한/토큰 문제

처음에는 Dependabot 권한 부족이나 GitHub App 인증 이슈를 의심.
하지만 같은 리포의 docker / pip ecosystem 은 정상 동작 → 권한이 아니라 ecosystem 별 입력 부재가 원인.

### 확정 원인

`.github/workflows/` 디렉토리에는 `.gitkeep` 만 있고 `.yml` 파일이 없음.
github-actions ecosystem 은 입력이 0 개이면 **에러로 분류**해 jobs 로그에 fail 누적.

```bash
$ ls .github/workflows/
.gitkeep
```

EPIC 3 Task 3.0/3.1 에서 ci.yml 이 작성될 예정이라 의도적인 미완성 상태였지만,
Dependabot 은 그 사정을 알 수 없으므로 "설정만 활성화 + 대상 파일 없음" 을 오류로 간주.

---

## Fix

### 즉시 복구 — github-actions entry 주석 처리

`.github/dependabot.yml` 에서 github-actions ecosystem block 을 그대로 두되 `#` 으로 주석 처리.
EPIC 3 Task 3.1 작성 시 주석을 풀면 즉시 활성화.

```yaml
# - package-ecosystem: github-actions
#   directory: /
#   ...
```

블록 위에 사유 메모를 남겨 다음 작업자가 컨텍스트 없이 보고 헷갈리지 않게 함.

### 장기 방어

운영 원칙 추가: **"설정만 활성화 + 대상 파일 없음" 을 만들지 말 것.**
Dependabot 같은 자동화 도구는 입력이 0 인 경우 실패 처리하는 경우가 많다.
ecosystem 이나 자동화는 **그 입력이 실제로 존재하게 된 시점에 활성화** 한다.

---

## Lessons learned

1. **Dependabot github-actions ecosystem 은 workflows 가 적어도 1 개 있어야 한다.**
   디렉토리만 비어 있으면 매 스캔 fail. 활성화 타이밍을 입력의 존재 시점에 맞추는 게 좋다.
2. **자동화 도구의 "fail" 로그는 의도된 미완성에서도 발생한다.**
   "있어야 할 게 없다" 와 "있는데 잘못됐다" 둘 다 fail 로 표시되므로,
   설정 활성화 전에 "지금 입력이 0 개 아닌가?" 를 한 번 점검하는 습관 필요.
3. **단계적 작업 시 의존성 그래프를 의식한다.**
   "Task 2.5 (Dependabot) 가 Task 3.1 (ci.yml) 보다 먼저 들어오면 github-actions 부분은 미리 활성화하면 안 된다" 처럼,
   순서가 어긋날 때 활성화하면 안 되는 항목을 식별하는 점검을 backlog 작성 단계에서 했다면 본 사건은 회피 가능.
