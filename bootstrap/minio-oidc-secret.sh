#!/usr/bin/env bash
# Creates the Authentik OIDC client credentials the MinIO Console uses for login.
# NOT stored in git — run once during bootstrap (re-run to rotate).
#
# Creates, in namespace `minio`:
#   - minio-oidc : client-id / client-secret (referenced by the Tenant spec.env
#                  MINIO_IDENTITY_OPENID_CLIENT_ID/SECRET)
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

kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic minio-oidc \
  -n minio \
  --from-literal=client-id="$MINIO_OIDC_CLIENT_ID" \
  --from-literal=client-secret="$MINIO_OIDC_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

info "MinIO OIDC secret created in namespace 'minio'."
