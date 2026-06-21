#!/usr/bin/env bash
# Registers a GitHub App with ArgoCD as a repo-creds credential template.
# Covers all repos under https://github.com/vercevo automatically.
#
# Usage:
#   GITHUB_APP_ID=123456 \
#   GITHUB_APP_INSTALLATION_ID=12345678 \
#   GITHUB_APP_PRIVATE_KEY_FILE=/path/to/private-key.pem \
#   ./bootstrap/github-app-secret.sh
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

GITHUB_APP_ID="${GITHUB_APP_ID:?Set GITHUB_APP_ID}"
GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID}"
GITHUB_APP_PRIVATE_KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:?Set GITHUB_APP_PRIVATE_KEY_FILE to path of .pem file}"

if [[ ! -f "${GITHUB_APP_PRIVATE_KEY_FILE}" ]]; then
  echo "Error: private key file not found: ${GITHUB_APP_PRIVATE_KEY_FILE}"
  exit 1
fi

info() { echo "[github-app-secret] $*"; }

PRIVATE_KEY=$(cat "${GITHUB_APP_PRIVATE_KEY_FILE}")

kubectl create secret generic github-app-creds \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/vercevo \
  --from-literal=githubAppID="${GITHUB_APP_ID}" \
  --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
  --from-literal=githubAppPrivateKey="${PRIVATE_KEY}" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - "argocd.argoproj.io/secret-type=repo-creds" --dry-run=client -o yaml \
  | kubectl apply -f -

info "GitHub App credentials registered with ArgoCD."
info "ArgoCD will now retry syncing — watch: kubectl get applications -n argocd -w"
