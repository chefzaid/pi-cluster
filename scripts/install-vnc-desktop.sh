#!/bin/bash
# VNC Desktop Environment Setup for Raspberry Pi 4 (Ubuntu 24.04)
# Installs XFCE4 (lightweight) + TigerVNC + native Firefox DEB
# Optimized for Pi4 running K3s (minimal resource overhead)
#
# Usage: sudo bash install-vnc-desktop.sh [VNC_PASSWORD]
#   VNC_PASSWORD defaults to "raspberry" if not provided
#
# Connect: vnc://<PI_IP>:5901 or <PI_IP>::5901

set -e

VNC_PASSWORD="${1:-raspberry}"
SUDO_USER_NAME="${SUDO_USER:-$(whoami)}"
SUDO_USER_HOME=$(eval echo ~${SUDO_USER_NAME})
MOZILLA_KEYRING="/etc/apt/keyrings/packages.mozilla.org.asc"
MOZILLA_SOURCE_LIST="/etc/apt/sources.list.d/mozilla.list"
MOZILLA_PREFERENCE="/etc/apt/preferences.d/mozilla"
MOZILLA_FINGERPRINT="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

echo "=== VNC Desktop Setup for Raspberry Pi 4 ==="
echo "User: ${SUDO_USER_NAME}"
echo ""

# ──────────────────────────────────────────────
# Step 1: Install XFCE4 desktop (lightweight)
# ──────────────────────────────────────────────
echo "[1/6] Installing XFCE4 desktop environment..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  ca-certificates \
  curl \
  gnupg \
  xfce4 \
  xfce4-terminal \
  xfce4-settings \
  xfce4-session \
  xfce4-panel \
  xfce4-whiskermenu-plugin \
  thunar \
  dbus-x11 \
  x11-xserver-utils \
  xfonts-base \
  xfonts-100dpi \
  xfonts-75dpi \
  fonts-dejavu-core \
  fonts-liberation \
  fonts-noto-color-emoji \
  gtk2-engines-pixbuf \
  libgtk-3-common \
  adwaita-icon-theme \
  gnome-themes-extra \
  policykit-1-gnome \
  at-spi2-core \
  mesa-utils \
  2>/dev/null

echo "  XFCE4 installed"

# ──────────────────────────────────────────────
# Step 2: Install TigerVNC server
# ──────────────────────────────────────────────
echo ""
echo "[2/6] Installing TigerVNC server..."
apt-get install -y -qq tigervnc-standalone-server tigervnc-common 2>/dev/null
echo "  TigerVNC installed"

# ──────────────────────────────────────────────
# Step 3: Install Firefox browser
# ──────────────────────────────────────────────
echo ""
echo "[3/6] Installing Firefox..."
# IMPORTANT: Ubuntu 24.04's archive firefox package is only a snap transition.
# Snap Firefox often fails in TigerVNC/X11 sessions, so install Mozilla's native DEB.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o "${MOZILLA_KEYRING}"

GNUPG_TMP_DIR=$(mktemp -d)
ACTUAL_FINGERPRINT=$(
  GNUPGHOME="${GNUPG_TMP_DIR}" gpg --batch --quiet --show-keys --with-colons "${MOZILLA_KEYRING}" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)
rm -rf "${GNUPG_TMP_DIR}"

if [ "${ACTUAL_FINGERPRINT}" != "${MOZILLA_FINGERPRINT}" ]; then
  echo "ERROR: Mozilla APT key fingerprint mismatch: ${ACTUAL_FINGERPRINT}"
  exit 1
fi

cat > "${MOZILLA_SOURCE_LIST}" << 'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF

cat > "${MOZILLA_PREFERENCE}" << 'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

INSTALLED_FIREFOX_VERSION=$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)
if [[ "${INSTALLED_FIREFOX_VERSION}" == *snap* ]]; then
  apt-get purge -y -qq firefox >/dev/null 2>&1 || true
fi

if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
  snap remove --purge firefox >/dev/null 2>&1 || true
fi

apt-get update -qq
apt-get install -y -qq firefox
echo "  Firefox installed from Mozilla APT repo (native DEB)"

# ──────────────────────────────────────────────
# Step 4: Configure VNC for the user
# ──────────────────────────────────────────────
echo ""
echo "[4/6] Configuring VNC server..."

# Create VNC directory
sudo -u "${SUDO_USER_NAME}" mkdir -p "${SUDO_USER_HOME}/.vnc"

# Set VNC password
echo "${VNC_PASSWORD}" | sudo -u "${SUDO_USER_NAME}" vncpasswd -f > "${SUDO_USER_HOME}/.vnc/passwd"
chmod 600 "${SUDO_USER_HOME}/.vnc/passwd"
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.vnc/passwd"

# VNC config - 24-bit color, optimized resolution for Pi4
cat > "${SUDO_USER_HOME}/.vnc/config" << 'EOF'
# TigerVNC configuration
geometry=1280x720
depth=24
dpi=96
localhost=no
alwaysshared=yes
EOF
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.vnc/config"

# VNC xstartup script - launches XFCE4 properly
cat > "${SUDO_USER_HOME}/.vnc/xstartup" << 'XSTARTUP'
#!/bin/bash

# Clean up lock files from previous sessions
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Ensure desktop apps launched from VNC inherit the expected X11 runtime state
export XAUTHORITY=$HOME/.Xauthority
export DISPLAY=:1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.vnc/runtime}"
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Fix color scheme / GTK warnings
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export XDG_CONFIG_DIRS=/etc/xdg
export GTK_THEME=Adwaita
export NO_AT_BRIDGE=1
export GTK_A11Y=none

