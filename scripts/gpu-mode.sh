#!/usr/bin/env bash
# gpu-mode.sh — switch the GA403WR between supergfxctl Integrated and Hybrid GPU modes,
# working around the fact that supergfxd's logout-based switching never completes under
# greetd (its 30s WaitLogout never sees a clean logout — see README issue #7).
#
# Instead of relying on the logout flow, this stops the graphical session, frees + unloads
# the dGPU, lets supergfxd apply the new mode in a clean window, then brings the session back.
#
# Usage:  sudo ./gpu-mode.sh integrated   # dGPU OFF (daily driver: clean suspend, best battery)
#         sudo ./gpu-mode.sh hybrid       # dGPU ON  (gaming via prime-run, HDMI output)
#         ./gpu-mode.sh status            # show current mode + dGPU state (no root needed)
#
# Run it from a TTY (Ctrl+Alt+F2), NOT from a terminal inside the desktop you're about to kill.
# After switching, the desktop comes back; if the DMS bar/launcher is missing, run
# scripts/dms-restart.sh (README issue #5).

set -euo pipefail

DGPU=0000:64:00.0
USERNAME=jhnhnsn
UID_NUM=1000

die() { echo "error: $*" >&2; exit 1; }

dgpu_state() {
    if [ -e "/sys/bus/pci/devices/$DGPU" ]; then
        echo "present (D-state $(cat /sys/bus/pci/devices/$DGPU/power_state 2>/dev/null))"
    else
        echo "removed from PCI bus (powered off)"
    fi
}

status() {
    echo "supergfxctl mode : $(supergfxctl -g 2>/dev/null)"
    echo "nvidia module    : $(lsmod | grep -q '^nvidia ' && echo loaded || echo 'not loaded')"
    echo "dGPU ($DGPU): $(dgpu_state)"
}

[ "${1:-}" = "status" ] && { status; exit 0; }
[ "$(id -u)" -eq 0 ] || die "switching needs root: sudo $0 $*"

case "${1:-}" in
    integrated|Integrated) MODE=Integrated ;;
    hybrid|Hybrid)         MODE=Hybrid ;;
    *) die "usage: $0 {integrated|hybrid|status}" ;;
esac

CUR=$(supergfxctl -g 2>/dev/null || echo unknown)
if [ "$CUR" = "$MODE" ]; then echo "already in $MODE; nothing to do."; status; exit 0; fi

echo "==> switching $CUR -> $MODE (the desktop will go down briefly)"

# 1. Tear down the graphical session so nothing holds the dGPU.
systemctl stop greetd 2>/dev/null || true
sleep 2
# kill any orphaned compositor/clients greetd left behind
pkill -TERM -u "$USERNAME" -x niri 2>/dev/null || true
pkill -TERM -u "$USERNAME" -x qs 2>/dev/null || true
pkill -TERM -u "$USERNAME" -x Xwayland 2>/dev/null || true
pkill -TERM -u "$USERNAME" -x ghostty 2>/dev/null || true
systemctl stop nvidia-powerd.service 2>/dev/null || true
sleep 2

# 2. Unload the nvidia stack (only matters Hybrid->Integrated; harmless otherwise).
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true

# 3. Hand supergfxd a clean window to apply the mode (it removes/rescans the dGPU + writes config).
systemctl stop supergfxd.service 2>/dev/null || true
supergfxctl -m "$MODE" >/dev/null 2>&1 || true   # arm the mode in config
systemctl restart supergfxd.service
sleep 3

# 4. Bring the desktop back.
systemctl start greetd.service
sleep 3

echo "==> done."
status
echo
echo "If the top bar / wallpaper / launcher are missing after you log in, run:"
echo "    ./dms-restart.sh        # (README issue #5)"
