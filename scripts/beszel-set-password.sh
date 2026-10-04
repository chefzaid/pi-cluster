#!/bin/bash
# Change the Beszel admin password. Updates the Beszel user, the matching
# PocketBase superuser (database admin at /_/), and secret
# monitoring/beszel-hub-env so scripts/beszel-bootstrap.sh keeps working.
# Agents are not affected: they connect with their own token.
#
# Usage:
#   bash scripts/beszel-set-password.sh            # prompts for the new password
#   NEW_PASSWORD=... bash scripts/beszel-set-password.sh

set -euo pipefail

NS="monitoring"
HUB="${BESZEL_HUB_URL:-http://127.0.0.1:30090}"

secret_value() {
  kubectl -n "$NS" get secret beszel-hub-env -o jsonpath="{.data.$1}" | base64 -d
}

json() {
  python3 -c 'import json,sys; a=sys.argv[1:]; print(json.dumps(dict(zip(a[::2], a[1::2]))))' "$@"
}

EMAIL="$(secret_value USER_EMAIL)"
OLD="$(secret_value USER_PASSWORD)"

NEW="${NEW_PASSWORD:-}"
if [ -z "$NEW" ]; then
  read -rsp "New Beszel password for ${EMAIL} (min 8 chars): " NEW
  echo ""
fi
if [ "${#NEW}" -lt 8 ]; then
  echo "ERROR: password must be at least 8 characters" >&2
  exit 1
fi

# Authenticate as the superuser (created with the same credentials as the user)
AUTH="$(curl -fs -X POST "${HUB}/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' -d "$(json identity "$EMAIL" password "$OLD")" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"

record_id() {
  curl -fs -G -H "Authorization: ${AUTH}" "${HUB}/api/collections/$1/records" \
    --data-urlencode "filter=email='${EMAIL}'" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["items"][0]["id"])'
}

for collection in users _superusers; do
  curl -fs -o /dev/null -X PATCH -H "Authorization: ${AUTH}" -H 'Content-Type: application/json' \
    "${HUB}/api/collections/${collection}/records/$(record_id "$collection")" \
    -d "$(json password "$NEW" passwordConfirm "$NEW")"
  echo "  Updated ${collection}"
done

kubectl -n "$NS" patch secret beszel-hub-env --type=merge \
  -p "$(python3 -c 'import json,sys; print(json.dumps({"stringData":{"USER_PASSWORD":sys.argv[1]}}))' "$NEW")" >/dev/null
echo "  Updated secret ${NS}/beszel-hub-env"
echo "Done. Log in at http://pi-cluster.internal:30090 as ${EMAIL}"
