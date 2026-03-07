#!/bin/bash
# Node Setup Script - Flannel Fix + Reboot Cleanup + Firewall
# ============================================================
# Fixes and hardens each node for reliable K3s cluster operation:
#   1. Flannel subnet.env - ensures networking works after reboot (all nodes)
#   2. Reboot cleanup service - auto-cleans stale pods on boot (control plane)
#   3. UFW firewall - secures node while allowing K3s traffic (all nodes)
#
# Usage: Run on EACH node with the correct subnet:
#   sudo bash node-setup.sh <SUBNET>             # worker nodes
#   sudo bash node-setup.sh <SUBNET> --server    # control plane
#
# Subnet reference:
#   pi-node-01: 10.42.0.1/24 --server (control plane)
#   pi-node-02: 10.42.1.1/24
#   pi-node-03: 10.42.2.1/24
#   pi-node-04: 10.42.3.1/24

set -e

FLANNEL_SUBNET="${1:-10.42.0.1/24}"
IS_SERVER=false
[ "$2" = "--server" ] && IS_SERVER=true

# ──────────────────────────────────────────────
# 1. Flannel subnet fix (all nodes)
# ──────────────────────────────────────────────
echo "=== Installing flannel-subnet-fix.service ==="
echo "Subnet: ${FLANNEL_SUBNET}"
echo ""

cat > /etc/systemd/system/flannel-subnet-fix.service << EOF
[Unit]
Description=Create flannel subnet.env before K3s starts
Before=k3s.service k3s-agent.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'mkdir -p /run/flannel && echo -e "FLANNEL_NETWORK=10.42.0.0/16\\nFLANNEL_SUBNET=${FLANNEL_SUBNET}\\nFLANNEL_MTU=1450\\nFLANNEL_IPMASQ=true" > /run/flannel/subnet.env'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable flannel-subnet-fix.service
systemctl start flannel-subnet-fix.service

if [ -f /run/flannel/subnet.env ]; then
  echo "  flannel-subnet-fix.service installed and started"
  cat /run/flannel/subnet.env
else
  echo "ERROR - subnet.env was not created"
  exit 1
fi
echo ""

# ──────────────────────────────────────────────
# 2. K3s reboot cleanup (control plane only)
# ──────────────────────────────────────────────
if [ "$IS_SERVER" = true ]; then
  echo "=== Installing k3s-reboot-cleanup.service ==="

  cat > /usr/local/bin/k3s-reboot-cleanup.sh <<'SCRIPT'
#!/bin/bash
# K3s Reboot Cleanup Script
# Automatically cleans up stale pods after a full cluster reboot.
# Uses a retry loop to keep cleaning Unknown pods until the cluster stabilizes.
# Worker kubelets report pod statuses at different times, so a single pass
# is not enough - pods may become Unknown minutes after the first cleanup.
#
# Strategy:
#   1. Wait for API + ALL nodes Ready
#   2. Loop: delete Unknown pods, wait, re-check - repeat until 2 consecutive
#      clean passes (no Unknown pods) or max 4 minutes
#   3. Restart any CrashLooping deployments (cloudflared, etc.)
#   4. Clean up Terminating pods

LOG_TAG="k3s-reboot-cleanup"
log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }

delete_unknown_pods() {
  local pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Unknown" | awk '{print $1 ":" $2}')
  if [ -z "$pods" ]; then
    return 1  # no Unknown pods found
  fi
  local count=$(echo "$pods" | wc -l)
  log "Found $count Unknown pods, force-deleting..."
  for entry in $pods; do
    local ns="${entry%%:*}"
    local pod="${entry##*:}"
    kubectl delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null && \
      log "  Deleted $ns/$pod" || true
  done
  return 0  # did delete some
}

delete_terminating_pods() {
  local pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1 ":" $2}')
  if [ -n "$pods" ]; then
    local count=$(echo "$pods" | wc -l)
    log "Force-deleting $count Terminating pods..."
    for entry in $pods; do
      local ns="${entry%%:*}"
      local pod="${entry##*:}"
      kubectl delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null || true
    done
  fi
}

