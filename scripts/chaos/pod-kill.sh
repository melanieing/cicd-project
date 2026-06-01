#!/usr/bin/env bash
# scripts/chaos/pod-kill.sh
#
# 카오스 #1 — payment-dev 의 notification pod 한 개를 강제 종료 후
# Istio sidecar 의 자동 retry 가 in-flight 요청을 살리는지 측정 (EPIC 8 Task 8.4).
#
# 시나리오
#   1. 백그라운드에서 transfer:8000/transfer 를 60 초간 지속 호출 (1 req/s)
#   2. 5 초 뒤 notification pod 를 강제 종료
#   3. K8s Deployment 가 새 pod 를 즉시 생성 (~10-20 초 ready)
#   4. 그 사이의 transfer 응답: 5xx 가 한두 건 발생할 수 있지만 대부분 retry 로 흡수되어야 함
#
# 측정 포인트
#   - transfer 응답의 status 분포 (200 vs 5xx)
#   - notification pod 의 재생성 시간
#
# 사용
#   ./scripts/chaos/pod-kill.sh
#   (옵션) 시간을 늘리려면 DURATION 환경변수: DURATION=120 ./scripts/chaos/pod-kill.sh
#
# 사전 조건
#   - payment-dev 의 모든 서비스 pod 가 READY 2/2
#   - kubectl context 가 cluster 를 가리킴
#
# [Bash 메모]
#   - set -euo pipefail : 실패 즉시 종료, 미정의 변수 거부, pipe 실패 전파
#   - $! : 직전 background job 의 PID
#   - trap : 스크립트 종료 시 cleanup (background curl 정리)

set -euo pipefail

DURATION="${DURATION:-60}"     # 부하 지속 시간 (초)
NS="payment-dev"
TARGET_SVC="notification"
CALLER_SVC="transfer"

echo "[*] $NS 의 $TARGET_SVC 한 pod 를 ${DURATION}s 부하 중에 강제 종료"
echo "[*] $CALLER_SVC 응답의 status 분포로 Istio retry 효과 측정"
echo

# ---------------------------------------------------------------------------
# 1. 사전 점검
# ---------------------------------------------------------------------------
NOTIF_POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component="$TARGET_SVC" \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$NOTIF_POD" ]; then
  echo "ERROR: $NS 에 $TARGET_SVC pod 가 없습니다. 사전 조건 확인하세요." >&2
  exit 2
fi
echo "[OK] 타겟 pod: $NOTIF_POD"

# ---------------------------------------------------------------------------
# 2. background 부하 시작 — payment-dev 의 임시 curl pod 가 transfer 를 ${DURATION}s 호출
# ---------------------------------------------------------------------------
RESULT_FILE=$(mktemp)
echo "[*] 백그라운드 부하 pod 생성 — 결과는 $RESULT_FILE 에 기록"

# heredoc 으로 컨테이너 안 셸 명령 정의:
#   - 매 1 초마다 transfer:/transfer 호출
#   - 응답의 HTTP status 만 추출 (curl -w '%{http_code}\n')
#   - 결과를 stdout 으로 (kubectl 이 받아 RESULT_FILE 로 redirect)
kubectl -n "$NS" run chaos-load --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --labels='chaos-test=pod-kill' \
  --command -- sh -c "
    end=\$(( \$(date +%s) + $DURATION ))
    while [ \$(date +%s) -lt \$end ]; do
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 \
        -X POST http://transfer:8000/transfer \
        -H 'Content-Type: application/json' \
        -d '{\"payload\":{\"from\":\"a1\",\"to\":\"a2\",\"amount\":1000}}' || echo TIMEOUT
      sleep 1
    done
  " > "$RESULT_FILE" 2>/dev/null &
LOAD_PID=$!

# 스크립트 종료 시 background job 정리
trap 'kill $LOAD_PID 2>/dev/null || true; kubectl -n '$NS' delete pod chaos-load --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -f '$RESULT_FILE'' EXIT

# ---------------------------------------------------------------------------
# 3. 5 초 후 pod-kill
# ---------------------------------------------------------------------------
echo "[*] 5 초 대기 후 $NOTIF_POD 강제 종료..."
sleep 5

KILL_START=$(date +%s)
kubectl -n "$NS" delete pod "$NOTIF_POD" --grace-period=0 --force 2>&1 | head -2
echo "[*] kill 시점: $(date -d "@$KILL_START" '+%H:%M:%S')"

# ---------------------------------------------------------------------------
# 4. 새 pod ready 측정
# ---------------------------------------------------------------------------
echo "[*] 새 pod 가 ready 될 때까지 대기 (최대 60 초)..."
kubectl -n "$NS" wait pod -l app.kubernetes.io/component="$TARGET_SVC" \
  --for=condition=Ready --timeout=60s 2>&1 | tail -2 || echo "WARN: 일부 pod 가 ready 안 됨"

READY_AT=$(date +%s)
echo "[OK] 새 pod ready 시점: $(date -d "@$READY_AT" '+%H:%M:%S')  (복구 시간: $((READY_AT - KILL_START))s)"

# ---------------------------------------------------------------------------
# 5. 부하 종료 대기 후 결과 집계
# ---------------------------------------------------------------------------
echo "[*] 남은 부하 시간 종료 대기..."
wait $LOAD_PID 2>/dev/null || true

echo
echo "================== 결과 분포 =================="
sort "$RESULT_FILE" | uniq -c | sort -rn
echo "==============================================="
echo
echo "[해석]"
echo "  - 대부분 '200'  이면 Istio retry 가 in-flight 요청을 잘 살린 것"
echo "  - '5xx' 가 몇 건 (1~3) : pod kill 직후 retry 한도를 초과한 요청 — 정상 범위"
echo "  - '5xx' 가 다수 (10+)  : retry 정책이 부족하거나 pod 복구가 너무 느림"
echo "  - 'TIMEOUT' 다수       : transfer 자체가 다운 — 시연 환경 점검 필요"
