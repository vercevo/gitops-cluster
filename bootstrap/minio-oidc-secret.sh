#!/usr/bin/env bash
# Configures MinIO Console login via Authentik OIDC (role-policy mode: every user
# who authenticates through the Authentik `minio` app gets the built-in
# `consoleAdmin` policy). NOT stored in git — run once during bootstrap (re-run to
# rotate). ArgoCD owns the rest.
#
# WHY this lives here and not in tenant.yaml: MinIO Operator v7.1.1 does not render
# Tenant `spec.env` into the StatefulSet, so OIDC env is injected into the tenant's
# `config.env` secret (minio-tenant-config) — the same file the root creds use,
# which the MinIO server reliably sources. (Re-running minio-secret.sh rewrites
# config.env and drops these lines — re-run this script afterwards.)
#
# Create the Authentik OAuth2/OpenID provider + application `minio` first
# (app slug `minio`, redirect URI https://minio.bergtobias.com/oauth_callback).
#
# Usage:
#   MINIO_OIDC_CLIENT_ID=… MINIO_OIDC_CLIENT_SECRET=… ./bootstrap/minio-oidc-secret.sh
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info() { echo "[minio-oidc-secret] $*"; }

: "${MINIO_OIDC_CLIENT_ID:?set MINIO_OIDC_CLIENT_ID (from the Authentik provider)}"
: "${MINIO_OIDC_CLIENT_SECRET:?set MINIO_OIDC_CLIENT_SECRET (from the Authentik provider)}"

CONFIG_URL="https://authentik.bergtobias.com/application/o/minio/.well-known/openid-configuration"

# Current config.env (root creds live here). Strip any prior OIDC lines so this is idempotent.
CURRENT="$(kubectl get secret minio-tenant-config -n minio -o jsonpath='{.data.config\.env}' | base64 -d)"
BASE="$(printf '%s\n' "$CURRENT" | grep -vE '^export (MINIO_IDENTITY_OPENID_|MINIO_BROWSER_REDIRECT_URL)=' || true)"

NEW_ENV="$(cat <<EOF
$BASE
export MINIO_IDENTITY_OPENID_CONFIG_URL=${CONFIG_URL}
export MINIO_IDENTITY_OPENID_CLIENT_ID=${MINIO_OIDC_CLIENT_ID}
export MINIO_IDENTITY_OPENID_CLIENT_SECRET=${MINIO_OIDC_CLIENT_SECRET}
export MINIO_IDENTITY_OPENID_SCOPES="openid,profile,email"
export MINIO_IDENTITY_OPENID_ROLE_POLICY=consoleAdmin
export MINIO_IDENTITY_OPENID_DISPLAY_NAME="Log in with Authentik"
export MINIO_BROWSER_REDIRECT_URL=https://minio.bergtobias.com
EOF
)"

kubectl create secret generic minio-tenant-config \
  -n minio \
  --from-literal=config.env="$NEW_ENV" \
  --dry-run=client -o yaml | kubectl apply -f -

# MinIO sources config.env at startup — restart the tenant pod to pick up the OIDC settings.
kubectl delete pod -n minio -l v1.min.io/tenant=techdocs --wait=false

info "MinIO OIDC injected into config.env; tenant pod restarting to apply."
info "Console: https://minio.bergtobias.com  (login via Authentik)."
