#!/bin/bash
# Node Cleanup (disk space and leftovers)
# =======================================
# Safe to re-run; keeps everything the running system or a rollback needs:
#   1. logrotate: drop the duplicate cloud-init config (cloud-init and
#      cloud-init-base both ship one, which makes logrotate.service fail)
#   2. apt: autoremove, purge leftover kernel packages and module dirs, clean cache
#      (installed kernels, including the fallback one, are kept)
#   3. snaps: drop disabled revisions, keep at most 2 per snap
#   4. logs: journal vacuum to 100 MB, rotated logs, crash reports
#   5. K3s: K3s binary backups, upgrade downloads, unpacked data of old K3s
#      versions (current/previous and any dir still in use are kept), and
#      container images not used by any container on this node
#
# Usage: sudo bash node-cleanup.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

disk_used() { df -BM --output=used / | tail -1 | tr -dc '0-9'; }
USED_BEFORE=$(disk_used)
echo "=== Cleanup on $(hostname), / used: ${USED_BEFORE} MB ==="

# ──────────────────────────────────────────────
# 1. logrotate duplicate
# ──────────────────────────────────────────────
echo "[1/5] logrotate"
if [ -f /etc/logrotate.d/cloud-init ] && [ -f /etc/logrotate.d/cloud-init-base ]; then
  # Removed conffiles are not restored by dpkg on upgrade
  mv /etc/logrotate.d/cloud-init /root/logrotate.d-cloud-init.bak-pi-cluster
  echo "  removed /etc/logrotate.d/cloud-init (cloud-init-base covers the same logs)"
fi
if logrotate -d /etc/logrotate.conf 2>&1 | grep -q '^error:'; then
  logrotate -d /etc/logrotate.conf 2>&1 | grep '^error:' | sed 's/^/  /'
else
  systemctl reset-failed logrotate.service 2>/dev/null || true
  systemctl start logrotate.service && echo "  logrotate.service: $(systemctl is-active logrotate.service) (ok)"
fi

# ──────────────────────────────────────────────
# 2. apt
# ──────────────────────────────────────────────
echo "[2/5] apt"
apt-get autoremove --purge -y -qq >/dev/null
RC_KERNEL_PKGS=$(dpkg -l | awk '/^rc/ && $2 ~ /^linux-(image|modules|main-modules|headers)-/ {print $2}')
if [ -n "$RC_KERNEL_PKGS" ]; then
  # shellcheck disable=SC2086
  dpkg --purge $RC_KERNEL_PKGS >/dev/null
  echo "  purged $(echo "$RC_KERNEL_PKGS" | wc -l) leftover kernel package configs"
fi
# Module dirs left behind by purged kernels (dpkg records them under /usr/lib)
for dir in /lib/modules/*; do
  ver=$(basename "$dir")
  [ "$ver" = "$(uname -r)" ] && continue
  if ! dpkg -S "/usr/lib/modules/$ver" >/dev/null 2>&1 && ! dpkg -S "/lib/modules/$ver" >/dev/null 2>&1 \
     && ! dpkg-query -W -f='${Status}' "linux-modules-$ver" 2>/dev/null | grep -q 'ok installed'; then
    rm -rf "$dir"
    echo "  removed stale $dir"
  fi
done
apt-get clean
echo "  kernels kept: $(dpkg -l 'linux-image-[0-9]*' | awk '/^ii/{print $2}' | tr '\n' ' ')(running $(uname -r))"

# ──────────────────────────────────────────────
# 3. snaps
# ──────────────────────────────────────────────
echo "[3/5] snaps"
if command -v snap >/dev/null 2>&1 && systemctl is-active --quiet snapd.service; then
  snap set system refresh.retain=2
  snap list --all | awk '/disabled/ {print $1, $3}' | while read -r name rev; do
    snap remove --purge "$name" --revision="$rev" >/dev/null && echo "  removed $name rev $rev"
  done
else
  echo "  snapd not installed"
fi

# ──────────────────────────────────────────────
# 4. logs
# ──────────────────────────────────────────────
echo "[4/5] logs"
journalctl --vacuum-size=100M 2>&1 | tail -1 | sed 's/^/  /'
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
rm -f /var/crash/*
echo "  rotated logs and crash reports removed"

# ──────────────────────────────────────────────
# 5. K3s
# ──────────────────────────────────────────────
echo "[5/5] K3s"
rm -f /usr/local/bin/k3s.v* /usr/local/bin/k3s.bak*
rm -rf /var/tmp/k3s-upgrade
DATA=/var/lib/rancher/k3s/data
KEEP="$(readlink -f "$DATA/current" 2>/dev/null) $(readlink -f "$DATA/previous" 2>/dev/null)"
IN_USE=$(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null || true; done | awk -F/ -v d="$DATA" 'index($0, d"/")==1 {print d"/"$6}' | sort -u)
for dir in "$DATA"/*; do
  [ -d "$dir" ] && [ ! -L "$dir" ] || continue
  case "$(basename "$dir")" in cni) continue ;; esac
  case " $KEEP $IN_USE " in *" $dir "*) continue ;; esac
  rm -rf "$dir"
  echo "  removed old K3s data $(basename "$dir" | cut -c1-12)"
done
if command -v k3s >/dev/null 2>&1; then
  BEFORE=$(k3s crictl images -q 2>/dev/null | wc -l)
  k3s crictl rmi --prune >/dev/null 2>&1 || true
  echo "  images: ${BEFORE} -> $(k3s crictl images -q 2>/dev/null | wc -l)"
fi

USED_AFTER=$(disk_used)
echo "=== Cleanup done, / used: ${USED_AFTER} MB (freed $((USED_BEFORE - USED_AFTER)) MB) ==="
