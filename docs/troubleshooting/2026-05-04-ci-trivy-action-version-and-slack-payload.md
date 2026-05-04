# CI 실패 2건 동시 발생: trivy-action v0.36.0 미존재 + Slack payload JSON 깨짐

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (CI run 4 + 1 잡 fail, 사용자가 첫 실제 빌드에서 막힘) |
| **Affected** | `.github/workflows/ci.yml` 의 Trivy scan, Slack notification |
| **Tags** | `github-actions`, `trivy`, `slack`, `json`, `version-pin`, `supply-chain` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

EPIC 3 ci.yml 의 첫 머지 후 자동 run 에서 4 개 build-scan-push 잡과 notify 잡 모두 fail.
원인은 두 개의 독립된 결함이 동시 노출된 것:

1. **Trivy** — `aquasecurity/trivy-action@0.36.0` 핀이 잘못. 그 태그는 실재하지 않음.
   docs 검색 결과를 그대로 받아써서 검증 없이 사용한 게 원인.
2. **Slack** — `needs.changes.outputs.services` 의 JSON 배열 문자열을 그대로 페이로드의
   string field 에 보간해서 내부 `"` 가 JSON 을 깨뜨림.

전자는 `aquasec/trivy:0.70.0` Docker image 직접 호출로 우회 (action wrapper 자체를 제거 → 공급망 표면 축소).
후자는 jq 로 사람이 읽기 좋은 콤마 분리 문자열로 사전 가공.

---

## Symptom

GitHub Actions UI:
```
ci.yml — on: push (PR #20 merge)
  ✅ Detect changed services
  ✅ Test (account, transfer, loan, notification)   [4 잡 모두 통과]
  ❌ Build / Scan / Push (account)
     Unable to resolve action `aquasecurity/trivy-action@0.36.0`,
     unable to find version `0.36.0`
  ❌ Build / Scan / Push (transfer)   [동일 메시지]
  ❌ Build / Scan / Push (loan)       [동일 메시지]
  ❌ Build / Scan / Push (notification)  [동일 메시지]
  ❌ Notify Slack
     Invalid input! Failed to parse contents of the provided payload
```

---

## Investigation & Root cause

### 결함 1 — trivy-action v0.36.0 미존재

#### 진단 명령
```bash
$ curl -sL https://api.github.com/repos/aquasecurity/trivy-action/tags
# → v0.35.0 까지만 존재. v0.36.0 없음.
```

#### 원인
`docs/tech-stack-versions.md` 작성 시 WebSearch 결과:
> "the current recommended version shown in documentation is v0.36.0, which post-dates the security incidents."

이 문구를 검증 없이 그대로 핀 했음. 실제 release 페이지에서 v0.36.0 은 발견되지 않았는데
서치 결과의 "documentation 에 권장된" 표현을 "실재 태그" 로 오인.

또한 2026-03-19 공급망 사건으로 v0.34.2 이하 모든 태그가 force-push 되어
**기존 어떤 태그도 안전성을 보장 못 함**. v0.35.0 은 사건 직전 release 라 검증 부담.

#### Fix 방향성

옵션 A: 사후 새 태그 (v0.35.0 등) 의 SHA 핀 — 검증 부담
옵션 B: action wrapper 제거 + 공식 Trivy CLI Docker image 직접 호출 — **선택**

옵션 B 의 장점:
- 공급망 표면 제거 (third-party action 의존 없음)
- Trivy CLI 자체는 우리 `tech-stack-versions.md` 에 이미 0.70.0 으로 핀
- Docker image tag 는 immutable (re-push 불가)
- 호출이 명시적이라 디버깅 쉬움

### 결함 2 — Slack payload JSON parse 실패

#### 원인 분석

워크플로의 payload 라인:
```json
{ "title": "Services", "value": "${{ needs.changes.outputs.services }}", "short": false }
```

`needs.changes.outputs.services` 값:
```
["account","transfer","loan","notification"]
```

