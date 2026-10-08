#!/bin/bash
# K3s HA Migration - 1 server (SQLite) -> 3 servers (embedded etcd) + 1 agent
# ============================================================================
# Converts the existing cluster in place:
#   1. pi-node-01: switches the datastore from SQLite to embedded etcd
#      (k3s migrates the data automatically on restart with cluster-init)
#   2. pi-node-02, pi-node-03: converted from agent to server, one at a time
#   3. pi-node-04: stays a pure worker (untouched)
#
# Nodes are converted IN PLACE (node objects are NOT deleted) so each node
# keeps its podCIDR, which flannel-subnet-fix.service hardcodes, and its
# OpenEBS LocalPV data under /var/openebs/local.
#
# Pods pinned to pi-node-02/03 by LocalPVs are down while that node converts.
#
# Usage (on pi-node-01, as your normal user - NOT with sudo):
#   bash scripts/migrate-to-ha.sh
# You will be asked for your sudo password locally and on each converted node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K3S_CONFIG="$REPO_ROOT/config/k3s/config.yaml"
K3S_VERSION="${K3S_VERSION:-v1.36.3+k3s1}"
FIRST_SERVER="pi-node-01"
FIRST_SERVER_IP="192.168.1.191"
JOIN_NODES=("pi-node-02:192.168.1.192" "pi-node-03:192.168.1.193")
SSH_USER="${SSH_USER:-$USER}"

log() { echo -e "\033[0;36m==>\033[0m $1"; }
die() { echo -e "\033[0;31mERROR:\033[0m $1" >&2; exit 1; }

is_etcd_node() {
  [ "$(kubectl get node "$1" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/etcd}' 2>/dev/null)" = "true" ]
}

wait_etcd_ready() {
  local node="$1"
  log "Waiting for $node to be Ready with the etcd role..."
  for _ in $(seq 1 120); do
    if is_etcd_node "$node" && kubectl wait --for=condition=Ready "node/$node" --timeout=5s &>/dev/null; then
      log "$node is an etcd member and Ready"
      return 0
    fi
    sleep 5
  done
  die "$node did not become a Ready etcd member within 10 minutes"
}

# ── Preflight ──
[ "$EUID" -ne 0 ] || die "Run as your normal user (the script calls sudo itself)"
[ "$(hostname)" = "$FIRST_SERVER" ] || die "Run this on $FIRST_SERVER"
kubectl get nodes &>/dev/null || die "kubectl cannot reach the cluster"
sudo -v

# ── Step 1: SQLite -> embedded etcd on pi-node-01 ──
if is_etcd_node "$FIRST_SERVER"; then
  log "$FIRST_SERVER already runs embedded etcd, skipping datastore migration"
else
  BACKUP="/var/lib/rancher/k3s/server/db-sqlite-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  log "Backing up SQLite datastore to $BACKUP"
  sudo tar -czf "$BACKUP" -C /var/lib/rancher/k3s/server db token

  log "Enabling cluster-init + etcd tuning in /etc/rancher/k3s/config.yaml"
  sudo cp /etc/rancher/k3s/config.yaml "/etc/rancher/k3s/config.yaml.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp "$K3S_CONFIG" /etc/rancher/k3s/config.yaml
  echo 'cluster-init: true' | sudo tee -a /etc/rancher/k3s/config.yaml >/dev/null

  log "Restarting k3s (API is briefly unavailable; running pods are not affected)"
  sudo systemctl restart k3s
  until kubectl get nodes &>/dev/null; do sleep 3; done
  wait_etcd_ready "$FIRST_SERVER"
fi

TOKEN="$(sudo cat /var/lib/rancher/k3s/server/token)"

# ── Step 2: convert agents to servers, one at a time ──
for entry in "${JOIN_NODES[@]}"; do
  node="${entry%%:*}"
  ip="${entry##*:}"

  if is_etcd_node "$node"; then
    log "$node is already a server, skipping"
    continue
  fi

  log "Draining $node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=300s

  log "Converting $node ($ip) to a server"
  TMP="$(mktemp -d)"
  cp "$K3S_CONFIG" "$TMP/config.yaml"
  printf 'K3S_TOKEN=%q\nK3S_VERSION=%q\nFIRST_SERVER_IP=%q\n' \
    "$TOKEN" "$K3S_VERSION" "$FIRST_SERVER_IP" > "$TMP/token.env"
  cat > "$TMP/convert.sh" <<'REMOTE'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ./token.env

systemctl disable --now k3s-agent
/usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true

# Full server config (kubelet + apiserver + controller + etcd args)
install -m 0644 config.yaml /etc/rancher/k3s/config.yaml

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$K3S_TOKEN" \
  sh -s - server --server "https://${FIRST_SERVER_IP}:6443"

# Remove the leftover agent unit so only k3s.service manages the node
rm -f /etc/systemd/system/k3s-agent.service /etc/systemd/system/k3s-agent.service.env \
      /usr/local/bin/k3s-agent-uninstall.sh
systemctl daemon-reload
REMOTE
  chmod 600 "$TMP/token.env"

  ssh "${SSH_USER}@${ip}" 'rm -rf /tmp/k3s-ha && mkdir -m 700 /tmp/k3s-ha'
  scp -q "$TMP/convert.sh" "$TMP/config.yaml" "$TMP/token.env" "${SSH_USER}@${ip}:/tmp/k3s-ha/"
  rm -rf "$TMP"
  ssh -t "${SSH_USER}@${ip}" 'sudo bash /tmp/k3s-ha/convert.sh; rc=$?; rm -rf /tmp/k3s-ha; exit $rc'

  wait_etcd_ready "$node"
  kubectl uncordon "$node"
done

# ── Done ──
log "Migration complete"
kubectl get nodes -o wide
echo ""
echo "Expected: pi-node-01..03 = control-plane,etcd ; pi-node-04 = <none> (worker)"