# D-Bus session (prevents "Could not connect to session bus" errors)
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  eval $(dbus-launch --sh-syntax --exit-with-session)
  export DBUS_SESSION_BUS_ADDRESS
fi

# Set cursor and background
xsetroot -solid "#2d2d2d" -cursor_name left_ptr 2>/dev/null

# Disable screen saver / power management (useless over VNC)
xset -dpms 2>/dev/null
xset s off 2>/dev/null

# Start polkit agent (prevents auth popups failing)
/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 &

# Start XFCE4
exec startxfce4
XSTARTUP

chmod 755 "${SUDO_USER_HOME}/.vnc/xstartup"
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.vnc/xstartup"

echo "  VNC configured (password set, 1280x720 @ 24-bit)"

# ──────────────────────────────────────────────
# Step 5: Fix common Pi4 + VNC issues
# ──────────────────────────────────────────────
echo ""
echo "[5/6] Applying Pi4 + VNC fixes..."

# Fix XFCE color scheme - create proper config to avoid "Failed to load theme" errors
sudo -u "${SUDO_USER_NAME}" mkdir -p "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"

cat > "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
    <property name="EnableInputFeedbackSounds" type="bool" value="false"/>
    <property name="SoundThemeName" type="string" value=""/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="none"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="ColorScheme" type="string" value=""/>
    <property name="CursorThemeSize" type="int" value="24"/>
    <property name="DecorationLayout" type="string" value="menu:minimize,maximize,close"/>
    <property name="FontName" type="string" value="DejaVu Sans 10"/>
  </property>
</channel>
EOF
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"

# Window manager theme
cat > "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="use_compositing" type="bool" value="false"/>
    <property name="vblank_mode" type="string" value="off"/>
  </property>
</channel>
EOF
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"

# Disable compositing (no GPU acceleration over VNC, saves CPU)
# Also fix panel config to avoid errors
cat > "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="FailsafeSessionName" type="string" value="Failsafe"/>
    <property name="LockCommand" type="string" value=""/>
  </property>
</channel>
EOF
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml"

# Fix ownership of entire config tree
chown -R "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.config"

# Firefox VNC-friendly config (disable GPU accel, hardware decoding)
sudo -u "${SUDO_USER_NAME}" mkdir -p "${SUDO_USER_HOME}/.mozilla/firefox"
FIREFOX_PROFILE_DIR="${SUDO_USER_HOME}/.mozilla/firefox/vnc.default-release"
sudo -u "${SUDO_USER_NAME}" mkdir -p "${FIREFOX_PROFILE_DIR}"

cat > "${FIREFOX_PROFILE_DIR}/user.js" << 'EOF'
// VNC-optimized Firefox settings
user_pref("layers.acceleration.disabled", true);
user_pref("gfx.webrender.all", false);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("widget.use-xdg-desktop-portal", false);
user_pref("browser.tabs.remote.autostart", false);
user_pref("browser.aboutConfig.showWarning", false);
EOF
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${FIREFOX_PROFILE_DIR}/user.js"

# Create Firefox profiles.ini if it doesn't exist
if [ ! -f "${SUDO_USER_HOME}/.mozilla/firefox/profiles.ini" ]; then
cat > "${SUDO_USER_HOME}/.mozilla/firefox/profiles.ini" << 'EOF'
[Profile0]
Name=default-release
IsRelative=1
Path=vnc.default-release
Default=1

[General]
StartWithLastProfile=1
Version=2
EOF
chown "${SUDO_USER_NAME}:${SUDO_USER_NAME}" "${SUDO_USER_HOME}/.mozilla/firefox/profiles.ini"
fi

echo "  Color scheme, GTK themes, compositing, and browser fixes applied"

# ──────────────────────────────────────────────
# Step 6: Create systemd service for VNC
# ──────────────────────────────────────────────
echo ""
echo "[6/6] Creating VNC systemd service..."

cat > /etc/systemd/system/vncserver@.service << EOF
[Unit]
Description=TigerVNC Server for display :%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SUDO_USER_NAME}
Group=${SUDO_USER_NAME}
WorkingDirectory=${SUDO_USER_HOME}

ExecStartPre=/bin/sh -c '/usr/bin/tigervncserver -kill :%i > /dev/null 2>&1 || :'
ExecStart=/usr/bin/tigervncserver -fg :%i
ExecStop=/usr/bin/tigervncserver -kill :%i

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vncserver@1.service
systemctl start vncserver@1.service

# Wait a moment and verify
sleep 3
VNC_STATUS=$(systemctl is-active vncserver@1.service 2>/dev/null || echo "failed")

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================"
echo "  VNC Desktop Setup Complete"
echo "============================================"
echo ""
echo "  Status:     ${VNC_STATUS}"
echo "  Display:    :1 (port 5901)"
echo "  Resolution: 1280x720 @ 24-bit color"
echo "  Desktop:    XFCE4"
echo "  Browser:    Firefox"
echo ""
echo "  Connect with any VNC client:"
echo "    ${SERVER_IP}:5901"
echo "    VNC password: ${VNC_PASSWORD}"
echo ""
if [ "${VNC_STATUS}" != "active" ]; then
  echo "  WARNING: VNC service may not have started yet."
  echo "  Check: sudo systemctl status vncserver@1"
  echo "  Logs:  journalctl -u vncserver@1 -n 20"
fi
echo ""
echo "  Management:"
echo "    Start:   sudo systemctl start vncserver@1"
echo "    Stop:    sudo systemctl stop vncserver@1"
echo "    Restart: sudo systemctl restart vncserver@1"
echo "    Logs:    journalctl -u vncserver@1 -f"
