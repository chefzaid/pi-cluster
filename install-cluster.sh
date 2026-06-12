#!/bin/bash
# ============================================================================
# K3s Raspberry Pi 4 Cluster - Full Automated Installation
# ============================================================================
# This script performs a complete cluster installation with automatic worker
# node setup via SSH. It handles all configuration, K3s installation, node
# setup, and application deployment.
#
# Usage:
#   sudo bash install-cluster.sh
#
# Prerequisites:
#   - Fresh Ubuntu 24.04 LTS on Raspberry Pi 4 (4GB+ RAM)
#   - Internet connectivity
#   - Run this on the CONTROL PLANE node (pi-node-01)
#   - SSH access to worker nodes (if configuring workers)
# ============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
DEPLOYMENTS_DIR="$REPO_ROOT/deployments"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_step() {
  echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
  echo -e "${RED}[✗]${NC} $1"
}

wait_for_pods() {
  local namespace="$1"
  local timeout="${2:-300}"
  local label="${3:-}"
  
  echo "  Waiting for pods in $namespace to be ready (timeout: ${timeout}s)..."
  
  if [ -n "$label" ]; then
    kubectl -n "$namespace" wait --for=condition=ready pod -l "$label" --timeout="${timeout}s" 2>/dev/null || true
  else
    # Wait for all pods to be Running or Completed
    local end_time=$((SECONDS + timeout))
    while [ $SECONDS -lt $end_time ]; do
      local pending=$(kubectl -n "$namespace" get pods --no-headers 2>/dev/null | grep -v -E "Running|Completed|Succeeded" | wc -l)
      if [ "$pending" -eq 0 ]; then
        return 0
      fi
      sleep 5
    done
  fi
}

prompt_input() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local is_secret="${4:-false}"
  
  if [ "$is_secret" = "true" ]; then
    read -sp "$prompt: " value
    echo ""
  else
    if [ -n "$default" ]; then
      read -p "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -p "$prompt: " value
    fi
  fi
  
  eval "$var_name='$value'"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  
  if [ "$default" = "y" ]; then
    read -p "$prompt [Y/n]: " response
    response="${response:-y}"
  else
    read -p "$prompt [y/N]: " response
    response="${response:-n}"
  fi
  
  [[ "$response" =~ ^[Yy] ]]
}

run_on_worker() {
  local worker_ip="$1"
  local ssh_user="$2"
  local ssh_pass="$3"
  local control_ip="$4"
  local k3s_token="$5"
  local worker_subnet="$6"
  
  echo "  Connecting to worker $worker_ip..."
  
  # Use sshpass for password-based SSH
  if ! command -v sshpass &> /dev/null; then
    apt-get install -y sshpass
  fi
  
  # Copy scripts to worker
  sshpass -p "$ssh_pass" scp -o StrictHostKeyChecking=no \
    "${SCRIPTS_DIR}/install-k3s.sh" \
    "${SCRIPTS_DIR}/node-setup.sh" \
    "${ssh_user}@${worker_ip}:/tmp/"
  
  # Run install-k3s.sh in worker mode
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no "${ssh_user}@${worker_ip}" \
    "echo '$ssh_pass' | sudo -S bash /tmp/install-k3s.sh worker $control_ip $k3s_token"
  
  # Run node-setup.sh on worker
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no "${ssh_user}@${worker_ip}" \
    "echo '$ssh_pass' | sudo -S bash /tmp/node-setup.sh $worker_subnet"
  
  print_step "Worker $worker_ip configured"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

print_header "Pre-flight Checks"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  print_error "This script must be run as root (use sudo)"
  exit 1
fi
print_step "Running as root"

# Check if control plane
if ! [[ "$(hostname)" =~ node-01|master|control ]]; then
  print_warning "This doesn't look like the control plane node (hostname: $(hostname))"
  if ! prompt_yes_no "Continue anyway?"; then
    exit 1
  fi
fi
print_step "Running on: $(hostname)"

# Check internet connectivity
if ! ping -c 1 google.com &>/dev/null; then
  print_error "No internet connectivity"
  exit 1
fi
print_step "Internet connectivity OK"

# Check required script files exist
REQUIRED_SCRIPTS=(
  "install-k3s.sh"
  "node-setup.sh"
  "install-vnc-desktop.sh"
  "install-tailscale.sh"
  "openebs-install.sh"
)

for file in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -f "${SCRIPTS_DIR}/${file}" ]; then
    print_error "Missing required script: scripts/$file"
    exit 1
  fi
