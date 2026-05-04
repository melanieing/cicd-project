# CI workflow 첫 push 가 path filter 의 빈 매트릭스로 모든 후속 잡 skip 한 사례

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 낮음 (실패는 아님, UX 혼란) |
| **Affected** | `.github/workflows/ci.yml` 첫 머지 직후 첫 자동 run |
| **Tags** | `github-actions`, `path-filter`, `dorny`, `matrix`, `ux` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

EPIC 3 의 ci.yml 을 main 으로 머지한 직후 자동 실행된 push 트리거 run 이
`Detect changed services` 만 success 로 끝나고 `test / build-scan-push / notify` 가 모두 skipped 로 표시.
원인은 단순 — **그 푸시가 변경한 파일은 `.github/workflows/ci.yml` 단 한 개 뿐** 이었고,
4 service 디렉토리 어느 것도 안 건드렸기 때문에 dorny/paths-filter 가 빈 배열을 반환했다.
"path filter 가 변경된 service 만 빌드한다" 는 정의 그대로의 동작이지만,
**workflow 자체나 `_template` (4 서비스 코드 베이스) 같은 공유 영역의 변경은 4 서비스 모두에 영향**
이라는 점이 누락되어 있었다. 공유 변경 / `workflow_dispatch` 시 전체 매트릭스로 fallback 하는 분기 추가.

---

## Symptom

GitHub Actions UI 의 첫 run:
```
ci.yml — on: push
  ✅ Detect changed services       (3s)
  ⊘  Test (matrix)                  (skipped)
  ⊘  Build / Scan / Push (matrix)   (skipped)
  ⊘  Notify Slack                   (skipped)
Total duration: 7s   Status: Success
```

Detect 잡 로그:
```
Detected 1 changed files
Filter account = false
Filter transfer = false
Filter loan = false
Filter notification = false
Changes output set to []
Detected services: []
```

PR diff 는 `.github/workflows/ci.yml` 1 파일.

---

## Investigation & Root cause

### 가설: path filter 자체 결함?

dorny/paths-filter 는 **`base..head` git diff** 의 파일 목록을 패턴별로 분류한다.
이번 케이스에 들어온 파일은 `.github/workflows/ci.yml` 한 개. 우리 필터에는 4 서비스만 정의되어 있고
워크플로 파일을 매칭할 패턴은 없음 → 4 패턴 모두 false → 빈 배열 → has-changes=false.

이는 **명세 그대로의 동작**이지 결함이 아님.

### 진짜 원인 (설계 누락)

원 워크플로의 가정:
> "service 코드가 바뀐 만큼만 빌드해서 시간 절약"

빠진 가정:
1. **워크플로 자체** 가 바뀌면 → 빌드/테스트 로직이 변했다는 뜻 → 모든 서비스를 새 로직으로 한 번 돌려봐야 안전
2. **`services/_template/`** 가 바뀌면 → 4 서비스의 코드 베이스가 변했다는 뜻 → 모두 재빌드 필요
3. **`workflow_dispatch`** 수동 트리거 → 사용자가 "전부 다 돌려보자" 의도로 호출 → 전체 빌드가 합당

이 셋이 빠져 있어 **첫 푸시(워크플로 도입) 가 자동으로는 어떤 service 도 빌드하지 못함** 이라는 직관에 반하는 결과.

---

## Fix

### 즉시 — `Build matrix array` step 의 분기 보강

```bash
ALL='["account","transfer","loan","notification"]'

if [[ "$EVENT" == "workflow_dispatch" ]]; then
    arr="$ALL"; reason="manual workflow_dispatch trigger"
elif [[ "$WORKFLOW_CHANGED" == "true" ]] || [[ "$TEMPLATE_CHANGED" == "true" ]]; then
    arr="$ALL"; reason="shared change - rebuild all services"
else
    arr='[]'
    [[ "$ACCOUNT" == "true" ]] && arr=$(echo "$arr" | jq -c '. + ["account"]')
    ... (나머지 3 service 동일 패턴)
    reason="per-service path filter"
fi
```

`paths-filter` 의 `filters` 블록에도 두 항목 추가:
```yaml
workflow: '.github/workflows/**'
template: 'services/_template/**'
```

### 검증 (sandbox)

7 시나리오 (workflow-only / account-only / multi-service / template / dispatch / nothing / mixed) 입력으로
bash 로직 직접 실행 → 7/7 PASS. actionlint + JSON schema 재검증 통과.

### 결과적으로 사용자 시나리오의 새 동작:
```
PR #19 머지 → main push → workflow filter true → 4 service 모두 빌드/스캔/Slack 알림.
```

---

## Lessons learned

1. **Path filter 는 "변경 파일 → 영향 service" 매핑인데, 그 매핑은 자동으로 추론되지 않는다.**
   영향 범위가 광범위한 공유 자원(workflow, _template, shared lib, base image 정의 파일 등) 은
   필터 정의에 명시적으로 포함하고, 그것들이 변경되면 전체 매트릭스로 fallback 시켜야 직관에 맞다.
2. **`workflow_dispatch` 는 항상 "전체 빌드" 의도로 해석.**
   path filter 의 base..head 비교가 의미 없거나 동작 안 하는 케이스(수동 재실행, 특정 SHA 빌드)
   에서는 전체 매트릭스로 fallback 이 안전.
3. **첫 도입 직후의 자동 run 은 항상 "워크플로 자체 변경" 케이스다.**
   설계 시 첫 run UX 를 점검해야 "왜 안 도냐" 같은 즉각 혼란 회피.
4. **Empty matrix 는 "에러" 가 아니라 "skipped" 라 GHA UI 에서 잘 안 보인다.**
   matrix 가 비면 전체 워크플로가 success 로 표시되어 진짜 통과인지 no-op 인지 모호함.
   향후 `notify` 잡이라도 "no-op 여부" 를 명시적으로 알리도록 메시지에 services 목록을 항상 포함.
