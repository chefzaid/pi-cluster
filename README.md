# K3s Raspberry Pi 4 Cluster

4-node K3s cluster on Raspberry Pi 4 (4GB) running Ubuntu 24.04 LTS.

## Hardware

| Node | Role | IP |
|------|------|----|
| pi-node-01 | Control plane | 192.168.1.191 |
| pi-node-02 | Worker | 192.168.1.192 |
| pi-node-03 | Worker | 192.168.1.193 |
| pi-node-04 | Worker | 192.168.1.194 |

## Quick Start (Full Cluster Setup)

### 1. Install K3s on the control plane

```bash
# Copy files to pi-node-01
scp -r . zaid@192.168.1.191:~/k8s-deployment/

# SSH into pi-node-01
ssh zaid@192.168.1.191
cd ~/k8s-deployment

# Install K3s (outputs join token)
sudo bash install-k3s.sh
```

Save the **join token** printed at the end.

### 2. Join worker nodes

On each worker Pi:

```bash
# Copy the script
scp install-k3s.sh zaid@192.168.1.192:~/

# SSH in and join
ssh zaid@192.168.1.192
sudo bash install-k3s.sh worker 192.168.1.191 <TOKEN>
```

Repeat for pi-node-03 (`.193`) and pi-node-04 (`.194`).

### 3. Verify cluster

```bash
kubectl get nodes
# All 4 nodes should show Ready
```

### 4. Install Longhorn (distributed storage)

```bash
sudo bash longhorn-install.sh
```

This does:
- `kubectl apply` the official Longhorn v1.11.0 manifest (no Helm needed)
- Applies Pi4-optimized settings from `longhorn-pi4-settings.yaml`
- Creates Traefik ingress for the dashboard

Dashboard: `http://longhorn.local` (add `<CLUSTER_IP> longhorn.local` to your hosts file)

### 5. Install VNC desktop on control plane

Guacamole connects to the Pi desktops over VNC. Install a desktop environment on each node you want to access remotely:

```bash
sudo bash install-vnc-desktop.sh          # default password: raspberry
sudo bash install-vnc-desktop.sh mypass123 # or set your own
```

Connect with any VNC client to `192.168.1.191:5901`.

Installs XFCE4 (lightweight), TigerVNC, and Firefox with all fixes pre-applied:
- 24-bit color (no color scheme errors)
- Compositing disabled (saves CPU over VNC)
- GTK/Adwaita theme configured (no missing theme warnings)
- Firefox hardware acceleration disabled (works correctly over VNC)
- Runs as a systemd service (auto-starts on boot)

### 6. Set up Cloudflare Tunnel

Cloudflared exposes your cluster services to the internet through a Cloudflare Tunnel (no port forwarding needed).

#### a) Create the tunnel

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → **Networks** → **Tunnels**
2. Click **Create a tunnel** → choose **Cloudflared** connector
3. Name it (e.g. `pi-cluster`)
4. Copy the **tunnel token** shown (starts with `eyJ...`)

#### b) Create the K8s secret

```bash
kubectl create namespace cloudflared

kubectl create secret generic cloudflared-config \
  --namespace cloudflared \
  --from-literal=TUNNEL_TOKEN=<YOUR_TUNNEL_TOKEN>
```

#### c) Deploy cloudflared

```bash
kubectl apply -f cloudflare.yaml
```

Verify it connects:
```bash
kubectl -n cloudflared get pods
# Both replicas should be Running
# Check the tunnel shows "HEALTHY" in the Cloudflare dashboard
```

#### d) Configure public hostnames (routes)

In the Cloudflare dashboard, go to your tunnel → **Public Hostname** tab → **Add a public hostname** for each app:

| Subdomain | Domain | Service | URL |
|-----------|--------|---------|-----|
| `remote` | `yourdomain.com` | HTTP | `guacamole-service.guacamole.svc.cluster.local:80` |
| `ai` | `yourdomain.com` | HTTP | `open-webui-service.ai.svc.cluster.local:80` |
| `aiostreams` | `yourdomain.com` | HTTP | `aiostreams-service.stremio.svc.cluster.local:80` |

This makes your apps accessible at:
- `https://remote.yourdomain.com`
- `https://ai.yourdomain.com`
- `https://aiostreams.yourdomain.com`

> **Guacamole note:** In the route settings, set **Path** to `/guacamole/` or enable **No TLS Verify** if needed. Guacamole serves under the `/guacamole/` prefix by default.

