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

### 1. Resume-from-lid hard hang on s2idle (short cycles)

**Symptom:** Closing the lid and reopening occasionally produced a full system wedge
(force power-off required, then cold boot). Log signature: boot ends at
`PM: suspend entry (s2idle)` with **no** `SMU is resumed` / `PM: suspend exit` after it.

**Root cause:** NVIDIA dGPU loaded and in use, but `nvidia-suspend/resume/hibernate.service`
were **disabled** and `NVreg_EnableS0ixPowerManagement=0`, so dGPU VRAM was never saved/
restored across s2idle — a known intermittent-resume-hang recipe on s2idle hybrid laptops.

**Fix:**
1. Enable the NVIDIA sleep services:
   ```bash
   sudo systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service
   ```
2. Add [`configs/modprobe.d/nvidia-power.conf`](configs/modprobe.d/nvidia-power.conf):
   ```
   options nvidia NVreg_EnableS0ixPowerManagement=1 NVreg_PreserveVideoMemoryAllocations=1
   ```
3. Rebuild initramfs and **reboot** (the module param only goes live on reboot):
   ```bash
   sudo mkinitcpio -P
   ```

**Verify:** `grep EnableS0ix /proc/driver/nvidia/params` → `1`. A healthy resume logs
`amdgpu: SMU is resumed successfully!` and `PM: suspend exit`.

### 2. Long/overnight s2idle still wedges (deep-suspend fix)

**Symptom:** Even after fix #1, a *long* lid-close (e.g. ~12 h, on AC) entered suspend and
never resumed. Short cycles were fine; long ones hung. Not battery drain — it was plugged in.

**Root cause (two parts):** (a) eDP **Panel Self Refresh (PSR)** was active (`eDP-2: PSR support 1`)
and (b) the machine sat in s2idle indefinitely instead of dropping to a real low-power state.

**Fix:**
- **Disable eDP PSR** via kernel cmdline `amdgpu.dcdebugmask=0x10`.
- **suspend-then-hibernate** so a long s2idle escalates to S4 (hibernate):
  - 36 GiB NOCOW btrfs swapfile on a dedicated nested `@/swap` subvol (excluded from snapshots).
  - `resume=UUID=<root> resume_offset=<offset>` on the kernel cmdline.
  - [`configs/systemd/logind.conf.d/10-lid-hibernate.conf`](configs/systemd/logind.conf.d/10-lid-hibernate.conf):
    `HandleLidSwitch=suspend-then-hibernate` (+ `ExternalPower` — the overnight freeze was on AC).
  - [`configs/systemd/sleep.conf.d/10-hibernate-delay.conf`](configs/systemd/sleep.conf.d/10-hibernate-delay.conf):
    `HibernateDelaySec=60min`.

Kernel cmdline lives in [`configs/default/limine.cmdline`](configs/default/limine.cmdline) — see issue #5
for *why you must not edit `limine.conf` directly*. No `resume` mkinitcpio hook is needed; the
`systemd` hook handles resume from the cmdline.

**Verify:** after a long suspend, `journalctl -b -1 | grep -E 'PM: hibernation|Reached target Hibernate'`.
Run [`scripts/verify-suspend.sh`](scripts/verify-suspend.sh) to confirm the whole config is in place.

> Requires a **reboot** to activate — the running kernel has no `resume=` until you reboot, so do
> **not** `systemctl hibernate` before rebooting or the session won't come back.

### 3. niri desktop wedges after a VT switch ("another niri session is already running")

**Symptom:** After switching to a text console (`Ctrl+Alt+F2`) and back, VT1 shows a **text console
you can type into** instead of the desktop, and logging in at tuigreet is refused with
*"another niri session is already running."*

**Root cause:** A Wayland compositor only holds the GPU (DRM master) while *its* VT is in front.
On the switch back, niri **failed to re-acquire the AMD iGPU** (`/dev/dri/card2`) — logs fill with
`error queueing frame ... Page flip commit failed ... Permission denied (os error 13)` and
`pausing session`. The process stays alive but stops rendering, **and keeps holding niri's
single-instance lock**, so no new session can start. Likely a DRM-master handoff hiccup on the
hybrid GPU.

