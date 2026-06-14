# The s2idle resume wedge — root cause: nvidia `PEGP` ACPI D-notifier during s0ix

> **TL;DR** The GA403WR's intermittent "closed the lid, came back to a dead/unresponsive
> machine" was **not** an AMD s0ix-depth problem. During deep s2idle the EC dispatches an
> ACPI D-notifier event to `PEGP` (the dGPU); the still-bound nvidia driver fails to handle
> it (`NVRM: RmHandleDNotifierEvent ... status=0x11`), which triggers a spurious wake and
> **intermittently hangs the resume**. Short sleeps don't last long enough to catch one, so
> they always "worked." The fix is to keep the dGPU out of the sleep path entirely —
> **hibernate on lid close** (powers fully off → no s0ix), plus a sleep hook that unloads
> nvidia before any sleep.

## How it presents

- **Short lid close → always fine.** Long / overnight close → machine wedged, force-power
  required. Perfectly duration-dependent.
- Journal of the dead boot **ends at `PM: suspend entry (s2idle)`** with no resume — it died
  asleep. (Our `90-s0ix-debug-log.sh` hook captures a `pre` entry with no matching `post` for
  the same reason.)
- It survived the migration from supergfxctl to **cardwire**, which was the clue: see below.

## The smoking gun

Captured with **`amd-s2idle`** (package `amd-debug-tools`, in `extra`). Replaying a long cycle
that woke early shows, *during* s0ix, right before the spurious wake:

```
ACPI: EC: ACPI EC GPE dispatched
Dispatching Notify on [PEGP] (Device) Value 0xD4 (Hardware-Specific)
NVRM: RmHandleDNotifierEvent: Failed to handle ACPI D-Notifier event, status=0x11
...
PM: Triggering wakeup from IRQ 7 / IRQ 0
ACPI: PM: ACPI non-EC GPE wakeup           # woke via the AMD GPIO controller, NOT the RTC
```

`PEGP` is the ACPI node for the PCIe-graphics port = the **dGPU**. The EC pokes it with a
D-notifier mid-sleep; the bound nvidia driver chokes; a spurious GPIO-controller wake fires;
the (nvidia-laden, ~1.8 s `noirq`) resume path occasionally hangs on the way back.

### What it is NOT

- **Not s0ix depth.** `amd-s2idle` measured **71–98.7% hardware sleep** — residency is
  excellent. The platform sleeps beautifully.
- **Not battery drain, PSR, power-profile, or session-freeze** (those were all investigated
  and ruled out / fixed independently).

## Why cardwire didn't fix it (but supergfxctl had)

Both call their dGPU-off mode "Integrated," but they are **not** equivalent:

| | supergfxctl Integrated | cardwire Integrated |
|---|---|---|
| dGPU on PCI bus | **removed** (`0000:64:00.0` gone) | **present** (D3cold) |
| nvidia driver | unloaded / unbound | **still bound** |
| Receives `PEGP` notify in sleep? | **no** (no device) | **yes** → NVRM fails |

So supergfxctl genuinely made suspend amdgpu-only; cardwire only blocks the dGPU **device
nodes** (eBPF) and leaves nvidia bound, which reintroduced this bug. cardwire is still the
convenient no-reboot GPU switcher for gaming — it just doesn't fix suspend.

## The fix

**1. Lid close → hibernate (S4).** Powers fully off, so there is no s0ix and nothing pokes
`PEGP`. Also zero battery drain while closed. See
[`configs/systemd/logind.conf.d/10-lid-hibernate.conf`](../configs/systemd/logind.conf.d/10-lid-hibernate.conf)
(`HandleLidSwitch=hibernate`, `HandleLidSwitchExternalPower=hibernate`,
`HandleLidSwitchDocked` left unset = `ignore` so clamshell with an external monitor keeps
running). Hibernate prereqs (contiguous swapfile, `resume_offset`, nvidia-out-of-initramfs)
are issue #2 in the README.

> ⚠️ Hibernate powers the machine **off** — opening the lid does **not** wake it. Press the
> **power button** to boot back and resume.

**2. Unload nvidia before any sleep** —
[`configs/systemd/system-sleep/80-nvidia-teardown.sh`](../configs/systemd/system-sleep/80-nvidia-teardown.sh).
On `pre` it stops `nvidia-powerd` and unloads the whole nvidia stack (verified `nvidia_mods`
→ 0); on `post` it reloads. **Fail-open** (always `exit 0`, never blocks suspend). This makes
the dGPU driverless during sleep — no NVRM handler to fail — and so also covers manual
`systemctl suspend` (fast s2idle), not just hibernate.

## Diagnostic tooling left in place

- [`configs/systemd/system-sleep/90-s0ix-debug-log.sh`](../configs/systemd/system-sleep/90-s0ix-debug-log.sh)
  → `/var/log/suspend-s0ix.log`: per-transition s0ix residency, SMU idlemask, armed wake
  sources, dGPU power state. A `pre` with no `post` = the machine died in sleep.
- [`configs/tmpfiles.d/pm-debug.conf`](../configs/tmpfiles.d/pm-debug.conf): persists
  `/sys/power/pm_debug_messages = 1` across boots.
- `amd-debug-tools`:
  - `sudo amd-s2idle test --count 1 --duration 1800 --wait 0 --format txt --report-file /var/log/amd-s2idle.txt`
    runs a controlled cycle + full static/prereq analysis. **Pass `--wait`** or it EOFs when
    run non-interactively.
  - `sudo amd-s2idle report --since <date>` replays prior runs from
    `/var/local/lib/amd-s2idle/data.db`.
  - ⚠️ `amd-s2idle test` suspends via `/sys/power/state` **directly**, bypassing
    `systemd-sleep` hooks — so the teardown/log hooks do **not** run for it. Test real lid
    behavior with an actual lid close.

## Verifying

After a lid-close hibernate + power-on resume:
- `journalctl -b 0 | grep -E "Lid closed|Hibernating|hibernation (entry|exit)"` — shows the
  lid triggered it and it completed.
- Same `boot_id` after wake = true restore (a changed `boot_id` = it cold-booted / resume failed).
- `grep nvidia-teardown /var/log/suspend-s0ix.log` — `pre ... nvidia_mods=0`, `post ... nvidia_mods=5`.
