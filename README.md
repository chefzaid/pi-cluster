# K3s Raspberry Pi 4 Cluster

4-node K3s cluster on Raspberry Pi 4 (4GB) running Ubuntu 24.04 LTS.

## Hardware

| Node       | Role          | IP              |
|------------|---------------|-----------------|
| pi-node-01 | Control plane | 192.168.1.191   |
| pi-node-02 | Worker        | 192.168.1.192   |
| pi-node-03 | Worker        | 192.168.1.193   |
| pi-node-04 | Worker        | 192.168.1.194   |

## File Reference

### Root

| File                       | Purpose                                                                    |
|----------------------------|----------------------------------------------------------------------------|
| `install-cluster.sh`       | Full automated cluster installation (interactive, SSH to workers)          |

### Scripts (`scripts/`)

| File                       | Purpose                                                                    |
|----------------------------|----------------------------------------------------------------------------|
| `install-k3s.sh`           | Install K3s control plane or join as worker node                           |
| `node-setup.sh`            | Flannel fix + reboot cleanup service + UFW firewall                        |
| `install-vnc-desktop.sh`   | Install XFCE4 + TigerVNC + native Firefox DEB (for Guacamole)              |
| `install-tailscale.sh`     | Install Tailscale and advertise home LAN route from Pi                     |
| `openebs-install.sh`       | Install OpenEBS LocalPV provisioner                                        |

### Deployments (`deployments/`)

| File                       | Purpose                                                                    |
|----------------------------|----------------------------------------------------------------------------|
| `k3s-config.yaml`          | K3s server config: eviction thresholds, reserved resources, max-pods       |
| `openebs-localpv.yaml`     | OpenEBS LocalPV StorageClass (openebs-hostpath, default for cluster)       |
| `grafana-prometheus.yaml`  | Prometheus + Grafana + Node Exporter (CPU, RAM, disk, temperature)         |
| `cloudflare.yaml`          | Cloudflared tunnel deployment (2 replicas with anti-affinity)              |
| `guacamole.yaml`           | Guacamole all-in-one, OpenEBS PVC (`guacamole-pvc`, 1Gi)                   |
| `openwebui.yaml`           | Open WebUI AI chat                                                         |
| `openclaw.yaml`            | OpenClaw AI assistant gateway, OpenEBS PVC (`openclaw-pvc`, 2Gi)           |
| `adguard.yaml`             | AdGuard Home DNS, OpenEBS PVCs (`adguard-work-pvc` 1Gi, `conf` 256Mi)      |
| `portainer.yaml`           | Portainer UI to manage Kubernetes + service account/cluster RBAC           |
| `dashboard.yaml`           | Homepage dashboard (CPU, RAM, temperature, service status)                 |

## Local Network Access

All services are accessible on your local network via `pi-cluster.local` domain (add the entry to your hosts file).

---

## Quick Start (Full Cluster Setup)

Run a single script that installs everything interactively:

```bash
# Clone the repo on pi-node-01 (control plane)
ssh zaid@192.168.1.191
git clone https://github.com/chefzaid/pi-cluster.git
cd pi-cluster

# Run the full installer
sudo bash install-cluster.sh
```

The script will:
- Prompt for worker node IPs and SSH credentials (automates worker setup via SSH)
- Prompt for configuration (VNC password, Cloudflare token, API keys, etc.)
- Install K3s, OpenEBS LocalPV storage, monitoring, and all applications
- Create necessary secrets
- Automatically configure all worker nodes

---

## Setting up Cloudflare Tunnel

Cloudflared exposes your cluster services to the internet through a Cloudflare Tunnel (no port forwarding needed).

### a) Create the tunnel

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → **Networks** → **Tunnels**
2. Click **Create a tunnel** → choose **Cloudflared** connector
3. Name it (e.g. `pi-cluster`)
4. Copy the **tunnel token** shown (starts with `eyJ...`)

> **Note:** This first step has to be done before executing the install script, which will prompt for the token

### b) Configure public hostnames (routes)

In the Cloudflare dashboard, go to your tunnel → **Public Hostname** tab → **Add a public hostname** for each app:

| Subdomain      | Domain        | Service | URL                                                     |
|----------------|---------------|---------|---------------------------------------------------------|
| `remote`       | `swirlit.dev` | HTTP    | `guacamole-service.guacamole.svc.cluster.local:80`      |
| `ai`           | `swirlit.dev` | HTTP    | `open-webui-service.ai.svc.cluster.local:80`            |

### c) Protect internet-exposed apps with Cloudflare Access (email OTP)

