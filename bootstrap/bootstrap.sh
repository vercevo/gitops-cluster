#!/usr/bin/env bash
# Installs k3s + ArgoCD, then hands control to GitOps.
# Requires: REPO_URL env var pointing to this repo.
# Must run as root (k3s installer requires it).
set -euo pipefail

REPO_URL="${REPO_URL:?Set REPO_URL to your git repo, e.g. https://github.com/myorg/gitops-cluster}"
K3S_VERSION="${K3S_VERSION:-v1.32.4+k3s1}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

info() { echo "[bootstrap] $*"; }

# ── 1. k3s ───────────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet k3s 2>/dev/null; then
  info "Installing k3s ${K3S_VERSION}..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    sh -s - \
      --disable traefik \
      --write-kubeconfig-mode 644
  info "k3s installed."
else
  info "k3s already running, skipping install."
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
info "Waiting for node Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

# ── 2. ArgoCD ────────────────────────────────────────────────────────────────
if ! kubectl get namespace argocd &>/dev/null 2>&1; then
  info "Installing ArgoCD ${ARGOCD_VERSION}..."
  kubectl create namespace argocd
  kubectl apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  info "Waiting for argocd-server..."
  kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
else
  info "ArgoCD already present, skipping install."
fi

# ── 3. Seed App-of-Apps ───────────────────────────────────────────────────────
info "Applying seed (platform + applications App-of-Apps)..."
sed "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g" "${ROOT}/bootstrap/argocd-seed.yaml" \
  | kubectl apply -f -

info ""
info "Bootstrap complete. ArgoCD is now reconciling the cluster."
info ""
info "Track progress:"
info "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
info "  kubectl get applications -n argocd -w"
info ""
info "ArgoCD admin password:"
info "  kubectl -n argocd get secret argocd-initial-admin-secret \\"
info "    -o jsonpath='{.data.password}' | base64 -d && echo"
info ""
info "Once Vault pods are Running:"
info "  ./bootstrap/vault-init.sh"
