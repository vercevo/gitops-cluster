#!/usr/bin/env bash
# Run ONCE before committing: stamps the repo URL into all seed manifests.
# Domain and email are already set to bergtobias.com / tobiaswillyberg@gmail.com.
# Usage: ./bootstrap/configure.sh <repo-url>
#   repo-url  Full HTTPS URL of this repo, e.g. https://github.com/tobbe/gitops-cluster
set -euo pipefail

REPO_URL="${1:?Usage: $0 <repo-url>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

info() { echo "[configure] $*"; }

find "${ROOT}" -name "*.yaml" -not -path "${ROOT}/.git/*" | while read -r f; do
  sed -i "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g" "${f}"
done

info "Applied REPO_URL = ${REPO_URL}"
info ""
info "Next: git commit -am 'Configure repo URL' && git push"
info "Then: sudo REPO_URL='${REPO_URL}' ./bootstrap/bootstrap.sh"
