#!/bin/bash
# K3s Installation Script (Minimal)
# ==================================
# Installs K3s on a Raspberry Pi 4 as control plane (server) or worker (agent).
# This script ONLY installs K3s - config and node setup are handled by
# 00_full_cluster_install.sh or can be applied manually.
#
# Usage:
#   Control plane:  sudo bash install-k3s.sh
#   Worker node:    sudo bash install-k3s.sh worker <SERVER_IP> <TOKEN>
#
# Note: For full automated cluster setup, use 00_full_cluster_install.sh instead.

set -e

NODE_ROLE="${1:-server}"
SERVER_IP="${2:-}"
TOKEN="${3:-}"

# Worker node join
if [ "$NODE_ROLE" = "worker" ]; then
  if [ -z "$SERVER_IP" ] || [ -z "$TOKEN" ]; then
    echo "Usage: sudo bash install-k3s.sh worker <SERVER_IP> <TOKEN>"
    exit 1
  fi

  echo "=== K3s Worker Node Installation ==="
  echo "Joining cluster at: ${SERVER_IP}"
  curl -sfL https://get.k3s.io | K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN="${TOKEN}" sh -
  echo ""
  echo "=== K3s agent installed ==="
  exit 0
fi

# Control plane (server) installation
echo "=== K3s Control Plane Installation ==="
echo "Node: $(hostname)"

echo "[1/2] Installing K3s..."
curl -sfL https://get.k3s.io | sh -

echo "[2/2] Waiting for K3s to be ready..."
sleep 5
until kubectl get nodes &>/dev/null; do
  echo "  Waiting for API server..."
  sleep 3
done
kubectl wait --for=condition=Ready node/$(hostname) --timeout=120s 2>/dev/null || true

# Setup kubeconfig for current user
SUDO_USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
mkdir -p "${SUDO_USER_HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${SUDO_USER_HOME}/.kube/config"
[ -n "$SUDO_USER" ] && chown -R "${SUDO_USER}:${SUDO_USER}" "${SUDO_USER_HOME}/.kube"

TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "=== K3s Control Plane Ready ==="
echo "Server: ${SERVER_IP}:6443"
echo ""
echo "Join token:"
echo "  ${TOKEN}"
echo ""
echo "Worker join command:"
echo "  sudo bash install-k3s.sh worker ${SERVER_IP} <TOKEN>"