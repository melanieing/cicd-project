#!/usr/bin/env bash
# scripts/rollback.sh
#
# 통합 자동 롤백 스크립트 (EPIC 9 Task 9.4 — R-A3-O2).
#
# docs/runbook/rollback.md 의 § 3 절차를 1 개 명령으로 wrap 한 자동화.
# 운영자가 사고 시점에 도구 / 명령 / 매개변수를 외울 필요 없이 다음 한 줄로 실행:
#
#   ./scripts/rollback.sh <service> <strategy>
#
# strategy 종류
#   canary     — istio/canary/scripts/set-canary-weight.sh 호출, weight 를 0 으로
#                  → transfer 의 canary 측 트래픽 차단, stable 만 살림
#   blue-green — scripts/switch-bluegreen.sh 호출, weight 를 한 번 더 swap
#                  → account 의 라이브 측 (blue/green) 을 즉시 반대로 전환
#   argocd     — argocd CLI 로 직전 sync revision 으로 rollback
#                  → 전체 chart 단위 롤백
#   k8s        — kubectl rollout undo 로 직전 ReplicaSet 으로 복귀
#                  → 단일 Deployment 단위 롤백
#
# 측정
#   본 스크립트는 자동으로 시작 시각 / 완료 시각을 기록해 elapsed 시간을 출력한다.
#   docs/metrics/rollback-time.md 의 표가 본 출력을 누적해서 채워나간다.
#
# 사전 조건
#   - kubectl context 가 사고 cluster 를 가리키고 있어야 함
#   - argocd CLI 가 설치 + 로그인되어 있어야 함 (strategy=argocd 일 때만)
#   - istio/canary/ 와 istio/blue-green/ 의 매니페스트가 cluster 에 적용된 상태여야 함
#
# 예시
#   ./scripts/rollback.sh transfer canary
#   ./scripts/rollback.sh account  blue-green
#   ./scripts/rollback.sh payment-prod argocd
#   ./scripts/rollback.sh transfer k8s

set -euo pipefail

SERVICE="${1:?usage: $0 <service> <canary|blue-green|argocd|k8s>}"
STRATEGY="${2:?usage: $0 <service> <canary|blue-green|argocd|k8s>}"

NS="${NS:-payment-dev}"        # default namespace, override 가능: NS=payment-prod ./scripts/rollback.sh ...
LOG_FILE="${LOG_FILE:-/tmp/rollback-$(date +%s).log}"

echo "[*] 롤백 시작: service=$SERVICE strategy=$STRATEGY ns=$NS"
echo "[*] 로그 기록: $LOG_FILE"
START=$(date +%s)

