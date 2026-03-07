#!/bin/bash
# Tailscale Subnet Router Setup (Pi control plane)
# ================================================
# Installs Tailscale on Ubuntu/Debian and configures this node as a subnet
# router so remote Tailnet nodes (e.g. OVH dedicated server) can reach home LAN.
#
# Required env vars:
#   TAILSCALE_AUTHKEY   Tailscale auth key (tskey-auth-...)
#
# Optional env vars:
#   TAILSCALE_ROUTES    Comma-separated routes to advertise (default: 192.168.1.0/24)
#   TAILSCALE_HOSTNAME  Hostname inside tailnet (default: <hostname>-pi-gateway)
#
# Usage:
#   sudo TAILSCALE_AUTHKEY="tskey-auth-..." \
#        TAILSCALE_ROUTES="192.168.1.0/24" \
#        TAILSCALE_HOSTNAME="pi-lan-gateway" \
#        bash install-tailscale.sh

set -e

TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_ROUTES="${TAILSCALE_ROUTES:-192.168.1.0/24}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)-pi-gateway}"

if [ -z "$TAILSCALE_AUTHKEY" ]; then
  echo "ERROR: TAILSCALE_AUTHKEY is required"
  echo "Example:"
  echo "  sudo TAILSCALE_AUTHKEY='tskey-auth-...' bash install-tailscale.sh"
  exit 1
fi

echo "=== Installing Tailscale ==="
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "  Tailscale already installed"
fi

echo "=== Enabling IPv4 forwarding ==="
cat > /etc/sysctl.d/99-tailscale-router.conf << 'EOF'
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-tailscale-router.conf >/dev/null

echo "=== Enabling and starting tailscaled ==="
systemctl enable tailscaled >/dev/null
systemctl restart tailscaled

echo "=== Bringing Tailscale up as subnet router ==="
tailscale up \
  --authkey "$TAILSCALE_AUTHKEY" \
  --hostname "$TAILSCALE_HOSTNAME" \
  --advertise-routes "$TAILSCALE_ROUTES" \
  --accept-dns=false \
  --reset

if command -v ufw >/dev/null 2>&1; then
  echo "=== Configuring UFW for tailscale0 ==="
  ufw allow in on tailscale0 comment 'Tailscale inbound' >/dev/null || true
  ufw route allow in on tailscale0 out on eth0 comment 'Tailscale routed traffic to LAN' >/dev/null || true
fi

echo ""
echo "=== Tailscale Subnet Router Ready ==="
echo "Advertised routes: $TAILSCALE_ROUTES"
echo "Tailnet hostname:   $TAILSCALE_HOSTNAME"
echo ""
echo "IMPORTANT: In Tailscale admin, approve the advertised route(s) if required:"
echo "  https://login.tailscale.com/admin/machines"
echo ""
tailscale status || true
echo ""
tailscale ip -4 || true
