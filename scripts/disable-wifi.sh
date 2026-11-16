#!/bin/bash
# Disable WiFi on a node that is wired over Ethernet
# ==================================================
# The Ubuntu Pi image joins WiFi from the cloud-init network-config, so every
# node ends up with a second IP on wlan0 (a backup default route, metric 600).
# K3s and flannel only use eth0. This removes wlan0 from netplan, takes it down
# now, and switches the radio off at boot (dtoverlay=disable-wifi).
#
# Refuses to run unless eth0 has an IPv4 address and a default route.
# Usage: sudo bash disable-wifi.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

ETH_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -1)
if [ -z "$ETH_IP" ] || ! ip -4 route show default dev eth0 | grep -q .; then
  echo "ERROR: eth0 has no IPv4 address or default route; keeping WiFi"
  exit 1
fi
echo "=== Disabling WiFi on $(hostname) (eth0 ${ETH_IP}) ==="

# 1. netplan: drop the wifis section (backup outside /etc/netplan, it holds the PSK)
for f in /etc/netplan/*.yaml; do
  grep -q '^  wifis:' "$f" || continue
  install -m 600 "$f" "/root/$(basename "$f").bak-pi-cluster"
  awk '/^  wifis:/ {skip=1; next} skip && /^  [^ ]/ {skip=0} !skip' "/root/$(basename "$f").bak-pi-cluster" > "$f"
  chmod 600 "$f"
  echo "  removed wifis from $f (backup in /root)"
done
# cloud-init must not write the WiFi config back
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF

# 2. Take wlan0 down without touching eth0 (no networkd restart)
netplan generate
for unit in $(systemctl list-units --plain --no-legend 'netplan-wpa-*' | awk '{print $1}'); do
  systemctl stop "$unit"
done
networkctl reload
if ip link show wlan0 >/dev/null 2>&1; then
  ip addr flush dev wlan0
  ip link set wlan0 down
fi
command -v rfkill >/dev/null 2>&1 && rfkill block wifi || true

# 3. Radio off from the next boot
CONFIG_TXT=/boot/firmware/config.txt
if [ -f "$CONFIG_TXT" ] && ! grep -q '^dtoverlay=disable-wifi' "$CONFIG_TXT"; then
  [ -f "${CONFIG_TXT}.bak-pi-cluster" ] || cp -p "$CONFIG_TXT" "${CONFIG_TXT}.bak-pi-cluster"
  printf '\n[all]\n# Wired node: WiFi radio off (scripts/disable-wifi.sh)\ndtoverlay=disable-wifi\n' >> "$CONFIG_TXT"
  echo "  added dtoverlay=disable-wifi to $CONFIG_TXT"
fi

ip -br addr show | grep -E '^(eth0|wlan0)' | sed 's/^/  /'
ip route show default | sed 's/^/  /'
echo "=== WiFi disabled ==="
