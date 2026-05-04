#!/usr/bin/env bash
#
# scripts/latest-image-sha.sh
#
# GHCR 의 service 패키지에 **실제로 존재하는** 가장 최근 40-hex sha 태그를 출력한다.
#
# [왜 필요한가]
# `git rev-parse origin/main` 은 main 의 가장 최근 커밋 sha 를 줄 뿐이다.
# 그 커밋이 docs-only 였거나 path-filter 가 service 빌드를 트리거 안 한 경우
# GHCR 에는 해당 sha 의 image 가 없어 helm install 시 manifest unknown 발생.
#
# 본 script 는 GitHub Packages REST API 를 직접 조회해 **GHCR 에 푸시된 진짜 sha**
# 중 가장 최근 것을 찾는다. 4 service 가 매번 같은 sha 로 빌드된다는 보장은 없지만
# (path-filter 결과에 따라 다름), 실무적으로는 다음 중 하나의 sha 가 4 패키지 모두에 존재:
#   - workflow / _template / multi-service / dependabot 그룹 변경 commit
#   - workflow_dispatch 수동 트리거
# 본 script 는 한 service (default: account) 의 최신 sha 를 반환하고,
# helm install 이 다른 service 에서 manifest unknown 으로 실패하면 그때 GHCR UI 로 직접 골라야 함.
#
# [사용]
#   ./scripts/latest-image-sha.sh                # default OWNER=melanieing, PROBE_SVC=account
#   OWNER=other-user ./scripts/latest-image-sha.sh
#   PROBE_SVC=transfer ./scripts/latest-image-sha.sh
#
#   # helm install 과 결합:
#   SHA=$(./scripts/latest-image-sha.sh)
#   helm upgrade payment charts/payment-platform/ -n payment-dev \
#     -f charts/payment-platform/values-dev.yaml \
#     --set global.imageTag="$SHA"
#
# [의존성] gh (GitHub CLI), jq

set -euo pipefail

OWNER="${OWNER:-melanieing}"
PROBE_SVC="${PROBE_SVC:-account}"
PER_PAGE="${PER_PAGE:-30}"

command -v gh >/dev/null 2>&1 || {
    echo "ERR: gh CLI required (https://cli.github.com). Install: " >&2
    echo "  sudo apt install gh   # Ubuntu" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "ERR: jq required (sudo apt install jq)" >&2
    exit 1
}

# gh 가 인증되어 있는지 1차 확인 (private 패키지 조회는 인증 필요. public 은 없어도 OK)
gh auth status >/dev/null 2>&1 || {
    echo "WARN: gh CLI is not authenticated. Run 'gh auth login' if package is private." >&2
}

# 가장 최근 40-hex sha 태그 1개 출력.
# - GitHub Packages API: /users/<owner>/packages/container/<name>/versions
# - 응답 각 element 의 metadata.container.tags 가 그 version 의 모든 태그 배열
# - 우리는 git-sha-tag 정책상 40-hex 만 쓰므로 grep 으로 필터
SHA=$(gh api -H "Accept: application/vnd.github+json" \
    "/users/$OWNER/packages/container/$PROBE_SVC/versions?per_page=$PER_PAGE" 2>/dev/null \
    | jq -r '.[].metadata.container.tags[]' \
    | grep -E '^[0-9a-f]{40}$' \
    | head -1) || true

if [[ -z "${SHA:-}" ]]; then
    cat >&2 <<EOF
ERR: $PROBE_SVC 패키지에서 40-hex sha 태그를 찾지 못했습니다.

가능한 원인:
  1. CI 가 한 번도 main push 를 처리하지 않음 (PR 머지가 아직 없음)
  2. 패키지가 다른 OWNER 소유 — OWNER 환경변수 확인
  3. 패키지가 private + gh 인증 안 됨 — 'gh auth login' 실행

수동 확인:
  https://github.com/users/$OWNER/packages/container/$PROBE_SVC/versions
EOF
    exit 1
fi

echo "$SHA"
