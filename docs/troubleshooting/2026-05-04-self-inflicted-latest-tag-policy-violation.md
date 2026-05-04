# `:latest` 태그를 추가한 직전 fix 가 docs/registry.md §3.2 정책 위반이었던 사례 — 자기 결정 docs 미참조

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (정책-구현 모순. portfolio 일관성 평가 손상 가능) |
| **Affected** | `.github/workflows/ci.yml` push step, `charts/payment-platform/values*.yaml` 의 imageTag default |
| **Tags** | `policy-vs-implementation`, `verification-scope`, `self-doc-review`, `helm`, `tag-policy` |
| **Related commits** | (이 사건을 수정하는 커밋), 직전 잘못된 fix 의 한 commit |

---

## Summary

직전 사건 (helm install ImagePullBackOff) 의 fix 로 CI 에 `:latest` 태그 push 추가 + values default `imageTag: latest` 채택.
사용자 검토 결과 **이 변경은 본 프로젝트의 자기 결정 정책 `docs/registry.md` §3.2 ("`:latest` 태그는 의도적으로 사용하지 않는다") 와 정면 충돌**.
원인은 단순 — 직전 fix 작성 시 `docs/registry.md` 를 읽지 않고 "first-install UX" 만 고려했음.

해결: `:latest` 흔적 전부 revert + `imageTag` 미설정 시 `helm fail()` 로 즉시 abort + chart README 의 first-install 절차에 명시적 `--set global.imageTag=<sha>` 명령 안내.

이 사건은 "외부 시스템" 검증 누락이 아니라 **자기 결정 docs 의 검증 누락** 이라는 새 카테고리.

---

## Symptom

사용자 지적:
> "근데 우리 latest 태그를 쓰지 않기로 정하지 않았어?
> docs/registry.md 의 태그정책에 보면 3.2에 있지 않아? 이 정책을 바꿔도 바람직한지 검증해."

`docs/registry.md` §3.2 인용:
> ### 3.2 사용 안 함: `latest`
> `latest` 태그는 **의도적으로 사용하지 않는다**. 이유:
> - mutable — 어제의 latest 와 오늘의 latest 가 다른 image
> - 어떤 git commit 인지 즉시 알 수 없음
> - K8s 가 `imagePullPolicy: Always` 가 아니면 캐시된 latest 를 그대로 쓰는 함정

직전 commit 의 ci.yml:
```yaml
tags: |
  ${{ steps.refs.outputs.tag_full }}
  ${{ steps.refs.outputs.tag_short }}
  ${{ steps.refs.outputs.image }}:latest    # ← 정책 위반
```

→ 정책 문서가 명시적으로 금지한 패턴을 코드 fix 가 도입.

---

## Investigation & Root cause

### 정책 재검증 (혹시 정책이 틀렸나?)

| 평가 | `:latest` 도입 | 현행 sha-only |
|---|---|---|
| 재현성 | ❌ mutable | ✅ sha 는 immutable |
| 추적성 | ❌ commit 추론 필요 | ✅ tag = commit |
| GitOps | ❌ updater 가 latest watch 는 anti-pattern | ✅ updater 가 sha 패턴 watch |
| K8s 캐싱 | ❌ imagePullPolicy:Always 아니면 stale | ✅ sha 다르면 무조건 pull |
| 일관성 | ❌ docs 와 모순 | ✅ docs-code 일치 |
| First-install UX | ✅ 한 줄 install | ⚠ 사용자가 sha override |

5:1 로 sha-only 정책 우월. UX 손실은 chart README + helm `fail()` 로 보완 가능. **정책 변경 정당화 안 됨**.

### 메타 결함 — 자기 결정 docs 의 검증 누락

직전 fix 는 사용자의 ImagePullBackOff 증상을 보고 가장 빠른 unblock 으로 `:latest` 도입을 선택.
그 시점에 다음 검증을 하지 않음:
1. **`docs/registry.md` 의 태그 정책 확인**
2. **chart의 GitOps 호환성** (ArgoCD image updater + mutable tag = 미흡)
3. **자기 commit 의 정합성** (CI 와 chart values 가 같은 태그를 다루는가)

A-5 의 "실행으로 검증" 정신은 코드뿐 아니라 **자기 결정 docs 의 정합성** 도 포함해야 한다.
이전 사건 (GHCR retention UI) 도 자기 결정 가정의 미검증 사례 — 메타 결함 같은 카테고리.

