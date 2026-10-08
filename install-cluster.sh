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
K3S_CONFIG="$REPO_ROOT/config/k3s/config.yaml"
K8S_DIR="$REPO_ROOT/k8s"

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
  local k3s_role="${7:-worker}"
  
  echo "  Connecting to worker $worker_ip..."
  
  # Use sshpass for password-based SSH
  if ! command -v sshpass &> /dev/null; then
    apt-get install -y sshpass
  fi
  
  # Copy scripts to worker
  sshpass -p "$ssh_pass" scp -o StrictHostKeyChecking=no \
    "${SCRIPTS_DIR}/install-k3s.sh" \
    "${SCRIPTS_DIR}/node-setup.sh" \
    "$K3S_CONFIG" \
    "${ssh_user}@${worker_ip}:/tmp/"
  
  # Control planes need the full server config (incl. etcd args) before install
  if [ "$k3s_role" = "server-join" ]; then
    sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no "${ssh_user}@${worker_ip}" \
      "echo '$ssh_pass' | sudo -S install -D -m 0644 /tmp/config.yaml /etc/rancher/k3s/config.yaml"
  fi

  # Run install-k3s.sh as worker or additional control plane
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no "${ssh_user}@${worker_ip}" \
    "echo '$ssh_pass' | sudo -S bash /tmp/install-k3s.sh $k3s_role $control_ip $k3s_token"
  
  # Run node-setup.sh on worker
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no "${ssh_user}@${worker_ip}" \
    "echo '$ssh_pass' | sudo -S bash /tmp/node-setup.sh $worker_subnet"
  
  print_step "Node $worker_ip configured ($k3s_role)"
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
  "beszel-bootstrap.sh"
  "transmute-bootstrap.sh"
  "sabnzbd-bootstrap.sh"
)

for file in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -f "${SCRIPTS_DIR}/${file}" ]; then
    print_error "Missing required script: scripts/$file"
    exit 1
  fi
done

# Check required configuration and Kubernetes manifests exist
if [ ! -f "$K3S_CONFIG" ]; then
  print_error "Missing required K3s configuration: config/k3s/config.yaml"
  exit 1
fi

REQUIRED_K8S_MANIFESTS=(
  "storage/openebs-localpv.yaml"
  "platform/beszel.yaml"
  "platform/cloudflare.yaml"
  "apps/guacamole.yaml"
  "apps/openclaw.yaml"
  "apps/aiostreams.yaml"
  "apps/musicgrabber.yaml"
  "apps/sabnzbd.yaml"
  "apps/stirling-pdf.yaml"
  "apps/changedetection.yaml"
  "apps/transmute.yaml"
  "apps/cyberchef.yaml"
  "platform/portainer.yaml"
  "platform/dashboard.yaml"
)

for file in "${REQUIRED_K8S_MANIFESTS[@]}"; do
  if [ ! -f "${K8S_DIR}/${file}" ]; then
    print_error "Missing required Kubernetes file: k8s/$file"
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
prompt_input WORKER_IPS "Other node IPs (comma-separated, e.g. 192.168.1.192,193,194; first 2 become control planes)" ""
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

# MusicGrabber
echo -e "${CYAN}MusicGrabber (Music Downloader)${NC}"
prompt_input INSTALL_MUSICGRABBER "Install MusicGrabber? (y/n)" "n"
echo ""

# SABnzbd
echo -e "${CYAN}SABnzbd (Usenet Downloader)${NC}"
prompt_input INSTALL_SABNZBD "Install SABnzbd? (y/n)" "n"
if [[ "$INSTALL_SABNZBD" =~ ^[Yy] ]]; then
  prompt_input SABNZBD_PASSWORD "SABnzbd web UI password (leave empty to generate)" "" true
fi
echo ""

# Stirling PDF
echo -e "${CYAN}Stirling PDF (PDF Toolbox)${NC}"
prompt_input INSTALL_STIRLING_PDF "Install Stirling PDF? (y/n)" "n"
echo ""

# changedetection.io
echo -e "${CYAN}changedetection.io (Website Change Detection)${NC}"
prompt_input INSTALL_CHANGEDETECTION "Install changedetection.io? (y/n)" "n"
echo ""

# Transmute
echo -e "${CYAN}Transmute (File Converter)${NC}"
prompt_input INSTALL_TRANSMUTE "Install Transmute? (y/n)" "n"
if [[ "$INSTALL_TRANSMUTE" =~ ^[Yy] ]]; then
  echo "Day-to-day use is one-click guest access; the admin account is only for settings."
  prompt_input TRANSMUTE_ADMIN_PASSWORD "Transmute admin password, min 8 chars (leave empty to generate)" "" true
fi
echo ""

# CyberChef
echo -e "${CYAN}CyberChef (Data Toolkit)${NC}"
prompt_input INSTALL_CYBERCHEF "Install CyberChef? (y/n)" "n"
echo ""

