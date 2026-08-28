# Pi 4 Cluster

Setup for 4-nodes cluster of Raspberry Pi 4 to self-host a mini home lab and necessary utilities.

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

### Configuration (`config/`)

| File | Purpose |
|------|---------|
| `k3s/config.yaml` | K3s server config: eviction thresholds, reserved resources, and max pods |

### Kubernetes (`k8s/`)

| File                       | Purpose                                                                    |
|----------------------------|----------------------------------------------------------------------------|
| `storage/openebs-localpv.yaml` | OpenEBS LocalPV StorageClass (`openebs-hostpath`) |
| `platform/grafana-prometheus.yaml` | Prometheus, Grafana, and Node Exporter monitoring |
| `platform/cloudflare.yaml` | Cloudflared tunnel deployment with two anti-affined replicas |
| `platform/portainer.yaml` | Portainer Kubernetes management UI and cluster RBAC |
| `platform/dashboard.yaml` | Homepage dashboard for resources and service status |
| `apps/guacamole.yaml` | Guacamole all-in-one with a 1 GiB OpenEBS PVC |
| `apps/openclaw.yaml` | OpenClaw AI assistant gateway with a 2 GiB OpenEBS PVC |
| `apps/aiostreams.yaml` | AIOStreams Stremio addon aggregator with a 1 GiB OpenEBS PVC |
| `apps/adguard.yaml` | AdGuard Home DNS with OpenEBS work and configuration PVCs |

### Ansible (`ansible/`)

| File                       | Purpose                                                                    |
|----------------------------|----------------------------------------------------------------------------|
| `deploy-aiostreams.yml`    | Optional AIOStreams deployment flow with prompts and generated secret key   |
| `inventory.example.ini`    | Example control-plane inventory for Ansible runs                           |

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
| `aiostreams`   | `swirlit.dev` | HTTP    | `aiostreams-service.media.svc.cluster.local:80`         |

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
6. Repeat the same steps for all other critical internet-facing applications.

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

## Setting up OpenClaw

OpenClaw is preconfigured to use OpenRouter with `openrouter/moonshotai/kimi-k3` as its primary model. The installer stores the supplied `OPENROUTER_API_KEY` in a Kubernetes Secret.

### First-time setup

Open <http://pi-cluster.local:30789> from the cluster dashboard. No OpenClaw token, password, onboarding wizard, or model selection is required.

The gateway intentionally uses no application-level authentication so it is ready on first use. Keep this NodePort and the `openclaw.local` ingress on a trusted LAN; do not expose them directly to the public internet without adding an authenticated reverse proxy.

### Running CLI commands

```bash
kubectl exec -n ai deployment/openclaw -- YOUR_COMMAND_HERE
```

See the [OpenClaw docs](https://docs.openclaw.ai) for more details.

### Skills

OpenClaw skills are managed independently from the main cluster install. See [`openclaw-skills/README.md`](openclaw-skills/README.md) for setup and deployment instructions.

---

## Setting up AIOStreams

AIOStreams is installed only if you answer `y` to the installer prompt. The installer asks for `BASE_URL` and generates the required 64-character `SECRET_KEY`.

- For this cluster, accept the default `https://aiostreams.swirlit.dev`
- For local-only use, enter `http://aiostreams.local`

Access the configuration UI:

```bash
https://aiostreams.swirlit.dev/stremio/configure
```

Local NodePort access is also available:

```bash
http://pi-cluster.local:30300/stremio/configure
```

If you use the ingress hostname directly, add `aiostreams.local` to your hosts file and open:

```bash
http://aiostreams.local/stremio/configure
```

The `SECRET_KEY` is stored in the Kubernetes secret `aiostreams-env` and must not be changed after first run because it encrypts saved addon configurations.

You can deploy AIOStreams independently with Ansible from a machine that can SSH to the control plane:

```bash
ansible-playbook -i ansible/inventory.example.ini ansible/deploy-aiostreams.yml
```

See the [AIOStreams deployment docs](https://github.com/Viren070/AIOStreams/wiki/Deployment) and [project README](https://github.com/Viren070/AIOStreams) for setup details and usage notes.

---

## Mandatory post-deployment checklist

1. **VNC password:** Change from default `raspberry` - run `vncpasswd` on the Pi. You may need to restart the server.
2. **Guacamole:** Delete the default `guacadmin` account immediately
3. **Grafana:** Change the default `admin`/`admin` password on first login
4. **AIOStreams:** Use a stable `BASE_URL`; changing it later can break generated install URLs
5. **Cloudflare Access:** Set up email OTP, at least for `remote` and `aiostreams` subdomains
6. **Tailscale:** Approve the advertised route in Tailscale admin so your DS can reach the home LAN