done

# Check required deployment files exist
REQUIRED_DEPLOYMENTS=(
  "k3s-config.yaml"
  "openebs-localpv.yaml"
  "grafana-prometheus.yaml"
  "cloudflare.yaml"
  "guacamole.yaml"
  "openwebui.yaml"
  "openclaw.yaml"
  "aiostreams.yaml"
  "adguard.yaml"
  "portainer.yaml"
  "dashboard.yaml"
)

for file in "${REQUIRED_DEPLOYMENTS[@]}"; do
  if [ ! -f "${DEPLOYMENTS_DIR}/${file}" ]; then
    print_error "Missing required deployment: deployments/$file"
    exit 1
  fi
done
print_step "All required files present"

# ============================================================================
# Gather Configuration
# ============================================================================

print_header "Configuration"

echo "Please provide the following configuration values."
echo "Press Enter to accept defaults where shown."
echo ""

# Worker nodes
echo -e "${CYAN}Worker Nodes (optional - automates setup via SSH)${NC}"
prompt_input WORKER_IPS "Worker node IPs (comma-separated, e.g. 192.168.1.192,193,194)" ""
if [ -n "$WORKER_IPS" ]; then
  prompt_input SSH_USER "SSH username for worker nodes" "zaid"
  prompt_input SSH_PASSWORD "SSH/sudo password for worker nodes" "" true
  prompt_input WORKER_SUBNET_BASE "Worker subnet base (e.g. 10.42.X.1/24)" "10.42"
fi
echo ""

# VNC
echo -e "${CYAN}VNC Desktop${NC}"
prompt_input INSTALL_VNC "Install VNC desktop on control plane? (y/n)" "n"
if [[ "$INSTALL_VNC" =~ ^[Yy] ]]; then
  prompt_input VNC_PASSWORD "VNC password" "raspberry" true
fi
echo ""

# Cloudflare
echo -e "${CYAN}Cloudflare Tunnel${NC}"
prompt_input INSTALL_CLOUDFLARE "Install Cloudflare tunnel? (y/n)" "y"
if [[ "$INSTALL_CLOUDFLARE" =~ ^[Yy] ]]; then
  echo "Get your tunnel token from: https://one.dash.cloudflare.com/ → Networks → Tunnels"
  while true; do
    prompt_input CLOUDFLARE_TOKEN "Cloudflare tunnel token (eyJ...)" "" true
    if [ -n "$CLOUDFLARE_TOKEN" ]; then
      break
    fi
    print_warning "Cloudflare token cannot be empty when Cloudflare install is enabled"
  done
fi
echo ""

# Tailscale (Pi as subnet router for dedicated server access)
echo -e "${CYAN}Tailscale Subnet Router${NC}"
prompt_input INSTALL_TAILSCALE "Install Tailscale subnet router on this Pi? (y/n)" "y"
if [[ "$INSTALL_TAILSCALE" =~ ^[Yy] ]]; then
  prompt_input TAILSCALE_ROUTES "Home LAN routes to advertise" "192.168.1.0/24"
  prompt_input TAILSCALE_HOSTNAME "Tailscale hostname" "$(hostname)-pi-gateway"
  echo "Create an auth key from: https://login.tailscale.com/admin/settings/keys"
  while true; do
    prompt_input TAILSCALE_AUTHKEY "Tailscale auth key (tskey-auth-...)" "" true
    if [ -n "$TAILSCALE_AUTHKEY" ]; then
      break
    fi
    print_warning "Tailscale auth key cannot be empty when Tailscale install is enabled"
  done
