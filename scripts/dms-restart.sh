#!/usr/bin/env bash
# dms-restart.sh — bring back the DankMaterialShell bar/launcher after it died.
#
# Symptom this fixes (README issue #7): top bar missing and the app launcher
# (Super) does nothing. Usually happens when niri/greetd was restarted by hand
# mid-session and dms.service raced the Wayland socket, crash-looped, and got
# rate-limited by systemd (`start-limit-hit`, `Failed to create wl_display`).
#
# Run as your normal user from inside the graphical session.
set -euo pipefail

if ! systemctl --user cat dms.service >/dev/null 2>&1; then
    echo "dms.service not found for this user — is DMS installed / are you in the session?" >&2
    exit 1
fi

echo ">> dms.service state: $(systemctl --user is-active dms.service 2>/dev/null) / $(systemctl --user is-failed dms.service 2>/dev/null || true)"
echo ">> Clearing failed/rate-limited state and starting DMS..."
systemctl --user reset-failed dms.service
systemctl --user restart dms.service
sleep 4

if pgrep -af 'qs -p /usr/share/quickshell/dms' >/dev/null 2>&1; then
    echo "✓ DMS is up — bar and launcher should be back."
else
    echo "✗ quickshell still not running. Check: journalctl --user -u dms.service -b | tail -30" >&2
    exit 1
fi
