# CI Trivy 게이트가 base image 의 libgnutls30 CVE 로 빌드 차단

## Summary

EPIC 6 의 `/version` 엔드포인트 변경을 main 에 머지하자 CI 의 `build-scan-push` job 이
`account` 서비스의 Trivy 스캔 (HIGH/CRITICAL 차단 게이트) 에서 exit code 1 로 실패했다.
원인은 우리 코드가 아니라 base image `python:3.14-slim-bookworm` 에 포함된 Debian OS 패키지
`libgnutls30` (3.7.9-2+deb12u6) 의 신규 CVE 5 건 (CRITICAL 2, HIGH 3) 이었다. 모두 Debian 이
패치 (+deb12u7) 를 이미 발행한 상태 (`Status: fixed`) 였으나, Docker 의 base image 가 그 패치를
포함해 재빌드되기 전이라 옛 패키지가 남아 있었다. 4 개 서비스 Dockerfile 의 runtime stage 에
`apt-get upgrade` 를 추가해 빌드 시점에 OS 보안 패치를 끌어오는 방식으로 해결.

## Symptom

PR 머지 후 GitHub Actions 의 `build-scan-push (account)` job:

```
ghcr.io/melanieing/account:c63257d... (debian 12.14)
Total: 5 (HIGH: 3, CRITICAL: 2)

┌─────────────┬────────────────┬──────────┬────────┬───────────────────┬─────────────────┐
│   Library   │ Vulnerability  │ Severity │ Status │ Installed Version │  Fixed Version  │
├─────────────┼────────────────┼──────────┼────────┼───────────────────┼─────────────────┤
│ libgnutls30 │ CVE-2026-33845 │ CRITICAL │ fixed  │ 3.7.9-2+deb12u6   │ 3.7.9-2+deb12u7 │
│             │ CVE-2026-42010 │ CRITICAL │ fixed  │                   │                 │
│             │ CVE-2026-33846 │ HIGH     │ fixed  │                   │                 │
│             │ CVE-2026-3833  │ HIGH     │ fixed  │                   │                 │
│             │ CVE-2026-42009 │ HIGH     │ fixed  │                   │                 │
└─────────────┴────────────────┴──────────┴────────┴───────────────────┴─────────────────┘
Error: Process completed with exit code 1.
```

CI 워크플로의 게이트 step (`.github/workflows/ci.yml`):

```yaml
- name: Trivy scan (block on HIGH/CRITICAL)
  run: |
    docker run ... aquasec/trivy:0.70.0 image \
      --severity HIGH,CRITICAL \
      --exit-code 1 \
      ...
```

## Investigation & Root cause

### 1차 확인 — 우리 코드 변경과 무관

스캔 표의 Python 패키지 행 (fastapi, asyncpg, pydantic 등) 은 모두 `0` (clean). 유일한 취약점은
OS 패키지 `libgnutls30` 한 개에 몰려 있었다. 즉 본 PR 의 `/version` 엔드포인트 추가와 인과관계 없음.

### 확정 원인 — base image 의 패치 지연 창

- `libgnutls30` 은 `python:3.14-slim-bookworm` (Debian 12 bookworm) base image 에 포함된 OS 패키지.
- CVE 들이 모두 `CVE-2026-...` 로 최근 (사건 시점 2026-05-31 무렵) 공개됨.
- Trivy 의 `Status: fixed` + `Fixed Version: 3.7.9-2+deb12u7` → **Debian 보안팀은 이미 패치를 발행**.
- 그러나 Docker Hub 의 `python:3.14-slim-bookworm` 이미지는 아직 그 패치를 포함해 재빌드되지 않아
  옛 `+deb12u6` 이 남아 있었음.
- 즉 "Debian 패치 발행 ↔ base image 재빌드" 사이의 시간 창에 빌드가 걸린 것. base image 를 쓰는
  모든 프로젝트가 주기적으로 마주치는 전형적 사건.

### 4 개 서비스 모두 동일

`account`/`transfer`/`loan`/`notification` 의 Dockerfile 이 byte-identical (`diff` 로 확인) 이고
같은 base image 를 쓰므로, 본 PR 에서 빌드된 account/transfer 뿐 아니라 loan/notification 도
다음 빌드 시 같은 실패를 낼 상태였음.

