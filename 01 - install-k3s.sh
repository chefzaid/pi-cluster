#!/bin/bash
# K3s Cluster Installation Script
# Installs K3s on a Raspberry Pi 4 as control plane (server) node
# Outputs the join token for worker nodes
#
# Usage:
#   Control plane:  sudo bash install-k3s.sh
#   Worker node:    sudo bash install-k3s.sh worker <SERVER_IP> <TOKEN>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_ROLE="${1:-server}"
SERVER_IP="${2:-}"
TOKEN="${3:-}"

# ──────────────────────────────────────────────
# Worker node join
# ──────────────────────────────────────────────
if [ "$NODE_ROLE" = "worker" ]; then
  if [ -z "$SERVER_IP" ] || [ -z "$TOKEN" ]; then
    echo "Usage: sudo bash install-k3s.sh worker <SERVER_IP> <TOKEN>"
    echo "  SERVER_IP: IP of the control plane node (e.g. 192.168.1.191)"
    echo "  TOKEN:     Join token from the control plane install"
    exit 1
  fi

  echo "=== K3s Worker Node Installation ==="
  echo "Joining cluster at: ${SERVER_IP}"
  echo ""

  # Install K3s agent
  curl -sfL https://get.k3s.io | K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN="${TOKEN}" sh -

  echo ""
  echo "=== Worker node joined the cluster ==="
  echo "Verify from control plane: kubectl get nodes"
  exit 0
fi

# ──────────────────────────────────────────────
# Control plane (server) installation
# ──────────────────────────────────────────────
echo "=== K3s Control Plane Installation ==="
echo "Node: $(hostname)"
echo ""

# Step 1: Copy K3s config if available
CONFIG_FILE="${SCRIPT_DIR}/02 - k3s-config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="${SCRIPT_DIR}/k3s-config.yaml"
fi

if [ -f "$CONFIG_FILE" ]; then
  echo "[1/4] Applying K3s config (Pi4 optimized)..."
  mkdir -p /etc/rancher/k3s
  cp "$CONFIG_FILE" /etc/rancher/k3s/config.yaml
  echo "  Copied $(basename "$CONFIG_FILE") -> /etc/rancher/k3s/config.yaml"
else
  echo "[1/4] No k3s-config.yaml found, using defaults..."
  mkdir -p /etc/rancher/k3s
fi

# Step 2: Install K3s server
echo ""
echo "[2/4] Installing K3s..."
curl -sfL https://get.k3s.io | sh -

# Step 3: Wait for K3s to be ready
echo ""
echo "[3/4] Waiting for K3s to be ready..."
sleep 5
until kubectl get nodes &>/dev/null; do
  echo "  Waiting for API server..."
  sleep 3
done
kubectl wait --for=condition=Ready node/$(hostname) --timeout=120s 2>/dev/null || true
echo "  Node $(hostname) is ready"

# Step 4: Extract join token
echo ""
echo "[4/4] Extracting join token..."
TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
SERVER_IP=$(hostname -I | awk '{print $1}')

# Setup kubeconfig for current user
SUDO_USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
mkdir -p "${SUDO_USER_HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${SUDO_USER_HOME}/.kube/config"
if [ -n "$SUDO_USER" ]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${SUDO_USER_HOME}/.kube"
fi
echo "  Kubeconfig copied to ${SUDO_USER_HOME}/.kube/config"

echo ""
echo "============================================"
echo "  K3s Control Plane Ready"
echo "============================================"
echo ""
echo "Server IP: ${SERVER_IP}"
echo "API:       https://${SERVER_IP}:6443"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  JOIN TOKEN (use this on worker nodes):                 │"
echo "├─────────────────────────────────────────────────────────┤"
echo "│                                                         │"
echo "  ${TOKEN}"
echo "│                                                         │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "To join worker nodes, run on each Pi:"
echo ""
echo "  sudo bash install-k3s.sh worker ${SERVER_IP} ${TOKEN}"
echo ""
echo "Or manually:"
echo ""
echo "  curl -sfL https://get.k3s.io | K3S_URL=https://${SERVER_IP}:6443 K3S_TOKEN=${TOKEN} sh -"
echo ""
echo "Verify: kubectl get nodes"
