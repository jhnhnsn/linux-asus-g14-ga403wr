# Removing the boot logos — CachyOS splash (done) and the ROG firmware animation (experiment)

There are **two** logos at startup, and they live in completely different layers:

| Logo | When | Layer | Removable from Linux? |
|---|---|---|---|
| **ROG animation + chime** | the instant you power on, before the OS | **firmware** (UEFI) | maybe — via an EFI variable (this doc) |
| **CachyOS logo** (lower-center, with spinner) | during kernel/initramfs boot | **Plymouth** splash | yes — done, see below |

---

## Part 1 — CachyOS Plymouth splash (DONE, 2026-06-13)

The lower CachyOS logo is the **Plymouth** boot splash, triggered purely by the `splash`
token on the kernel cmdline. Removed by deleting `splash` from `KERNEL_CMDLINE[default]` in
**`/etc/default/limine`** (see README issue #4 — never edit `/boot/limine.conf` directly), then:

```bash
sudo limine-update
```

Result: no CachyOS logo during boot; `quiet` is kept so the boot stays clean. The ROG firmware
animation is unaffected (different layer). To revert: add `splash` back and re-run `limine-update`.

> Note: `limine-update` currently logs an `autodetect` failure (`Cannot acquire used modules`)
> caused by a stale NVIDIA backlight path under `/sys`. It's pre-existing and **not** caused by
> this change — mkinitcpio safely falls back to a full (all-modules) initramfs and the build
> succeeds. Tracked separately.

---

## Part 2 — ROG firmware animation + chime (EFI variable experiment — NOT YET DONE)

The animated ROG logo with sound plays **before the kernel loads** (audio stack isn't even up
yet), so nothing in Linux — Limine, cmdline, Plymouth — can touch it. The only OS-side lever is
a UEFI variable, *if* the firmware exposes a writable one. It does. While scanning
`/sys/firmware/efi/efivars` we found:

```
AsusAnimationSetupConfig-607005d5-3f75-4b2e-98f0-85ba66797a3e
  size: 7 bytes
  bytes: 07 00 00 00 | 00 01 00
         └─ attrs ──┘  └─ data ─┘
```

- **Attributes `0x07`** = NV + BootService + **Runtime** → writable from the running OS.
  No BIOS modding, no reflash. (ASUS ships **signed BIOS capsules** on this generation, so the
  classic "swap the logo BMP and reflash" mod is blocked anyway — this var is the only viable path.)
- **Name** — literally `AnimationSetupConfig`, almost certainly the boot-animation setting the
  BIOS menu writes (the GA403 user-facing BIOS has no visible toggle for it).
- **Data `00 01 00`** — the middle `01` looks like an enable flag. The exact byte semantics are a
  **guess** (no HII map), so this is an experiment: flipping it may disable the animation, the
  chime, both, or do nothing.

### Risk

**Low, but not zero.** It's the same NV variable the BIOS setup menu itself writes; worst realistic
outcome is "no effect," or a setting you reset via **Load Optimized Defaults** / CMOS clear in the
BIOS. Still firmware, so back up the exact bytes first (the script does) and change one thing at a time.

### The plan (run tomorrow)

Use [`scripts/disable-rog-boot-animation.sh`](../scripts/disable-rog-boot-animation.sh), or by hand:

```bash
VAR=/sys/firmware/efi/efivars/AsusAnimationSetupConfig-607005d5-3f75-4b2e-98f0-85ba66797a3e

# 1. Back up exact current bytes (07 00 00 00 00 01 00)
sudo cp "$VAR" ~/AsusAnimationSetupConfig.bak

# 2. efivars are immutable by default — clear the flag, then write attrs + new data
sudo chattr -i "$VAR"
printf '\x07\x00\x00\x00\x00\x00\x00' | sudo tee "$VAR" >/dev/null   # data 00 -> 00 00 (middle byte 01->00)

# 3. Reboot and observe: did the animation stop? the chime? both? neither?
```

### Restore

```bash
VAR=/sys/firmware/efi/efivars/AsusAnimationSetupConfig-607005d5-3f75-4b2e-98f0-85ba66797a3e
sudo chattr -i "$VAR" 2>/dev/null
printf '\x07\x00\x00\x00\x00\x01\x00' | sudo tee "$VAR" >/dev/null    # original bytes
# …or just `Load Optimized Defaults` in the BIOS.
```

### If flipping the middle byte does nothing

The flag may be a different byte. Try them one at a time (reboot between each), restoring to
`00 01 00` first if a change misbehaves:

- `00 00 00` — middle byte (most likely): primary attempt above
- `00 01 00` → leave middle, try first byte? It's already `00`. Try `01 01 00` only if the others
  are inert (less likely to be the flag).
- The third byte is `00`; setting `00 01 01` is another low-probability candidate.

Record what each value does in this file when we test it.

### Results log

- _2026-06-13_ — found the variable, documented the plan. **Not yet written/tested.**