Add a one-time-password gate so only authorized users can reach your services. **Do this for every critical internet-facing app** - without it, anyone who guesses the subdomain has direct access.

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → **Access** → **Applications**
2. Click **Add an application** → **Self-hosted**
3. Configure the application:
   - **Application name:** `Guacamole`
   - **Session duration:** `24 hours` (or your preference)
   - **Subdomain:** `remote` | **Domain:** `swirlit.dev`
4. Click **Next** to configure the access policy:
   - **Policy name:** `Email OTP`
   - **Action:** `Allow`
   - **Include rule:** `Emails` → enter the email addresses that should have access (e.g. `you@gmail.com`)
   - **Authentication method:** Leave as default (Cloudflare will offer **One-time PIN** automatically)
5. Click **Next** → **Add application**
6. Repeat the same steps for all other critical applications (Open WebUI, ...):

---

## Tailscale bridge for dedicated server

If you host Guacamole on an dedicated server, use the Pi control-plane node as a **Tailscale subnet router** so the DS can reach your home LAN (for example your laptop at `192.168.1.50`).

### Topology

- Dedicated Server (Guacamole) joins your Tailnet
- Pi control plane joins the same Tailnet and advertises `192.168.1.0/24`
- Guacamole on dedicated server connects to your laptop using its **home LAN IP**

### 1) Create a Tailscale auth key

