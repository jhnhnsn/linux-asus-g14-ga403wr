# amdgpu MES / graphics-ring reset-path wedge (gfx1150) — known issue, no proven fix

> **TL;DR** Separate from the nvidia suspend bug. The **amdgpu iGPU** (Radeon 890M = gfx1150,
> Ryzen AI 9 HX 370) intermittently wedges its MES (MicroEngine Scheduler) + graphics-ring
> reset path → black screen on resume. It is **not** suspend-specific (it also reproduces under
> pure compute load on this exact silicon). **As of June 2026 there is no proven parameter cure.**
> Do not chase `cwsr_enable=0`, `mes=0`, or `gpu_recovery=0`. The right posture is the one
> already in place: hibernate-on-lid, a current kernel + MES firmware, and GPU recovery left on.

## Signature

Intermittent, seen on a hibernate resume (a prior resume the same session was clean):
```
amdgpu 0000:65:00.0: ring gfx_0.0.0 timeout, signaled seq=…, emitted seq=…
amdgpu 0000:65:00.0: Starting gfx_0.0.0 ring reset
amdgpu 0000:65:00.0: MES failed to respond to msg=RESET
amdgpu 0000:65:00.0: reset via MES failed and try pipe reset -110
amdgpu 0000:65:00.0: Ring gfx_0.0.0 reset failed
amdgpu 0000:65:00.0: GPU reset begin!. Source: 1
amdgpu 0000:65:00.0: MES failed to respond to msg=REMOVE_QUEUE   (loops every ~3s)
```
The compositor (niri, on Mesa/amdgpu) then `SIGABRT`s in `dri_create_fence_fd`, so the whole
session is lost. **No disk corruption** — btrfs error counters stay zero and the hibernate image
restores fine; this is purely GPU state.

## Root cause (deep-research, adversarially verified June 2026)

A **general MES / graphics-ring (`gfx_0.0.0`) reset-path fragility — not a suspend/resume bug.**
The decisive evidence: the identical signature reproduces on this *exact* silicon (gfx1150/890M)
under **pure compute load with no suspend at all** ([ROCm/TheRock #1271][1]). Suspend/resume is
just one of several triggers of the same fragile path; once MES stops answering, the GPU-reset
path *itself* fails (`reset via MES failed`, repeated `MES failed to respond`), leaving the GPU
wedged. AMD (Alex Deucher) is actively reworking the gfx11 graphics-ring (kgq) reset code
upstream, so this is a moving target.

## What does NOT work (verified / invalid)

| Knob | Verdict |
|---|---|
| `amdgpu.cwsr_enable=0` | **Unproven for this.** CWSR is a *compute* wave save/restore workaround ([ROCm #5590][2], [#5724][3]); mechanistically mismatched to the graphics-ring wedge. The "works on gfx1150" claim is hearsay (refuted in verification) and it did **not** help on the sibling gfx1152 ([#5844][4]). Low-risk but not a fix. |
| `amdgpu.mes=0` / `mes_kiq=0` | **No-op on gfx11+.** MES is integral; the param is ignored and being removed, and AMD's engineer told users to stop using it ([Framework #52][5]). |
| `amdgpu.gpu_recovery=0` | **Harmful** — recovery is exactly what's failing; disabling it guarantees the wedge. |
| `lr_compute_wa` (commit `1fb7107`) | Targeted long compute jobs, was insufficient, and was **reverted in the 6.19 cycle** (`6b0d812`). Irrelevant to the graphics-ring case. |

## Correct posture (already in place here)

1. **Hibernate on lid close** (issue #2) — avoids most s2idle resume cycling.
2. **Current kernel + MES firmware** — kernel `7.0.12-cachyos`, `linux-firmware 1:20260519` is
   already past the bad **MES 0x83** regression onto **0x86+** ([ROCm #6165][6]), the right place to be.
3. **Keep updating the kernel** — the one genuinely useful lever, since the gfx11 reset path is
   under active rework upstream.
4. **Leave GPU recovery on.**
5. **Recovery when it happens:** if the screen goes black on resume, switch to a TTY
   (**Ctrl+Alt+F2**) to give amdgpu room to reset — do **not** hit the power button (which, via
   DMS, suspends again and stacks another cycle onto a wedged GPU).

[1]: https://github.com/ROCm/TheRock/issues/1271
[2]: https://github.com/ROCm/ROCm/issues/5590
[3]: https://github.com/ROCm/ROCm/issues/5724
[4]: https://github.com/ROCm/ROCm/issues/5844
[5]: https://community.frame.work/t/amd-gpu-mes-timeouts-causing-system-hangs-on-framework-laptop-13-amd-ai-300-series/71364/52
[6]: https://github.com/ROCm/ROCm/issues/6165
