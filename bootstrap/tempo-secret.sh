#!/usr/bin/env bash
# Creates the S3 credentials Tempo uses to read/write traces in the MinIO `tempo`
# bucket. NOT stored in git — run once during bootstrap (re-run to rotate). Reuses
# the MinIO tenant root creds (same pattern as bootstrap/loki-secret.sh). The
# `tempo` bucket is declared in platform/minio-tenant/tenant.yaml.
#
# Creates, in namespace `tempo`:
#   - tempo-s3 : AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (Tempo's minio-go client
#                reads these from env; see tempo.extraEnvFrom in values.yaml)
#
# Usage:
#   ./bootstrap/tempo-secret.sh
#   MINIO_ACCESS_KEY=… MINIO_SECRET_KEY=… ./bootstrap/tempo-secret.sh   # override
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info() { echo "[tempo-secret] $*"; }

if [[ -z "${MINIO_ACCESS_KEY:-}" || -z "${MINIO_SECRET_KEY:-}" ]]; then
  CONFIG_ENV="$(kubectl get secret minio-tenant-config -n minio -o jsonpath='{.data.config\.env}' | base64 -d)"
  MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-$(sed -n 's/^export MINIO_ROOT_USER=//p' <<<"$CONFIG_ENV")}"
  MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-$(sed -n 's/^export MINIO_ROOT_PASSWORD=//p' <<<"$CONFIG_ENV")}"
fi
: "${MINIO_ACCESS_KEY:?could not resolve MinIO access key}"
: "${MINIO_SECRET_KEY:?could not resolve MinIO secret key}"

kubectl create namespace tempo --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic tempo-s3 \
  -n tempo \
  --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Tempo S3 secret created in namespace 'tempo' (bucket 'tempo' on the MinIO tenant)."
