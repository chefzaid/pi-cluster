#!/bin/bash
# Beszel bootstrap: deploys the hub, creates the first admin, then wires the
# per-node agents to the hub with its public key and a permanent universal token.
# Safe to re-run: existing secrets (admin credentials, agent token) are reused.
#
# Usage:
#   BESZEL_ADMIN_EMAIL=you@example.com [BESZEL_ADMIN_PASSWORD=...] bash scripts/beszel-bootstrap.sh
#
# If BESZEL_ADMIN_PASSWORD is empty, a random one is generated and printed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/k8s/platform/beszel.yaml"
NS="monitoring"
HUB="${BESZEL_HUB_URL:-http://127.0.0.1:30090}"

secret_value() {
  kubectl -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true
}

json_field() {
  python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1. Admin credentials (first user is created from these on the hub's first start)
EMAIL="$(secret_value beszel-hub-env USER_EMAIL)"
PASSWORD="$(secret_value beszel-hub-env USER_PASSWORD)"
GENERATED_PASSWORD=false
if [ -z "$EMAIL" ]; then
  EMAIL="${BESZEL_ADMIN_EMAIL:?BESZEL_ADMIN_EMAIL is required on first run}"
  PASSWORD="${BESZEL_ADMIN_PASSWORD:-}"
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(openssl rand -base64 18)"
    GENERATED_PASSWORD=true
  fi
  kubectl -n "$NS" create secret generic beszel-hub-env \
    --from-literal=USER_EMAIL="$EMAIL" \
    --from-literal=USER_PASSWORD="$PASSWORD"
fi

# 2. Hub (the agent DaemonSet waits on beszel-agent-secret, created below)
kubectl apply -f "$MANIFEST"
kubectl -n "$NS" rollout status deployment/beszel --timeout=600s

echo "  Waiting for hub API at ${HUB}..."
for _ in $(seq 1 60); do
  curl -fs "${HUB}/api/health" >/dev/null && break
  sleep 5
done

# 3. Public key + permanent universal token for agent self-registration
AUTH_TOKEN="$(curl -fs -X POST "${HUB}/api/collections/users/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"identity":sys.argv[1],"password":sys.argv[2]}))' "$EMAIL" "$PASSWORD")" \
  | json_field token)"

KEY="$(curl -fs -H "Authorization: ${AUTH_TOKEN}" "${HUB}/api/beszel/info" | json_field key)"

TOKEN="$(secret_value beszel-agent-secret TOKEN)"
[ -n "$TOKEN" ] || TOKEN="$(cat /proc/sys/kernel/random/uuid)"
curl -fs -H "Authorization: ${AUTH_TOKEN}" \
  "${HUB}/api/beszel/universal-token?enable=1&permanent=1&token=${TOKEN}" >/dev/null

kubectl -n "$NS" create secret generic beszel-agent-secret \
  --from-literal=KEY="$KEY" \
  --from-literal=TOKEN="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Agents
kubectl -n "$NS" rollout restart daemonset/beszel-agent
kubectl -n "$NS" rollout status daemonset/beszel-agent --timeout=600s

echo ""
echo "Beszel is ready: http://pi-cluster.internal:30090"
echo "  Login: ${EMAIL}"
if [ "$GENERATED_PASSWORD" = true ]; then
  echo "  Generated password: ${PASSWORD}"
fi
echo "  (credentials are stored in secret ${NS}/beszel-hub-env)"
