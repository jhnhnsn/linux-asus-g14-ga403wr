# linux-asus-g14-ga403wr

Notes, fixes, and config snapshots for running Linux on an **ASUS ROG Zephyrus G14
(GA403WR)** — AMD Strix Halo + NVIDIA dGPU — under **CachyOS**. This is a personal lab notebook —
every entry is something that actually broke on this machine and the fix that resolved it.

> ⚠️ Machine-specific values (partition UUIDs, `resume_offset`, hostname) appear in the
> config snapshots. They document *this* laptop — **regenerate your own** before reusing.

## Hardware / software baseline

| | |
|---|---|
| **Laptop** | ASUS ROG Zephyrus G14 — model **GA403WR** (board `GA403WR`, hostname `cachyos-g14`) |
| **APU** | AMD Strix Halo — Radeon 880M/890M **iGPU is the primary display** (`amdgpu`, `fb0`) |
| **dGPU** | NVIDIA RTX 5070 Ti Laptop — proprietary driver, **render-offload only** |
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

### 2. Long/overnight s2idle still wedges (deep-suspend fix)

**Symptom:** Even after fix #1, a *long* lid-close (e.g. ~12 h, on AC) entered suspend and
never resumed. Short cycles were fine; long ones hung. Not battery drain — it was plugged in.

**Root cause (two parts):** (a) eDP **Panel Self Refresh (PSR)** was active (`eDP-2: PSR support 1`)
and (b) the machine sat in s2idle indefinitely instead of dropping to a real low-power state.

**Fix:**
- **Disable eDP PSR** via kernel cmdline `amdgpu.dcdebugmask=0x10`.
- **suspend-then-hibernate** so a long s2idle escalates to S4 (hibernate):
  - 36 GiB NOCOW btrfs swapfile on a dedicated nested `@/swap` subvol (excluded from snapshots),
    created with `btrfs filesystem mkswapfile` so it is a **single contiguous extent**
    (see the ⚠️ callout below — this is the part that actually bites).
  - `resume=UUID=<root> resume_offset=<offset>` on the kernel cmdline, where `<offset>` comes from
    **`btrfs inspect-internal map-swapfile -r /swap/swapfile`** (NOT `filefrag` — that's the ext4 way).
  - [`configs/systemd/logind.conf.d/10-lid-hibernate.conf`](configs/systemd/logind.conf.d/10-lid-hibernate.conf):
    `HandleLidSwitch=suspend-then-hibernate` (+ `ExternalPower` — the overnight freeze was on AC).
  - [`configs/systemd/sleep.conf.d/10-hibernate-delay.conf`](configs/systemd/sleep.conf.d/10-hibernate-delay.conf):
    `HibernateDelaySec=60min`.

Kernel cmdline lives in [`configs/default/limine.cmdline`](configs/default/limine.cmdline) — see issue #4
for *why you must not edit `limine.conf` directly*. No `resume` mkinitcpio hook is needed; the
`systemd` hook handles resume from the cmdline.

**Verify:** after a long suspend, `journalctl -b -1 | grep -E 'PM: hibernation|Reached target Hibernate'`.
Run [`scripts/verify-suspend.sh`](scripts/verify-suspend.sh) to confirm the whole config is in place.

> Requires a **reboot** to activate — the running kernel has no `resume=` until you reboot, so do
> **not** `systemctl hibernate` before rebooting or the session won't come back.

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

### 7. dGPU off by default via supergfxctl (Integrated mode) — the real cure

After fighting the NVIDIA dGPU through suspend/resume for a long time (issue #1, the hibernate
`-5`, VRAM-preservation crashes, `Xid 13` storms on resume), the decisive fix was to **take the
dGPU out of the picture entirely for daily use**. It's a Blackwell **render-offload** GPU the
desktop doesn't use for display — the internal panel and USB-C/DisplayPort outputs are all on the
**amdgpu** iGPU; only the **HDMI** port is wired to the dGPU. So for everyday + USB-C external
monitors, the dGPU is pure dead weight in the sleep path.

**Setup:**
```bash
sudo pacman -S --needed supergfxctl asusctl rog-control-center
sudo systemctl enable --now supergfxd.service asusd.service
supergfxctl -s     # supported modes; on the GA403WR: [Integrated, Hybrid, AsusMuxDgpu]
```
- **Integrated** = dGPU force-off (removed from the PCI bus). Daily driver. Suspend/resume is
  pure amdgpu — boring and reliable. No nvidia, no Xid.
- **Hybrid** = dGPU available for render-offload / gaming (`prime-run`) and the HDMI port.
- **AsusMuxDgpu** = MUX the panel directly to the dGPU for max gaming perf (needs reboot).

Switch with [`scripts/gpu-mode.sh`](scripts/gpu-mode.sh) (see the ⚠️ gotcha below for *why* the
plain `supergfxctl -m` flow fails on this machine).

**Verify Integrated is live:** `supergfxctl -g` → `Integrated`, `lsmod | grep '^nvidia'` empty,
and `/sys/bus/pci/devices/0000:64:00.0` is **gone** (dGPU removed from the bus).

#### ⚠️ supergfxd's logout-switching does NOT complete under greetd

`supergfxctl -m <mode>` only *arms* the switch and then waits for a full graphical logout
(`action: WaitLogout`, 30 s timeout). Under **greetd** that never happens — greetd immediately
respawns the greeter, and any lingering session (e.g. a `claude`/shell in another TTY) keeps the
user "logged in" — so it logs `Time (30 seconds) for logout exceeded` and **aborts without
persisting the mode**. A plain reboot then boots back into the *old* mode (the pending switch was
never written to `/etc/supergfxd.conf`). Two ways that actually work:

1. **From a TTY, stop the graphical session first** (what `scripts/gpu-mode.sh` does):
   `systemctl stop greetd` → kill the orphaned `niri`/clients + `systemctl stop nvidia-powerd`
   → `modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia` → `systemctl restart supergfxd`
   (it now removes the dGPU and writes mode=Integrated) → `systemctl start greetd`.
2. **Edit the config + reboot:** set `"mode": "Integrated"` in `/etc/supergfxd.conf` while
   `supergfxd` is stopped, then reboot — supergfxd applies the mode at boot, before any session
   holds the dGPU.

After either path, the **DMS bar race (issue #5)** usually fires because niri got restarted —
fix with `scripts/dms-restart.sh`.

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

---

## Repo layout

```
linux-asus-g14-ga403wr/
├── README.md
├── docs/
│   ├── nvidia-suspend-path-b.md   # why we use the kernel-notifier path + sources (issue #1)
│   └── rog-boot-logo-efivar.md    # remove CachyOS splash + ROG firmware animation (issue #8)
├── scripts/
│   ├── disable-rog-boot-animation.sh  # toggle the ROG boot animation EFI var (issue #8)
│   ├── dms-restart.sh       # bring back the DMS bar/launcher after a restart (issue #5)
│   ├── gpu-mode.sh          # switch Integrated <-> Hybrid the way that works under greetd (issue #7)
│   └── verify-suspend.sh    # check the suspend/hibernate config is intact (issues #1, #2)
└── configs/                 # sanitized snapshots of the working config (machine-specific!)
    ├── modprobe.d/nvidia-power.conf
    ├── modprobe.d/nvidia-drm.conf
    ├── initcpio/install/nvidia-noinitramfs  # keeps nvidia out of the initramfs (issue #1)
    ├── default/limine.cmdline
    └── systemd/
        ├── logind.conf.d/10-lid-hibernate.conf
        └── sleep.conf.d/10-hibernate-delay.conf
```
