#!/bin/bash
# SABnzbd bootstrap: creates the web UI credentials, deploys SABnzbd, then
# configures the login, hostname whitelist and download folders through the
# API. Safe to re-run: the existing secret is reused and settings re-applied.
#
# Usage:
#   bash scripts/sabnzbd-bootstrap.sh
#   [SABNZBD_PASSWORD=...] bash scripts/sabnzbd-bootstrap.sh
#
# If SABNZBD_PASSWORD is empty, a random one is generated and printed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/k8s/apps/sabnzbd.yaml"
NS="media"
HOST_WHITELIST="pi-cluster.internal,sabnzbd.local"

secret_value() {
  kubectl -n "$NS" get secret sabnzbd-env -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1. Web UI credentials
USERNAME="$(secret_value WEB_USERNAME)"
PASSWORD="$(secret_value WEB_PASSWORD)"
GENERATED_PASSWORD=false
if [ -z "$USERNAME" ]; then
  USERNAME="${SABNZBD_USERNAME:-admin}"
  PASSWORD="${SABNZBD_PASSWORD:-}"
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(openssl rand -hex 12)"
    GENERATED_PASSWORD=true
  fi
  kubectl -n "$NS" create secret generic sabnzbd-env \
    --from-literal=WEB_USERNAME="$USERNAME" \
    --from-literal=WEB_PASSWORD="$PASSWORD"
fi

# 2. Deploy
kubectl apply -f "$MANIFEST"
kubectl -n "$NS" rollout status deployment/sabnzbd --timeout=600s

# 3. Wait for SABnzbd to write its API key on first start
API_KEY=""
for _ in $(seq 1 60); do
  API_KEY="$(kubectl -n "$NS" exec deploy/sabnzbd -- sh -c \
    "sed -n 's/^api_key = //p' /config/sabnzbd.ini 2>/dev/null" || true)"
  [ -n "$API_KEY" ] && break
  sleep 5
done
if [ -z "$API_KEY" ]; then
  echo "SABnzbd did not generate an API key in time" >&2
  exit 1
fi

# 4. Settings via the API (from inside the pod: by IP, so no hostname check)
set_config() {
  kubectl -n "$NS" exec deploy/sabnzbd -- curl -fsS -G "http://127.0.0.1:8080/api" \
    --data-urlencode "mode=set_config" --data-urlencode "section=misc" \
    --data-urlencode "keyword=$1" --data-urlencode "value=$2" \
    --data-urlencode "apikey=${API_KEY}" --data-urlencode "output=json" >/dev/null
}
set_config host_whitelist "$HOST_WHITELIST"
set_config download_dir /downloads/incomplete
set_config complete_dir /downloads/complete
set_config username "$USERNAME"
set_config password "$PASSWORD"

echo ""
echo "SABnzbd is ready: http://pi-cluster.internal:30850"
echo "  Login: ${USERNAME}"
if [ "$GENERATED_PASSWORD" = true ]; then
  echo "  Generated password: ${PASSWORD}"
fi
echo "  (credentials are stored in secret ${NS}/sabnzbd-env)"
echo "  Add your Usenet provider under Config -> Servers."