fi
echo ""

# Guacamole
echo -e "${CYAN}Guacamole Remote Desktop${NC}"
prompt_input INSTALL_GUACAMOLE "Install Guacamole? (y/n)" "n"
echo ""

# Open WebUI
echo -e "${CYAN}Open WebUI (AI Chat Frontend)${NC}"
prompt_input INSTALL_OPENWEBUI "Install Open WebUI? (y/n)" "n"
if [[ "$INSTALL_OPENWEBUI" =~ ^[Yy] ]]; then
  if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "Get an OpenRouter API key from: https://openrouter.ai/keys"
    prompt_input OPENROUTER_API_KEY "OpenRouter API key (sk-or-v1-...)" "" true
  fi
fi
echo ""

# OpenClaw
echo -e "${CYAN}OpenClaw AI Assistant Gateway${NC}"
prompt_input INSTALL_OPENCLAW "Install OpenClaw? (y/n)" "n"
if [[ "$INSTALL_OPENCLAW" =~ ^[Yy] ]]; then
  if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "Get an OpenRouter API key from: https://openrouter.ai/keys"
    prompt_input OPENROUTER_API_KEY "OpenRouter API key (sk-or-v1-...)" "" true
  fi
fi
echo ""

# AIOStreams
echo -e "${CYAN}AIOStreams (Stremio Addon Aggregator)${NC}"
prompt_input INSTALL_AIOSTREAMS "Install AIOStreams? (y/n)" "n"
if [[ "$INSTALL_AIOSTREAMS" =~ ^[Yy] ]]; then
  echo "Use your public HTTPS URL here if you plan to expose AIOStreams through Cloudflare."
  prompt_input AIOSTREAMS_BASE_URL "AIOStreams base URL" "https://aiostreams.swirlit.dev"
fi
echo ""

# AdGuard Home
echo -e "${CYAN}AdGuard Home (DNS Ad Blocker)${NC}"
prompt_input INSTALL_ADGUARD "Install AdGuard Home? (y/n)" "y"
echo ""

# Grafana + Prometheus
echo -e "${CYAN}Grafana + Prometheus (Monitoring)${NC}"
prompt_input INSTALL_MONITORING "Install Grafana + Prometheus? (y/n)" "y"
echo ""

# Portainer
echo -e "${CYAN}Portainer${NC}"
prompt_input INSTALL_PORTAINER "Install Portainer? (y/n)" "y"
echo ""

# Dashboard
echo -e "${CYAN}Homepage Dashboard${NC}"
prompt_input INSTALL_DASHBOARD "Install Homepage dashboard? (y/n)" "y"
echo ""

# Confirmation
print_header "Installation Summary"
echo "The following will be installed:"
echo "  - K3s (control plane)"
echo "  - Node setup (flannel fix, firewall, cleanup service)"
echo "  - OpenEBS LocalPV (local storage)"
[[ "$INSTALL_VNC" =~ ^[Yy] ]] && echo "  - VNC desktop"
[[ "$INSTALL_CLOUDFLARE" =~ ^[Yy] ]] && echo "  - Cloudflare tunnel"
[[ "$INSTALL_TAILSCALE" =~ ^[Yy] ]] && echo "  - Tailscale subnet router (${TAILSCALE_ROUTES})"
[[ "$INSTALL_GUACAMOLE" =~ ^[Yy] ]] && echo "  - Guacamole (remote desktop gateway)"
[[ "$INSTALL_OPENWEBUI" =~ ^[Yy] ]] && echo "  - Open WebUI (AI chat)"
[[ "$INSTALL_OPENCLAW" =~ ^[Yy] ]] && echo "  - OpenClaw (AI assistant gateway)"
[[ "$INSTALL_AIOSTREAMS" =~ ^[Yy] ]] && echo "  - AIOStreams (Stremio addon aggregator)"
[[ "$INSTALL_ADGUARD" =~ ^[Yy] ]] && echo "  - AdGuard Home (DNS ad blocker)"
[[ "$INSTALL_MONITORING" =~ ^[Yy] ]] && echo "  - Prometheus + Grafana (monitoring)"
[[ "$INSTALL_PORTAINER" =~ ^[Yy] ]] && echo "  - Portainer (container management)"
[[ "$INSTALL_DASHBOARD" =~ ^[Yy] ]] && echo "  - Homepage dashboard"

