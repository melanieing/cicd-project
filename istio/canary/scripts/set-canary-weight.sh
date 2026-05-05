#!/usr/bin/env bash
# istio/canary/scripts/set-canary-weight.sh
#
# Canary 시연용 — VirtualService 의 weight 를 빠르게 변경.
#
# 운영 정석은 virtualservice.yaml 의 weight 를 git 에서 PR 로 바꾼 뒤 ArgoCD 가 sync 하는 것이지만,
# 시연 중 실시간으로 20→50→100 으로 변화시킬 때는 git 라운드트립이 너무 느리다. 본 스크립트는
# kubectl patch 로 cluster 의 VirtualService 객체를 직접 수정한다 (임시).
#
# Usage:
#   ./scripts/set-canary-weight.sh <canary_weight>
#   예) ./scripts/set-canary-weight.sh 20    → stable=80, canary=20
#       ./scripts/set-canary-weight.sh 50    → stable=50, canary=50
#       ./scripts/set-canary-weight.sh 100   → stable=0,  canary=100
#
# 시연이 끝나고 정상 git 상태로 복귀하려면:
#   kubectl -n payment-dev apply -f istio/canary/virtualservice.yaml
# (또는 ArgoCD UI 에서 Sync. 본 스크립트가 만든 임시 변경은 git 의 80/20 으로 복원됨)
#
# [Bash 메모]
#   set -euo pipefail
#     -e : 명령 실패 즉시 종료
#     -u : 정의 안 된 변수 참조 시 즉시 종료
#     -o pipefail : 파이프 중간 명령 실패도 전체 실패로 인지
#   ${VAR:?msg} : 변수 미정의 시 msg 출력 후 종료

set -euo pipefail

CANARY_WEIGHT="${1:?usage: $0 <canary_weight 0..100>}"

# 0..100 범위 검증
if ! [[ "$CANARY_WEIGHT" =~ ^[0-9]+$ ]] || [ "$CANARY_WEIGHT" -lt 0 ] || [ "$CANARY_WEIGHT" -gt 100 ]; then
  echo "ERROR: canary_weight 는 0..100 정수여야 함 (입력: $CANARY_WEIGHT)" >&2
  exit 2
fi
STABLE_WEIGHT=$((100 - CANARY_WEIGHT))

NS="payment-dev"
VS="transfer"

echo "[*] VirtualService $NS/$VS 의 weight 를 stable=$STABLE_WEIGHT canary=$CANARY_WEIGHT 로 변경"

# JSON Patch 로 두 weight 동시 수정.
# spec.http[0].route[0] = stable, spec.http[0].route[1] = canary 라는 사실은
# virtualservice.yaml 의 작성 순서로 보장 (시연 중에만 의존하는 약한 가정).
kubectl -n "$NS" patch virtualservice "$VS" --type=json \
  -p="[
    {\"op\": \"replace\", \"path\": \"/spec/http/0/route/0/weight\", \"value\": $STABLE_WEIGHT},
    {\"op\": \"replace\", \"path\": \"/spec/http/0/route/1/weight\", \"value\": $CANARY_WEIGHT}
  ]"

echo "[OK] 변경 완료. 새 weight 가 mesh 의 모든 사이드카에 RDS 로 전파될 때까지 약 1~3 초."
echo
echo "[*] 검증: 100 회 호출 분포 측정 (./scripts/test-traffic-split.sh 100)"