## Fix

### 적용한 해결책 — runtime stage 에 OS 보안 패치

4 개 Dockerfile 의 runtime stage (`USER appuser` 강하 이전, root 구간) 에 추가:

```dockerfile
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*
```

- 빌드 시점에 Debian 의 최신 보안 패치를 끌어와 `libgnutls30` 을 `+deb12u7` 로 갱신 → Trivy 통과.
- base image 가 패치를 포함해 재빌드되면 이 단계는 사실상 no-op 이 되어 비용 ~0.
- `USER appuser` 보다 위에 배치해 root 권한으로 apt 실행 (위치 틀리면 빌드 깨짐 — `grep` 으로 순서 검증).

관련 커밋: 본 troubleshooting 파일과 함께 push 되는 커밋.

### 왜 .trivyignore 가 아닌가 (반려한 대안)

`.trivyignore` 로 CVE 를 억제하면 게이트는 통과하지만 **fix 가 존재하는 진짜 취약점을 숨기는 것**
이라 보안 게이트의 목적을 무력화한다. 본 CVE 들은 모두 `Status: fixed` 이므로 억제가 아니라 패치가
정답. (만약 `Status: affected` 로 fix 가 없는 CVE 였다면 `.trivyignore` + 만료일 + 근거 주석이
임시 타협안이 될 수 있으나, 그조차 마지막 수단.)

### 검증

- 4 개 Dockerfile byte-identical 유지 (`diff` 확인), `apt-get upgrade` 위치가 `USER appuser` 이전임 확인.
- **sandbox 에 docker daemon 이 없어 (`ulimit` privileged 제약) `docker build` 실행 미수행.** 실제
  빌드 + Trivy 통과 검증은 사용자의 CI 재실행이 수행. 변경은 표준 Dockerfile 관용구라 회귀 위험 낮음.

## Lessons learned

1. **base image 의 OS 패키지 CVE 는 Dependabot 으로 안 잡힌다.** 본 프로젝트의 Dependabot
   (Task 2.5) 은 base image **태그** (python 3.14 → 3.15) 를 추적할 뿐, 같은 태그 안의 OS 패키지
   패치는 못 본다. 그 빈틈을 `apt-get upgrade` 가 메운다. 둘은 상호 보완 — Dependabot 은 메이저/마이너
   업그레이드, `apt-get upgrade` 는 같은 base 안의 OS 보안 패치.

2. **Trivy 게이트 실패 = 보안 정책이 작동한다는 신호.** 빌드가 깨졌을 때 첫 반응이 "게이트를
   느슨하게" 가 되면 안 된다. 표를 읽고 (a) OS 패키지인지 앱 의존성인지, (b) `Status: fixed` 인지
   `affected` 인지를 먼저 분류하면 해결 방향이 결정된다. fixed → 패치, affected + fix 없음 → 위험
   수용 여부 판단.

3. **base image 를 쓰는 한 이 사건은 주기적으로 재발한다.** 항구적 완화는 두 방향:
   (a) `apt-get upgrade` 상시 적용 (본 fix — 빌드마다 최신 패치) +
   (b) 장기적으로 distroless / Chainguard(Wolfi) 같은 zero-CVE 지향 base image 로 이전 시 OS 패키지
   표면 자체가 축소. (b) 는 apt 부재 + 디버깅 난이도 상승 trade-off 가 있어 별도 EPIC 으로 평가할
   backlog 후보. 본 사건은 (a) 로 즉시 해결하고 (b) 를 백로그에 남긴다.

4. **동일 파일 4 벌은 한쪽만 고치면 drift 가 난다.** 4 개 서비스 Dockerfile 이 byte-identical 인
   현재 구조에서 한쪽만 패치하면 나머지 3 개가 다음 빌드에서 같은 실패를 낸다. `diff` 로 동일성을
   확인한 뒤 한 곳을 고치고 `cp` 로 전파해 4 개를 동기 유지. (더 근본적으로는 공유 Dockerfile +
   build-arg 로 중복을 없애는 게 정석이나, 본 프로젝트는 서비스별 독립 Dockerfile 정책이라 현 구조
   유지 + 동기화 규율로 대응.)
