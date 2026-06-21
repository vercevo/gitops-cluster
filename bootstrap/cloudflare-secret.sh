#!/usr/bin/env bash
# Creates the Cloudflare API token secret used by cert-manager and external-dns.
# Run once after bootstrap, before cert-manager-issuers syncs.
#
# Required Cloudflare API token permissions:
#   Zone / Zone / Read
#   Zone / DNS / Edit
# Scope: bergtobias.com (specific zone, not all zones)
#
# Create token at: https://dash.cloudflare.com/profile/api-tokens
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
CF_API_TOKEN="${CF_API_TOKEN:?Set CF_API_TOKEN to your Cloudflare API token}"

info() { echo "[cloudflare-secret] $*"; }

# cert-manager reads from cert-manager namespace
kubectl create secret generic cloudflare-api-token \
  -n cert-manager \
  --from-literal=token="${CF_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# external-dns reads from its own namespace
kubectl create secret generic cloudflare-api-token \
  -n external-dns \
  --from-literal=token="${CF_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Cloudflare API token secret created in: cert-manager, external-dns"
