#!/usr/bin/env bash
# Creates the secrets Airflow needs. These are intentionally NOT stored in git —
# run once during bootstrap (and re-run to rotate). ArgoCD owns everything else.
#
# Creates, in namespace `airflow`:
#   - airflow-pg-user  : CNPG role/initdb creds (basic-auth: username + password)
#   - airflow-metadata : SQLAlchemy connection string for the metadata DB
#   - airflow-keys     : fernet-key + api-secret-key + jwt-secret (Airflow 3 signing keys)
#   - airflow-oidc     : Authentik OAuth client-id + client-secret
#
# The Authentik OIDC client id/secret are required inputs (create the provider/app in
# Authentik first — redirect URI https://airflow.bergtobias.com/auth/oauth-authorized/authentik).
#
# Usage:
#   AIRFLOW_OIDC_CLIENT_ID=... AIRFLOW_OIDC_CLIENT_SECRET=... ./bootstrap/airflow-secret.sh
#   # optionally pin the DB password: AIRFLOW_DB_PASSWORD=... (default: random)
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info() { echo "[airflow-secret] $*"; }
die()  { echo "[airflow-secret] ERROR: $*" >&2; exit 1; }

: "${AIRFLOW_OIDC_CLIENT_ID:?set AIRFLOW_OIDC_CLIENT_ID (from the Authentik provider)}"
: "${AIRFLOW_OIDC_CLIENT_SECRET:?set AIRFLOW_OIDC_CLIENT_SECRET (from the Authentik provider)}"

DB_USER="airflow"
DB_PASSWORD="${AIRFLOW_DB_PASSWORD:-$(openssl rand -hex 24)}"
DB_HOST="airflow-pg-rw.airflow.svc.cluster.local"
# hex password is URL-safe, so it needs no escaping in the connection string.
CONNECTION="postgresql+psycopg2://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:5432/airflow"

# Fernet key must be url-safe base64 of 32 bytes (no external deps required).
FERNET_KEY="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
API_SECRET_KEY="$(openssl rand -hex 32)"
JWT_SECRET="$(openssl rand -hex 32)"

# Namespace must exist before the secrets (ArgoCD also creates it, but pods that
# mount these secrets must not start first).
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

# 1) CNPG role + initdb credentials (consumed by postgres.yaml).
kubectl create secret generic airflow-pg-user \
  -n airflow --type=kubernetes.io/basic-auth \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Metadata DB connection string (chart: data.metadataSecretName).
kubectl create secret generic airflow-metadata \
  -n airflow \
  --from-literal=connection="$CONNECTION" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Airflow 3 signing keys (chart: fernetKeySecretName / apiSecretKeySecretName / jwtSecretName).
kubectl create secret generic airflow-keys \
  -n airflow \
  --from-literal=fernet-key="$FERNET_KEY" \
  --from-literal=api-secret-key="$API_SECRET_KEY" \
  --from-literal=jwt-secret="$JWT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4) Authentik OIDC client (read by webserver_config.py via env).
kubectl create secret generic airflow-oidc \
  -n airflow \
  --from-literal=client-id="$AIRFLOW_OIDC_CLIENT_ID" \
  --from-literal=client-secret="$AIRFLOW_OIDC_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Airflow secrets created in namespace 'airflow'."
info "DB password: ${DB_PASSWORD}  (store it; needed only if you recreate the DB)"
