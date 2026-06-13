#!/usr/bin/env bash
# niri-recover.sh — recover a wedged niri session on the ASUS G14.
#
# Symptom this fixes (README issue #3): after a VT switch, niri fails to re-acquire
# the AMD iGPU, stops rendering but stays alive holding its single-instance lock, so
# tuigreet login is refused with "another niri session is already running".
#
# Run from another VT (Ctrl+Alt+F2) or over SSH. Needs root (uses sudo if not root).
set -euo pipefail

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

TARGET_USER="${SUDO_USER:-${1:-$USER}}"

echo ">> Checking for wedged niri processes (user: $TARGET_USER)..."
if pgrep -u "$TARGET_USER" -x niri >/dev/null 2>&1; then
    echo "   Confirming the page-flip wedge in the journal:"
    $SUDO journalctl "_UID=$(id -u "$TARGET_USER")" -b --no-pager 2>/dev/null \
        | grep -m1 'Page flip commit failed' || echo "   (no page-flip error found — recovering anyway)"

    echo ">> Killing niri / niri-session to release the lock..."
    $SUDO pkill -TERM -u "$TARGET_USER" -x niri 2>/dev/null || true
    $SUDO pkill -TERM -u "$TARGET_USER" -x niri-session 2>/dev/null || true
    sleep 3
    $SUDO pkill -KILL -u "$TARGET_USER" -x niri 2>/dev/null || true
    sleep 1
else
    echo "   No niri process found — will just refresh the greeter."
fi

echo ">> Restarting greetd for a clean tuigreet login on VT1..."
$SUDO systemctl restart greetd
sleep 2

echo ">> Switching display to VT1..."
$SUDO chvt 1 || true

echo
echo "Done. Log in at the tuigreet screen on VT1 — niri should start cleanly."