restart_crashlooping() {
  # Restart deployments stuck in CrashLoopBackOff/Error
  local bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error" | awk '{print $1}' | sort -u)
  for ns in $bad_pods; do
    local deps=$(kubectl get deployments -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')
    for dep in $deps; do
      local unavail=$(kubectl get deployment "$dep" -n "$ns" -o jsonpath='{.status.unavailableReplicas}' 2>/dev/null)
      if [ -n "$unavail" ] && [ "$unavail" -gt 0 ]; then
        kubectl rollout restart deployment/"$dep" -n "$ns" 2>/dev/null && \
          log "  Restarted $ns/$dep (had unavailable replicas)" || true
      fi
    done
  done
}

log "Starting reboot cleanup..."

# ── Wait for K3s API (max 120s) ──
SECONDS=0
until kubectl get nodes &>/dev/null; do
  if [ $SECONDS -gt 120 ]; then
    log "ERROR: K3s API not available after 120s, aborting"
    exit 1
  fi
  sleep 2
done
log "K3s API available after ${SECONDS}s"

# ── Wait for ALL nodes to be Ready (max 120s) ──
TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[ "$TOTAL_NODES" -lt 1 ] && TOTAL_NODES=1
SECONDS=0
while true; do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready" | wc -l)
  if [ "$READY" -ge "$TOTAL_NODES" ]; then
    log "All $READY nodes Ready after ${SECONDS}s"
    break
  fi
  if [ $SECONDS -gt 120 ]; then
    log "WARNING: Only $READY/$TOTAL_NODES nodes Ready after 120s, proceeding"
    break
  fi
  sleep 3
done

# ── Initial wait for kubelets to report pod statuses ──
log "Waiting 20s for kubelets to reconcile pod statuses..."
sleep 20

# ── Retry loop: keep cleaning Unknown pods until stable ──
CLEAN_PASSES=0
MAX_LOOPS=12       # 12 loops × 15s = 3 min max
DID_ANY_CLEANUP=false
for i in $(seq 1 $MAX_LOOPS); do
  if delete_unknown_pods; then
    CLEAN_PASSES=0
    DID_ANY_CLEANUP=true
    delete_terminating_pods
    log "Cleanup pass $i done, waiting 15s for more Unknown pods..."
    sleep 15
  else
    CLEAN_PASSES=$((CLEAN_PASSES + 1))
    if [ "$CLEAN_PASSES" -ge 2 ]; then
      log "2 consecutive clean passes - no more Unknown pods (pass $i)"
      break
    fi
    log "Pass $i clean, waiting 10s to confirm..."
    sleep 10
  fi
done

if [ "$CLEAN_PASSES" -lt 2 ]; then
  log "WARNING: Reached max loops with Unknown pods still appearing"
  # One final cleanup attempt
  delete_unknown_pods || true
fi

# ── Restart crashlooping deployments if we did any cleanup ──
if [ "$DID_ANY_CLEANUP" = true ]; then
  sleep 5
  delete_terminating_pods
  sleep 10
  restart_crashlooping
fi

# ── Final Terminating pod cleanup ──
sleep 5
delete_terminating_pods

log "Reboot cleanup finished (total ${SECONDS}s since start)"
SCRIPT

  chmod +x /usr/local/bin/k3s-reboot-cleanup.sh

  cat > /etc/systemd/system/k3s-reboot-cleanup.service <<EOF
[Unit]
Description=Clean up stale pods after K3s reboot
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k3s-reboot-cleanup.sh
TimeoutStartSec=600
Environment="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable k3s-reboot-cleanup.service
  echo "  k3s-reboot-cleanup.service installed and enabled"
  echo ""
fi

# ──────────────────────────────────────────────
# 3. UFW Firewall (all nodes)
# ──────────────────────────────────────────────
echo "=== Configuring UFW firewall ==="

CLUSTER_CIDR="10.42.0.0/16"      # K3s pod network
SERVICE_CIDR="10.43.0.0/16"      # K3s service network
LAN_CIDR="192.168.1.0/24"        # Local LAN

# Check if UFW is available
if command -v ufw &>/dev/null; then
  echo "  Setting defaults..."
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default allow routed >/dev/null

  echo "  Allowing SSH, K3s, and services from LAN..."
  ufw allow from $LAN_CIDR to any port 22 proto tcp comment 'SSH' >/dev/null
  ufw allow from $LAN_CIDR to any port 6443 proto tcp comment 'K3s API' >/dev/null
  ufw allow from $LAN_CIDR to any port 8472 proto udp comment 'Flannel VXLAN' >/dev/null
  ufw allow from $LAN_CIDR to any port 10250 proto tcp comment 'Kubelet' >/dev/null
  ufw allow from $LAN_CIDR to any port 9100 proto tcp comment 'Node Exporter' >/dev/null
  ufw allow from $LAN_CIDR to any port 2379:2380 proto tcp comment 'etcd' >/dev/null
  ufw allow from $CLUSTER_CIDR comment 'K3s Pod Network' >/dev/null
  ufw allow from $SERVICE_CIDR comment 'K3s Service Network' >/dev/null
  ufw route allow from $CLUSTER_CIDR >/dev/null
  ufw route allow from $SERVICE_CIDR >/dev/null
  ufw route allow to $CLUSTER_CIDR >/dev/null
  ufw route allow to $SERVICE_CIDR >/dev/null

  echo "  Allowing NodePorts, HTTP/HTTPS, VNC, DNS..."
  ufw allow from $LAN_CIDR to any port 30000:32767 proto tcp comment 'K3s NodePorts' >/dev/null
  ufw allow from $LAN_CIDR to any port 80 proto tcp comment 'HTTP' >/dev/null
  ufw allow from $LAN_CIDR to any port 443 proto tcp comment 'HTTPS' >/dev/null
  ufw allow from $LAN_CIDR to any port 5901 proto tcp comment 'VNC' >/dev/null
  ufw allow from $LAN_CIDR to any port 53 proto tcp comment 'DNS TCP' >/dev/null
  ufw allow from $LAN_CIDR to any port 53 proto udp comment 'DNS UDP' >/dev/null
  ufw allow proto icmp comment 'ICMP ping' >/dev/null

  ufw --force enable >/dev/null
  echo "  UFW enabled with K3s-compatible rules"
else
  echo "  UFW not installed, skipping firewall setup"
fi
echo ""

echo "=== Node setup complete ==="
echo ""
echo "Services installed:"
echo "  - flannel-subnet-fix.service (ensures /run/flannel/subnet.env on boot)"
[ "$IS_SERVER" = true ] && echo "  - k3s-reboot-cleanup.service (cleans Unknown pods after reboot)"
echo "  - UFW firewall (K3s-compatible rules)"
echo ""
echo "Run order for each node:"
echo "  pi-node-01: sudo bash '02 - node-setup.sh' 10.42.0.1/24 --server"
echo "  pi-node-02: sudo bash '02 - node-setup.sh' 10.42.1.1/24"
echo "  pi-node-03: sudo bash '02 - node-setup.sh' 10.42.2.1/24"
echo "  pi-node-04: sudo bash '02 - node-setup.sh' 10.42.3.1/24"
