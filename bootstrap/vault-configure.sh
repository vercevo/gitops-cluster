#!/usr/bin/env bash
# One-time Vault configuration: Kubernetes auth + KV-v2 secrets engine.
# Usage: VAULT_TOKEN=<root-token> ./bootstrap/vault-configure.sh
set -euo pipefail

VAULT_NS="vault"
LOCAL_PORT="8200"

info() { echo "[vault-configure] $*"; }

export VAULT_ADDR="http://127.0.0.1:${LOCAL_PORT}"
export VAULT_TOKEN="${VAULT_TOKEN:?Set VAULT_TOKEN to the root token from vault-init.sh}"

# Port-forward for local vault CLI access
kubectl port-forward -n "${VAULT_NS}" svc/vault "${LOCAL_PORT}:8200" &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null; exit' EXIT INT TERM
sleep 3

# ── Kubernetes auth ───────────────────────────────────────────────────────────
info "Enabling Kubernetes auth..."
vault auth enable kubernetes 2>/dev/null || info "kubernetes auth already enabled"

K8S_HOST=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
vault write auth/kubernetes/config \
  kubernetes_host="https://${K8S_HOST}:443"

# ── KV-v2 secrets engine ──────────────────────────────────────────────────────
info "Enabling KV-v2 at secret/..."
vault secrets enable -path=secret kv-v2 2>/dev/null || info "kv-v2 already enabled"

# ── Base policy ───────────────────────────────────────────────────────────────
vault policy write app-read - <<'EOF'
path "secret/data/{{identity.entity.aliases.auth_kubernetes_*.metadata.service_account_namespace}}/*" {
  capabilities = ["read"]
}
EOF

# ── Default role (binds to all service accounts in apps namespace) ─────────────
vault write auth/kubernetes/role/app \
  bound_service_account_names="*" \
  bound_service_account_namespaces="apps,default" \
  policies="app-read" \
  ttl=1h

info ""
info "Vault configured:"
info "  auth/kubernetes/ — bound to in-cluster k8s API"
info "  secret/          — KV-v2, namespaced paths"
info "  role/app         — all service accounts in: apps, default"
info ""
info "Write a secret:  vault kv put secret/myapp/config key=value"
info "Read a secret:   vault kv get secret/myapp/config"
