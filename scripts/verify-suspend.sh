#!/usr/bin/env bash
# verify-suspend.sh — sanity-check the s2idle / suspend-then-hibernate config on the G14.
# Covers README issues #1 (short-cycle resume) and #2 (long-suspend hibernate).
# Read-only: makes no changes. Run as your normal user.

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

echo "== NVIDIA s0ix / VRAM preservation (issue #1) =="
check "NVreg_EnableS0ixPowerManagement is live (=1)" \
    "grep -q 'EnableS0ixPowerManagement: 1' /proc/driver/nvidia/params 2>/dev/null"
check "nvidia-suspend.service enabled"  "systemctl is-enabled -q nvidia-suspend.service"
check "nvidia-resume.service enabled"   "systemctl is-enabled -q nvidia-resume.service"
check "nvidia-hibernate.service enabled" "systemctl is-enabled -q nvidia-hibernate.service"
check "nvidia-power.conf present"        "test -f /etc/modprobe.d/nvidia-power.conf"

echo "== Long-suspend / hibernate (issue #2) =="
check "eDP PSR disabled on cmdline (amdgpu.dcdebugmask=0x10)" \
    "grep -q 'amdgpu.dcdebugmask=0x10' /proc/cmdline"
check "resume= present on cmdline"        "grep -q 'resume=' /proc/cmdline"
check "resume_offset present on cmdline"  "grep -q 'resume_offset=' /proc/cmdline"
check "lid switch = suspend-then-hibernate" \
    "grep -rqi 'HandleLidSwitch=suspend-then-hibernate' /etc/systemd/logind.conf.d/ 2>/dev/null"
check "HibernateDelaySec configured" \
    "grep -rqi 'HibernateDelaySec=' /etc/systemd/sleep.conf.d/ 2>/dev/null"
check "swap active (for hibernate)" "test -n \"\$(swapon --noheadings 2>/dev/null)\""

echo "== Platform =="
check "sleep mode is s2idle" "grep -q '\\[s2idle\\]' /sys/power/mem_sleep"

echo
echo "Tip: after a long lid-close, confirm hibernation actually fired with:"
echo "  journalctl -b -1 | grep -E 'PM: hibernation|Reached target Hibernate'"
