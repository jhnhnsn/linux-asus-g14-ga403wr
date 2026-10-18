# g14-diag — catch every freeze with evidence attached

A small toolkit that turns "the laptop was dead this morning" into a diagnosis. It was built
after a hang (README issue #12) where the evidence was nearly lost: the journal was capped at
50 MB (about 4 days), crash records weren't being archived, and the sleep hook failed silently.

Everything stays **on your machine**. Bundles contain full system logs, including hostnames,
IP and MAC addresses, app names and window titles. Nothing here uploads anything. If you
share a log in an issue, quote only the lines you need.

## What it does

| Layer | Piece | Effect |
|---|---|---|
| Don't lose evidence | `etc/systemd/journald.conf.d/50-g14-diag.conf` | journal keeps 1 GB (months) and syncs every 15 s instead of every 5 min. Overrides CachyOS's default `SystemMaxUse=50M` |
| | `systemd-pstore.service` enabled | kernel panic records saved to `/var/lib/systemd/pstore` |
| | `etc/sysctl.d/50-g14-diag.conf` | soft lockups panic (so they leave a crash record); full Magic SysRq |
| Prevent known wedges | `g14-nvidia-teardown.service` / `-reload.service` | **fail-closed** replacement for `80-nvidia-teardown.sh`: unloads NVIDIA before sleep and **refuses the sleep** if it can't, or if the loaded driver no longer matches the installed one |
| | `pacman/95-g14-diag-reboot-check.hook` | after a kernel/NVIDIA upgrade: terminal + desktop warning to reboot before sleeping |
| Per-boot bundle | `g14-diag-collect.service` | at every boot, writes `/var/log/g14-diag/<date>_boot-<id>/` describing how the previous boot ended |
| Live alarm | `g14-diag-watch.service` (user) | desktop notification + state snapshot the moment an Xid / GPU timeout / hung task is logged |

### A bundle

```
summary.txt            verdict + the counts that matter — read this first
tail.log               last 300 journal lines (firewall spam filtered)
kernel-errors.log      every NVRM/Xid/amdgpu/lockup/BUG line from that boot
sleep.log              lid, power key, suspend/resume/hibernate events
nvidia-teardown.log    nvidia_mods= results per sleep (pre should be 0) and refused sleeps
packages.log           packages changed during that boot (= running without a reboot)
coredumps.txt          crashed processes
pstore/                kernel panic records (bad boots only)
state-at-next-boot.txt MUX mode, driver versions, who holds the dGPU
notes.txt              what you saw (g14-diag note "...")
```

Verdicts are `clean shutdown/reboot`, `HARD RESET or power loss`, or `KERNEL PANIC`. A bad
verdict can add `died DURING sleep/resume` or `Ns after resuming from sleep`. A boot that
ended cleanly is still flagged bad if it logged a fatal Xid (31, 79, 154, ...).

For example, the 2026-10-18 hang, collected after the fact:

```
VERDICT   : HARD RESET or power loss (journal ends with no shutdown sequence) — 0s after resuming from sleep
teardown  : post nvidia_mods=5 ×2; pre nvidia_mods=5 ×3; (healthy: pre nvidia_mods=0)
GPU faults: Xid 13 ×62, Xid 31 ×1, Xid 154 ×1,  — FATAL Xid: 154 31
!! 12 NVRM 'API mismatch' lines — userspace driver upgraded under a running module (reboot needed)
packages upgraded during this boot (no reboot after):
  2026-10-17T15:43:05-0700 upgraded nvidia-utils (615.71.09-1 -> 615.78.08-2)
```

## Install

```bash
sudo diag/install.sh                  # everything
sudo diag/install.sh --without-guard  # everything except the sleep guard
sudo diag/install.sh --uninstall      # restores the old 80-nvidia-teardown.sh hook
systemctl --user start g14-diag-watch.service
```

Settings live in `/etc/g14-diag.conf`: bundle dir, the group allowed to read bundles
(`wheel`), retention, and `GUARD_MODE`.

> ⚠️ **In dGPU-direct MUX mode (`gpu_mux_mode=0`) the guard refuses every sleep**, because the
> compositor is running on NVIDIA and it can never be unloaded. That's deliberate: sleeping
> in that state is what wedged this machine (issue #11). Switch the MUX to hybrid, or set
> `GUARD_MODE=warn` if you accept the risk.

## Use

```bash
g14-diag status                 # versions, MUX mode, panel GPU, dGPU power, who holds NVIDIA
g14-diag latest                 # summary of the newest bundle
g14-diag pending                # bad boots not yet reviewed
g14-diag note "black screen after lid open, caps lock still toggled"
g14-diag ack all                # mark reviewed
```

### When it freezes (before you hold the power button)

1. Note the time and what you see: black or frozen screen, fans, keyboard backlight.
   Does Caps Lock still toggle its light?
2. Try **Ctrl+Alt+F3**. If a text console appears, the kernel is alive and the compositor hung.
3. If not, press **Alt+SysRq+W** (dumps blocked tasks to the log), wait 5 s, then
   **Alt+SysRq+C** (forces a panic, which writes a crash record and reboots).
4. SSH in from another device if you can.
5. After reboot: `g14-diag note "what you saw"`.

## Hooking it to an AI assistant (optional)

`g14-diag pending --claude` prints nothing on healthy boots and a short briefing when there's
an unreviewed bad boot. You can wire it into a Claude Code `SessionStart` hook in
`~/.claude/settings.json`:

```json
{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "g14-diag pending --claude" } ] } ] } }
```

The next session then opens with the incident summary already in context.
