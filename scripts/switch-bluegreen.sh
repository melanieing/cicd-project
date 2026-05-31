#!/usr/bin/env bash
# scripts/switch-bluegreen.sh
#
# Blue-Green 즉시 전환 스크립트 — account 서비스의 VirtualService weight 를 한 번에 뒤집는다.
#
# 동작 원리
#   현재 cluster 의 VS `account` 의 weight 두 값을 읽어와 서로 뒤집는다.
#   - 호출 전:  blue=100  green=0    →  호출 후: blue=0    green=100
#   - 호출 전:  blue=0    green=100  →  호출 후: blue=100  green=0
#   즉 같은 명령을 두 번 호출하면 원위치. 인스턴트 롤백 시연에 그대로 활용 가능.
#
# Usage:
#   ./scripts/switch-bluegreen.sh
#
# 사전 조건
#   istio/blue-green/{destinationrule,virtualservice}.yaml + account-green.yaml 적용 완료.
#   `kubectl -n payment-dev get vs account` 로 확인.
#
# 시연 후 정상 git 상태로 복원
#   kubectl -n payment-dev apply -f istio/blue-green/virtualservice.yaml
#
# [Bash 메모]
#   - jq 필수 (대부분 Ubuntu 24.04 에 이미 설치, 없으면 `sudo apt install jq`)
#   - `kubectl ... -o json | jq` 패턴으로 현재 weight 추출 후 swap

set -euo pipefail

NS="payment-dev"
VS="account"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq 가 필요합니다. 'sudo apt install jq' 로 설치 후 재시도하세요." >&2
  exit 1
fi

echo "[*] 현재 VirtualService $NS/$VS 의 weight 조회"

# spec.http[0].route[0] = blue, spec.http[0].route[1] = green 이라는 사실은
# virtualservice.yaml 의 작성 순서로 보장 (전환 도중에만 가정).
CURRENT_BLUE=$(kubectl -n "$NS" get virtualservice "$VS" -o json \
  | jq -r '.spec.http[0].route[0].weight')
CURRENT_GREEN=$(kubectl -n "$NS" get virtualservice "$VS" -o json \
  | jq -r '.spec.http[0].route[1].weight')

echo "    현재: blue=$CURRENT_BLUE  green=$CURRENT_GREEN"

# 0/100 또는 100/0 의 두 상태만 가정 (Blue-Green 의 정의).
# 중간값 (예: 50/50) 이면 본 스크립트의 의미가 모호하므로 거부.
if [[ "$CURRENT_BLUE" != "0" && "$CURRENT_BLUE" != "100" ]]; then
  echo "ERROR: blue weight 가 0 또는 100 이 아닙니다 (현재 $CURRENT_BLUE)." >&2
  echo "       Blue-Green 은 binary 전환이라 0/100 이 아닌 상태는 본 스크립트에서 다루지 않습니다." >&2
  echo "       Canary 의 점진 변경을 의도하셨다면 istio/canary/scripts/set-canary-weight.sh 를 사용하세요." >&2
  exit 2
fi

# Swap — 두 값 자리바꿈
NEW_BLUE=$CURRENT_GREEN
NEW_GREEN=$CURRENT_BLUE

echo "[*] 전환:  blue=$NEW_BLUE  green=$NEW_GREEN"

kubectl -n "$NS" patch virtualservice "$VS" --type=json \
  -p="[
    {\"op\": \"replace\", \"path\": \"/spec/http/0/route/0/weight\", \"value\": $NEW_BLUE},
    {\"op\": \"replace\", \"path\": \"/spec/http/0/route/1/weight\", \"value\": $NEW_GREEN}
  ]"

echo "[OK] 전환 완료. mesh 의 모든 사이드카에 새 RDS 가 전파될 때까지 약 1-3 초."
echo
echo "[*] 검증: 100 회 호출 후 분포 측정"
echo "    ./scripts/test-bluegreen.sh 100"
echo
echo "[*] 롤백: 다시 한 번 본 스크립트 호출"
echo "    ./scripts/switch-bluegreen.sh"