#### e) Protect Guacamole with Cloudflare Access (email OTP)

Add a one-time-password gate so only authorized users can reach Guacamole:

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → **Access** → **Applications**
2. Click **Add an application** → **Self-hosted**
3. Configure the application:
   - **Application name:** `Guacamole`
   - **Session duration:** `24 hours` (or your preference)
   - **Subdomain:** `remote` | **Domain:** `yourdomain.com`
4. Click **Next** to configure the access policy:
   - **Policy name:** `Email OTP`
   - **Action:** `Allow`
   - **Include rule:** `Emails` → enter the email addresses that should have access (e.g. `you@gmail.com`)
   - **Authentication method:** Leave as default (Cloudflare will offer **One-time PIN** automatically)
5. Click **Next** → **Add application**

How it works:
- When someone visits `https://remote.yourdomain.com/guacamole/`, Cloudflare shows a login page
- The user enters their email address
- If the email matches your allow list, Cloudflare sends a **6-digit OTP** to that email
- After entering the code, the user gets a session cookie and can access Guacamole
- No passwords to manage — Cloudflare handles authentication before traffic ever reaches your cluster

> **Tip:** You can also protect other apps (Open WebUI, Stremio) the same way by adding more Access applications.

### 7. Deploy workloads

```bash
kubectl apply -f guacamole.yaml
kubectl apply -f openwebui.yaml
kubectl apply -f ollama.yaml
kubectl apply -f stremio.yaml
```

### 8. (If needed) Flannel fix

If pods get stuck in `ContainerCreating` after a reboot due to missing `/run/flannel/subnet.env`:

```bash
# On the affected node (adjust subnet per node)
sudo bash flannel-fix-install.sh              # pi-node-01: 10.42.0.1/24
sudo bash flannel-fix-install.sh 10.42.1.1/24 # pi-node-02
sudo bash flannel-fix-install.sh 10.42.2.1/24 # pi-node-03
sudo bash flannel-fix-install.sh 10.42.3.1/24 # pi-node-04
```

---

## File Reference

| # | File | Purpose |
|---|------|---------|
| 01 | `install-k3s.sh` | Install K3s control plane or join as worker node |
| 02 | `k3s-config.yaml` | K3s server config: eviction thresholds, reserved resources, max-pods |
| 03 | `longhorn-install.sh` | Install Longhorn via `kubectl apply` (no Helm) |
| 04 | `longhorn-pi4-settings.yaml` | Longhorn Setting CRs optimized for Pi4 (2 replicas, low CPU, fast rebuild) |
| 05 | `longhorn-ingress.yaml` | Traefik ingress for Longhorn UI at `longhorn.local` |
| 06 | `install-vnc-desktop.sh` | Install XFCE4 + TigerVNC + Firefox (required for Guacamole) |
| 07 | `cloudflare.yaml` | Cloudflared tunnel deployment (2 replicas with anti-affinity) |
| 08 | `guacamole.yaml` | Guacamole + guacd, Longhorn PVC (`guacamole-pvc`, 1Gi) |
| 09 | `openwebui.yaml` | Open WebUI, Longhorn PVC (`open-webui-pvc`, 2Gi) |
| 10 | `ollama.yaml` | Ollama LLM server, local-path PVC (20Gi) |
| 11 | `stremio.yaml` | AIOStreams (stateless) |
| 12 | `flannel-fix-install.sh` | *(If needed)* Install systemd fix for flannel subnet.env issue |

> **Note:** Secrets (`guacamole-config`, `cloudflared-config`, `aiostreams-config`) are created manually on the cluster and not stored in these files.

---

## Pi4 Optimizations Applied

### K3s (`k3s-config.yaml`)
- Hard eviction at 200Mi free memory / 10% disk
- Soft eviction at 500Mi / 15% with 90s grace
- Reserved: 200m CPU + 256Mi RAM for kube + system each
- Max 50 pods per node

### Longhorn (`longhorn-pi4-settings.yaml`)
- 2 replicas per volume (not 3 -- saves 33% storage IO)
- 5% guaranteed instance manager CPU (down from 12%)
- 1 concurrent rebuild/backup per node (prevents IO storms)
- Fast replica rebuild enabled
- Soft anti-affinity (allows scheduling when nodes are limited)

### Workloads
All deployments include:
- Resource requests and limits sized for Pi4
- Readiness and liveness probes
- Pod anti-affinity where applicable (cloudflared)
