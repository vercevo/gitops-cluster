#!/usr/bin/env bash
# Creates the secrets Dagster needs. NOT stored in git — run once during
# bootstrap (re-run to rotate). ArgoCD owns everything else.
#
# Creates, in namespace `dagster`:
#   - jaffle-pg-user       : warehouse CNPG role/initdb creds (basic-auth)
#   - dagster-pg-user      : metadata CNPG role/initdb creds (basic-auth) PLUS a
#                            `postgresql-password` key the Dagster chart reads
#   - dagster-oauth2-proxy : OAUTH2_PROXY_* env for the UI auth gate
#   - ghcr-pull            : GHCR pull secret (copied from the backstage ns)
#
# The Authentik OIDC client id/secret are required inputs — create the
# OAuth2/OpenID provider + application in Authentik first (app slug `dagster`,
# redirect URI https://dagster.bergtobias.com/oauth2/callback).
#
# Usage:
#   DAGSTER_OIDC_CLIENT_ID=... DAGSTER_OIDC_CLIENT_SECRET=... ./bootstrap/dagster-secret.sh
#   # optionally pin DB passwords: JAFFLE_DB_PASSWORD=... DAGSTER_DB_PASSWORD=...
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info() { echo "[dagster-secret] $*"; }

: "${DAGSTER_OIDC_CLIENT_ID:?set DAGSTER_OIDC_CLIENT_ID (from the Authentik provider)}"
: "${DAGSTER_OIDC_CLIENT_SECRET:?set DAGSTER_OIDC_CLIENT_SECRET (from the Authentik provider)}"

JAFFLE_PASSWORD="${JAFFLE_DB_PASSWORD:-$(openssl rand -hex 24)}"
DAGSTER_PASSWORD="${DAGSTER_DB_PASSWORD:-$(openssl rand -hex 24)}"
# oauth2-proxy cookie secret must decode to 16/24/32 bytes.
COOKIE_SECRET="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"

# Namespace must exist before the secrets (pods that mount them must not start first).
kubectl create namespace dagster --dry-run=client -o yaml | kubectl apply -f -

# 1) Warehouse CNPG creds (postgres.yaml jaffle-pg; also read by user code + Evidence).
kubectl create secret generic jaffle-pg-user \
  -n dagster --type=kubernetes.io/basic-auth \
  --from-literal=username="jaffle" \
  --from-literal=password="$JAFFLE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Metadata CNPG creds (postgres.yaml dagster-pg). The extra `postgresql-password`
#    key is what the Dagster chart's postgresqlSecretName expects.
kubectl create secret generic dagster-pg-user \
  -n dagster --type=kubernetes.io/basic-auth \
  --from-literal=username="dagster" \
  --from-literal=password="$DAGSTER_PASSWORD" \
  --from-literal=postgresql-password="$DAGSTER_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) oauth2-proxy config (envFrom in oauth2-proxy.yaml).
kubectl create secret generic dagster-oauth2-proxy \
  -n dagster \
  --from-literal=OAUTH2_PROXY_CLIENT_ID="$DAGSTER_OIDC_CLIENT_ID" \
  --from-literal=OAUTH2_PROXY_CLIENT_SECRET="$DAGSTER_OIDC_CLIENT_SECRET" \
  --from-literal=OAUTH2_PROXY_COOKIE_SECRET="$COOKIE_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4) GHCR pull secret — reuse the one already configured for backstage.
DOCKERCFG="$(kubectl get secret ghcr-pull -n backstage -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)"
kubectl create secret generic ghcr-pull \
  -n dagster --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$DOCKERCFG" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Dagster secrets created in namespace 'dagster'."
info "Warehouse (jaffle) password: ${JAFFLE_PASSWORD}"
info "Metadata (dagster) password: ${DAGSTER_PASSWORD}"
info "Store these; needed only if you recreate the DBs."
