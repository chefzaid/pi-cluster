#!/bin/bash
# Node Memory & Performance Tuning (Raspberry Pi 4, 4 GB, K3s)
# ============================================================
# Idempotent; safe to re-run. Applies to servers and agents (auto-detected):
#   1. zram swap (zstd, up to 2 GB) + swap-friendly VM sysctls
#   2. Kubelet LimitedSwap - Burstable pods may swap a share proportional to
#      their memory request; Guaranteed/critical pods never swap
#   3. K3s Go memory limit (GOMEMLIMIT) and no swap for the K3s/containerd
#      cgroup (Go GC scans its whole heap, and etcd needs low latency)
#   4. Disable daemons a headless K3s node does not need
#   5. noatime on the root filesystem (fewer SD card writes)
#   6. Smaller GPU reservations in config.txt (CMA 64 MB, gpu_mem 16 MB)
#      - takes effect on next reboot
#
# Usage: sudo bash node-tuning.sh [--no-restart]
#   --no-restart  write the K3s/kubelet changes but do not restart K3s
#                 (they apply on the next K3s restart or reboot)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

RESTART_K3S=true
[ "${1:-}" = "--no-restart" ] && RESTART_K3S=false

if [ -n "$(systemctl list-unit-files k3s.service --no-legend 2>/dev/null)" ]; then
  K3S_UNIT=k3s
  GOMEMLIMIT_VALUE=400MiB   # server: apiserver + etcd + controllers in one process
else
  K3S_UNIT=k3s-agent
  GOMEMLIMIT_VALUE=160MiB
fi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

echo "=== Node tuning on $(hostname) (${K3S_UNIT}) ==="

# ──────────────────────────────────────────────
# 1. zram swap
# ──────────────────────────────────────────────
echo "[1/6] zram swap"
if ! dpkg -s systemd-zram-generator >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq systemd-zram-generator >/dev/null
fi
cat > /etc/systemd/zram-generator.conf <<'EOF'
# Compressed swap in RAM (~3:1 with zstd), managed by systemd-zram-generator
[zram0]
zram-size = min(ram / 2, 2048)
compression-algorithm = zstd
swap-priority = 100
EOF
cat > /etc/sysctl.d/99-pi-cluster-memory.conf <<'EOF'
# zram swap is cheap compared to dropping hot page cache or OOM-killing pods
vm.swappiness = 100
# zram has no seek cost; read-ahead of swap pages only wastes CPU
vm.page-cluster = 0
# Start background reclaim earlier, so allocations rarely stall in direct reclaim
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
# Required by K3s pod networking
net.ipv4.ip_forward = 1
EOF
sysctl -q -p /etc/sysctl.d/99-pi-cluster-memory.conf
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service
swapon --show=NAME,SIZE,USED,PRIO | sed 's/^/  /'

# ──────────────────────────────────────────────
# 2. Kubelet LimitedSwap (K3s reads kubelet config drop-ins from this dir)
# ──────────────────────────────────────────────
echo "[2/6] kubelet LimitedSwap"
KUBELET_DROPIN_DIR=/var/lib/rancher/k3s/agent/etc/kubelet.conf.d
mkdir -p "$KUBELET_DROPIN_DIR"
cat > "$KUBELET_DROPIN_DIR/10-pi-cluster-swap.conf" <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
memorySwap:
  swapBehavior: LimitedSwap
EOF
chmod 600 "$KUBELET_DROPIN_DIR/10-pi-cluster-swap.conf"

# ──────────────────────────────────────────────
# 3. K3s memory limit (also inherited by the embedded containerd)
# ──────────────────────────────────────────────
echo "[3/6] ${K3S_UNIT} GOMEMLIMIT=${GOMEMLIMIT_VALUE}, no swap"
mkdir -p "/etc/systemd/system/${K3S_UNIT}.service.d"
cat > "/etc/systemd/system/${K3S_UNIT}.service.d/10-pi-cluster-memory.conf" <<EOF
[Service]
# Soft cap: the Go GC works harder near this value instead of letting the heap
# grow to 2x the live set (k3s-server otherwise sits at 500-750 MB on a Pi)
Environment=GOMEMLIMIT=${GOMEMLIMIT_VALUE}
# Keep K3s/etcd/containerd out of swap; pods have their own cgroups
MemorySwapMax=0
EOF
systemctl daemon-reload

