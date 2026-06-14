#!/usr/bin/env bash
# disable-rog-boot-animation.sh — toggle the ASUS ROG firmware boot animation + chime
# via the UEFI variable AsusAnimationSetupConfig. See docs/rog-boot-logo-efivar.md.
#
#   *** EXPERIMENTAL / UNVERIFIED ***
# The byte semantics are an educated guess (no HII map). Flipping the flag may disable the
# animation, the chime, both, or nothing. Risk is low — it's the same NV var the BIOS setup
# menu writes; worst case is "no effect" or a BIOS "Load Optimized Defaults" to recover —
# but it IS firmware, so this always backs up the exact bytes first.
#
# Usage:
#   sudo ./disable-rog-boot-animation.sh            # back up, then write data 00 00 00 (flag off)
#   sudo ./disable-rog-boot-animation.sh --show     # just print the current value, no changes
#   sudo ./disable-rog-boot-animation.sh --restore  # write the original 00 01 00 back
#   sudo ./disable-rog-boot-animation.sh --write HH HH HH   # write arbitrary 3 data bytes (hex)
#
# Reboot after a write to observe the effect. Log results in docs/rog-boot-logo-efivar.md.
set -euo pipefail

VAR=/sys/firmware/efi/efivars/AsusAnimationSetupConfig-607005d5-3f75-4b2e-98f0-85ba66797a3e
BAK="${HOME}/AsusAnimationSetupConfig.bak"
ATTRS='\x07\x00\x00\x00'   # NV + BootService + Runtime — must be preserved on every write

[ -e "$VAR" ] || { echo "error: $VAR not present (not booted UEFI? wrong firmware?)" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (writes a firmware NV variable). Re-run with sudo." >&2
    exit 1
fi

show() { echo "current:"; hexdump -C "$VAR"; }

write_data() {  # $1 $2 $3 = three data bytes in hex (e.g. 00 00 00)
    local b0="$1" b1="$2" b2="$3"
    # Back up first (only if we don't already have one).
    if [ ! -f "$BAK" ]; then cp "$VAR" "$BAK"; echo "backed up original -> $BAK"; fi
    chattr -i "$VAR" 2>/dev/null || true   # efivars are immutable by default
    printf "${ATTRS}\\x${b0}\\x${b1}\\x${b2}" > "$VAR"
    echo "wrote data: $b0 $b1 $b2"
    show
    echo "--> reboot to observe. Restore with: sudo $0 --restore"
}

case "${1:-}" in
    --show)    show ;;
    --restore) write_data 00 01 00 ;;   # original value captured 2026-06-13
    --write)   write_data "${2:?need 3 hex bytes}" "${3:?}" "${4:?}" ;;
    "")        echo "before:"; show; echo; write_data 00 00 00 ;;
    *)         echo "unknown arg: $1 (see header for usage)" >&2; exit 2 ;;
esac
