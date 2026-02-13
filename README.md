# K3s Raspberry Pi 4 Cluster

4-node K3s cluster on Raspberry Pi 4 (4GB) running Ubuntu 24.04 LTS.

## Hardware

| Node       | Role          | IP              |
|------------|---------------|-----------------|
| pi-node-01 | Control plane | 192.168.1.191   |
| pi-node-02 | Worker        | 192.168.1.192   |
| pi-node-03 | Worker        | 192.168.1.193   |
| pi-node-04 | Worker        | 192.168.1.194   |

## Local Network Access

All services are accessible on your local network via `.local` domains (requires mDNS/Avahi or adding entries to your hosts file):

| Service      | URL                         | Description                             |
|--------------|-----------------------------|-----------------------------------------|
| Longhorn     | `http://longhorn.local`     | Distributed storage dashboard           |
| Grafana      | `http://grafana.local`      | Monitoring dashboards                   |
| AdGuard      | `http://adguard.local`      | DNS ad blocker admin UI                 |
| Open WebUI   | `http://openwebui.local`    | AI chat frontend (Gemini, OpenAI, etc.) |
| OpenClaw     | `http://openclaw.local`     | AI assistant gateway                    |
| Guacamole    | `http://guacamole.local`    | Remote desktop gateway (RDP/VNC/SSH)    |
| AIOStreams   | `http://aiostreams.local`   | Stremio addon aggregator                |
| Dashboard    | `http://dashboard.local`    | Cluster services dashboard (Homepage)   |

> **Note:** These domains resolve to cluster ingress IPs (192.168.1.191-194). If your router doesn't support mDNS, add entries to your local machine's hosts file pointing to any node IP.

## Quick Start (Full Cluster Setup)

### 1. Install K3s on the control plane

```bash
# Clone the repo on pi-node-01
ssh zaid@192.168.1.191
# On the Pi:
git clone https://github.com/chefzaid/pi-cluster.git
cd pi-cluster

# (To update in the future:)
# git pull

# Install K3s (outputs join token)
sudo bash install-k3s.sh
```

Save the **join token** printed at the end.

### 2. Join worker nodes

On each worker Pi:

```bash
# Clone the repo on each worker
ssh zaid@192.168.1.192
# On the Pi:
git clone https://github.com/chefzaid/pi-cluster.git
cd pi-cluster

# Install as worker
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

Dashboard: `http://longhorn.local`

### 5. Install Prometheus + Grafana (cluster monitoring)

```bash
kubectl apply -f "06 - grafana-prometheus.yaml"
```

This deploys:
- **Node Exporter** DaemonSet on every node (CPU, RAM, disk, network, temperature)
- **Prometheus** with 15-day retention on a 5Gi Longhorn volume
- **Grafana** with a pre-loaded "Pi Cluster Overview" dashboard

Grafana dashboard: `http://grafana.local`

Default credentials: `admin` / `admin` (change on first login).

The built-in dashboard shows per-node panels for:
- CPU usage & system load
- Memory usage
- CPU temperature (hwmon + thermal_zone)
- Disk usage & I/O
- Network throughput (RX/TX)

> **Tip:** Import dashboard ID **1860** ("Node Exporter Full") in Grafana for even more detail. The Prometheus datasource is pre-configured.

### 6. Install VNC desktop on control plane

Guacamole connects to the Pi desktops over VNC. Install a desktop environment on each node you want to access remotely:

```bash
sudo bash install-vnc-desktop.sh           # default password: raspberry
sudo bash install-vnc-desktop.sh mypass123 # or set your own
```

Connect with any VNC client to `192.168.1.191:5901`.

Installs XFCE4 (lightweight), TigerVNC, and Firefox with all fixes pre-applied:
- 24-bit color (no color scheme errors)
- Compositing disabled (saves CPU over VNC)
- GTK/Adwaita theme configured (no missing theme warnings)
- Firefox hardware acceleration disabled (works correctly over VNC)
- Runs as a systemd service (auto-starts on boot)

