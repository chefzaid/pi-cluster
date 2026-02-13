#!/bin/bash
# Secure Pi Cluster Firewall Configuration
# Enables UFW with rules that allow K3s to function properly
# Run on each node: sudo bash '15 - secure-firewall.sh'

set -e

echo "=== Pi Cluster Firewall Security Setup ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Define cluster network
CLUSTER_CIDR="10.42.0.0/16"      # K3s pod network
SERVICE_CIDR="10.43.0.0/16"      # K3s service network
LAN_CIDR="192.168.1.0/24"        # Local LAN

echo "[1/6] Setting UFW defaults..."
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed   # Required for K3s pod-to-pod communication

echo "[2/6] Allowing SSH from LAN..."
ufw allow from $LAN_CIDR to any port 22 proto tcp comment 'SSH'

echo "[3/6] Allowing K3s cluster communication..."
# K3s API server
ufw allow from $LAN_CIDR to any port 6443 proto tcp comment 'K3s API'

# Flannel VXLAN (node-to-node)
ufw allow from $LAN_CIDR to any port 8472 proto udp comment 'Flannel VXLAN'

# Kubelet metrics
ufw allow from $LAN_CIDR to any port 10250 proto tcp comment 'Kubelet'

# etcd (embedded in K3s)
ufw allow from $LAN_CIDR to any port 2379:2380 proto tcp comment 'etcd'

# K3s internal pod/service network
ufw allow from $CLUSTER_CIDR comment 'K3s Pod Network'
ufw allow from $SERVICE_CIDR comment 'K3s Service Network'

# K3s routing for pod-to-pod and service communication
ufw route allow from $CLUSTER_CIDR
ufw route allow from $SERVICE_CIDR
ufw route allow to $CLUSTER_CIDR
ufw route allow to $SERVICE_CIDR

echo "[4/6] Allowing exposed services..."
# NodePort range for ingress/services
ufw allow from $LAN_CIDR to any port 30000:32767 proto tcp comment 'K3s NodePorts'

# HTTP/HTTPS for ingress
ufw allow from $LAN_CIDR to any port 80 proto tcp comment 'HTTP'
ufw allow from $LAN_CIDR to any port 443 proto tcp comment 'HTTPS'

# VNC (only on control plane node)
ufw allow from $LAN_CIDR to any port 5901 proto tcp comment 'VNC'

# AdGuard DNS
ufw allow from $LAN_CIDR to any port 53 proto tcp comment 'DNS TCP'
ufw allow from $LAN_CIDR to any port 53 proto udp comment 'DNS UDP'

echo "[5/6] Allowing ICMP (ping) for diagnostics..."
ufw allow proto icmp comment 'ICMP ping'

echo "[6/6] Enabling UFW..."
ufw --force enable

echo ""
echo "=== Firewall configured ==="
ufw status verbose
echo ""
echo "NOTE: If K3s networking breaks, run: sudo ufw disable"