# ──────────────────────────────────────────────
# 4. Disable unneeded daemons
# ──────────────────────────────────────────────
echo "[4/6] Disabling unneeded daemons"
# fwupd: firmware updates for desktop peripherals (50-100 MB RSS)
# ModemManager: cellular modems; udisks2: desktop disk automount
# iscsid: iSCSI initiator (OpenEBS LocalPV hostpath does not need it)
# rsyslog: duplicates journald and doubles log writes to the SD card
for unit in fwupd.service fwupd-refresh.timer fwupd-refresh.service \
            ModemManager.service udisks2.service \
            iscsid.service iscsid.socket open-iscsi.service \
            rsyslog.service syslog.socket; do
  if [ -n "$(systemctl list-unit-files "$unit" --no-legend 2>/dev/null)" ]; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || true
    echo "  masked $unit"
  fi
done
# snapd: remove only when no snaps besides the base/snapd snaps are installed
if command -v snap >/dev/null 2>&1; then
  OTHER_SNAPS=$(snap list 2>/dev/null | awk 'NR>1 && $1 !~ /^(snapd|core[0-9]*|bare)$/ {print $1}')
  if [ -z "$OTHER_SNAPS" ]; then
    apt-get purge -y -qq snapd >/dev/null
    rm -rf /var/cache/snapd /root/snap
    echo "  purged snapd (no snaps in use)"
  else
    echo "  keeping snapd (snaps in use: $(echo $OTHER_SNAPS | tr '\n' ' '))"
  fi
fi

# ──────────────────────────────────────────────
# 5. noatime on /
# ──────────────────────────────────────────────
echo "[5/6] noatime on /"
if awk '$2=="/" && $4 !~ /noatime/ {found=1} END {exit !found}' /etc/fstab; then
  cp -p /etc/fstab /etc/fstab.bak-pi-cluster
  awk 'BEGIN{OFS="\t"} $2=="/" && $4 !~ /noatime/ {$4=$4",noatime"} {print}' /etc/fstab.bak-pi-cluster > /etc/fstab
fi
mount -o remount,noatime /
echo "  $(findmnt -no OPTIONS /)"

# ──────────────────────────────────────────────
# 6. GPU memory reservations (next reboot)
# ──────────────────────────────────────────────
echo "[6/6] GPU memory reservations in config.txt"
CONFIG_TXT=/boot/firmware/config.txt
if [ -f "$CONFIG_TXT" ]; then
  [ -f "${CONFIG_TXT}.bak-pi-cluster" ] || cp -p "$CONFIG_TXT" "${CONFIG_TXT}.bak-pi-cluster"
  # The KMS overlay defaults to a 512 MB CMA pool on a Pi 4; a headless node or
  # a software-rendered VNC desktop needs far less
  sed -i -E 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,cma-64/' "$CONFIG_TXT"
  # gpu_mem=16 boots the cut-down firmware (no camera/codecs); only set it when
  # that firmware is present in every boot location in use
  CD_OK=true
  for d in /boot/firmware /boot/firmware/current; do
    [ -d "$d" ] || continue
    [ -f "$d/start4cd.elf" ] && [ -f "$d/fixup4cd.dat" ] || CD_OK=false
  done
  if [ "$CD_OK" = true ] && ! grep -q '^gpu_mem=' "$CONFIG_TXT"; then
    sed -i -E '/^\[pi4\]$/a gpu_mem=16' "$CONFIG_TXT"
  fi
  grep -nE '^(dtoverlay=vc4-kms-v3d|gpu_mem=|\[pi4\])' "$CONFIG_TXT" | sed 's/^/  /'
fi

# ──────────────────────────────────────────────
# Apply K3s changes
# ──────────────────────────────────────────────
if [ "$RESTART_K3S" = true ]; then
  echo "Restarting ${K3S_UNIT} (running pods are not affected)"
  # Detached, so this works even when launched through this node's kubelet
  systemd-run --quiet --unit="pi-cluster-k3s-restart-$$" --on-active=3 /bin/systemctl restart "${K3S_UNIT}"
else
  echo "K3s restart skipped; changes apply on next ${K3S_UNIT} restart"
fi
echo "=== Node tuning done (GPU changes apply after reboot) ==="
