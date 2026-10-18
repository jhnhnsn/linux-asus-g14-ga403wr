# linux-asus-g14-ga403wr

Notes, fixes, and config snapshots for running Linux on an **ASUS ROG Zephyrus G14
(GA403WR)** — AMD Strix Point + NVIDIA dGPU — under **CachyOS**. This is a personal lab notebook —
every entry is something that actually broke on this machine and the fix that resolved it.

> ⚠️ Machine-specific values (partition UUIDs, `resume_offset`, hostname) appear in the
> config snapshots. They document *this* laptop — **regenerate your own** before reusing.

## Current status (2026-10-18)

| | |
|---|---|
| **Lid close** | does **not** sleep — logind ignores it, niri just blanks the panel ([`10-lid-ignore.conf`](configs/systemd/logind.conf.d/10-lid-ignore.conf)) |
| **Suspend / hibernate** | explicit only (power key / menu). Hibernate works with `shutdown` mode (#10) |
| **dGPU during sleep** | must be driverless. The old fail-open hook silently failed twice (#11), so it's being replaced by the fail-closed [g14-diag sleep guard](diag/README.md) |
| **⚠️ MUX** | found in **dGPU-direct** (`gpu_mux_mode=0`): NVIDIA drives the panel, so nothing can unload it (#11). **Switching back to hybrid is the pending fix** |
| **After every kernel/NVIDIA upgrade** | **reboot before sleeping** (#12) |
| **Diagnostics** | [`diag/`](diag/README.md): per-boot incident bundles, live GPU-fault alerts, no lost logs |

Quick health check: [`scripts/verify-suspend.sh`](scripts/verify-suspend.sh) (config) and
`g14-diag status` (live state).

## Hardware / software baseline

| | |
|---|---|
| **Laptop** | ASUS ROG Zephyrus G14 — model **GA403WR** (board `GA403WR`, hostname `cachyos-g14`) |
| **APU** | AMD Strix Point — Ryzen AI 9 HX 370 + Radeon 890M (gfx1150). **Primary display in hybrid MUX mode** (`amdgpu`, panel = `eDP-1`) |
| **dGPU** | NVIDIA RTX 5070 Ti Laptop (Blackwell GB205M), open kernel module — **render-offload in hybrid mode**; drives the panel (`eDP-2`) in dGPU-direct mode (#11) |
| **MUX** | `gpu_mux_mode`: `1` = hybrid, `0` = dGPU-direct. Read it: `cat /sys/class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value` |
| **Sleep** | s2idle-only (`/sys/power/mem_sleep` = `[s2idle]`) — no deep/S3 |
| **Disk** | single btrfs partition, subvols `@` (root), `@home`, nested `@/swap` (NOCOW swapfile) |
| **Boot** | **Limine** (not GRUB/sd-boot) |
| **Desktop** | niri (Wayland) + DankMaterialShell (DMS) · greetd + tuigreet · Ghostty |

---

## Issues & solutions

### 1. NVIDIA dGPU suspend/resume — use the kernel-notifier path, not VRAM preservation

**Symptom(s):** Closing the lid and reopening intermittently killed the desktop. The
*kernel* resumed fine (`SMU is resumed successfully`, `PM: suspend exit`), but the nvidia
driver then melted down restoring its VRAM:
```
NVRM: GPU0 _clientUnmapInterBackRefMappings: Failed to auto-unmap backref (status=0x57)
NVRM: GPU0 nvAssertFailedNoLog: Assertion failed ... rs_client.c / map.c / rs_resource.c
```
A session client holding live nvidia mappings took a `SIGABRT` → black screen. (Separately,
the same heavyweight path aborted *hibernate* with `nv_pmops_freeze returns -5`.)

**Root cause:** we were on NVIDIA's **VRAM-preservation path** — `PreserveVideoMemoryAllocations=1`
+ the `nvidia-suspend/resume/hibernate` systemd services + the `/proc/driver/nvidia/suspend`
interface. That "save & restore *all* VRAM" machinery is the thing that corrupts on resume and
races the initramfs on hibernate. NVIDIA's docs describe a second, **mutually-exclusive** path —
the kernel suspend-notifier callbacks — which *"requires no configuration."* You pick one; mixing
them is what breaks. **Full write-up + sources:** [`docs/nvidia-suspend-path-b.md`](docs/nvidia-suspend-path-b.md).

**Fix — switch to Path B (kernel notifiers):**
1. Disable the VRAM-preservation services:
   ```bash
   sudo systemctl disable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service
   ```
2. Set [`configs/modprobe.d/nvidia-power.conf`](configs/modprobe.d/nvidia-power.conf) to:
   ```
   options nvidia NVreg_PreserveVideoMemoryAllocations=0
   ```
3. Keep nvidia **out of the initramfs** — install hook
   [`configs/initcpio/install/nvidia-noinitramfs`](configs/initcpio/install/nvidia-noinitramfs)
   added last in `HOOKS` (required for hibernate resume; see the hook's own comments).
4. Rebuild + regenerate boot entries, then **reboot** (params are read at module load):
   ```bash
   sudo mkinitcpio -P && sudo limine-update
   ```

**Verify:** `grep PreserveVideoMemoryAllocations /proc/driver/nvidia/params` → `0`;
`systemctl is-enabled nvidia-suspend.service` → `disabled`. A healthy resume logs
`amdgpu: SMU is resumed successfully!` / `PM: suspend exit` with **no** `NVRM ... nvAssertFailed`
storm afterward.

**Trade-off:** GPU contexts aren't preserved across suspend — an app *actively* using the dGPU
(a running game / CUDA job) can lose its context on resume. Fine here: the dGPU is idle offload,
we don't suspend mid-game. Games still run via `prime-run`; external HDMI (wired to the dGPU)
still works.

> Path B made *short* s2idle reliable, but a separate, intermittent **long-sleep** wedge
> remained — later root-caused to an nvidia ACPI D-notifier failure during s0ix and resolved
> by hibernating on lid close. See **issue #2** and
> [`docs/nvidia-pegp-dnotifier-s2idle-wedge.md`](docs/nvidia-pegp-dnotifier-s2idle-wedge.md).

### 2. Long/overnight s2idle wedges — root cause was nvidia; keep the dGPU out of sleep

**Symptom:** Even after fix #1, a *long* lid-close (e.g. overnight) entered s2idle and never
resumed — force-power required. **Short cycles were always fine; only long ones hung.** Not
battery drain (on AC), not s0ix depth.

**Root cause (found 2026-06-14):** **nvidia.** During deep s0ix the EC dispatches an ACPI
D-notifier to `PEGP` (the dGPU) and the still-bound nvidia driver fails it
(`NVRM: RmHandleDNotifierEvent ... status=0x11`), triggering a spurious wake that intermittently
hangs resume. `amd-s2idle` (pkg `amd-debug-tools`) measured **71–98.7 % hardware sleep**, so
residency was never the problem — short cycles just never lasted long enough to catch a spurious
wake. Full analysis + method: [`docs/nvidia-pegp-dnotifier-s2idle-wedge.md`](docs/nvidia-pegp-dnotifier-s2idle-wedge.md).

> Earlier theories here were dead ends: eDP **PSR** (`amdgpu.dcdebugmask=0x10` is kept as
> harmless hygiene) and **suspend-then-hibernate** escalation — the latter does s2idle *first*,
> so it wedged in the exact same nvidia path before it could ever escalate. Both removed.

**Fix — keep the dGPU out of the sleep path:**
- **Lid close does nothing to power state** (since 2026-06-16, by choice) —
  [`configs/systemd/logind.conf.d/10-lid-ignore.conf`](configs/systemd/logind.conf.d/10-lid-ignore.conf)
  sets `HandleLidSwitch=ignore` and niri's `switch-events` blank the panel. Suspend and hibernate
  are explicit (power key / DMS menu). *Before that:* lid → hibernate (S4), which powers fully
  off so nothing pokes `PEGP`. It works with issue #10's `shutdown` mode; the old config is kept
  as a rollback in the conf file's comments.
- **Unload nvidia before any sleep, so the dGPU is driverless.** This is the actual fix: no NVRM
  handler means the `PEGP` notify is harmless. It was first done with
  [`configs/systemd/system-sleep/80-nvidia-teardown.sh`](configs/systemd/system-sleep/80-nvidia-teardown.sh)
  (stop `nvidia-powerd`, unload the stack on `pre`, reload on `post`; healthy run logs `pre …
  nvidia_mods=0`).

> ⚠️ **The fail-open hook is a trap.** It always exits 0, and systemd-sleep hooks can't abort
> a sleep anyway. So when the unload fails, because something still holds the GPU, the machine
> sleeps with nvidia bound and the original wedge returns: `status=0x11` → Xid 13 storm →
> Xid 31 → **Xid 154 (reboot required)**. That happened 2026-08-07 and 2026-10-18, both times
> with `nvidia_mods=4/5` in `/var/log/suspend-s0ix.log`. **Replaced by the fail-closed
> [g14-diag sleep guard](diag/README.md)**: a oneshot service the sleep units *Require*, which
> refuses the sleep and tells you which process holds the GPU. See #11 for why it was held.

> ⚠️ Hibernate powers the machine **off** — press the **power button** to boot back and
> resume (same `boot_id`, session intact).

Hibernate still depends on a correct swapfile + cmdline (next ⚠️). Kernel cmdline lives in
[`configs/default/limine.cmdline`](configs/default/limine.cmdline) — see issue #4 for why you must
not edit `limine.conf` directly. No `resume` mkinitcpio hook is needed; the `systemd` hook handles
resume from the cmdline. Confirm the whole config with
[`scripts/verify-suspend.sh`](scripts/verify-suspend.sh).

#### ⚠️ The hibernation swapfile MUST be a single contiguous extent (btrfs gotcha)

The single most painful failure here, and the most underdocumented.

**Symptom:** hibernate writes fine and the kernel even *finds* the image on resume
(`PM: Image signature found, resuming`), then **fails mid-load** and cold-boots — session gone,
`boot_id` changed:
```
PM: hibernation: Failed to load image, recovering.
PM: hibernation: resume failed (-5)        # -5 = EIO
```

**Cause:** the btrfs swapfile was **fragmented** — `filefrag /swap/swapfile` reports "2 extents found".
`swapon` doesn't care about fragmentation so it silently works, but **early resume reads the swapfile
as one contiguous run starting at `resume_offset`**. The header (extent #1) reads fine, then the bulk
load dies the instant it crosses into a physically non-contiguous extent.

**Fix — recreate it contiguous and re-point the offset:**
```bash
sudo swapoff /swap/swapfile
sudo rm /swap/swapfile
sudo btrfs filesystem mkswapfile --size 36g /swap/swapfile   # single contiguous NOCOW extent
sudo swapon  /swap/swapfile
filefrag /swap/swapfile                                      # MUST report "1 extent found"
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile   # NEW resume_offset (it will change)
```
Put the new offset into `/etc/default/limine` → `sudo limine-update` → **reboot** → test with
`systemctl hibernate`. Success = your windows/terminals restore **and** `boot_id` is unchanged after
wake. A changed `boot_id` means it cold-booted (resume failed). Breadcrumb trick to tell them apart:
`cat /proc/sys/kernel/random/boot_id` before hibernating, compare after waking.

### 3. niri config is DankMaterialShell (DMS) managed — don't hand-edit

The niri config at `~/.config/niri/` is the canonical **DMS** layout (`dms setup`).
`config.kdl` includes `dms/{colors,layout,alttab,binds,outputs,cursor}.kdl`.

- **Window gaps, corner radius, border** are controlled by the **DMS settings GUI**, which
  rewrites `dms/layout.kdl` then live-reloads niri. **Don't hand-edit `dms/*.kdl`** — they're
  auto-overwritten. (niri legally merges multiple `layout {}` blocks.)
- `dms/windowrules.kdl` exists but is intentionally **not included** until a rule is added via the GUI.
- The old hand-written `~/.config/niri/cfg/*.kdl` modular setup was **deleted** — don't reintroduce
  `cfg/` includes.

### 4. Limine cmdline gotcha — edit `/etc/default/limine`, not `limine.conf`

Editing `/boot/limine.conf` directly is **futile**: the `limine-update` / mkinitcpio hook
regenerates it from `KERNEL_CMDLINE[default]` in **`/etc/default/limine`**. Put kernel params there,
then:
```bash
sudo limine-update
```

### 5. DMS bar/launcher missing after a manual niri/greetd restart

**Symptom:** Desktop is up but the **top bar is gone** and the **app launcher (Super) does
nothing** (it just spawns stray `app-niri-dms-*` scopes).

**Root cause:** When niri/greetd is restarted *by hand* mid-session,
`dms.service` can launch **before niri's Wayland socket is ready**
(`Failed to create wl_display (Connection refused)`), crash-loop, and trip systemd's
start-rate limit (`start-limit-hit`) — after which it stays dead. A normal boot orders
this correctly and doesn't hit it.

**Fix** (run as your user, inside the session — or [`scripts/dms-restart.sh`](scripts/dms-restart.sh)):
```bash
systemctl --user reset-failed dms.service
systemctl --user restart dms.service
```
Confirm: `pgrep -af 'qs -p /usr/share/quickshell/dms'`. **No reboot needed.**

### 6. Benign boot warnings (safe to ignore)

These appear every boot and are **not** problems:
- `RDSEED32 is broken. Please update your firmware.`
- `ACPI BIOS Error ... \_SB.PCI0.GPP5.WLAN._S0W, AE_ALREADY_EXISTS`
- `platform acp_asoc_acp70.0: warning: No matching ASoC machine driver found`
- `bluetoothd: Failed to set default system config for hci0`

### 7. dGPU off by default for daily use — now via cardwire (supergfxctl deprecated)

**In hybrid MUX mode** the desktop never uses the dGPU for display. The internal panel and most
USB-C/DisplayPort outputs are on the **amdgpu** iGPU; the **HDMI** port (`HDMI-A-1`) and one DP
output (`DP-9`) enumerate on the dGPU. So for everyday use and USB-C monitors, the Blackwell
render-offload card is dead weight; keep it off and only switch it on for gaming. (In
dGPU-direct mode none of this applies: see #11.)

**supergfxctl graphics switching is deprecated upstream** (asus-linux.org). The daily switcher is
now **cardwire** (eBPF LSM), which switches **instantly — no reboot, no logout** (supergfxctl's
logout-switch never completed under greetd; that entire saga is gone):

```bash
cardwire set integrated    # daily driver — dGPU device nodes blocked
cardwire set hybrid        # dGPU available for prime-run / gaming
```
Config `/etc/cardwire/cardwire.toml` (`auto_apply_gpu_state=true`, `experimental_nvidia_block=true`).
Gaming: `cardwire set hybrid` → `prime-run <game>` → `cardwire set integrated`.

> #### ⚠️ cardwire-Integrated is NOT supergfxctl-Integrated — and does NOT fix suspend
>
> Both call it "Integrated," but **supergfxctl removed the dGPU from the PCI bus** whereas
> **cardwire only blocks the device nodes (eBPF) and leaves the nvidia driver bound.** That
> difference is exactly why suspend kept wedging under cardwire: the bound driver still chokes on
> the `PEGP` ACPI D-notifier during s0ix (**issue #2**). cardwire is the convenient GPU switcher;
> the suspend problem is solved separately by **unloading nvidia before every sleep**, not by the GPU mode.
>
> ⚠️ **cardwire's mode is software-only and does not reflect the hardware MUX.** With the MUX in
> dGPU-direct mode, `cardwire get` still says `Hybrid` but only offers `hybrid, manual`, with no
> `integrated`. That's the tell that NVIDIA is driving the panel (#11).

The old `scripts/gpu-mode.sh` (a TTY session-teardown switcher needed for supergfxctl under
greetd) is **retired** — cardwire needs none of it. The DMS-bar-after-restart fix (issue #5)
still applies if you ever hand-restart niri/greetd.

### 8. Boot logos — CachyOS splash (removed) + ROG firmware animation (EFI-var experiment)

Two separate logos at startup, two different layers. **Full write-up:**
[`docs/rog-boot-logo-efivar.md`](docs/rog-boot-logo-efivar.md).

- **CachyOS logo** (lower-center, with spinner) = the **Plymouth** splash, fired by the `splash`
  token on the kernel cmdline. **Removed** by deleting `splash` from `KERNEL_CMDLINE[default]` in
  `/etc/default/limine` (issue #4) + `sudo limine-update`. Different layer from the ROG logo.
- **ROG animation + chime** (the instant you power on) = **firmware**, before the kernel — no
  cmdline/Plymouth fix possible. Signed BIOS capsules block the logo-swap-and-reflash mod, so the
  only OS-side lever is a UEFI variable: `AsusAnimationSetupConfig` (attrs `0x07` = NV+BS+**Runtime**,
  data `00 01 00` — middle byte looks like an enable flag). **Experiment, not yet tested** — flip
  it with [`scripts/disable-rog-boot-animation.sh`](scripts/disable-rog-boot-animation.sh) (backs up
  the bytes first; `--restore` to revert).

### 9. amdgpu iGPU MES / graphics-ring wedge on resume — known issue, no proven fix

Separate from the nvidia suspend bug (issues #1/#2). The **amdgpu iGPU itself** (Radeon 890M =
**gfx1150**) intermittently wedges its MES (MicroEngine Scheduler) + graphics-ring reset path →
**black screen on resume**:
```
amdgpu 0000:65:00.0: ring gfx_0.0.0 timeout ... → MES failed to respond to msg=RESET
→ reset via MES failed ... → Ring gfx_0.0.0 reset failed → GPU reset begin! (loops)
```
niri (on Mesa/amdgpu) then `SIGABRT`s in `dri_create_fence_fd` and the session is lost. **No disk
corruption** — it's pure GPU state.

It is **not** suspend-specific — the same signature reproduces on this exact silicon under pure
compute load — so it's a general gfx11 MES/graphics-ring reset-path fragility that AMD is still
reworking upstream. **As of June 2026 there is no proven parameter cure.** Crucially, do **not**
chase `amdgpu.cwsr_enable=0` (a compute-path knob, unproven here), `amdgpu.mes=0` (no-op on
gfx11+), or `amdgpu.gpu_recovery=0` (makes it worse). The right posture is already in place:
few sleep cycles (lid close doesn't sleep, #2), a current kernel + MES firmware (past the bad MES `0x83` onto `0x86+`), GPU
recovery left on, and updating the kernel to pick up the ongoing reset-path fixes. If it black-
screens, switch to a TTY (**Ctrl+Alt+F2**) rather than hitting power. **Full analysis + sources:**
[`docs/amdgpu-mes-graphics-ring-wedge.md`](docs/amdgpu-mes-graphics-ring-wedge.md).

### 10. Hibernate writes & resumes but never powers off — `platform` S4 bounce; use `shutdown` mode

**Symptom:** `systemctl hibernate` snapshots and resumes fine but won't power the machine
**off** — it bounces back on its own (often to the greeter), or stalls half-on needing a
hard-off. The *next* cold boot then resumes from the on-disk image, which masks it as
"working." Lived experience: *"hibernate kind of works, it just never shuts all the way
down."* Image-write and resume were always fine — only the final power-off was broken.

**Root cause:** the default `/sys/power/disk = platform` hands the power-off to **firmware**
ACPI **S4**, and this board's firmware **bounces** (`Preparing to enter S4` → `Waking up from
S4` in the same second) instead of cutting power. `shutdown` mode makes the **kernel** power
off itself, bypassing the broken handoff. **Both** `shutdown` mode **and** the issue-#2
nvidia-teardown hook are required — with the dGPU still bound, the power-off aborts even in
`shutdown` mode (same `PEGP`/NVRM root as issue #2).

> ⚠️ The kernel log is **deceptively identical** for a bounce and a real hibernate. `boot_id`
> stays unchanged for **both** (a real resume restores the saved `boot_id`; a bounce never
> left), and the `Image saving` lines never persist (emitted while journald is frozen). The
> only reliable test is **physical**: did the machine go fully dark and need a power-button
> press to return? See the doc for the full forensic trap.

**Fix:** [`configs/tmpfiles.d/hibernate-shutdown-mode.conf`](configs/tmpfiles.d/hibernate-shutdown-mode.conf)
(`w /sys/power/disk - - - - shutdown`) — the knob is runtime-only, so the `tmpfiles.d` `w`
rule re-sets it every boot. Apply now: `sudo systemd-tmpfiles --create
/etc/tmpfiles.d/hibernate-shutdown-mode.conf`. The teardown hook is already in place from
issue #2.

**Verify:** machine goes **fully dark** + needs a power-button press to resume (primary check —
logs can't tell a bounce from success); session restores with `boot_id` unchanged; after a
reboot `cat /sys/power/disk` still shows `[shutdown]`. **Full write-up:**
[`docs/hibernate-s4-platform-bounce.md`](docs/hibernate-s4-platform-bounce.md).

### 11. MUX found in dGPU-direct mode — NVIDIA drives the panel, so it can never be unloaded

**Symptom:** issue #2's wedge came back (2026-08-07, 2026-10-18) even though the teardown hook
was installed: `nvidia_mods=4/5` on every sleep, then `RmHandleDNotifierEvent ... status=0x11`
→ Xid 13 → Xid 31 → **Xid 154**. On lid open the panel stayed black:
`[nvidia-drm] Failed to allocate NVKMS memory for GEM object`.

**Root cause:** the firmware MUX was set to **dGPU-direct** (`gpu_mux_mode=0`). The internal
panel was wired to NVIDIA (`card*-eDP-2` connected on the `nvidia` card, `eDP-1` on amdgpu
disconnected), niri picked NVIDIA as its primary renderer (`using as the render node:
renderD129`), and every client followed it. With the compositor holding `nvidia_drm`
(refcount ~30), `modprobe -r` can never succeed. The hook failed open and the machine slept
with the dGPU bound. When the MUX changed is unknown: June 2026 was hybrid (panel on `eDP-1`),
and logs from the switch had already rotated out. Likely culprits are a BIOS update/reset or a
GPU-mode toggle.

```bash
cat /sys/class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value  # 1 = hybrid, 0 = dGPU-direct
for c in /sys/class/drm/card*-eDP-*; do echo "$c $(cat $c/status)"; done
g14-diag status        # also shows which GPU drives the panel and who holds /dev/nvidia*
```

**Fix (pending on this machine):** set the MUX back to hybrid, either in BIOS (GPU mode →
Optimus/Standard) or with `asusctl armoury set gpu_mux_mode 1`, then do a **full power-off
boot**. Then verify:
- panel on `eDP-1` / amdgpu
- niri logs `renderD128`
- nothing holds `/dev/nvidia*` at idle
- dGPU `runtime_status` = `suspended`
- the next sleep logs `pre … nvidia_mods=0`

Install the [g14-diag sleep guard](diag/README.md) with it, so that if anything pins the dGPU
(a game, Ollama, a dGPU-wired monitor), the sleep is refused instead of wedging. Hybrid
trade-off: a few % of game FPS (frames are copied to the iGPU). Run games with `prime-run`.

**Upstream context:**
- NVIDIA/open-gpu-kernel-modules [#1117](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1117):
  Blackwell s2idle resume hangs, still open on 615.71.09. One report says it fails only when the
  MUX routes the panel to the dGPU.
- [#1322](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1322): RTX 5070 Ti, the same
  Xid 13 → 154 signature with `PreserveVideoMemoryAllocations=0`.
- Hybrid's own risk is [#1064](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1064):
  GSP/DIFR hangs when the dGPU wakes from runtime power-off (partial mitigation
  `NVreg_DynamicPowerManagement=0x00`).

### 12. Driver upgraded without a reboot → next sleep wedges the dGPU

**Symptom (2026-10-18):** after a `pacman -Syu` that moved NVIDIA 615.71.09 → 615.78.08 (and
the kernel 7.2.9 → 7.2.10), the next suspend/resume cycles logged
`Direct firmware load for nvidia/615.71.09/gsp_ga10x.bin failed with error -2`, an Xid
13/31/154 cascade, `uvm encountered global fatal error 0x60, requiring os reboot` and
`NVRM: API mismatch: the client ... has the version 615.78.08, but this kernel module has the
version 615.71.09`. Then a hard hang.

**Root cause:** the still-loaded 615.71.09 module needs its GSP firmware again every time the
GPU re-initializes (each resume), and the upgrade had **deleted** `/usr/lib/firmware/nvidia/615.71.09/`.
New userspace tools (`nvidia-smi`, `nvidia-powerd`) also can't talk to the old module.

**Fix:** reboot after any kernel or NVIDIA upgrade, **before** suspending, hibernating or
closing the lid on a sleep-on-lid setup. [g14-diag](diag/README.md) enforces it: a pacman hook
warns in the terminal and on the desktop, and the sleep guard refuses to sleep while the loaded
and installed driver versions differ.

### 13. Open / unexplained incidents

Kept so patterns show up over time. [g14-diag](diag/README.md) bundles exist for incidents after 2026-10-18.

| Date | What happened | Evidence | Status |
|---|---|---|---|
| 2026-08-01 | Hard lockup mid-session | `SIGILL` inside libsystemd's code pages in RAM (disk copy clean). Points to corrupted memory | overnight memtest86+ clean. Inconclusive |
| 2026-08-05 | dGPU wedged mid-session, later hung a reboot | `/dev/nvidia0` missing | corrupt `nvidia-utils` install; fixed by reinstall + 2 reboots |
| 2026-09-23 | Screen froze; kernel, logind and apps kept running | niri ignored the power key; no Xid/amdgpu errors | compositor hang, cause unknown. Next time: Ctrl+Alt+F3 / SSH before hard reset |
| 2026-10-18 | Black screen on lid open, then hang after suspend cycles | issues #11 + #12 | root-caused; MUX switch pending |

---

## Repo layout

```
linux-asus-g14-ga403wr/
├── README.md
├── docs/
│   ├── nvidia-suspend-path-b.md              # kernel-notifier path + sources (issue #1)
│   ├── nvidia-pegp-dnotifier-s2idle-wedge.md # long-sleep wedge root cause + fix (issue #2)
│   ├── amdgpu-mes-graphics-ring-wedge.md     # amdgpu iGPU MES wedge, no proven fix (issue #9)
│   ├── hibernate-s4-platform-bounce.md       # hibernate won't power off; shutdown mode fix (issue #10)
│   └── rog-boot-logo-efivar.md               # remove CachyOS splash + ROG animation (issue #8)
├── scripts/
│   ├── disable-rog-boot-animation.sh  # toggle the ROG boot animation EFI var (issue #8)
│   ├── dms-restart.sh       # bring back the DMS bar/launcher after a restart (issue #5)
│   └── verify-suspend.sh    # check the suspend/hibernate config is intact (issues #1, #2, #10–#12)
├── diag/                    # g14-diag: per-boot incident bundles, sleep guard, live alerts (diag/README.md)
│   ├── g14-diag             # the CLI (status / pending / note / ack / collect / guard / watch)
│   ├── install.sh           # sudo diag/install.sh [--without-guard | --uninstall]
│   ├── systemd/             # collect-at-boot, fail-closed nvidia teardown/reload, user watcher
│   ├── etc/                 # systemd/journald.conf.d retention/sync + sysctl crash-capture drop-ins
│   └── pacman/              # reboot-needed warning after kernel/NVIDIA upgrades
└── configs/                 # sanitized snapshots of the working config (machine-specific!)
    ├── modprobe.d/nvidia-power.conf
    ├── modprobe.d/nvidia-drm.conf
    ├── initcpio/install/nvidia-noinitramfs  # keeps nvidia out of the initramfs (issue #1)
    ├── tmpfiles.d/pm-debug.conf             # persist pm_debug_messages=1 (issue #2 diag)
    ├── tmpfiles.d/hibernate-shutdown-mode.conf  # force /sys/power/disk=shutdown each boot (issue #10)
    ├── default/limine.cmdline
    └── systemd/
        ├── logind.conf.d/10-lid-ignore.conf      # lid close -> no sleep, niri blanks the panel (issue #2)
        ├── system/systemd-suspend.service.d/20-freeze-user-sessions.conf  # re-freeze sessions (issue #2)
        └── system-sleep/
            ├── 80-nvidia-teardown.sh      # fail-open predecessor of the g14-diag sleep guard (issue #2)
            └── 90-s0ix-debug-log.sh       # log s0ix residency/wakes per transition (issue #2 diag)
```

## License

[GPL-3.0](LICENSE). Scripts and configs are free to reuse and modify; changes you distribute
must stay under the same license.