if [ -n "$WORKER_IPS" ]; then
  echo ""
  echo "  Worker nodes to configure: $WORKER_IPS"
fi
echo ""

if ! prompt_yes_no "Proceed with installation?"; then
  echo "Installation cancelled."
  exit 0
fi

# ============================================================================
# Phase 1: Core Infrastructure
# ============================================================================

print_header "Phase 1: Core Infrastructure"

# Step 1a: Apply K3s config BEFORE installation
echo -e "${CYAN}[1a/15] Applying K3s configuration...${NC}"
mkdir -p /etc/rancher/k3s
cp "${DEPLOYMENTS_DIR}/k3s-config.yaml" /etc/rancher/k3s/config.yaml
print_step "K3s config applied"

# Step 1b: Install K3s
echo -e "${CYAN}[1b/15] Installing K3s...${NC}"
bash "${SCRIPTS_DIR}/install-k3s.sh"
print_step "K3s installed"

# Step 1c: Node setup on control plane
echo -e "${CYAN}[1c/15] Running node setup on control plane...${NC}"
bash "${SCRIPTS_DIR}/node-setup.sh" "10.42.0.1/24" --server
print_step "Node setup applied on control plane"

# Save join token for workers
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
CONTROL_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${YELLOW}Join token saved for workers${NC}"
echo ""

