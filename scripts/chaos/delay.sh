#!/usr/bin/env bash
# scripts/chaos/delay.sh
#
# 카오스 #2 — loan 서비스에 200ms fault.delay 를 적용 후 P99 영향을 측정 (EPIC 8 Task 8.5).
#
# 흐름
#   1. baseline (적용 전) 50 회 호출 → P95 / max latency 출력
#   2. fault-delay VS 적용
#   3. 사이드카로 RDS 전파 3 초 대기
#   4. 같은 50 회 호출 → baseline + 200ms 정도 늘었는지 확인
#   5. fault-delay VS 제거 (자동 cleanup)
#
# 사용: ./scripts/chaos/delay.sh

set -euo pipefail

NS="payment-dev"
VS_FILE="istio/resilience/fault-delay.yaml"
TARGET="loan:8000/health/ready"

if [ ! -f "$VS_FILE" ]; then
  echo "ERROR: $VS_FILE 가 본 cwd 에서 보이지 않습니다. 프로젝트 root 에서 실행하세요." >&2
  exit 2
fi

# cleanup hook — 스크립트가 어떤 이유로 종료되든 VS 를 정리해서 다음 시연에 영향 안 주게
trap 'kubectl -n '"$NS"' delete -f '"$VS_FILE"' --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------------------
# 측정 함수 — mesh 안의 transfer pod 안에서 curl 50 회, time_total 분포 추출
# ---------------------------------------------------------------------------
measure() {
  local label="$1"
  echo "  [$label] 50 회 호출 측정 중..."
  kubectl -n "$NS" exec deploy/transfer -c transfer -- \
    sh -c "for i in \$(seq 1 50); do curl -s -o /dev/null -w '%{time_total}\n' --max-time 3 http://$TARGET || echo 9.999; done" \
    | sort -n \
    | awk '{
        c++; sum+=$1; vals[c]=$1
      } END {
        printf "    min  = %.3fs\n", vals[1]
        printf "    P50  = %.3fs\n", vals[int(c*0.5)]
        printf "    P95  = %.3fs\n", vals[int(c*0.95)]
        printf "    P99  = %.3fs\n", vals[int(c*0.99)]
        printf "    max  = %.3fs\n", vals[c]
        printf "    mean = %.3fs\n", sum/c
      }'
}

# ---------------------------------------------------------------------------
# 1. Baseline
# ---------------------------------------------------------------------------
echo "[*] BASELINE — fault-delay 적용 전"
measure "baseline"
echo

# ---------------------------------------------------------------------------
# 2. Fault 주입
# ---------------------------------------------------------------------------
echo "[*] fault-delay VS 적용"
kubectl apply -f "$VS_FILE"
echo "[*] 사이드카 RDS 전파 대기 (3 초)..."
sleep 3
echo

# ---------------------------------------------------------------------------
# 3. After
# ---------------------------------------------------------------------------
echo "[*] AFTER — fault-delay (200ms) 적용 후"
measure "after-200ms-injection"
echo

echo "[해석]"
echo "  - AFTER 의 모든 분위수가 BASELINE + 약 0.20s 정도 늘었어야 정상 (fault.delay 100% percent)"
echo "  - 늘어남이 0.05s 미만이면: VS 가 mesh 안에 전파 안 됨. istioctl proxy-status 점검"
echo "  - 늘어남이 0.50s 이상이면: 다른 요인 (네트워크 혼잡 등) 가 섞임 → 재측정"
echo
echo "[*] cleanup — fault-delay VS 자동 삭제 (trap)"
