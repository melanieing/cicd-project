#!/usr/bin/env bash
#
# scripts/migrate-to-helm.sh
#
# Task 1.4 의 plain `kubectl apply -f postgres.yaml` 로 만든 리소스를
# EPIC 4 의 Helm chart 로 마이그레이션한다.
#
# [배경]
# Task 1.4 가 kubectl 로 직접 apply 한 5 개 리소스(secret, configmap, 2 service,
# statefulset) 는 Helm 의 ownership label/annotation 이 없다. 이 상태에서
# `helm install payment ...` 를 시도하면 다음 에러 발생:
#   Error: ... exists and cannot be imported into the current release:
#   invalid ownership metadata; missing key "app.kubernetes.io/managed-by"
#
# 이 스크립트는 두 가지 모드를 제공:
#
#   MODE=clean (기본, 권장)
#     기존 리소스를 모두 삭제하고 PVC 까지 비운 뒤 fresh helm install.
#     dev 환경의 mock 데이터라 손실 부담 없음.
#
#   MODE=adopt
#     Helm 3.13+ 의 --take-ownership 으로 기존 리소스를 흡수.
#     postgres 데이터(4 DB 포함) 가 보존됨. 개발 진행 중 데이터 의미 있을 때.
#
# [bash 특수 문법]
#   set -euo pipefail : -e 실패시 즉시 중단, -u 미정의 변수 오류, -o pipefail 파이프 중간 실패도 잡음
#   ${VAR:-default}   : VAR 비어있으면 default 사용
#   $(command)        : command stdout 캡처
#
# 사용:
#   ./scripts/migrate-to-helm.sh                       # 기본 = clean
#   MODE=clean  ./scripts/migrate-to-helm.sh           # 명시적 clean
#   MODE=adopt  ./scripts/migrate-to-helm.sh           # 데이터 보존
#   NAMESPACE=payment-dev RELEASE=payment ./scripts/migrate-to-helm.sh

set -euo pipefail

# ------ 설정 ------
NAMESPACE="${NAMESPACE:-payment-dev}"
RELEASE="${RELEASE:-payment}"
MODE="${MODE:-clean}"
CHART_DIR="${CHART_DIR:-$(cd "$(dirname "$0")/.." && pwd)/charts/payment-platform}"
VALUES_FILE="${VALUES_FILE:-$CHART_DIR/values-dev.yaml}"

# ANSI colors
B="\033[34m"; G="\033[32m"; R="\033[31m"; Y="\033[33m"; N="\033[0m"
log()  { echo -e "${B}[*]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR]${N} $*" >&2; }

# ------ 사전 점검 ------
log "Prerequisites check"
for cmd in kubectl helm; do
    command -v "$cmd" >/dev/null 2>&1 || { err "$cmd not found on PATH"; exit 1; }
done
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || {
    err "namespace '$NAMESPACE' does not exist"
    exit 1
}
[[ -d "$CHART_DIR" ]] || { err "chart dir '$CHART_DIR' does not exist"; exit 1; }
[[ -f "$VALUES_FILE" ]] || { err "values file '$VALUES_FILE' does not exist"; exit 1; }
ok "prerequisites OK (kubectl + helm + namespace + chart)"

# 이미 helm release 가 있는지 확인
if helm list -n "$NAMESPACE" -o json 2>/dev/null | grep -q "\"name\":\"$RELEASE\""; then
    warn "helm release '$RELEASE' already exists in '$NAMESPACE'. Use 'helm upgrade' instead."
    log "Current release status:"
    helm status "$RELEASE" -n "$NAMESPACE" | head -10
    exit 0
fi

case "$MODE" in
    clean)
        log "MODE=clean — deleting Task 1.4 resources, then fresh helm install"
        log "Resources to delete:"
        kubectl -n "$NAMESPACE" get secret/postgres-secret \
            configmap/postgres-init \
            service/postgres service/postgres-headless \
            statefulset/postgres \
            pvc/data-postgres-0 \
            2>/dev/null || true
        echo
        read -rp "Continue? This will delete the postgres data. [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || { warn "Aborted by user"; exit 0; }

        for res in \
            statefulset/postgres \
            service/postgres service/postgres-headless \
            configmap/postgres-init \
            secret/postgres-secret \
            pvc/data-postgres-0; do
            log "deleting $res..."
            kubectl -n "$NAMESPACE" delete "$res" --ignore-not-found --wait=false
        done

        log "waiting for postgres-0 pod to terminate..."
        kubectl -n "$NAMESPACE" wait --for=delete pod/postgres-0 --timeout=60s 2>/dev/null || true
        ok "cleanup done"
        ;;

    adopt)
        log "MODE=adopt — using Helm 3.13+ --take-ownership to keep existing resources"
        log "(Helm will adopt the existing postgres-secret etc. and add ownership labels)"
        ;;

    *)
        err "unknown MODE='$MODE'. valid: clean | adopt"
        exit 1
        ;;
esac

# ------ helm install ------
log "Running helm install"
INSTALL_ARGS=(install "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE")
[[ "$MODE" == "adopt" ]] && INSTALL_ARGS+=(--take-ownership)

helm "${INSTALL_ARGS[@]}"

# ------ 검증 ------
log "Waiting for postgres-0 ready..."
kubectl -n "$NAMESPACE" wait --for=condition=ready pod/postgres-0 --timeout=180s

log "Waiting for service pods ready (account/transfer/loan/notification)..."
for svc in account transfer loan notification; do
    kubectl -n "$NAMESPACE" wait \
        --for=condition=ready pod \
        -l "app.kubernetes.io/component=$svc" \
        --timeout=120s 2>&1 | tee /dev/null || warn "$svc pod not ready (may need more time or image pull)"
done

echo
log "Final state:"
kubectl -n "$NAMESPACE" get all
ok "Migration complete. Verify:
  kubectl -n $NAMESPACE port-forward svc/account 8001:8000 &
  curl -s localhost:8001/health
"