# Beszel
echo -e "${CYAN}Beszel (Node Monitoring)${NC}"
prompt_input INSTALL_BESZEL "Install Beszel? (y/n)" "y"
if [[ "$INSTALL_BESZEL" =~ ^[Yy] ]]; then
  while true; do
    prompt_input BESZEL_ADMIN_EMAIL "Beszel admin email" ""
    if [ -n "$BESZEL_ADMIN_EMAIL" ]; then
      break
    fi
    print_warning "Beszel admin email cannot be empty"
  done
  prompt_input BESZEL_ADMIN_PASSWORD "Beszel admin password (leave empty to generate)" "" true
fi
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
echo "  - K3s (control plane, embedded etcd; first 2 other nodes join as control planes)"
echo "  - Node setup (flannel fix, firewall, cleanup service)"
echo "  - OpenEBS LocalPV (local storage)"
[[ "$INSTALL_VNC" =~ ^[Yy] ]] && echo "  - VNC desktop"
[[ "$INSTALL_CLOUDFLARE" =~ ^[Yy] ]] && echo "  - Cloudflare tunnel"
[[ "$INSTALL_TAILSCALE" =~ ^[Yy] ]] && echo "  - Tailscale subnet router (${TAILSCALE_ROUTES})"
[[ "$INSTALL_GUACAMOLE" =~ ^[Yy] ]] && echo "  - Guacamole (remote desktop gateway)"
[[ "$INSTALL_OPENCLAW" =~ ^[Yy] ]] && echo "  - OpenClaw (AI assistant gateway)"
[[ "$INSTALL_AIOSTREAMS" =~ ^[Yy] ]] && echo "  - AIOStreams (Stremio addon aggregator)"
[[ "$INSTALL_MUSICGRABBER" =~ ^[Yy] ]] && echo "  - MusicGrabber (music downloader)"
[[ "$INSTALL_SABNZBD" =~ ^[Yy] ]] && echo "  - SABnzbd (Usenet downloader)"
[[ "$INSTALL_STIRLING_PDF" =~ ^[Yy] ]] && echo "  - Stirling PDF (PDF toolbox)"
[[ "$INSTALL_CHANGEDETECTION" =~ ^[Yy] ]] && echo "  - changedetection.io (website change monitoring)"
[[ "$INSTALL_TRANSMUTE" =~ ^[Yy] ]] && echo "  - Transmute (file converter)"
[[ "$INSTALL_CYBERCHEF" =~ ^[Yy] ]] && echo "  - CyberChef (encode/decode/crypto toolkit)"
[[ "$INSTALL_BESZEL" =~ ^[Yy] ]] && echo "  - Beszel (node monitoring)"
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
echo -e "${CYAN}[1a/17] Applying K3s configuration...${NC}"
mkdir -p /etc/rancher/k3s
cp "$K3S_CONFIG" /etc/rancher/k3s/config.yaml
print_step "K3s config applied"

# Step 1b: Install K3s
echo -e "${CYAN}[1b/17] Installing K3s...${NC}"
bash "${SCRIPTS_DIR}/install-k3s.sh"
print_step "K3s installed"

# Step 1c: Node setup on control plane
echo -e "${CYAN}[1c/17] Running node setup on control plane...${NC}"
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
  echo -e "${CYAN}[2/17] Installing VNC desktop...${NC}"
  bash "${SCRIPTS_DIR}/install-vnc-desktop.sh" "$VNC_PASSWORD"
  print_step "VNC desktop installed"
else
  echo -e "${CYAN}[2/17] Skipping VNC desktop${NC}"
fi

# Step 3: OpenEBS LocalPV
echo -e "${CYAN}[3/17] Installing OpenEBS LocalPV...${NC}"
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
    # First 2 extra nodes join as control planes (3 etcd members for quorum)
    if [ "$WORKER_NUM" -le 3 ]; then K3S_ROLE="server-join"; else K3S_ROLE="worker"; fi
    
    echo -e "${CYAN}Setting up $K3S_ROLE: $worker (subnet: $WORKER_SUBNET)${NC}"
    run_on_worker "$worker" "$SSH_USER" "$SSH_PASSWORD" "$CONTROL_IP" "$K3S_TOKEN" "$WORKER_SUBNET" "$K3S_ROLE"
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