### 7. Set up Cloudflare Tunnel

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
kubectl apply -f "08 - cloudflare.yaml"
```

Verify it connects:
```bash
kubectl -n cloudflared get pods
# Both replicas should be Running
# Check the tunnel shows "HEALTHY" in the Cloudflare dashboard
```

#### d) Configure public hostnames (routes)

In the Cloudflare dashboard, go to your tunnel → **Public Hostname** tab → **Add a public hostname** for each app:

| Subdomain      | Domain        | Service | URL                                                     |
|----------------|---------------|---------|---------------------------------------------------------|
| `remote`       | `swirlit.dev` | HTTP    | `guacamole-service.guacamole.svc.cluster.local:80`      |
| `ai`           | `swirlit.dev` | HTTP    | `open-webui-service.ai.svc.cluster.local:80`            |
| `assistant`    | `swirlit.dev` | HTTP    | `openclaw-service.openclaw.svc.cluster.local:80`        |
| `aiostreams`   | `swirlit.dev` | HTTP    | `aiostreams-service.aiostreams.svc.cluster.local:80`    |
| `dashboard`    | `swirlit.dev` | HTTP    | `dashboard-service.dashboard.svc.cluster.local:80`      |
| `grafana`      | `swirlit.dev` | HTTP    | `grafana-service.monitoring.svc.cluster.local:80`       |

This makes your apps accessible at:
- `https://remote.swirlit.dev`
- `https://ai.swirlit.dev`
- `https://assistant.swirlit.dev`
- `https://aiostreams.swirlit.dev`
- `https://dashboard.swirlit.dev`
- `https://grafana.swirlit.dev`

#### e) Protect internet-exposed apps with Cloudflare Access (email OTP)

Add a one-time-password gate so only authorized users can reach your services. **Do this for every internet-facing app** - without it, anyone who guesses the subdomain has direct access.

##### Guacamole (critical - remote desktop access)

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

##### Open WebUI (important - AI chat with API keys stored inside)

Repeat the same steps:
- **Application name:** `Open WebUI`
- **Subdomain:** `ai` | **Domain:** `swirlit.dev`
- Use the same policy (Email OTP with your email)

> **Why this matters:** The first person to sign up on Open WebUI becomes admin. Without Cloudflare Access, a stranger could create the admin account before you do. Even after you set up your account, the login page is still exposed.

##### Dashboard (recommended - shows internal service topology)

Repeat the same steps:
- **Application name:** `Dashboard`
- **Subdomain:** `dashboard` | **Domain:** `swirlit.dev`
- Use the same policy (Email OTP with your email)

> **Why this matters:** Dashboard shows pod names, namespaces, health status, and internal URLs. While read-only, this gives an attacker a detailed map of your cluster. Protect it.

##### Grafana (recommended - metrics and monitoring)

Repeat the same steps:
- **Application name:** `Grafana`
- **Subdomain:** `grafana` | **Domain:** `swirlit.dev`
- Use the same policy (Email OTP with your email)

> **Why this matters:** Grafana displays cluster metrics, resource usage, and potentially sensitive infrastructure data. The default admin credentials are well-known (`admin`/`admin`). Protect it with OTP before exposing to the internet.

##### AIOStreams (optional - low risk)

AIOStreams is stateless and contains no credentials beyond what's in its addon configuration. You can still add Cloudflare Access if you want, using the same steps with subdomain `aiostreams`.

How it works:
- When someone visits any protected URL, Cloudflare shows a login page
- The user enters their email address
- If the email matches your allow list, Cloudflare sends a **6-digit OTP** to that email
- After entering the code, the user gets a session cookie and can access the app
- No passwords to manage - Cloudflare handles authentication before traffic ever reaches your cluster

### 8. Deploy workloads

```bash
kubectl apply -f "09 - guacamole.yaml"
kubectl apply -f "10 - openwebui.yaml"
kubectl apply -f "11 - openclaw.yaml"
kubectl apply -f "12 - aiostreams.yaml"
kubectl apply -f "13 - adguard.yaml"
kubectl apply -f "14 - dashboard.yaml"
```

