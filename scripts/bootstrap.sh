#!/usr/bin/env bash
#
# bootstrap.sh - Create kind cluster + base namespaces for payment-platform
#
# Prerequisites: see docs/setup/local-tools.md
#   docker, kind v0.27.0, kubectl v1.33.x must be on PATH
#
# Usage:
#   ./scripts/bootstrap.sh           # default
#   CLUSTER_NAME=foo ./scripts/bootstrap.sh
#
# Idempotency: safe to re-run. Existing cluster is detected and reused.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-payment}"
KIND_CONFIG="${KIND_CONFIG:-$(cd "$(dirname "$0")/.." && pwd)/kind-config.yaml}"
NAMESPACES_MANIFEST="${NAMESPACES_MANIFEST:-$(cd "$(dirname "$0")/.." && pwd)/manifests/namespaces.yaml}"

C_RESET="\033[0m"; C_BLUE="\033[34m"; C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"
log()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# 1) Prerequisite check
# ---------------------------------------------------------------------------
log "Checking prerequisites"
missing=0
for cmd in docker kind kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd not found on PATH"
    missing=1
  fi
done
if [[ $missing -eq 1 ]]; then
  err "Install missing tools first. See docs/setup/local-tools.md"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  err "Docker daemon is not reachable. Start with: sudo systemctl start docker"
  exit 1
fi
ok "All prerequisites present"

# ---------------------------------------------------------------------------
# 2) Create kind cluster (idempotent)
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists. Skipping create."
else
  log "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 5m
  ok "Cluster created"
fi

# ---------------------------------------------------------------------------
# 3) Switch kubectl context
# ---------------------------------------------------------------------------
CTX="kind-${CLUSTER_NAME}"
log "Switching kubectl context to ${CTX}"
kubectl config use-context "${CTX}"
ok "Context: $(kubectl config current-context)"

# ---------------------------------------------------------------------------
# 4) Apply base namespaces
# ---------------------------------------------------------------------------
log "Applying namespaces from ${NAMESPACES_MANIFEST}"
kubectl apply -f "${NAMESPACES_MANIFEST}"
ok "Namespaces applied"

# ---------------------------------------------------------------------------
# 5) Verify
# ---------------------------------------------------------------------------
echo
log "Cluster nodes:"
kubectl get nodes -o wide
echo
log "Namespaces:"
kubectl get namespaces --show-labels
echo
ok "Bootstrap complete. Next steps:"
cat <<EOF

  - Verify: kubectl get pods -A
  - Continue with EPIC 1 (services) or EPIC 5 (ArgoCD install)
  - Tear down when done: kind delete cluster --name ${CLUSTER_NAME}

EOF
