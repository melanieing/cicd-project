#!/usr/bin/env bash
# scripts/test-bluegreen.sh
#
# Blue-Green 전환 검증 — payment-dev 에 임시 curl pod 를 띄워 account:8000/version 을
# N 회 호출 후 응답의 version 필드 분포 집계.
#
# Blue-Green 은 즉시 전환이라 기대 분포는 **N : 0** 형태로 한쪽 100% 여야 한다.
# 중간 분포 (예: 60:40) 가 나오면 전환 직후 라 mesh 의 일부 사이드카가 아직 옛 RDS 를 들고 있는
# 과도기. 3 초 더 기다린 뒤 재실행하면 깨끗한 100:0 으로 정렬.
#
# Usage:
#   ./scripts/test-bluegreen.sh [iterations]
#   기본 iterations=100

set -euo pipefail

ITERATIONS="${1:-100}"
NS="payment-dev"

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
  echo "ERROR: iterations 는 양의 정수여야 함 (입력: $ITERATIONS)" >&2
  exit 2
fi

echo "[*] $NS namespace 에서 account:8000/version 을 $ITERATIONS 회 호출"
echo "[*] 사이드카가 자동 주입되므로 응답은 VirtualService 의 weight 에 따라 한쪽으로 갈 것"
echo

kubectl -n "$NS" run curl-bluegreen-test \
  --image=curlimages/curl:8.10.1 \
  --rm -i --restart=Never \
  --quiet \
  --labels='app=bluegreen-test,test-pod=true' \
  --overrides='{"spec":{"containers":[{"name":"curl","image":"curlimages/curl:8.10.1","stdin":true,"tty":false,"command":["sh","-c","for i in $(seq 1 '"$ITERATIONS"'); do curl -s --max-time 2 http://account.payment-dev.svc.cluster.local:8000/version | sed -n '\''s/.*\"version\":\"\\([^\"]*\\)\".*/\\1/p'\''; done"]}]}}' \
  2>/dev/null | sort | uniq -c | sort -rn

echo
echo "[*] 분포 해석:"
echo "    - 정상 Blue-Green 전환 직후: 한 행에 ~$ITERATIONS 회 + 다른 색깔 0 회 → 한쪽 100% 로 라우팅 중"
echo "    - 두 행이 섞임: 전환 직후 사이드카 RDS 전파 과도기. 3 초 후 재실행 → 한 행으로 수렴"
echo "    - 'unknown' 이 보이면: stable image 가 SERVICE_VERSION 을 안 읽는 옛 코드. CI 새 image 사용"
