#!/usr/bin/env bash
# Creates the secret Grafana needs for Authentik OIDC login + its admin account.
# NOT stored in git — run once during bootstrap (re-run to rotate). ArgoCD owns
# everything else.
#
# Creates, in namespace `monitoring`:
#   - grafana-oidc : GF_* env consumed by the Grafana pod (envFromSecret in
#                    platform/kube-prometheus-stack/values.yaml)
#
# The Authentik OIDC client id/secret are required inputs — create the
# OAuth2/OpenID provider + application in Authentik first (app slug `grafana`,
# redirect URI https://grafana.bergtobias.com/login/generic_oauth). Optionally
# create a `Grafana Admins` group and add yourself for Admin role mapping.
#
# Usage:
#   GRAFANA_OIDC_CLIENT_ID=... GRAFANA_OIDC_CLIENT_SECRET=... ./bootstrap/grafana-secret.sh
#   # optionally pin the local admin password: GRAFANA_ADMIN_PASSWORD=...
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info() { echo "[grafana-secret] $*"; }

: "${GRAFANA_OIDC_CLIENT_ID:?set GRAFANA_OIDC_CLIENT_ID (from the Authentik provider)}"
: "${GRAFANA_OIDC_CLIENT_SECRET:?set GRAFANA_OIDC_CLIENT_SECRET (from the Authentik provider)}"

ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -hex 24)}"

# Namespace must exist before the secret (the Grafana pod mounting it must not
# start first). ArgoCD also sets CreateNamespace=true, but bootstrap may run first.
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-oidc \
  -n monitoring \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID="$GRAFANA_OIDC_CLIENT_ID" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$GRAFANA_OIDC_CLIENT_SECRET" \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Grafana OIDC secret created in namespace 'monitoring'."
info "Local admin (user 'admin') password: ${ADMIN_PASSWORD}"
info "Store it — the OIDC login is the normal path; admin is the break-glass account."
