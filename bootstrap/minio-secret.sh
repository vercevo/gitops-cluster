#!/usr/bin/env bash
# Creates the MinIO tenant root credentials and the matching S3 credential
# secret that Backstage uses to read TechDocs from MinIO.
#
# Secrets are intentionally NOT stored in git. Run once during bootstrap.
#
# Usage:
#   ./bootstrap/minio-secret.sh            # generates a random password
#   MINIO_ROOT_PASSWORD=... ./bootstrap/minio-secret.sh
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -hex 24)}"

info() { echo "[minio-secret] $*"; }

# Namespaces (idempotent — ArgoCD also creates these, but the secrets must
# exist before the Tenant/Backstage pods start).
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

# 1) Tenant root credentials — referenced by Tenant spec.configuration.name.
kubectl create secret generic minio-tenant-config \
  -n minio \
  --from-literal=config.env="$(printf 'export MINIO_ROOT_USER=%s\nexport MINIO_ROOT_PASSWORD=%s\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD")" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) S3 credentials for Backstage to read the techdocs bucket.
kubectl create secret generic minio-techdocs \
  -n backstage \
  --from-literal=access-key="$MINIO_ROOT_USER" \
  --from-literal=secret-key="$MINIO_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

info "MinIO credentials created."
info ""
info "Add these as GitHub Actions secrets (repo or org level) for the docs CI:"
info "  MINIO_ACCESS_KEY = ${MINIO_ROOT_USER}"
info "  MINIO_SECRET_KEY = ${MINIO_ROOT_PASSWORD}"
info "  MINIO_ENDPOINT   = https://s3.bergtobias.com"