이게 string field 안에 그대로 보간되면:
```json
{ "title": "Services", "value": "["account","transfer","loan","notification"]", "short": false }
                                  ▲ JSON parser 가 첫 " 에서 string 종료로 인식 → 파싱 실패
```

**JSON 안에 JSON-encoded 문자열을 그대로 박아넣은 게 원인**.
GHA 의 string interpolation 은 escape 를 자동으로 해주지 않으므로 사용자가 책임.

#### Fix

`Determine overall status` step 에서 jq 로 평탄화:
```bash
services_json='${{ needs.changes.outputs.services }}'
if [[ -z "$services_json" || "$services_json" == "[]" ]]; then
  services_display="none"
else
  services_display=$(echo "$services_json" | jq -r '. | join(", ")')
fi
echo "services_display=$services_display" >> "$GITHUB_OUTPUT"
```

Payload 에서:
```json
"value": "${{ steps.status.outputs.services_display }}"
```

값 예: `"account, transfer, loan, notification"` — JSON-safe + 사람이 읽기 좋음.

---

## Fix

### ci.yml 변경 요약

1. `aquasecurity/trivy-action@0.36.0` 2회 호출 → `aquasec/trivy:0.70.0` Docker image 직접 호출 2회
   - host 의 `/var/run/docker.sock` 마운트로 host image 스캔
   - 첫 호출: gate (exit-code 1)
   - 두 번째 호출: PR comment 용 (exit-code 0, output 파일)
2. `Determine overall status` step 에 services_display 가공 추가
3. Slack payload 의 `Services` field 가 가공된 값을 사용하도록 변경

### Sandbox 검증 (A-5)

- `docker pull aquasec/trivy:0.70.0`: 성공, immutable digest 확인
- `docker run --rm aquasec/trivy:0.70.0 --version`: `Version: 0.70.0` 정상 출력
- `docker run ... image alpine:3.20 --severity HIGH,CRITICAL`: 실행 시작, sandbox 의 SSL 인터셉션으로 trivy-db 다운로드만 막힘 (GHA runner 는 정상 인터넷이라 문제없음)
- Slack payload jq 로 파싱: gating logic 적용 후 valid JSON 확인
- `actionlint`: clean (exit 0)
- `jsonschema` (github-workflow.json): pass

---

## Lessons learned

1. **Search 결과의 "권장된 버전" 은 실재 태그와 다를 수 있다.**
   docs/blog 에 적힌 버전 문자열은 misprint, future-tense, 또는 사후 force-push 로 인해
   실재 태그와 어긋날 수 있다. **반드시 GitHub releases/tags API 로 1차 확인** 후 핀 한다.
2. **공급망 사건이 있었던 third-party action 은 wrapper 자체 제거가 최선의 방어.**
   tag SHA 핀은 검증 부담이 크고, action 의 후속 release 도 신뢰 회복까지 시간이 걸린다.
   동등 기능을 공식 CLI Docker image 로 대체할 수 있으면 그게 가장 간단·안전.
3. **GHA expression 의 string interpolation 은 자동 escape 를 하지 않는다.**
   `${{ ... }}` 가 JSON / YAML / shell 어느 컨텍스트에 들어가든 사용자가 escape 책임.
   특히 JSON 페이로드 안의 string field 에 임의 데이터를 넣을 때는
   pre-processing step 에서 jq 등으로 평탄화·escape 한다.
4. **A-5 의 "실제로 실행" 의 한계도 의식.**
   이번에 ci.yml 자체는 actionlint + JSON schema 까지 통과했지만 GHA 의 action 해석은
   별개 시스템 (actionlint 가 action 의 실제 존재를 확인하지 않음).
   action 핀의 실재 여부 확인은 **공식 release/tag 페이지 1차 조회** 가 유일한 방법.
   향후 third-party action 핀 추가 시 commit 메시지에 "release page 에서 태그 확인함" 을 명시.
