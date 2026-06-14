#!/usr/bin/env bash
# verify-suspend.sh — sanity-check the s2idle / hibernate config on the G14.
# Covers README issues #1 (short-cycle resume) and #2 (lid-close hibernate),
# including the btrfs swapfile single-extent + matching-offset checks.
# Read-only: makes no changes. Run as your normal user (a couple of checks use
# `sudo -n` to read the 0600 swapfile; they degrade to a '?' hint without sudo).

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

echo "== NVIDIA suspend = Path B / kernel suspend-notifier (issue #1) =="
# Path B: do NOT preserve VRAM, do NOT use the nvidia sleep services. See
# docs/nvidia-suspend-path-b.md. These checks are intentionally inverted vs the
# old VRAM-preservation setup.
check "PreserveVideoMemoryAllocations is OFF (=0)" \
    "grep -q 'PreserveVideoMemoryAllocations: 0' /proc/driver/nvidia/params 2>/dev/null"
check "nvidia-suspend.service disabled"   "! systemctl is-enabled -q nvidia-suspend.service"
check "nvidia-resume.service disabled"    "! systemctl is-enabled -q nvidia-resume.service"
check "nvidia-hibernate.service disabled" "! systemctl is-enabled -q nvidia-hibernate.service"
check "nvidia-power.conf present"         "test -f /etc/modprobe.d/nvidia-power.conf"
check "nvidia kept OUT of initramfs (noinitramfs hook)" \
    "test -f /etc/initcpio/install/nvidia-noinitramfs"

echo "== Long-suspend / hibernate (issue #2) =="
check "eDP PSR disabled on cmdline (amdgpu.dcdebugmask=0x10)" \
    "grep -q 'amdgpu.dcdebugmask=0x10' /proc/cmdline"
check "resume= present on cmdline"        "grep -q 'resume=' /proc/cmdline"
check "resume_offset present on cmdline"  "grep -q 'resume_offset=' /proc/cmdline"
check "lid switch = hibernate" \
    "grep -rqi 'HandleLidSwitch=hibernate' /etc/systemd/logind.conf.d/ 2>/dev/null"
check "nvidia-teardown sleep hook installed" \
    "test -x /usr/lib/systemd/system-sleep/80-nvidia-teardown.sh"
check "swap active (for hibernate)" "test -n \"\$(swapon --noheadings 2>/dev/null)\""

echo "== Hibernation swapfile contiguity (issue #2 ⚠️) =="
warn() { printf '  \033[33m?\033[0m %s\n' "$1"; }
SF="$(swapon --noheadings --show=NAME 2>/dev/null | grep -v zram | head -1)"
if [ -z "$SF" ]; then
    fail "no disk swap found (zram alone can't hold a hibernation image)"
else
    # filefrag/map-swapfile need root to read a 0600 swapfile
    FF="$(sudo -n filefrag "$SF" 2>/dev/null || true)"
    if [ -z "$FF" ]; then
        warn "can't read extents of $SF unprivileged — run: sudo filefrag $SF (want '1 extent found')"
    else
        check "swapfile is a single contiguous extent ($SF)" "echo \"$FF\" | grep -q ': 1 extent found'"
    fi
    # the cmdline resume_offset must match the swapfile's actual btrfs offset
    WANT="$(sudo -n btrfs inspect-internal map-swapfile -r "$SF" 2>/dev/null || true)"
    HAVE="$(grep -o 'resume_offset=[0-9]*' /proc/cmdline | cut -d= -f2)"
    if [ -z "$WANT" ]; then
        warn "can't compute expected offset unprivileged — run: sudo btrfs inspect-internal map-swapfile -r $SF"
    else
        check "cmdline resume_offset matches swapfile (want $WANT, have ${HAVE:-none})" "[ \"$WANT\" = \"$HAVE\" ]"
    fi
fi

echo "== Platform =="
check "sleep mode is s2idle" "grep -q '\\[s2idle\\]' /sys/power/mem_sleep"

echo
echo "Tip: after a long lid-close, confirm hibernation actually fired with:"
echo "  journalctl -b -1 | grep -E 'PM: hibernation|Reached target Hibernate'"