1. Open [Tailscale admin](https://login.tailscale.com/admin/settings/keys)
2. Create an auth key (`tskey-auth-...`)
3. Keep it ready for the full installer prompt

### 2) Install/configure Tailscale on the Pi (subnet router)

Run the full installer and enable:

- `Install Tailscale subnet router on this Pi?` → `y`
- `Home LAN routes to advertise` → `192.168.1.0/24` (or your LAN CIDR)
- `Tailscale hostname` → e.g. `pi-lan-gateway`
- `Tailscale auth key` → your `tskey-auth-...`

Or run manually:

```bash
sudo TAILSCALE_AUTHKEY="tskey-auth-..." \
   TAILSCALE_ROUTES="192.168.1.0/24" \
   TAILSCALE_HOSTNAME="pi-lan-gateway" \
   bash install-tailscale-subnet-router.sh
```

### 3) Approve advertised route in Tailscale admin

Approve the route in the admin console (most common cause) - [Tailscale admin → Machines](https://login.tailscale.com/admin/machines) → find the Pi → `...` → **Edit route settings** → enable `192.168.1.0/24`

### 4) Join the dedicated server to the same Tailnet

On the Dedicated Server (DS):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --authkey "tskey-auth-..." --accept-routes --accept-dns=false
tailscale status
```

`--accept-routes` is required so the DS learns `192.168.1.0/24` via the Pi.

### 5) Configure Guacamole on DS

In Guacamole (running on the DS), create your RDP/VNC/SSH connection with:

- **Hostname** = laptop/home host LAN IP (example `192.168.1.50`)
- **Port/protocol** = usual LAN service port (`3389`, `22`, `5901`, etc.)

Traffic path will be: `DS (Tailnet) -> Pi subnet router -> Home LAN host`.

### Troubleshooting

- On DS, verify route exists: `ip route | grep 192.168.1.0/24`
- On Pi, verify Tailscale state: `tailscale status`
- Ensure target laptop firewall allows the protocol from your LAN

---

## Setting up Guacamole

Guacamole provides browser-based access to your machines via RDP, VNC, and SSH.

### First login & replacing the default admin

Default credentials: `guacadmin` / `guacadmin`.

1. Log in with `guacadmin` / `guacadmin`
2. Go to **Settings** (top-right menu) → **Users** → **New User**
3. Create your own admin account - check **all permissions** (Administer system, Create users/connections, etc.)
4. Log out, log back in with your new account
5. Go to **Settings** → **Users** → delete `guacadmin`

> **Important:** Do this immediately. The `guacadmin` account is the #1 attack vector on Guacamole instances.

### Adding an RDP connection (Windows PC)

1. Go to **Settings** → **Connections** → **New Connection**
2. Configure:

| Field                        | Value                                          |
|------------------------------|------------------------------------------------|
| **Name**                     | `Windows` (or any label)                       |
| **Protocol**                 | `RDP`                                          |
| **Hostname**                 | IP of the Windows machine (e.g. `192.168.1.50`)|
| **Port**                     | `3389`                                         |
| **Username**                 | Your Windows username                          |
| **Password**                 | Your Windows password                          |
| **Domain**                   | Leave blank (unless domain-joined)             |
| **Security mode**            | `RDP encryption`                               |
| **Ignore server certificate**| `Yes` (check this - avoids TLS errors)         |

3. Under **Display** → set **Color depth** to `True color (24-bit)` for best quality, or `High color (16-bit)` for speed
4. Click **Save**

> **Prerequisite:** Remote Desktop must be enabled on the Windows machine: **Settings** → **System** → **Remote Desktop** → **On** (Windows 11 Pro). You may need to tinker with RDP options and policies to be able to connect through Guacamole.

RDP performance tips:
- Set **Color depth** to `High color (16-bit)` - halves bandwidth with barely noticeable quality loss
- Set **Resize method** to `Reconnect` for proper scaling when you resize the browser

### Adding a VNC connection (Pi control plane desktop)

This connects to the TigerVNC desktop installed in step 6.

The installer pulls Firefox from Mozilla's APT repository instead of Ubuntu's snap-backed transitional package, because the snap build is unreliable in TigerVNC sessions and can fail to launch from the desktop/menu.

1. Go to **Settings** → **Connections** → **New Connection**
2. Configure:

| Field              | Value                                          |
|--------------------|------------------------------------------------|
| **Name**           | `Linux - Desktop`                              |
| **Protocol**       | `VNC`                                          |
| **Hostname**       | ``                                |
| **Port**           | `5901`                                         |
| **Username**       | Leave blank (it's not Linux username)          |
| **Password**       | The VNC password (default: `raspberry`)        |
| **Color depth**    | `True color (24-bit)`                          |
| **Read only**      | Unchecked                                      |

3. Click **Save**

### Adding an SSH connection (Pi control plane terminal)

1. Go to **Settings** → **Connections** → **New Connection**
2. Configure:

| Field              | Value                                          |
|--------------------|------------------------------------------------|
| **Name**           | `Linux - SSH`                                  |
| **Protocol**       | `SSH`                                          |
| **Hostname**       | ``                                |
| **Port**           | `22`                                           |
| **Username**       | `zaid`                                         |
| **Password**       | Your SSH password                              |
| **Color scheme**   | `Green on black` (or your preference)          |

3. Click **Save**

### Keyboard layout & input settings

Guacamole defaults to `en-US` keyboard layout. If you use a different layout:

1. In each **connection's settings**, scroll to **Basic Settings**
2. Set **Keyboard layout** to your layout (e.g. `French (fr-fr-azerty)`)
3. This is **per-connection** - you must set it on each RDP/VNC/SSH connection individually

---

## Setting Open WebUI

1. Get an API key from [OpenRouter](https://openrouter.ai/keys)
   - Sign in to OpenRouter
   - Create or copy your API key (starts with `sk-or-v1-...`)

2. In Open WebUI, go to **Admin Panel** (top-left) → **Settings** → **Connections**

3. Under **OpenAI API**, click **+** to add a new connection:

| Field          | Value                                              |
|----------------|----------------------------------------------------|
| **URL**        | `https://openrouter.ai/api/v1`                     |
| **API Key**    | Your `sk-or-v1-...` key                            |

4. Click the **check mark** to verify the connection - it should show a green confirmation
5. Click **Save**

> **Tip:** You can add multiple providers (OpenAI, Anthropic, Mistral, etc.) the same way. Each one gets its own URL + API key entry under **OpenAI API** connections. Open WebUI uses the OpenAI-compatible API format, and most providers support it.

---

## Setting up OpenClaw

OpenClaw uses an `OPENROUTER_API_KEY` and a `OPENCLAW_GATEWAY_TOKEN` secret (auto-generated by the installer).

### First-time setup

Retrieve your token at any time:

```bash
kubectl get secret openclaw-env-secret -n ai -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d && echo
```

Provide the **Gateway Token** once via URL parameter:

```
http://pi-cluster.local:30789/?token=YOUR_GATEWAY_TOKEN
```

The token is saved in browser localStorage - subsequent visits work without it.

### Running CLI commands

```bash
kubectl exec -n ai deployment/openclaw -- YOUR_COMMAND_HERE
```

See the [OpenClaw docs](https://docs.openclaw.ai) for more details.

### Skills

OpenClaw skills are managed independently from the main cluster install. See [`openclaw-skills/README.md`](openclaw-skills/README.md) for setup and deployment instructions.

---

## Mandatory post-deployment checklist

1. **VNC password:** Change from default `raspberry` - run `vncpasswd` on the Pi. You may need to restart the server.
2. **Guacamole:** Delete the default `guacadmin` account immediately
3. **Grafana:** Change the default `admin`/`admin` password on first login
4. **Open WebUI:** Create your admin account before anyone else can
5. **Cloudflare Access:** Set up email OTP, at least for `remote` and `ai` subdomains
6. **Tailscale:** Approve the advertised route in Tailscale admin so your DS can reach the home LAN