case "$STRATEGY" in
  # ---------------------------------------------------------------------------
  # canary — VirtualService weight 를 0 으로 → stable 100%
  # ---------------------------------------------------------------------------
  canary)
    if [ "$SERVICE" != "transfer" ]; then
      echo "WARN: 본 프로젝트의 canary 시연은 transfer 만 다룸. SERVICE=$SERVICE 는 지원 안 됨." >&2
      echo "      다른 서비스에 canary 가 구성됐다면 istio/canary/scripts/set-canary-weight.sh 직접 호출." >&2
      exit 2
    fi
    echo "[*] Canary weight → 0 (stable 100%)"
    ./istio/canary/scripts/set-canary-weight.sh 0 2>&1 | tee -a "$LOG_FILE"

    # RDS 전파 대기 + 검증
    sleep 3
    echo "[*] 검증: 50 회 호출 분포"
    ./istio/canary/scripts/test-traffic-split.sh 50 2>&1 | tee -a "$LOG_FILE"
    ;;

  # ---------------------------------------------------------------------------
  # blue-green — switch 한 번 더 호출 → 이전 라이브 측으로 복귀
  # ---------------------------------------------------------------------------
  blue-green)
    if [ "$SERVICE" != "account" ]; then
      echo "WARN: 본 프로젝트의 blue-green 시연은 account 만 다룸. SERVICE=$SERVICE 는 지원 안 됨." >&2
      exit 2
    fi
    echo "[*] Blue-green swap (현재 라이브의 반대로)"
    ./scripts/switch-bluegreen.sh 2>&1 | tee -a "$LOG_FILE"

    sleep 3
    echo "[*] 검증: 50 회 호출 분포"
    ./scripts/test-bluegreen.sh 50 2>&1 | tee -a "$LOG_FILE"
    ;;

  # ---------------------------------------------------------------------------
  # argocd — Application 의 직전 sync revision 으로 rollback
  # ---------------------------------------------------------------------------
  argocd)
    APP="$SERVICE"   # SERVICE 인자에 Application 이름이 들어옴 (예: payment-prod)

    if ! command -v argocd >/dev/null 2>&1; then
      echo "ERROR: argocd CLI 없음. UI 의 History 탭에서 Rollback 버튼 사용:" >&2
      echo "       kubectl -n argocd port-forward svc/argocd-server 8080:80" >&2
      exit 3
    fi

    echo "[*] Application $APP 의 sync 이력 조회"
    argocd app history "$APP" 2>&1 | tee -a "$LOG_FILE"

    # 직전 (== 마지막에서 두 번째) revision 의 history ID 추출
    PREV_ID=$(argocd app history "$APP" -o json 2>/dev/null | jq -r '.[-2].id // empty')
    if [ -z "$PREV_ID" ]; then
      echo "ERROR: 이전 revision 을 찾지 못함. 첫 sync 였거나 history 가 비어있음." >&2
      exit 4
    fi

    echo "[*] $APP 을 history ID $PREV_ID 로 rollback"
    argocd app rollback "$APP" "$PREV_ID" 2>&1 | tee -a "$LOG_FILE"

    echo "[*] Sync 완료 대기 (최대 5 분)"
    argocd app wait "$APP" --sync --health --timeout 300 2>&1 | tee -a "$LOG_FILE"
    ;;

  # ---------------------------------------------------------------------------
  # k8s — kubectl rollout undo, Deployment 1 개
  # ---------------------------------------------------------------------------
  k8s)
    echo "[*] Deployment $SERVICE (ns=$NS) 의 revision history"
    kubectl -n "$NS" rollout history deployment "$SERVICE" 2>&1 | tee -a "$LOG_FILE"

    echo "[*] 직전 revision 으로 undo"
    kubectl -n "$NS" rollout undo deployment "$SERVICE" 2>&1 | tee -a "$LOG_FILE"

    echo "[*] rollout 완료 대기 (최대 2 분)"
    kubectl -n "$NS" rollout status deployment "$SERVICE" --timeout=2m 2>&1 | tee -a "$LOG_FILE"

    # ArgoCD 가 watch 중이면 다음 sync 에서 git 상태로 되돌아갈 수 있다는 경고
    echo
    echo "[!] 주의: 본 deployment 가 ArgoCD 의 watch 대상이면 다음 sync 에서 git 상태로 되돌아갈 수 있음."
    echo "         영구 롤백 원하면 git 의 매니페스트도 같이 revert + PR 머지 필요."
    ;;

  *)
    echo "ERROR: strategy '$STRATEGY' 미지원. 다음 중 하나 선택:" >&2
    echo "       canary | blue-green | argocd | k8s" >&2
    exit 1
    ;;
esac

END=$(date +%s)
ELAPSED=$((END - START))

echo
echo "================================================="
echo "[OK] 롤백 완료"
echo "  service   : $SERVICE"
echo "  strategy  : $STRATEGY"
echo "  elapsed   : ${ELAPSED}s"
echo "  log       : $LOG_FILE"
echo "================================================="
echo
echo "[*] 다음 단계 (docs/runbook/rollback.md § 6):"
echo "    1. 사용자 영향 종료 확인 (Slack / Grafana)"
echo "    2. 사고 timeline 을 docs/troubleshooting/ 에 기록"
echo "    3. 근본 원인 분석 시작 (24 시간 안)"
echo "    4. docs/metrics/rollback-time.md 에 본 실행의 elapsed=${ELAPSED}s 추가"
