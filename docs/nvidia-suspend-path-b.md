# NVIDIA suspend/resume on this hybrid laptop — why we use "Path B"

**TL;DR:** On an AMD-iGPU-primary + NVIDIA-dGPU-offload laptop, there are two
mutually-exclusive ways to handle the dGPU across suspend/hibernate. We started on
the *heavyweight* path (Path A), it corrupted on resume, and after reading the
upstream bug trackers + NVIDIA's own docs we switched to the *modern default*
path (Path B). This file records the reasoning and the sources, so future-me
doesn't "helpfully" re-enable the broken settings.

---

## The two paths

NVIDIA's power-management documentation describes two non-overlapping mechanisms.
You pick one. Mixing them is what breaks.

| | **Path A — VRAM preservation (heavyweight)** | **Path B — kernel suspend-notifier (default)** |
|---|---|---|
| `NVreg_PreserveVideoMemoryAllocations` | `1` (driver saves/restores *all* VRAM to disk) | `0` |
| `nvidia-suspend` / `-resume` / `-hibernate` services | **enabled** (required) | **disabled** (unused) |
| `/proc/driver/nvidia/suspend` procfs interface | required | unused |
| Who moves GPU state | the nvidia driver itself, via the systemd hooks | the kernel's suspend-notifier callbacks (`UseKernelSuspendNotifiers=1`) |
| Intended for | CUDA/UVM context persistence across suspend | everyone else |
| NVIDIA's own words | — | *"requires no configuration if the default power management mechanism is used"* |

## What we hit on Path A (both failures live in the heavyweight path)

1. **s2idle resume → compositor crash (the "short lid close froze it").**
   The kernel resumed fine (`SMU is resumed successfully`, `PM: suspend exit`),
   but the dGPU's VRAM save/restore machinery corrupted itself:
   ```
   NVRM: GPU0 _clientUnmapInterBackRefMappings: Failed to auto-unmap backref (status=0x57)
   NVRM: GPU0 nvAssertFailedNoLog: Assertion failed ... rs_client.c / map.c / rs_resource.c
   ```
   (~395 backref failures + ~1838 assertions in the one boot it happened, zero in
   every other boot.) A session client holding live nvidia mappings then took a
   `SIGABRT` → black screen → we power-buttoned it off.

2. **Hibernate → `nv_pmops_freeze returns -5`.**
   With `PreserveVideoMemoryAllocations=1`, the driver tries to self-restore VRAM
   from the hibernation image *before* the `system-sleep/nvidia` hook runs —
   especially when nvidia is early-loaded in the initramfs. Result:
   `pci_pm_freeze(): nv_pmops_freeze [nvidia] returns -5` → `resume failed (-5)`
   → cold boot.

Both are properties of the save/restore-all-VRAM path. Path B has no such
machinery to corrupt or to race the initramfs.

## What we changed (Path B)

1. `/etc/modprobe.d/nvidia-power.conf` → `options nvidia NVreg_PreserveVideoMemoryAllocations=0`
   (was `EnableS0ixPowerManagement=1 PreserveVideoMemoryAllocations=1`).
2. Disabled the sleep services:
   `systemctl disable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service`.
3. Kept nvidia **out of the initramfs** — the custom install hook
   `/etc/initcpio/install/nvidia-noinitramfs` (added last in `HOOKS`). This is the
   *correct* half of the early-KMS fix and stays regardless of path; both the Arch
   thread and NVIDIA #922 confirm early-loaded nvidia + hibernate don't mix.
4. Kept `nvidia_drm modeset=1` (so nvidia doesn't fight amdgpu for the console fb)
   and `DynamicPowerManagement=2` (idle dGPU still drops to D3cold for power).
5. `mkinitcpio -P` + `limine-update`, then **reboot** (params are read at module
   load — the running kernel keeps the old value until then).

**Trade-off (accepted):** GPU contexts are *not* preserved across suspend, so an
app actively using the dGPU (a running game, a CUDA job) can lose its context on
resume. Fine for this machine: the dGPU is idle render-offload and we don't
suspend mid-game. Games still run via `prime-run`; external HDMI (wired to the
dGPU) still works.

## Blackwell caveat (RTX 5070 Ti Laptop)

RTX 50-series **mobile (Blackwell)** is rough on Linux during the current
driver/kernel rollout — GSP timeouts (`0x0000ca7d`), `Xid 79` ("GPU fallen off the
bus"). On the *literal* GA403 + RTX 5070 Mobile forum thread, a moderator's first
move was pointing at **stale ASUS firmware** ("4 versions behind on critical
firmware updates"). So: keep BIOS/firmware current. This machine's BIOS at the
time of writing is `GA403WR.309` (2025-09-17). `fwupd` was **not installed** — worth
adding (`fwupdmgr get-updates`) to track EC/UEFI capsule updates.

## Sources read & synthesized (2026-06-13)

- **NVIDIA — Configuring Power Management Support** (driver README): the
  authoritative description of `PreserveVideoMemoryAllocations`,
  `EnableS0ixPowerManagement`, and the statement that the default mechanism needs
  no configuration / no systemd services.
  <https://download.nvidia.com/XFree86/Linux-x86_64/580.82.07/README/powermanagement.html>
- **Arch BBS — "nvidia-resume from hibernation not working with early KMS enabled"**:
  exact mechanism of the `nv_pmops_freeze -5` race (early-loaded nvidia self-restores
  before the sleep hook); fix = remove nvidia from initramfs + drop `Preserve=1`.
  <https://bbs.archlinux.org/viewtopic.php?id=285508>
- **Arch BBS — "cannot resume from suspend with PreserveVideoMemoryAllocations"**:
  `Preserve=1` + services → black screen on resume; the parameter itself is the trigger.
  <https://bbs.archlinux.org/viewtopic.php?id=290126>
- **NVIDIA/open-gpu-kernel-modules #922 — "Suspend & Hibernate Fails on hybrid laptop"**:
  *"PreserveVideoMemoryAllocations module parameter is set. System Power Management
  attempted without driver procfs suspend interface."* → `nv_pmops_freeze -5`.
  <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/922>
- **NVIDIA/open-gpu-kernel-modules #887 — "crashes after resume"**: intermittent
  `nv_pmops_*_suspend returned -5`, affects both proprietary and open driver →
  deeper PM/hardware interaction, not a per-driver bug.
  <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/887>
- **omarchy #5500 — "Hibernation failure due to NVidia driver: how I fixed it"**
  (same Limine setup as us): the concrete Path-B recipe — `Preserve=0`, disable the
  three nvidia sleep services, rebuild, reboot; "works out of the box."
  <https://github.com/basecamp/omarchy/discussions/5500>
- **NVIDIA forums — RTX 5070 Mobile (Blackwell) GSP timeouts / Xid 79 on GA403**:
  Blackwell-mobile instability + the firmware-version angle.
  <https://forums.developer.nvidia.com/t/rtx-5070-mobile-blackwell-gsp-timeouts-0x0000ca7d-xid-79-on-kernel-6-17-driver-580-126-ubuntu-24-04-4/360897>
- **asus-linux.org — supergfxctl manual**: GPU mode definitions (Integrated
  force-disables the dGPU; Hybrid = offload). Considered as an alternative lever;
  deferred unless Path-B Hybrid suspend proves unreliable.
  <https://asus-linux.org/manual/supergfxctl-manual/>
