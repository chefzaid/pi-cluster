#!/bin/bash
# Trim the VNC desktop node down to what the TigerVNC/XFCE session needs
# =====================================================================
# The Ubuntu desktop packages pull in a login screen on the HDMI output and
# background services that only matter on a laptop. The VNC session
# (vncserver@1, used by Guacamole) runs on its own and keeps working.
#
# Usage: sudo bash vnc-desktop-trim.sh [VNC_USER]
#   VNC_USER defaults to the User= of vncserver@1, then $SUDO_USER

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

VNC_USER="${1:-$(systemctl show vncserver@1.service -p User --value 2>/dev/null)}"
VNC_USER="${VNC_USER:-${SUDO_USER:-}}"
if [ -z "$VNC_USER" ] || ! id "$VNC_USER" >/dev/null 2>&1; then
  echo "ERROR: cannot determine the VNC user; pass it as the first argument"
  exit 1
fi
VNC_HOME=$(getent passwd "$VNC_USER" | cut -d: -f6)

echo "=== Trimming desktop services (VNC user: ${VNC_USER}) ==="

# 1. No graphical login on the HDMI output (lightdm + greeter + Xorg ~200 MB)
echo "[1/4] Boot to multi-user target, disable lightdm"
systemctl set-default multi-user.target >/dev/null
systemctl disable --now lightdm.service >/dev/null 2>&1 || true

# 2. Laptop/desktop daemons with no use on a headless cluster node.
#    NetworkManager manages no interface here (netplan uses systemd-networkd).
echo "[2/4] Disabling printing, bluetooth, colord and NetworkManager"
for unit in cups.service cups.socket cups.path cups-browsed.service \
            bluetooth.service colord.service \
            NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service; do
  if [ -n "$(systemctl list-unit-files "$unit" --no-legend 2>/dev/null)" ]; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || true
    echo "  masked $unit"
  fi
done
if command -v snap >/dev/null 2>&1 && snap list cups >/dev/null 2>&1; then
  snap remove --purge cups >/dev/null
  echo "  removed cups snap"
fi

# 3. evolution-data-server: GNOME calendar/contacts backend, 4 processes ~180 MB
echo "[3/4] Removing evolution-data-server"
if dpkg -s evolution-data-server >/dev/null 2>&1; then
  apt-get purge -y -qq evolution-data-server >/dev/null
fi

# 4. Session autostarts that are useless over VNC
echo "[4/4] Hiding session autostarts (nm-applet, print applet, screen lockers)"
AUTOSTART_DIR="${VNC_HOME}/.config/autostart"
install -d -o "$VNC_USER" -g "$(id -gn "$VNC_USER")" "$AUTOSTART_DIR"
for entry in nm-applet print-applet light-locker xscreensaver blueman org.gnome.Evolution-alarm-notify; do
  printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$entry" > "${AUTOSTART_DIR}/${entry}.desktop"
  chown "$VNC_USER":"$(id -gn "$VNC_USER")" "${AUTOSTART_DIR}/${entry}.desktop"
done
# Stop the ones already running in the current session without restarting it
pkill -u "$VNC_USER" -x nm-applet 2>/dev/null || true
pkill -u "$VNC_USER" -f '^/usr/libexec/evolution' 2>/dev/null || true
pkill -u "$VNC_USER" -x light-locker 2>/dev/null || true
pkill -u "$VNC_USER" -x xscreensaver 2>/dev/null || true

echo "=== Desktop trim done; vncserver@1: $(systemctl is-active vncserver@1.service 2>/dev/null || echo unknown) ==="