> **Note on LLMs:** Ollama has been intentionally removed from this cluster. A Raspberry Pi 4 with 4GB RAM cannot run any local LLM in a usable way - even the tiniest models (qwen2.5:0.5b at ~1GB) would get < 1 token/second on the Cortex-A72 with no GPU/NPU, and that's before K3s, Longhorn, and other workloads claim their share of RAM. Open WebUI is still useful as a frontend for cloud LLM APIs (OpenAI, Anthropic, Google, etc.) - configure API keys in its settings after deployment.

---

#### 8a) Guacamole - remote desktop gateway

Guacamole provides browser-based access to your machines via RDP, VNC, and SSH. Uses the `jwetzell/guacamole` all-in-one image (ARM64 compatible - the official Apache images don't support ARM64). Access it at `https://remote.swirlit.dev`.

##### First login & replacing the default admin

Default credentials: `guacadmin` / `guacadmin`.

1. Log in with `guacadmin` / `guacadmin`
2. Go to **Settings** (top-right menu) → **Users** → **New User**
3. Create your own admin account - check **all permissions** (Administer system, Create users/connections, etc.)
4. Log out, log back in with your new account
5. Go to **Settings** → **Users** → delete `guacadmin`

> **Important:** Do this immediately. The `guacadmin` account is the #1 attack vector on Guacamole instances.

##### Adding an RDP connection (Windows PC)

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
| **Security mode**            | `RDP`                                          |
| **Ignore server certificate**| `Yes` (check this - avoids TLS errors)         |

3. Under **Display** → set **Color depth** to `True color (24-bit)` for best quality, or `High color (16-bit)` for speed
4. Click **Save**

> **Prerequisite:** Remote Desktop must be enabled on the Windows machine: **Settings** → **System** → **Remote Desktop** → **On**.

RDP performance tips:
- Set **Color depth** to `High color (16-bit)` - halves bandwidth with barely noticeable quality loss
- Enable **Disable wallpaper**, **Disable font smoothing**, **Disable full-window drag**, **Disable theming** under **Performance** - significantly reduces data over slow links
- Set **Resize method** to `Reconnect` for proper scaling when you resize the browser

##### Adding a VNC connection (Pi control plane desktop)

This connects to the TigerVNC desktop installed in step 6.

1. Go to **Settings** → **Connections** → **New Connection**
2. Configure:

| Field              | Value                                          |
|--------------------|------------------------------------------------|
| **Name**           | `Linux - Desktop`                              |
| **Protocol**       | `VNC`                                          |
| **Hostname**       | `192.168.1.191`                                |
| **Port**           | `5901`                                         |
| **Password**       | The VNC password (default: `raspberry`)        |
| **Color depth**    | `True color (24-bit)`                          |
| **Read only**      | Unchecked                                      |

3. Click **Save**

VNC performance tips:
- The VNC desktop was already configured for performance in step 6 (compositing off, no GPU accel)
- If it feels slow over the internet (via Cloudflare Tunnel), reduce **Color depth** to `256 colors` - VNC compresses poorly compared to RDP
- Set **Cursor** to `Local` under **Display** - makes the mouse feel more responsive (renders the cursor in your browser instead of waiting for the server)

##### Adding an SSH connection (Pi control plane terminal)

1. Go to **Settings** → **Connections** → **New Connection**
2. Configure:

| Field              | Value                                          |
|--------------------|------------------------------------------------|
| **Name**           | `Linux - SSH`                                  |
| **Protocol**       | `SSH`                                          |
| **Hostname**       | `192.168.1.191`                                |
| **Port**           | `22`                                           |
| **Username**       | `zaid`                                         |
| **Password**       | Your SSH password                              |
| **Color scheme**   | `Green on black` (or your preference)          |
| **Font size**      | `14`                                           |

3. Click **Save**

> **Tip:** You can also use SSH key authentication - paste your private key into the **Private key** field instead of setting a password.

##### Keyboard layout & input settings

Guacamole defaults to `en-US` keyboard layout. If you use a different layout:

1. In each **connection's settings**, scroll to **Basic Settings**
2. Set **Keyboard layout** to your layout (e.g. `French (fr-fr-azerty)`)
3. This is **per-connection** - you must set it on each RDP/VNC/SSH connection individually

> **Caveat:** VNC and SSH connections use the **Guacamole on-screen keyboard** layout, not the server-side one. If special keys don't work (AltGr, accented characters), open the Guacamole side menu (Ctrl+Alt+Shift) and use the on-screen keyboard.

For **RDP** connections, the keyboard layout must match the Windows input language. If keys are swapped (e.g. `Z` and `Y` on QWERTZ), change both the Guacamole connection setting **and** the Windows input language to match.

##### Common caveats

- **Clipboard:** Copy/paste between your local machine and Guacamole uses the side menu (Ctrl+Alt+Shift → clipboard text box). Direct Ctrl+C/Ctrl+V passes through to the remote session, not your local clipboard. On Chromium-based browsers, enable "Clipboard" permission in the browser for seamless clipboard sync.
- **Session persistence:** If the Guacamole pod restarts, active sessions are dropped but saved connections persist (stored on the Longhorn PVC). You just need to reconnect.
- **RDP "Already in use" error:** Windows allows only one interactive session. If someone is logged in locally on the Windows PC, RDP will prompt to disconnect them. Use the **Console** session option in Guacamole (set **Console audio** under Device Redirection) to take over the active session instead.
- **Black screen on VNC:** If you see a black screen, the VNC server may not have started its X session. SSH into the Pi and run `sudo systemctl restart vncserver@1`.
- **Slow over Cloudflare Tunnel:** Guacamole renders on the server and streams images. High latency is expected over the internet. Reduce color depth, disable wallpaper, and use RDP over VNC when possible (RDP compresses much better).

---

#### 8b) Open WebUI - AI chat frontend

Open WebUI is a ChatGPT-like interface that connects to cloud LLM APIs. Access it at `https://ai.swirlit.dev` or `http://openwebui.local` on LAN.

> **ARM64 Compatibility:** Running **v0.7.2** with `onnxruntime==1.20.1` fix (init container). v0.8.0+ has unfixable `torch` SIGILL on ARM64.

##### Create the API key secret

Before deploying, create the secret with your Gemini API key:

```bash
kubectl create secret generic ai-keys -n ai --from-literal=GEMINI_API_KEY=<your-key>
```

##### First login

The first account you create becomes the admin. Open the URL and sign up.

##### Connecting to Google Gemini (API key)

1. Get an API key from [Google AI Studio](https://aistudio.google.com/apikey)
   - Sign in with your Google account
   - Click **Create API Key** → select or create a Google Cloud project
   - Copy the key (starts with `AIza...`)

2. In Open WebUI, go to **Admin Panel** (top-left) → **Settings** → **Connections**

3. Under **OpenAI API**, click **+** to add a new connection:

| Field          | Value                                              |
|----------------|----------------------------------------------------|
| **URL**        | `https://generativelanguage.googleapis.com/v1beta` |
| **API Key**    | Your `AIza...` key                                 |

4. Click the **check mark** to verify the connection - it should show a green confirmation
5. Click **Save**

Available models (Gemini 2.0 Flash, Gemini 2.5 Pro, etc.) will now appear in the model dropdown on the chat page.

> **Tip:** You can add multiple providers (OpenAI, Anthropic, Mistral, etc.) the same way. Each one gets its own URL + API key entry under **OpenAI API** connections. Open WebUI uses the OpenAI-compatible API format, and most providers support it.

> **Cost:** Google offers a generous free tier for Gemini API (rate-limited). For personal use on a Pi cluster, you're unlikely to hit the paid tier.

---

#### 8c) OpenClaw - personal AI assistant gateway

OpenClaw is a personal AI assistant that runs as a local gateway. It connects to the messaging platforms you already use (WhatsApp, Telegram, Slack, Discord, Signal, etc.) and routes conversations through cloud LLM APIs. It includes a WebChat UI, session management, and a skills/tools platform.

Web UI: `http://openclaw.local`

> **Note:** OpenClaw is single-instance by design (it holds WebSocket state and session data). It cannot scale horizontally - the pod runs on whichever node K3s schedules it, and Longhorn handles storage portability.

##### Create the secret

Before deploying, create the namespace and secret with your API keys:

```bash
kubectl create namespace openclaw
kubectl create secret generic openclaw-env-secret -n openclaw \
  --from-literal=OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32) \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-xxx
```

Add more keys as needed:
- `OPENAI_API_KEY` - for OpenAI/GPT models
- `GOOGLE_AI_API_KEY` - for Gemini models
- `TELEGRAM_BOT_TOKEN` - to connect a Telegram bot
- `DISCORD_BOT_TOKEN` - to connect a Discord bot

##### Deploy

```bash
kubectl apply -f "11 - openclaw.yaml"
```

##### First-time setup

1. Open `http://openclaw.local`
2. Enter your **Gateway Token** (the `OPENCLAW_GATEWAY_TOKEN` from the secret) and click **Connect**
3. Approve the browser device:

```bash
kubectl exec -n openclaw deployment/openclaw -- node dist/index.js devices list
kubectl exec -n openclaw deployment/openclaw -- node dist/index.js devices approve <REQUEST_ID>
```

##### Connecting messaging channels

Use `kubectl exec` to run OpenClaw CLI commands:

```bash
# WhatsApp (QR code pairing)
kubectl exec -it -n openclaw deployment/openclaw -- node dist/index.js channels login

# Telegram
kubectl exec -n openclaw deployment/openclaw -- node dist/index.js channels add --channel telegram --token "<BOT_TOKEN>"

# Discord
kubectl exec -n openclaw deployment/openclaw -- node dist/index.js channels add --channel discord --token "<BOT_TOKEN>"
```

See the [OpenClaw channel docs](https://docs.openclaw.ai/channels) for all supported platforms.

##### Changing the default model

Edit the `openclaw-config` ConfigMap in `11 - openclaw.yaml` → `agents.defaults.model.primary`. Options:
- `anthropic/claude-sonnet-4-20250514` (default)
- `anthropic/claude-opus-4-6`
- `openai/gpt-4o`
- `google/gemini-2.5-pro`

Then re-apply and restart:

```bash
kubectl apply -f "11 - openclaw.yaml"
kubectl rollout restart deployment/openclaw -n openclaw
```

> **Tip:** Protect it with Cloudflare Access (email OTP) - OpenClaw has shell access and should **never** be exposed without authentication.

##### Common issues

- **"disconnected (1008): pairing required":** Run the `devices list` + `devices approve` commands above.
- **Pod OOMKilled:** OpenClaw uses ~300-400Mi under load. If other workloads are competing, the 512Mi limit may need bumping - but check `kubectl top pods -n openclaw` first.
- **Config changes not taking effect:** The init container only seeds config on first run. To force a config reset, delete the PVC and re-apply: `kubectl delete pvc openclaw-pvc -n openclaw && kubectl apply -f "11 - openclaw.yaml"`

---

#### 8d) AIOStreams - Stremio addon aggregator

AIOStreams is a lightweight addon server for [Stremio](https://www.stremio.com/) that aggregates multiple streaming addons into a single endpoint. Instead of installing dozens of Stremio addons individually, you configure them all in AIOStreams and add just one addon URL to Stremio. It is completely stateless (no PVC needed).

---

#### 8e) AdGuard Home - network-wide DNS ad blocker

AdGuard Home blocks ads, trackers, and malware domains at the DNS level for every device on your network - phones, TVs, laptops - without installing anything on each device. It runs entirely in-memory (DNS lookups are hash table lookups) so it's extremely fast on a Pi4.

Admin UI: `http://adguard.local`

##### First-time setup

On first access, AdGuard Home shows a setup wizard:

1. Open `http://adguard.local`
2. Click **Get started**
3. **Admin web interface** - leave listen on port `3000` (already configured in the YAML)
4. **DNS server** - leave listen on port `53`
5. **Create admin credentials** - pick a username and password
6. Click **Next** → **Open Dashboard**

##### Configure your router to use AdGuard as DNS

For whole-network ad blocking, point your router's DNS at any node IP on port `30053`:

1. Log into your router's admin panel
2. Find **DNS settings** (usually under DHCP or WAN settings)
3. Set **Primary DNS** to `192.168.1.191` (pi-node-01)
4. Set **Secondary DNS** to `192.168.1.192` (pi-node-02 - fallback if the pod moves)
5. Save and reboot the router

> **Important:** AdGuard listens on NodePort `30053`, not standard port `53`. Most consumer routers allow setting a custom DNS port. If yours doesn't, you have two options:
> - Set DNS directly on each device (phone, laptop) to `192.168.1.191:30053`
> - Or use a Pi-hole-style approach: run AdGuard with `hostNetwork: true` and port 53 directly (requires stopping `systemd-resolved` on the host node)

##### Recommended filter lists

Go to **Filters** → **DNS blocklists** → **Add blocklist** → **Choose from list**:

| List                            | Purpose                                  |
|---------------------------------|------------------------------------------|
| **AdGuard DNS filter**          | Default, catches most ads and trackers   |
| **AdAway Default Blocklist**    | Mobile-focused ads                       |
| **OISD (small)**                | Well-maintained, low false-positive list |
| **Steven Black's Unified**      | Ads, malware, fakenews                   |

> **Tip:** Start with just the default **AdGuard DNS filter** and **OISD (small)**. Adding too many lists wastes memory with overlapping entries and increases false positives. You can always add more later.

##### Upstream DNS servers

Go to **Settings** → **DNS settings** → **Upstream DNS servers**. Recommended:

```
https://dns.cloudflare.com/dns-query
https://dns.google/dns-query
```

This uses DNS-over-HTTPS (encrypted) to Cloudflare and Google as fallback. Queries are fast and your ISP can't see your DNS lookups.

Enable **Parallel requests** - AdGuard queries all upstream servers simultaneously and uses the fastest response.

##### Performance tuning for Pi4

- Under **Settings** → **DNS settings** → **DNS cache configuration**:
  - Set **Cache size** to `10000` (default 4096 - more cache = fewer upstream queries)
  - Set **Minimum TTL** to `300` seconds - overrides short TTLs, keeps popular domains cached longer
- Under **Settings** → **General settings**:
  - Disable **Query log** → **Enable log** if you don't need to review queries (saves disk I/O on the Longhorn PVC)
  - Or set **Log retention** to `24 hours` instead of 90 days
  - Disable **Statistics** or set retention to `24 hours` for the same reason

##### Common issues

- **Some websites broken after enabling AdGuard:** Go to **Query Log**, find the blocked domain, and click **Unblock**. Common false positives: `s.youtube.com` (YouTube history), `graph.facebook.com`, CDN domains for banking apps.
- **DNS not resolving at all:** Check if the AdGuard pod is running: `kubectl -n adguard get pods`. If the pod moved to another node, your router's primary DNS IP is stale - this is why you set a secondary DNS.

---

#### 8f) Dashboard - cluster dashboard (Homepage)

Homepage is a unified dashboard showing all your services with live health status. It auto-discovers pods via the Kubernetes API and shows green/red indicators.

Dashboard: `http://dashboard.local` (LAN) or `https://dashboard.swirlit.dev` (internet, protected by Cloudflare Access)

No setup needed - it comes pre-configured with all your services.

**Top widgets:** Live cluster CPU and RAM usage per node (pulled from the Kubernetes API, no extra config).

**Bookmarks:** Quick links to Cloudflare Dashboard, GitHub repo, Google AI Studio.

##### Customizing

All configuration lives in the `dashboard-config` ConfigMap in [14 - dashboard.yaml](14%20-%20dashboard.yaml). To customize:

1. Edit the YAML file (services, bookmarks, widgets sections)
2. Re-apply: `kubectl apply -f "14 - dashboard.yaml"`
3. The pod auto-reloads config within a few seconds

To add a new service, add an entry under the appropriate group in `services.yaml`. See the [Homepage docs](https://gethomepage.dev/configs/services/) for all options.

> **Tip:** Replace `swirlit.dev` in the `services.yaml` section with your actual domain so the links work.

## File Reference

| #   | File                         | Purpose                                                                        |
|-----|------------------------------|--------------------------------------------------------------------------------|
| 01  | `01 - install-k3s.sh`        | Install K3s control plane or join as worker node                               |
| 02  | `02 - k3s-config.yaml`       | K3s server config: eviction thresholds, reserved resources, max-pods           |
| 03  | `03 - longhorn-install.sh`   | Install Longhorn via `kubectl apply`                                           |
| 04  | `04 - longhorn-pi4-settings.yaml` | Longhorn Setting CRs optimized for Pi4                                    |
| 05  | `05 - longhorn-ingress.yaml` | Traefik ingress for Longhorn UI at `longhorn.local`                            |
| 06  | `06 - grafana-prometheus.yaml` | Prometheus + Grafana + Node Exporter, Longhorn PVCs (5Gi + 1Gi)              |
| 07  | `07 - install-vnc-desktop.sh`| Install XFCE4 + TigerVNC + Firefox (required for Guacamole)                    |
| 08  | `08 - cloudflare.yaml`       | Cloudflared tunnel deployment (2 replicas with anti-affinity)                  |
| 09  | `09 - guacamole.yaml`        | Guacamole all-in-one , Longhorn PVC (`guacamole-pvc`, 1Gi)                     |
| 10  | `10 - openwebui.yaml`        | Open WebUI AI chat (v0.7.2 with onnxruntime fix for ARM64)                     |
| 11  | `11 - openclaw.yaml`         | OpenClaw AI assistant gateway, Longhorn PVC (`openclaw-pvc`, 2Gi)              |
| 12  | `12 - aiostreams.yaml`       | AIOStreams (stateless)                                                         |
| 13  | `13 - adguard.yaml`          | AdGuard Home DNS, Longhorn PVCs (`adguard-work-pvc` 1Gi, `conf` 256Mi)         |
| 14  | `14 - dashboard.yaml`        | Homepage dashboard (`gethomepage/homepage`, stateless, config in ConfigMap)    |
| XX  | `flannel-fix-install.sh`     | *(If needed)* Install systemd fix for flannel subnet.env issue                 |

> **Note:** Secrets (`guacamole-config`, `cloudflared-config`, `aiostreams-config`, `openclaw-env-secret`) are created manually on the cluster and not stored in these files.

---

## Mandatory post-deployment checklist

1. **Guacamole:** Delete the default `guacadmin` account immediately (see section 8a)
2. **Grafana:** Change the default `admin`/`admin` password on first login
3. **Open WebUI:** Create your admin account before anyone else can
4. **Cloudflare Access:** Set up email OTP for `remote`, `ai`, `assistant`, and `dashboard` subdomains (see section 7e)
5. **VNC password:** Change from default `raspberry` - run `vncpasswd` on the Pi

> **Tip:**
If after installing everything, some pods get stuck in `ContainerCreating` after a reboot due to missing `/run/flannel/subnet.env`:

```bash
# On the affected node (adjust subnet per node)
sudo bash "flannel-fix-install.sh"               # pi-node-01: 10.42.0.1/24
sudo bash "flannel-fix-install.sh" 10.42.1.1/24  # pi-node-02
sudo bash "flannel-fix-install.sh" 10.42.2.1/24  # pi-node-03
sudo bash "flannel-fix-install.sh" 10.42.3.1/24  # pi-node-04
```
