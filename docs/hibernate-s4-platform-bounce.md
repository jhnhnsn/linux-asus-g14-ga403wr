# Hibernate never powers off — the `platform` S4 bounce, fixed with `/sys/power/disk=shutdown`

> **TL;DR** Hibernate on the GA403WR wrote its image and resumed fine, but it would **not
> power the machine off** — it took the snapshot and then immediately resumed *in place*
> ("bounced"), leaving the laptop running. You'd find it still on (or stuck half-on) and have
> to hard-power it; the next cold boot then resumed from the on-disk image, which made it
> *look* like hibernate had worked. Root cause: the default `/sys/power/disk = platform`
> path asks the **firmware** to enter ACPI **S4**, and this board's firmware bounces instead
> of cutting power. Fix: **`/sys/power/disk = shutdown`** (the kernel powers itself off, no
> ACPI S4 handoff) — persisted via [`configs/tmpfiles.d/hibernate-shutdown-mode.conf`](../configs/tmpfiles.d/hibernate-shutdown-mode.conf)
> — **plus** the nvidia-teardown hook from issue #2 (with the dGPU still bound, even
> `shutdown` mode bounces).

## How it presents

- `systemctl hibernate` runs, the screen goes dark, then **the machine comes back on its own**
  — often to the greeter (the session got torn down) rather than a true resume.
- Or it sits in a **stuck half-on state** (fans/LEDs still on, display dead) until you
  force-power it. After the forced power-off, the *next* boot shows the Plymouth "resuming
  from hibernation" splash and restores the session — because the image really was on disk.
- Net effect the user actually lived with: *"hibernate kind of works, it just never shuts all
  the way down — I have to hard-stop it, then it restores on the next boot."* That single
  sentence is the whole bug: **image-write and resume were always fine; only the final
  power-off was broken.**

## The forensic trap (how to tell a *bounce* from a *real* hibernate)

This took two wrong conclusions to get right, because the kernel log is **deceptively
identical** for a bounce and a successful hibernate. Three traps, all of which produced
false readings here:

1. **"No `PM: Image saving progress` / `Wrote N kbytes` ⇒ nothing was written."** *Wrong.*
   Those lines are emitted **after** the RAM snapshot, while userspace (journald) is frozen,
   so they are **never flushed to the on-disk journal** across a real hibernate. Their
   absence proves nothing about whether an image was written.
2. **"Same `boot_id` after wake ⇒ it never powered off."** *Wrong, and also the inverse is
   wrong.* A successful hibernate **restores the saved `boot_id` from the image**, so a real
   resume-from-disk shows the **same** `boot_id` and does **not** appear as a new boot in
   `journalctl --list-boots`. A bounce *also* keeps the same `boot_id` (it never left). So
   `boot_id` unchanged is consistent with **both** — it cannot distinguish them. (A *changed*
   `boot_id` only tells you resume *failed* and it cold-booted fresh — see issue #2's
   fragmentation case.)
3. **"`PM: Image not found (code -22)` in the log ⇒ resume failed."** Only at the **cold
   start** of a boot. Mid-life resumes don't log it; the resume kernel's own messages are
   discarded when it jumps into the restored image.

The kernel sequence for a bounce — `hibernation entry` → (gap) → `Creating image` /
`Need to copy N pages` → `Waking up from S4` → `Hibernation image restored successfully` →
`Restarting tasks` → `hibernation exit`, all in the **same second** — is *byte-for-byte the
same shape* you'd hope a success looks like. The `Waking up from S4` and "restored
successfully" lines are part of the **normal in-RAM snapshot step** (the kernel always brings
the system back up briefly to write the image) and appear in the bounce too.

### The only reliable discriminator: physical observation

What actually settled it was watching the machine, not the logs:

| | Bounce (fail) | Real hibernate (success) |
|---|---|---|
| Fans / LEDs | stay on (or stuck half-on) | **fully off** (only the AC-charging LED, which dies with the cord) |
| Returns by itself? | yes, on its own | **no** — needs a **power-button** press to cold-boot |
| Session | greeter / torn down | restored intact |

A machine that goes **fully dark and needs the power button to come back, then restores your
session** is doing real hibernate-to-disk. Nothing in the journal substitutes for that
observation here.

