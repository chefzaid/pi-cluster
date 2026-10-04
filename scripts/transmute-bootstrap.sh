#!/bin/bash
# Transmute bootstrap: creates the signing key and admin credentials, deploys
# Transmute, then creates the admin account so guest access is available and
# no visitor can claim admin. Safe to re-run: existing secrets are reused and
# the admin is only created while the instance has no users.
#
# Usage:
#   bash scripts/transmute-bootstrap.sh
#   [TRANSMUTE_ADMIN_PASSWORD=...] bash scripts/transmute-bootstrap.sh
#
# If TRANSMUTE_ADMIN_PASSWORD is empty, a random one is generated and printed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/k8s/apps/transmute.yaml"
NS="transmute"
URL="${TRANSMUTE_URL:-http://127.0.0.1:30313}"

secret_value() {
  kubectl -n "$NS" get secret transmute-env -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1. Signing key + admin credentials
USERNAME="$(secret_value ADMIN_USERNAME)"
PASSWORD="$(secret_value ADMIN_PASSWORD)"
GENERATED_PASSWORD=false
if [ -z "$USERNAME" ]; then
  USERNAME="${TRANSMUTE_ADMIN_USERNAME:-admin}"
  PASSWORD="${TRANSMUTE_ADMIN_PASSWORD:-}"
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(openssl rand -base64 18)"
    GENERATED_PASSWORD=true
  fi
  kubectl -n "$NS" create secret generic transmute-env \
    --from-literal=AUTH_SECRET_KEY="$(openssl rand -base64 48)" \
    --from-literal=ADMIN_USERNAME="$USERNAME" \
    --from-literal=ADMIN_PASSWORD="$PASSWORD"
fi

# 2. Deploy (large image and slow first start on a Pi)
kubectl apply -f "$MANIFEST"
kubectl -n "$NS" rollout status deployment/transmute --timeout=900s

echo "  Waiting for Transmute API at ${URL}..."
for _ in $(seq 1 60); do
  curl -fs "${URL}/api/health/ready" >/dev/null && break
  sleep 5
done

# 3. Admin account (only while no users exist)
if curl -fs "${URL}/api/users/bootstrap-status" | grep -q '"requires_setup":true'; then
  curl -fs -X POST "${URL}/api/users" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$USERNAME" "$PASSWORD")" >/dev/null
  echo "  Created admin account '${USERNAME}'"
else
  echo "  Admin account already exists"
fi

echo ""
echo "Transmute is ready: http://pi-cluster.internal:30313 (click \"Use as guest\")"
echo "  Admin login: ${USERNAME}"
if [ "$GENERATED_PASSWORD" = true ]; then
  echo "  Generated password: ${PASSWORD}"
fi
echo "  (credentials are stored in secret ${NS}/transmute-env)"