# Step 2: VNC Desktop (if enabled)
if [[ "$INSTALL_VNC" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[2/15] Installing VNC desktop...${NC}"
  bash "${SCRIPTS_DIR}/install-vnc-desktop.sh" "$VNC_PASSWORD"
  print_step "VNC desktop installed"
else
  echo -e "${CYAN}[2/15] Skipping VNC desktop${NC}"
fi

# Step 3: OpenEBS LocalPV
echo -e "${CYAN}[3/15] Installing OpenEBS LocalPV...${NC}"
bash "${SCRIPTS_DIR}/openebs-install.sh"
print_step "OpenEBS LocalPV installed"

# Wait for OpenEBS to be fully ready
echo "  Waiting for OpenEBS to be fully operational..."
wait_for_pods "openebs" 180
print_step "OpenEBS ready"

# ============================================================================
# Phase 2: Worker Nodes (if specified)
# ============================================================================

if [ -n "$WORKER_IPS" ]; then
  print_header "Phase 2: Worker Nodes"
  
  # Parse worker IPs
  IFS=',' read -ra WORKERS <<< "$WORKER_IPS"
  WORKER_NUM=1
  
  for worker in "${WORKERS[@]}"; do
    # Handle shorthand IPs (e.g., 192 means 192.168.1.192)
    if [[ "$worker" =~ ^[0-9]{1,3}$ ]]; then
      # Extract base from control IP
      IP_BASE=$(echo "$CONTROL_IP" | cut -d. -f1-3)
      worker="${IP_BASE}.${worker}"
    fi
    
    WORKER_NUM=$((WORKER_NUM + 1))
    WORKER_SUBNET="${WORKER_SUBNET_BASE}.${WORKER_NUM}.1/24"
    
    echo -e "${CYAN}Setting up worker: $worker (subnet: $WORKER_SUBNET)${NC}"
    run_on_worker "$worker" "$SSH_USER" "$SSH_PASSWORD" "$CONTROL_IP" "$K3S_TOKEN" "$WORKER_SUBNET"
  done
  
  print_step "All worker nodes configured"
  
  # Wait for workers to join
  echo "  Waiting for workers to join the cluster..."
  sleep 30
  kubectl get nodes
fi

# ============================================================================
# Phase 3: Monitoring
# ============================================================================

print_header "Phase 3: Monitoring"

# Step 4: Prometheus + Grafana
if [[ "$INSTALL_MONITORING" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[4/15] Installing Prometheus + Grafana...${NC}"
  kubectl apply -f "${DEPLOYMENTS_DIR}/grafana-prometheus.yaml"
  wait_for_pods "monitoring" 300
  print_step "Prometheus + Grafana installed"
else
  echo -e "${CYAN}[4/15] Skipping Prometheus + Grafana${NC}"
fi

# ============================================================================
# Phase 4: Networking & Tunnels
# ============================================================================

print_header "Phase 4: Networking & Tunnels"

# Step 5: Cloudflare Tunnel
if [[ "$INSTALL_CLOUDFLARE" =~ ^[Yy] ]] && [ -n "$CLOUDFLARE_TOKEN" ]; then
  echo -e "${CYAN}[5/15] Installing Cloudflare tunnel...${NC}"
  
  # Create namespace and secret
  kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cloudflared-config \
    --namespace cloudflared \
    --from-literal=TUNNEL_TOKEN="$CLOUDFLARE_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  kubectl apply -f "${DEPLOYMENTS_DIR}/cloudflare.yaml"
  wait_for_pods "cloudflared" 120
  print_step "Cloudflare tunnel installed"
else
  echo -e "${CYAN}[5/15] Skipping Cloudflare tunnel${NC}"
fi

# Step 6: Tailscale subnet router (host-level)
if [[ "$INSTALL_TAILSCALE" =~ ^[Yy] ]] && [ -n "$TAILSCALE_AUTHKEY" ]; then
  echo -e "${CYAN}[6/15] Installing Tailscale subnet router...${NC}"
  TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" \
  TAILSCALE_ROUTES="$TAILSCALE_ROUTES" \
  TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" \
    bash "${SCRIPTS_DIR}/install-tailscale.sh"
  print_step "Tailscale subnet router installed"
else
  echo -e "${CYAN}[6/15] Skipping Tailscale subnet router${NC}"
fi

# ============================================================================
# Phase 5: Applications
# ============================================================================

print_header "Phase 5: Applications"

# Step 6: Guacamole
if [[ "$INSTALL_GUACAMOLE" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[7/15] Installing Guacamole...${NC}"
  kubectl apply -f "${DEPLOYMENTS_DIR}/guacamole.yaml"
  wait_for_pods "guacamole" 180
  print_step "Guacamole installed"
else
  echo -e "${CYAN}[7/15] Skipping Guacamole${NC}"
fi

# Step 7: Open WebUI
if [[ "$INSTALL_OPENWEBUI" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[8/15] Installing Open WebUI...${NC}"
  
  # Create namespace and secret if API key provided
  kubectl create namespace ai --dry-run=client -o yaml | kubectl apply -f -
  if [ -n "$OPENROUTER_API_KEY" ]; then
    kubectl create secret generic ai-keys \
      --namespace ai \
      --from-literal=OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
  
  kubectl apply -f "${DEPLOYMENTS_DIR}/openwebui.yaml"
  wait_for_pods "ai" 300
  print_step "Open WebUI installed"
else
  echo -e "${CYAN}[8/15] Skipping Open WebUI${NC}"
fi

# Step 8: OpenClaw
if [[ "$INSTALL_OPENCLAW" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[9/15] Installing OpenClaw...${NC}"

  # ai namespace already created by Open WebUI step (or create it here)
  kubectl create namespace ai --dry-run=client -o yaml | kubectl apply -f -

  GATEWAY_TOKEN=$(openssl rand -hex 32)
  
  kubectl create secret generic openclaw-env-secret \
    --namespace ai \
    --from-literal=OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    --from-literal=OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${DEPLOYMENTS_DIR}/openclaw.yaml"
  wait_for_pods "ai" 180
  print_step "OpenClaw installed"

  echo ""
  echo -e "${YELLOW}OpenClaw Gateway Token (save this):${NC}"
  echo "  $GATEWAY_TOKEN"
  echo ""
else
  echo -e "${CYAN}[9/15] Skipping OpenClaw${NC}"
fi

# Step 9: AIOStreams
if [[ "$INSTALL_AIOSTREAMS" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[10/15] Installing AIOStreams...${NC}"

  kubectl create namespace media --dry-run=client -o yaml | kubectl apply -f -
  AIOSTREAMS_SECRET_KEY=""
  if kubectl get secret aiostreams-env -n media &>/dev/null; then
    AIOSTREAMS_SECRET_KEY=$(kubectl get secret aiostreams-env -n media -o jsonpath='{.data.SECRET_KEY}' | base64 -d)
  fi
  if [ -z "$AIOSTREAMS_SECRET_KEY" ]; then
    AIOSTREAMS_SECRET_KEY=$(openssl rand -hex 32)
  fi

  kubectl create secret generic aiostreams-env \
    --namespace media \
    --from-literal=BASE_URL="$AIOSTREAMS_BASE_URL" \
    --from-literal=SECRET_KEY="$AIOSTREAMS_SECRET_KEY" \
    --from-literal=DATABASE_URI="sqlite://./data/db.sqlite" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${DEPLOYMENTS_DIR}/aiostreams.yaml"
  wait_for_pods "media" 180
  print_step "AIOStreams installed"

  echo ""
  echo -e "${YELLOW}AIOStreams SECRET_KEY is stored in secret aiostreams-env. Do not rotate it after first run.${NC}"
  echo ""
else
  echo -e "${CYAN}[10/15] Skipping AIOStreams${NC}"
fi

# Step 10: AdGuard Home
if [[ "$INSTALL_ADGUARD" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[11/15] Installing AdGuard Home...${NC}"
  kubectl apply -f "${DEPLOYMENTS_DIR}/adguard.yaml"
  wait_for_pods "adguard" 180
  print_step "AdGuard Home installed"
else
  echo -e "${CYAN}[11/15] Skipping AdGuard Home${NC}"
fi

# Step 11: Portainer
if [[ "$INSTALL_PORTAINER" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[12/15] Installing Portainer...${NC}"
  kubectl apply -f "${DEPLOYMENTS_DIR}/portainer.yaml"
  wait_for_pods "portainer" 180
  print_step "Portainer installed"
else
  echo -e "${CYAN}[12/15] Skipping Portainer${NC}"
fi

# Step 12: Dashboard
if [[ "$INSTALL_DASHBOARD" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[13/15] Installing Homepage dashboard...${NC}"
  kubectl apply -f "${DEPLOYMENTS_DIR}/dashboard.yaml"
  wait_for_pods "dashboard" 120
  print_step "Dashboard installed"
else
  echo -e "${CYAN}[13/15] Skipping Homepage dashboard${NC}"
fi

# ============================================================================
# Installation Complete
# ============================================================================

print_header "Installation Complete!"

echo "Cluster Status:"
kubectl get nodes
echo ""

echo "All Pods:"
kubectl get pods -A | head -30

echo ""
[[ "$INSTALL_DASHBOARD" =~ ^[Yy] ]] && echo "  Access your services:   http://pi-cluster.local"
echo ""

echo -e "${GREEN}Done!${NC}"
