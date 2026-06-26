#!/usr/bin/env bash
# Creates the S3 credentials Loki uses to read/write its chunks + index in the
# MinIO `loki` bucket. NOT stored in git — run once during bootstrap (re-run to
# rotate). Reuses the MinIO tenant root creds, the same homelab pattern Backstage
# uses (see bootstrap/minio-secret.sh). The `loki` bucket itself is declared in
# platform/minio-tenant/tenant.yaml and auto-created by the MinIO operator.
#
# Creates, in namespace `loki`:
#   - loki-s3 : AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (Loki's S3 client reads
#               these from env; see singleBinary.extraEnvFrom in values.yaml)
#
# Usage:
#   ./bootstrap/loki-secret.sh                 # reuse MinIO root creds
#   MINIO_ACCESS_KEY=… MINIO_SECRET_KEY=… ./bootstrap/loki-secret.sh   # override
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info() { echo "[loki-secret] $*"; }

# Pull the MinIO root creds out of the tenant config secret unless overridden.
if [[ -z "${MINIO_ACCESS_KEY:-}" || -z "${MINIO_SECRET_KEY:-}" ]]; then
  CONFIG_ENV="$(kubectl get secret minio-tenant-config -n minio -o jsonpath='{.data.config\.env}' | base64 -d)"
  MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-$(sed -n 's/^export MINIO_ROOT_USER=//p' <<<"$CONFIG_ENV")}"
  MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-$(sed -n 's/^export MINIO_ROOT_PASSWORD=//p' <<<"$CONFIG_ENV")}"
fi
: "${MINIO_ACCESS_KEY:?could not resolve MinIO access key}"
: "${MINIO_SECRET_KEY:?could not resolve MinIO secret key}"

# Namespace must exist before the secret (the Loki pod mounting it must not start first).
kubectl create namespace loki --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic loki-s3 \
  -n loki \
  --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Loki S3 secret created in namespace 'loki' (bucket 'loki' on the MinIO tenant)."
