#!/usr/bin/env bash
# scripts/chaos/abort.sh
#
# 카오스 #3 — notification 호출에 503 50% 주입 → outlierDetection ejection 시연 (EPIC 8 Task 8.6).
#
# 시연하려는 것
#   1. 503 주입 직후: transfer 의 응답 분포에 5xx 가 ~50% 출현
#   2. 5xx 가 5 회 연속 → notification pod 가 outlierDetection 으로 30 초간 ejection
#   3. ejection 동안 transfer 의 응답: 503 비율이 일시 0 으로 (격리된 endpoint 가 없어 모두 healthy)
#   4. 30 초 후 ejection 해제 → 다시 503 ~50% 로 복귀
#
# 흐름
#   1. 본 스크립트는 부하를 90 초 동안 발생 (1 req/s)
#   2. 30 초 시점에 fault-abort VS 적용
#   3. 부하 종료 후 응답 분포 시계열 출력
#   4. fault-abort VS 자동 정리 (trap)
#
# 측정 보강
#   더 정확한 ejection 시각화는 Grafana Service dashboard 의 'Outlier Detected' 메트릭 또는
#   Kiali Graph 의 edge color 변화로. 본 스크립트는 명령줄에서 응답 분포만 확인.
#
# 사용: ./scripts/chaos/abort.sh

set -euo pipefail

NS="payment-dev"
VS_FILE="istio/resilience/fault-abort.yaml"
DURATION=90               # 부하 총 시간 (초)
INJECT_AT=30              # 부하 시작 후 몇 초 시점에 fault 적용

if [ ! -f "$VS_FILE" ]; then
  echo "ERROR: $VS_FILE 가 본 cwd 에서 보이지 않습니다. 프로젝트 root 에서 실행하세요." >&2
  exit 2
fi

# cleanup hook
trap 'kubectl -n '"$NS"' delete -f '"$VS_FILE"' --ignore-not-found --wait=false >/dev/null 2>&1 || true; kubectl -n '"$NS"' delete pod chaos-abort-load --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

RESULT_FILE=$(mktemp)
echo "[*] ${DURATION}s 부하 + ${INJECT_AT}s 시점 fault 주입"
echo "[*] 결과 기록: $RESULT_FILE"

# ---------------------------------------------------------------------------
# 1. background 부하 — transfer /transfer 를 매 초 호출, 각 응답의 status + 초 시각 기록
# ---------------------------------------------------------------------------
kubectl -n "$NS" run chaos-abort-load --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --labels='chaos-test=fault-abort' \
  --command -- sh -c "
    start=\$(date +%s)
    end=\$(( start + $DURATION ))
    while [ \$(date +%s) -lt \$end ]; do
      elapsed=\$(( \$(date +%s) - start ))
      status=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        -X POST http://transfer:8000/transfer \
        -H 'Content-Type: application/json' \
        -d '{\"payload\":{\"from\":\"a1\",\"to\":\"a2\",\"amount\":1000}}' || echo TIMEOUT)
      printf '%03d %s\n' \$elapsed \$status
      sleep 1
    done
  " > "$RESULT_FILE" 2>/dev/null &
LOAD_PID=$!

# ---------------------------------------------------------------------------
# 2. INJECT_AT 초 대기 후 fault 적용
# ---------------------------------------------------------------------------
sleep "$INJECT_AT"
echo "[*] [+${INJECT_AT}s] fault-abort VS 적용 (notification 호출의 50% 를 503 으로)"
kubectl apply -f "$VS_FILE"

# ---------------------------------------------------------------------------
# 3. 부하 종료 대기 + 시계열 출력
# ---------------------------------------------------------------------------
wait $LOAD_PID 2>/dev/null || true

echo
echo "================== 시계열 응답 분포 =================="
echo "elapsed(s) | status"
echo "-----------|-------"
cat "$RESULT_FILE" | awk '{print "  " $1 "      | " $2}'
echo "======================================================"
echo
echo "[해석 — 기대되는 흐름]"
echo "  [0..${INJECT_AT}s)        : 모두 200 (fault 적용 전)"
echo "  [${INJECT_AT}..${INJECT_AT}+10s) : 200 + 5xx 가 약 50:50 (fault 가 50% 주입)"
echo "  [${INJECT_AT}+10..${INJECT_AT}+40s) : 5xx 비율 감소 (outlierDetection 이 notification pod ejection)"
echo "                              transfer 의 graceful-degrade 가 notification 실패를 흡수해 200 유지"
echo "  [${INJECT_AT}+40s..)       : ejection 해제 시점에 다시 5xx 등장 가능"
echo
echo "[추가 측정]"
echo "  - Kiali Graph 에서 transfer → notification 엣지의 color 변화 (red ↔ orange ↔ green)"
echo "  - Grafana 의 Service dashboard 에서 notification 의 'outlier_ejections_total' 카운터 증가"
echo "  - kubectl -n $NS get pod -l app.kubernetes.io/component=notification (모든 pod 살아있음)"
echo
echo "[*] cleanup 자동 진행 (trap)"

rm -f "$RESULT_FILE"
