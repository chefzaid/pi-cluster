#!/bin/bash
# Flannel Subnet Fix - Installation Script
# Fixes missing /run/flannel/subnet.env on K3s boot (common on Raspberry Pi)
#
# Problem: K3s with Flannel VXLAN sometimes fails to create /run/flannel/subnet.env
#          on boot, causing pods to stay in ContainerCreating state.
#
# Solution: A systemd service that creates the file before K3s starts.
#
# Usage: Run this script on each node that experiences the issue.
#   sudo bash "$0"              # default: 10.42.0.1/24
#   sudo bash "$0" 10.42.1.1/24 # example

set -e

# Detect the node's flannel subnet (or use default for control plane)
FLANNEL_SUBNET="${1:-10.42.0.1/24}"

echo "=== Installing Flannel Subnet Fix ==="
echo "Subnet: ${FLANNEL_SUBNET}"
echo ""

# Create the systemd service
cat > /etc/systemd/system/flannel-subnet-fix.service << EOF
[Unit]
Description=Create flannel subnet.env before K3s starts
Before=k3s.service k3s-agent.service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'mkdir -p /run/flannel && echo -e "FLANNEL_NETWORK=10.42.0.0/16\\nFLANNEL_SUBNET=${FLANNEL_SUBNET}\\nFLANNEL_MTU=1450\\nFLANNEL_IPMASQ=true" > /run/flannel/subnet.env'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable flannel-subnet-fix.service
systemctl start flannel-subnet-fix.service

# Verify
echo ""
if [ -f /run/flannel/subnet.env ]; then
  echo "SUCCESS - /run/flannel/subnet.env created:"
  cat /run/flannel/subnet.env
else
  echo "ERROR - File was not created"
  exit 1
fi

echo ""
echo "=== Flannel fix installed and enabled ==="
echo "The fix will run automatically on every boot before K3s starts."
echo ""
echo "Per-node subnet values (adjust if needed):"
echo "  pi-node-01 (control plane): 10.42.0.1/24"
echo "  pi-node-02:                 10.42.1.1/24"
echo "  pi-node-03:                 10.42.2.1/24"
echo "  pi-node-04:                 10.42.3.1/24"
echo ""
echo "To install on another node with a different subnet:"
echo "  sudo bash \"$0\" 10.42.X.1/24"