**Recovery** (from another VT or SSH — run [`scripts/niri-recover.sh`](scripts/niri-recover.sh)):
```bash
sudo pkill -KILL -u "$USER" -x niri   # clears the wedged process + its lock
sudo systemctl restart greetd         # fresh tuigreet greeter on VT1
sudo chvt 1                           # then log in normally
```

**Confirm it's this bug:** `journalctl _UID=$(id -u) -b | grep 'Page flip'`.

### 4. niri config is DankMaterialShell (DMS) managed — don't hand-edit

The niri config at `~/.config/niri/` is the canonical **DMS** layout (`dms setup`).
`config.kdl` includes `dms/{colors,layout,alttab,binds,outputs,cursor}.kdl`.

- **Window gaps, corner radius, border** are controlled by the **DMS settings GUI**, which
  rewrites `dms/layout.kdl` then live-reloads niri. **Don't hand-edit `dms/*.kdl`** — they're
  auto-overwritten. (niri legally merges multiple `layout {}` blocks.)
- `dms/windowrules.kdl` exists but is intentionally **not included** until a rule is added via the GUI.
- The old hand-written `~/.config/niri/cfg/*.kdl` modular setup was **deleted** — don't reintroduce
  `cfg/` includes.

### 5. Limine cmdline gotcha — edit `/etc/default/limine`, not `limine.conf`

Editing `/boot/limine.conf` directly is **futile**: the `limine-update` / mkinitcpio hook
regenerates it from `KERNEL_CMDLINE[default]` in **`/etc/default/limine`**. Put kernel params there,
then:
```bash
sudo limine-update
```

### 6. DMS bar/launcher missing after a manual niri/greetd restart

**Symptom:** Desktop is up but the **top bar is gone** and the **app launcher (Super) does
nothing** (it just spawns stray `app-niri-dms-*` scopes).

**Root cause:** When niri/greetd is restarted *by hand* mid-session (e.g. the issue #3
recovery), `dms.service` can launch **before niri's Wayland socket is ready**
(`Failed to create wl_display (Connection refused)`), crash-loop, and trip systemd's
start-rate limit (`start-limit-hit`) — after which it stays dead. A normal boot orders
this correctly and doesn't hit it.

**Fix** (run as your user, inside the session — or [`scripts/dms-restart.sh`](scripts/dms-restart.sh)):
```bash
systemctl --user reset-failed dms.service
systemctl --user restart dms.service
```
Confirm: `pgrep -af 'qs -p /usr/share/quickshell/dms'`. **No reboot needed.**

> Tie-in: after running the issue #3 recovery, check `systemctl --user is-active dms.service`
> and restart DMS if it's dead.

### 7. Benign boot warnings (safe to ignore)

These appear every boot and are **not** problems:
- `RDSEED32 is broken. Please update your firmware.`
- `ACPI BIOS Error ... \_SB.PCI0.GPP5.WLAN._S0W, AE_ALREADY_EXISTS`
- `platform acp_asoc_acp70.0: warning: No matching ASoC machine driver found`
- `bluetoothd: Failed to set default system config for hci0`

---

## Repo layout

```
linux-asus-g14-ga403wr/
├── README.md
├── scripts/
│   ├── niri-recover.sh      # recover a wedged niri/greetd session (issue #3)
│   ├── dms-restart.sh       # bring back the DMS bar/launcher after a restart (issue #6)
│   └── verify-suspend.sh    # check the suspend/hibernate config is intact (issues #1, #2)
└── configs/                 # sanitized snapshots of the working config (machine-specific!)
    ├── modprobe.d/nvidia-power.conf
    ├── modprobe.d/nvidia-drm.conf
    ├── default/limine.cmdline
    └── systemd/
        ├── logind.conf.d/10-lid-hibernate.conf
        └── sleep.conf.d/10-hibernate-delay.conf
```
