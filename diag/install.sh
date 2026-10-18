#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install / uninstall the g14-diag toolkit. Run as root from the repo:
#   sudo diag/install.sh                  # everything
#   sudo diag/install.sh --without-guard  # everything except the fail-closed sleep guard
#   sudo diag/install.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

OLD_HOOK=/usr/lib/systemd/system-sleep/80-nvidia-teardown.sh
BACKUP=/usr/local/lib/g14-diag/backup
GUARD_UNITS="g14-nvidia-teardown.service g14-nvidia-reload.service"

uninstall() {
  systemctl disable g14-diag-collect.service $GUARD_UNITS 2>/dev/null || true
  systemctl --global disable g14-diag-watch.service 2>/dev/null || true
  rm -f /etc/systemd/system/g14-diag-collect.service /etc/systemd/system/g14-nvidia-{teardown,reload}.service \
        /etc/systemd/user/g14-diag-watch.service /etc/pacman.d/hooks/95-g14-diag-reboot-check.hook \
        /etc/journald.conf.d/50-g14-diag.conf /etc/sysctl.d/50-g14-diag.conf /usr/local/bin/g14-diag
  if [ -e "$BACKUP/80-nvidia-teardown.sh" ] && [ ! -e "$OLD_HOOK" ]; then
    install -m 755 "$BACKUP/80-nvidia-teardown.sh" "$OLD_HOOK" && echo "restored $OLD_HOOK"
  fi
  systemctl daemon-reload; systemctl restart systemd-journald; sysctl --system >/dev/null
  echo "uninstalled (kept /etc/g14-diag.conf, bundles in /var/log/g14-diag, systemd-pstore enabled)"
}

case "${1:-}" in --uninstall) uninstall; exit 0 ;; esac
WITH_GUARD=1; [ "${1:-}" = --without-guard ] && WITH_GUARD=0

# CLI + config
install -D -m 755 g14-diag /usr/local/bin/g14-diag
[ -e /etc/g14-diag.conf ] || install -m 644 g14-diag.conf /etc/g14-diag.conf
# shellcheck source=/dev/null
. /etc/g14-diag.conf
install -d -m 2770 -g "${DIAG_GROUP:-wheel}" "${DIAG_DIR:-/var/log/g14-diag}" "${DIAG_DIR:-/var/log/g14-diag}/live"

# 1. stop losing evidence
install -D -m 644 etc/journald.conf.d/50-g14-diag.conf /etc/journald.conf.d/50-g14-diag.conf
install -D -m 644 etc/sysctl.d/50-g14-diag.conf /etc/sysctl.d/50-g14-diag.conf
systemctl restart systemd-journald
sysctl --system >/dev/null
systemctl enable systemd-pstore.service

# 2. reboot-needed warning after kernel/NVIDIA upgrades
install -D -m 644 pacman/95-g14-diag-reboot-check.hook /etc/pacman.d/hooks/95-g14-diag-reboot-check.hook

# 3. per-boot bundle, 4. live watcher
install -m 644 systemd/g14-diag-collect.service /etc/systemd/system/
install -D -m 644 systemd/user/g14-diag-watch.service /etc/systemd/user/g14-diag-watch.service
systemctl daemon-reload
systemctl enable g14-diag-collect.service
systemctl --global enable g14-diag-watch.service

# fail-closed sleep guard (replaces the fail-open 80-nvidia-teardown.sh hook)
if [ "$WITH_GUARD" = 1 ]; then
  install -m 644 systemd/g14-nvidia-teardown.service systemd/g14-nvidia-reload.service /etc/systemd/system/
  if [ -e "$OLD_HOOK" ]; then
    install -d "$BACKUP"; mv "$OLD_HOOK" "$BACKUP/" && echo "moved old hook to $BACKUP/"
  fi
  systemctl daemon-reload
  systemctl enable $GUARD_UNITS
fi

echo
echo "installed. Next:"
echo "  - start the watcher in your session:  systemctl --user start g14-diag-watch.service"
echo "  - bundle the last boot now:           sudo g14-diag collect -1"
echo "  - check health any time:              g14-diag status"
[ "$WITH_GUARD" = 1 ] && echo "  - sleep guard is ENFORCING: sleep is refused while anything holds the NVIDIA GPU"
exit 0