# Step 4: Beszel (hub + per-node agents)
if [[ "$INSTALL_BESZEL" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[4/17] Installing Beszel...${NC}"
  BESZEL_ADMIN_EMAIL="$BESZEL_ADMIN_EMAIL" BESZEL_ADMIN_PASSWORD="$BESZEL_ADMIN_PASSWORD" \
    bash "${SCRIPTS_DIR}/beszel-bootstrap.sh"
  print_step "Beszel installed"
else
  echo -e "${CYAN}[4/17] Skipping Beszel${NC}"
fi

# ============================================================================
# Phase 4: Networking & Tunnels
# ============================================================================

print_header "Phase 4: Networking & Tunnels"

# Step 5: Cloudflare Tunnel
if [[ "$INSTALL_CLOUDFLARE" =~ ^[Yy] ]] && [ -n "$CLOUDFLARE_TOKEN" ]; then
  echo -e "${CYAN}[5/17] Installing Cloudflare tunnel...${NC}"
  
  # Create namespace and secret
  kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cloudflared-config \
    --namespace cloudflared \
    --from-literal=TUNNEL_TOKEN="$CLOUDFLARE_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  kubectl apply -f "${K8S_DIR}/platform/cloudflare.yaml"
  wait_for_pods "cloudflared" 120
  print_step "Cloudflare tunnel installed"
else
  echo -e "${CYAN}[5/17] Skipping Cloudflare tunnel${NC}"
fi

# Step 6: Tailscale subnet router (host-level)
if [[ "$INSTALL_TAILSCALE" =~ ^[Yy] ]] && [ -n "$TAILSCALE_AUTHKEY" ]; then
  echo -e "${CYAN}[6/17] Installing Tailscale subnet router...${NC}"
  TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" \
  TAILSCALE_ROUTES="$TAILSCALE_ROUTES" \
  TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" \
    bash "${SCRIPTS_DIR}/install-tailscale.sh"
  print_step "Tailscale subnet router installed"
else
  echo -e "${CYAN}[6/17] Skipping Tailscale subnet router${NC}"
fi

# ============================================================================
# Phase 5: Applications
# ============================================================================

print_header "Phase 5: Applications"

# Step 7: Guacamole
if [[ "$INSTALL_GUACAMOLE" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[7/17] Installing Guacamole...${NC}"
  kubectl apply -f "${K8S_DIR}/apps/guacamole.yaml"
  wait_for_pods "guacamole" 180
  print_step "Guacamole installed"
else
  echo -e "${CYAN}[7/17] Skipping Guacamole${NC}"
fi

# Step 8: OpenClaw
if [[ "$INSTALL_OPENCLAW" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[8/17] Installing OpenClaw...${NC}"

  # Create the shared AI namespace if needed
  kubectl create namespace ai --dry-run=client -o yaml | kubectl apply -f -

  GATEWAY_TOKEN=$(openssl rand -hex 32)
  
  kubectl create secret generic openclaw-env-secret \
    --namespace ai \
    --from-literal=OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    --from-literal=OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${K8S_DIR}/apps/openclaw.yaml"
  wait_for_pods "ai" 180
  print_step "OpenClaw installed"

  echo ""
  echo -e "${YELLOW}OpenClaw Gateway Token (save this):${NC}"
  echo "  $GATEWAY_TOKEN"
  echo ""
else
  echo -e "${CYAN}[8/17] Skipping OpenClaw${NC}"
fi

# Step 9: AIOStreams
if [[ "$INSTALL_AIOSTREAMS" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[9/17] Installing AIOStreams...${NC}"

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

  kubectl apply -f "${K8S_DIR}/apps/aiostreams.yaml"
  wait_for_pods "media" 180
  print_step "AIOStreams installed"

  echo ""
  echo -e "${YELLOW}AIOStreams SECRET_KEY is stored in secret aiostreams-env. Do not rotate it after first run.${NC}"
  echo ""
else
  echo -e "${CYAN}[9/17] Skipping AIOStreams${NC}"
fi

# Step 10: MusicGrabber
if [[ "$INSTALL_MUSICGRABBER" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[10/17] Installing MusicGrabber...${NC}"

  # slskd sidecar (Soulseek source). Keep existing credentials on re-runs: the
  # Soulseek account is registered to its password on first login.
  kubectl create namespace media --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl get secret slskd-env -n media &>/dev/null; then
    kubectl create secret generic slskd-env \
      --namespace media \
      --from-literal=SLSKD_SLSK_USERNAME="picluster_$(openssl rand -hex 3)" \
      --from-literal=SLSKD_SLSK_PASSWORD="$(openssl rand -hex 12)" \
      --from-literal=SLSKD_USERNAME=admin \
      --from-literal=SLSKD_PASSWORD="$(openssl rand -hex 16)" \
      --from-literal=SLSKD_JWT_KEY="$(openssl rand -hex 32)"
  fi

  kubectl apply -f "${K8S_DIR}/apps/musicgrabber.yaml"
  # ~1 GB image, slow first pull on a Pi
  wait_for_pods "media" 600
  kubectl -n media rollout status deploy/musicgrabber --timeout=600s

  # Point MusicGrabber at slskd (stored in its settings DB, still editable in the UI)
  SLSKD_WEB_USER=$(kubectl get secret slskd-env -n media -o jsonpath='{.data.SLSKD_USERNAME}' | base64 -d)
  SLSKD_WEB_PASS=$(kubectl get secret slskd-env -n media -o jsonpath='{.data.SLSKD_PASSWORD}' | base64 -d)
  kubectl exec -n media deploy/musicgrabber -c musicgrabber -- \
    env WU="$SLSKD_WEB_USER" WP="$SLSKD_WEB_PASS" python3 -c '
import httpx, os
httpx.put("http://localhost:8080/api/settings", json={
    "slskd_url": "http://localhost:5030", "slskd_user": os.environ["WU"],
    "slskd_pass": os.environ["WP"], "slskd_downloads_path": "/slskd/downloads",
    "source_soulseek_enabled": True}).raise_for_status()' \
    || echo -e "${YELLOW}Could not configure slskd in MusicGrabber; set it in Settings -> Soulseek.${NC}"
  print_step "MusicGrabber installed (with slskd)"
  echo ""
  echo -e "${YELLOW}MusicGrabber has no login by default. Set an API key in Settings -> Security before exposing it publicly.${NC}"
  echo -e "${YELLOW}slskd web UI: http://pi-cluster.internal:30530 (login in secret slskd-env). Forward TCP 30534 on your router for better Soulseek results.${NC}"
  echo ""
else
  echo -e "${CYAN}[10/17] Skipping MusicGrabber${NC}"
fi

# Step 11: SABnzbd
if [[ "$INSTALL_SABNZBD" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[11/17] Installing SABnzbd...${NC}"
  SABNZBD_PASSWORD="$SABNZBD_PASSWORD" bash "${SCRIPTS_DIR}/sabnzbd-bootstrap.sh"
  print_step "SABnzbd installed"
else
  echo -e "${CYAN}[11/17] Skipping SABnzbd${NC}"
fi

# Step 12: Stirling PDF
if [[ "$INSTALL_STIRLING_PDF" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[12/17] Installing Stirling PDF...${NC}"
  kubectl apply -f "${K8S_DIR}/apps/stirling-pdf.yaml"
  # Large image and slow JVM start on a Pi
  wait_for_pods "stirling-pdf" 600
  print_step "Stirling PDF installed"
else
  echo -e "${CYAN}[12/17] Skipping Stirling PDF${NC}"
fi

# Step 13: changedetection.io
if [[ "$INSTALL_CHANGEDETECTION" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[13/17] Installing changedetection.io...${NC}"
  kubectl apply -f "${K8S_DIR}/apps/changedetection.yaml"
  wait_for_pods "changedetection" 300
  print_step "changedetection.io installed"
else
  echo -e "${CYAN}[13/17] Skipping changedetection.io${NC}"
fi

# Step 14: Transmute
if [[ "$INSTALL_TRANSMUTE" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[14/17] Installing Transmute...${NC}"
  TRANSMUTE_ADMIN_PASSWORD="$TRANSMUTE_ADMIN_PASSWORD" \
    bash "${SCRIPTS_DIR}/transmute-bootstrap.sh"
  print_step "Transmute installed"
else
  echo -e "${CYAN}[14/17] Skipping Transmute${NC}"
fi

# Step 15: CyberChef
if [[ "$INSTALL_CYBERCHEF" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[15/17] Installing CyberChef...${NC}"
  kubectl apply -f "${K8S_DIR}/apps/cyberchef.yaml"
  wait_for_pods "cyberchef" 180
  print_step "CyberChef installed"
else
  echo -e "${CYAN}[15/17] Skipping CyberChef${NC}"
fi

# Step 16: Portainer
if [[ "$INSTALL_PORTAINER" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[16/17] Installing Portainer...${NC}"
  kubectl apply -f "${K8S_DIR}/platform/portainer.yaml"
  wait_for_pods "portainer" 180
  print_step "Portainer installed"
else
  echo -e "${CYAN}[16/17] Skipping Portainer${NC}"
fi

# Step 17: Dashboard
if [[ "$INSTALL_DASHBOARD" =~ ^[Yy] ]]; then
  echo -e "${CYAN}[17/17] Installing Homepage dashboard...${NC}"
  kubectl apply -f "${K8S_DIR}/platform/dashboard.yaml"
  # Config is copied at pod start, so pick up changes on re-runs
  kubectl -n monitoring rollout restart deploy/dashboard
  wait_for_pods "dashboard" 120
  print_step "Dashboard installed"
else
  echo -e "${CYAN}[17/17] Skipping Homepage dashboard${NC}"
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
[[ "$INSTALL_DASHBOARD" =~ ^[Yy] ]] && echo "  Access your services:   http://pi-cluster.internal"
echo ""

echo -e "${GREEN}Done!${NC}"
