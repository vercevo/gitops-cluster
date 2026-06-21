#!/usr/bin/env bash
# One-time Vault initialization. Run AFTER Vault pods are Running.
# Outputs unseal key + root token — back them up securely.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
VAULT_NS="vault"

info() { echo "[vault-init] $*"; }

# Wait for vault pod
info "Waiting for Vault pod..."
kubectl wait pod \
  -l app.kubernetes.io/name=vault \
  -n "${VAULT_NS}" \
  --for=condition=Ready \
  --timeout=300s

# Idempotency check
if kubectl exec -n "${VAULT_NS}" vault-0 -- vault status -format=json 2>/dev/null \
    | grep -q '"initialized":true'; then
  info "Vault is already initialized."
  exit 0
fi

info "Initializing Vault (1 key share / threshold 1 — increase for production)..."
INIT_JSON=$(kubectl exec -n "${VAULT_NS}" vault-0 -- \
  vault operator init -key-shares=1 -key-threshold=1 -format=json)

UNSEAL_KEY=$(echo "${INIT_JSON}" | grep -o '"unseal_keys_b64":\["[^"]*"' | grep -o '[A-Za-z0-9+/=]\{20,\}')
ROOT_TOKEN=$(echo "${INIT_JSON}" | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)

# Save locally (git-ignored)
mkdir -p .secrets
echo "${INIT_JSON}" > .secrets/vault-init.json
chmod 600 .secrets/vault-init.json

info "Unseal key and root token saved to .secrets/vault-init.json"
info "IMPORTANT: Back this file up somewhere secure (1Password, etc.)."
info ""

# Unseal
info "Unsealing vault-0..."
kubectl exec -n "${VAULT_NS}" vault-0 -- vault operator unseal "${UNSEAL_KEY}"

info ""
info "Vault unsealed. Root token: ${ROOT_TOKEN}"
info ""
info "Next:"
info "  VAULT_TOKEN=${ROOT_TOKEN} ./bootstrap/vault-configure.sh"