## Root cause

`/sys/power/disk` selects what happens **after** the image is written:

- **`platform`** (default) — hand off to the **firmware** to enter ACPI **S4**. On this board
  the firmware immediately wakes instead of powering down (`Preparing to enter S4` →
  `Waking up from S4` in the *same second*). Known-messy on AMD Ryzen AI + NVIDIA ASUS
  laptops (e.g. Arch BBS `id=311112`, Phoronix Strix Halo threads).
- **`shutdown`** — the **kernel** powers the machine off itself (plain poweroff), no ACPI S4
  handshake. Resume on next boot is unchanged.

## The A/B that proves it (and pins the second variable)

Same machine, same day, only two variables changed:

| `/sys/power/disk` | `80-nvidia-teardown` hook | Result |
|---|---|---|
| `platform` | parked | bounced — never powered off |
| `shutdown` | **parked** | **still bounced** — `shutdown` alone is **not** enough |
| `shutdown` | **active** | **fully powered off + clean resume** ✅ |

So **both** are required. With the dGPU still bound (issue #2's `PEGP`/NVRM problem), the
power-off aborts even in `shutdown` mode; the teardown hook making the dGPU driverless is what
lets `shutdown` complete. This is also why the hook was *briefly* (and wrongly) "exonerated"
mid-investigation — a `shutdown`-mode test with hooks parked bounced, which looked like the
hook didn't matter. It does.

## The fix

1. **`/sys/power/disk = shutdown`, persisted across boots** —
   [`configs/tmpfiles.d/hibernate-shutdown-mode.conf`](../configs/tmpfiles.d/hibernate-shutdown-mode.conf):
   ```
   w /sys/power/disk - - - - shutdown
   ```
   The knob is **runtime-only** (resets to `platform` every boot), so a `tmpfiles.d` `w` rule
   re-writes it on each boot. Apply now without rebooting:
   ```bash
   sudo systemd-tmpfiles --create /etc/tmpfiles.d/hibernate-shutdown-mode.conf
   ```
2. **Unload nvidia before sleep** — the existing
   [`configs/systemd/system-sleep/80-nvidia-teardown.sh`](../configs/systemd/system-sleep/80-nvidia-teardown.sh)
   from issue #2 (already in place for the s2idle wedge). No extra work if issue #2 is done.

Resume itself needs nothing new here — the `systemd` initramfs hook + `resume=` / `resume_offset=`
on the cmdline (issue #2) already handle it. No `resume` mkinitcpio hook (that's the
udev/busybox style; mixing it with the `systemd` hook is wrong — see Arch BBS `id=306112`,
which does **not** apply to this systemd-hook setup).

## Verifying

After `systemctl hibernate`:

1. **Watch the hardware** — it must go **fully dark** and require a **power-button** press to
   return. This is the primary check; the logs can't replace it (see the trap above).
2. After the power-on resume, the session restores **and** `boot_id` is unchanged:
   ```bash
   # before:  cat /proc/sys/kernel/random/boot_id
   # after :  cat /proc/sys/kernel/random/boot_id   # same = real restore
   ```
   ⚠️ **`boot_id` unchanged is necessary but NOT sufficient** — a bounce also keeps it
   unchanged. Combine it with check #1 (did it actually power off?). A *changed* `boot_id`
   means resume failed and it cold-booted (suspect the swapfile, issue #2).
3. Mode survives reboot — after a real reboot, `cat /sys/power/disk` shows `[shutdown]`.
4. Hook ran — `grep nvidia-teardown /var/log/suspend-s0ix.log` → `pre … nvidia_mods=0`,
   `post … nvidia_mods=5`.

## Relationship to issue #2

Issue #2 got hibernate-on-lid *configured* (swapfile contiguity, `resume_offset`, nvidia out
of initramfs, the teardown hook) and assumed the default `platform` power-off worked. It
doesn't on this firmware — which is why hibernate appeared to "half-work" (write + resume OK,
power-off bouncing). This issue is the missing final piece: **`shutdown` mode.** It also
refines issue #2's success test — *"`boot_id` unchanged = success"* is incomplete; you must
also confirm a true power-off, or a bounce reads as a pass.
