#!/usr/bin/env bash
# Run ONCE before committing: sets cluster identity across all manifests.
# Usage: ./bootstrap/configure.sh <repo-url> <cluster-domain> <acme-email>
#   repo-url       Full HTTPS URL of this repo, e.g. https://github.com/myorg/gitops-cluster
#   cluster-domain Base domain for ingress, e.g. cluster.example.com
#   acme-email     Email for Let's Encrypt notifications
set -euo pipefail

REPO_URL="${1:?Usage: $0 <repo-url> <cluster-domain> <acme-email>}"
CLUSTER_DOMAIN="${2:?}"
ACME_EMAIL="${3:?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

info() { echo "[configure] $*"; }

find "${ROOT}" -name "*.yaml" -not -path "${ROOT}/.git/*" | while read -r f; do
  sed -i \
    -e "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g" \
    -e "s|CLUSTER_DOMAIN_PLACEHOLDER|${CLUSTER_DOMAIN}|g" \
    -e "s|ACME_EMAIL_PLACEHOLDER|${ACME_EMAIL}|g" \
    "${f}"
done

info "Applied:"
info "  REPO_URL      = ${REPO_URL}"
info "  CLUSTER_DOMAIN= ${CLUSTER_DOMAIN}"
info "  ACME_EMAIL    = ${ACME_EMAIL}"
info ""
info "Next: git commit -am 'Configure cluster' && git push"
info "Then: sudo REPO_URL='${REPO_URL}' ./bootstrap/bootstrap.sh"