---

## Fix

### 1. `.github/workflows/ci.yml`
push step 에서 `:latest` 태그 제거. 주석으로 정책 근거 명시:
```yaml
# `:latest` 같은 mutable 태그는 의도적으로 push 하지 않는다.
# docs/registry.md §3.2 의 결정: 재현성·추적성·캐싱 함정 회피.
```

### 2. `charts/payment-platform/values.yaml` + values-{dev,prod}.yaml
`imageTag: latest` → `imageTag: ""` + 주석으로 정책 근거 + override 명령 예시.

### 3. `charts/payment-platform/templates/_helpers.tpl`
`payment-platform.requireImageTag` helper 추가:
```helm
{{- define "payment-platform.requireImageTag" -}}
{{- if not .Values.global.imageTag -}}
{{- fail (printf "global.imageTag must be set to a CI-pushed git sha. Example:\n  helm install ... --set global.imageTag=$(git rev-parse origin/main)\nSee charts/payment-platform/README.md and docs/registry.md.") -}}
{{- end -}}
{{- end -}}
```

`templates/deployment.yaml` 첫 줄에서 `include` 호출.
빈 `imageTag` 로 helm 시도 시 `fail()` 가 즉시 abort + 안내 메시지.

### 4. `charts/payment-platform/README.md`
"사전 점검" 섹션 정정:
- 1번 항목을 "`:latest` 태그 존재 여부" → "**sha 태그** 존재 여부 + 본 chart 는 정책상 `:latest` 미사용" 으로 변경
- Quickstart 섹션의 helm install 예시에 `--set global.imageTag=$(git rev-parse origin/main)` 명시
- EPIC 5 의 ArgoCD image updater 가 자동화할 예정임을 부기

### 5. 검증 (sandbox)

- `helm template ... -f values-dev.yaml`: **fail() 발동 확인**, 메시지 정확히 표시
- `helm template ... --set global.imageTag=abc1234`: 17 docs 정상 렌더, 모든 image 라인이 `:abc1234` 로 채워짐
- `kubeconform`: 17/17 valid (sha override 시)
- `helm lint`: clean
- `actionlint` (ci.yml): clean

---

## Lessons learned

1. **자기 결정 docs 도 외부 시스템과 같은 검증 대상이다.**
   `docs/registry.md`, `docs/requirements.md`, ADR 등 프로젝트 자체의 정책 문서는
   코드 변경 시 1차로 참조해야 하는 source of truth.
   "외부 docs (GitHub Docs, Helm Docs) 검증" 만큼 "자기 docs 검증" 도 빠짐없이.
2. **A-5 의 검증 범위 추가 — 정책 정합성 점검.**
   기존 A-5 가 "runtime / static / cluster-state / registry-state" 등을 다뤘다면,
   **policy-state (자기 결정 docs 와의 정합성)** 도 새 layer 로 명시 필요.
3. **fix 가 또 다른 정책 위반을 만들지 않게 한다.**
   증상 기반 unblock 은 빠르지만, 그 fix 가 자기 docs 와 충돌하면 portfolio 일관성이 망가짐.
   fix 후 반드시 self-review 루프 ("이 변경이 어떤 자기 docs 에 닿는가?") 를 추가해야 함.
4. **Helm 의 `fail()` 은 정책을 코드로 강제하는 좋은 패턴.**
   default values 를 비워두고 user 입력을 강제하는 게 docs 만으로 안내하는 것보다 훨씬 강력.
   주요 정책 (이미지 태그 패턴, 비밀번호 placeholder 거부 등) 에 활용 권장.
5. **이 사건과 이전 사건들의 공통 메타 결함 — verification scope 가 좁음.**
   A-5 가 도입된 이래 7건 이상의 troubleshooting 이 누적됐고, 그중 5건이 **검증 범위 누락** 카테고리:
   - test 환경 오염 (DATABASE_URL leak)
   - test-all.sh 의 cd 누락
   - dependabot github-actions ecosystem 입력 부재
   - Helm chart IDE 결함
   - Helm install Task 1.4 ownership
   - Helm install ImagePullBackOff (registry-state)
   - 본 사건 (policy-state)
   이쯤에서 **"검증 범위" 자체를 명시적 체크리스트** 로 정리해야 한다 (CLAUDE.md 차후 업데이트 후보).
