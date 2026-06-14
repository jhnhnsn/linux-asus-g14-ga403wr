#!/bin/bash
# Root-cause fix for the G14 (GA403WR) s2idle resume wedge.
#
# During deep s2idle the EC dispatches an ACPI D-notifier (Notify 0xD4) to PEGP
# (the dGPU). The still-bound nvidia driver fails to handle it:
#   NVRM: RmHandleDNotifierEvent: Failed to handle ACPI D-Notifier event, status=0x11
# which triggers a spurious wake and INTERMITTENTLY wedges resume (confirmed
# 2026-06-14 via amd-s2idle replay). cardwire-Integrated only blocks the device
# NODES, leaving nvidia bound, so the dGPU keeps receiving these events. (supergfxctl
# removed the card from the PCI bus, which is why it didn't have this problem.)
#
# Fix: unload the nvidia stack before sleep so the dGPU is driverless during s2idle
# (no NVRM handler -> the PEGP notify is harmless), reload it on resume.
#
# FAIL-OPEN: every step is best-effort; we always exit 0 so a failed unload can
# never block or wedge suspend. Whether the unload actually succeeded is logged to
# /var/log/suspend-s0ix.log (nvidia_mods=0 means the dGPU went driverless).
LOG=/var/log/suspend-s0ix.log
case "$1" in
  pre)
    systemctl stop nvidia-powerd 2>/dev/null
    for m in nvidia_drm nvidia_uvm nvidia_modeset nvidia_wmi_ec_backlight nvidia; do
      modprobe -r "$m" 2>/dev/null
    done
    echo "$(date '+%F %T') nvidia-teardown pre  ($2): nvidia_mods=$(lsmod | grep -c '^nvidia')" >> "$LOG"
    ;;
  post)
    # deps pull in nvidia + nvidia_modeset automatically
    modprobe nvidia_drm 2>/dev/null
    modprobe nvidia_uvm 2>/dev/null
    modprobe nvidia_wmi_ec_backlight 2>/dev/null
    systemctl start nvidia-powerd 2>/dev/null
    echo "$(date '+%F %T') nvidia-teardown post ($2): nvidia_mods=$(lsmod | grep -c '^nvidia')" >> "$LOG"
    ;;
esac
exit 0
