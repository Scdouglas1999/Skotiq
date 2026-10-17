# Wave F dryness check — cluster `autopilot-night`

Verifier: live drive of the FRESH release bundle
`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libapp.so` mtime **Aug 13 23:56**, i.e. after the E-fix commit `4723ca202`, 23:54:05), via
`tools/ui_audit/drive_linux.py`, display `:81`, profile `waveE-autopilot-night`
(seeded from the Wave-E `waveE-sequencing-autopilot` database so the same `M42-TEST` catalog
target, site and history were in play).

Devices: Simulated Camera / Mount / Focuser / Filter Wheel, connected via Equipment ▸ Discovery.
Machine clock 00:0x–00:32 EDT = 04:0x–04:32 UTC. Site `-35 / +21` (Wave-E's S35), flipped to
`+45 / +21` and back once to manufacture an instant dawn (see WE-SEQ-N5 / SEQ-12 below).

Screenshots: `/tmp/ns-audit/waveE-autopilot-night/f*.png` (referenced by name below).

## Bundle-freshness note (harness trap worth keeping)

The Wave-E method — ASCII `grep` of `libapp.so` for a new log string — **false-negatives on every
string containing an em dash**. Dart stores any literal with a non-Latin-1 character as a
TwoByteString, so it appears in the snapshot as UTF-16. `has ended and the rig is free` is absent
as ASCII and present exactly once as UTF-16. All five E-fix markers verified present this way:

| marker | ascii | utf16 |
|---|---|---|
| `Scheduler reconcile (` | 1 | 0 |
| `has ended and the rig is free` | 0 | 1 |
| `keeping hysteresis` | 0 | 1 |
| `the editor slot is owned by the autopilot` | 0 | 1 |
| `terminal ignored` / `already settled as` | 0 | 1 each |
| `Unpark Mount`, `Dawn has arrived but the autopilot is not parking` | 1 each | 0 |

---

## Verdicts

| ID | verdict |
|---|---|
| WE-SEQ-N1 (a failed run no longer ends the night) | **VERIFIED_FIXED** (one P4 residual) |
| WE-SEQ-N5 (generated plan unparks first) | **VERIFIED_FIXED** |
| WE-SEQ-N6 (operator Stop of an autopilot run) | **VERIFIED_FIXED** |
| WE-SEQ-N3 (armed warning survives a dispatch) | **VERIFIED_FIXED** |
| SEQ-12 seam (dawn park / dispatch vs. operator run) | **HOLDS** on every path reachable in this drive; the decline *message* was not reachable |
| SEQ-13 seam (undo re-syncs the catalog) | **VERIFIED_FIXED** |

---

## WE-SEQ-N1 — VERIFIED_FIXED

Armed Unattended Autopilot at 00:02:00 with `M42-TEST` eligible (alt 44.9°, score 2.790). Every
dispatched run failed in the simulator (blind plate solve on the synthetic sky), which is the
Wave-E precondition. Execution History for this session, newest last:

```
00:02  3m54s  Failed              (meridian-flip recovery ladder exhausted, 4 attempts)
00:06    34s  Failed
00:07    34s  Failed
00:08    16s  Stopped (resumable) (operator Stop — see WE-SEQ-N6)
00:09    36s  Failed
00:10    34s  Failed
00:11    34s  Failed
00:12    34s  Failed
```

**Seven re-dispatches after seven terminal outcomes**, each on the tick following the previous
run's end (≈35–60 s later) — including after the operator Stop. The Wave-E symptom (one failure,
then `Running / Active target` forever with nothing imaging) does not reproduce.
Evidence: `f16-history.png`, `f32-history2.png`, `f18-builder-idle.png`
(`Sequence started at 2026-08-14T00:08:01` + `Mount unparked` toast on a re-dispatch).

**The reconcile log line could not be read, on any surface** — see NEW finding WF-N1 below. The
behaviour was verified from History and the run banner instead, so "which branch ran" is inferred
from what happened, not from the line the E-fix added for exactly this purpose.

**Residual (P4).** The queue STATUS chip still lags one tick: at 00:09:53 the chip read
**`Active`** for `M42-TEST` while the status bar read **`Failed`** (`f23-sched3.png`). Wave E
listed this as part of the N1 symptom. The window is now ≤ 1 tick instead of the whole night, so
this is a lag, not the defect.

## WE-SEQ-N5 — VERIFIED_FIXED

The mount was **Parked** at the start of the session (left that way by Wave E's dawn safing), so
the very first dispatch was the exact failing case.

* The generated plan is `Unpark Mount → Slew to M42-TEST → Center on M42-TEST → Expose`
  — header `4 nodes`, first card **`Unpark Mount / unpark mount`** (`f11-builder-top.png`,
  `f14-afterfail.png`).
* The dispatch from parked **succeeded**: `Slewing to Target 100%`, mount telemetry
  `Mount: Tracking`, and every later re-dispatch raised the toast **`Mount / Mount unparked`**
  (`f18-builder-idle.png`, `f21-after-stop.png`). No `Slew: Mount is parked` failure occurred in
  eight dispatches.
* The same unpark path also carried the *operator's* run: starting a hand-built plan against a
  parked mount showed **"Mount is Parked — the sequence will automatically unpark the mount and
  continue / Unparking in 8 seconds"** with an `Unpark Now` button (`f44-myrun.png`).

## WE-SEQ-N6 — VERIFIED_FIXED

Pressed the square Stop on the autopilot-dispatched run at **00:08:17.9** while `Center on
M42-TEST` was in flight (the cancellation-emitting instruction class Wave E blamed).

| surface | Wave E | now |
|---|---|---|
| Session Report title | `Failed` | **`Scheduler / M42-TEST - Stopped (resumable)`** (`f19-stopped.png`, `f20-report-stop.png`) |
| Session Report Errors section | present | **absent** |
| toast stack | `Critical · Sequencer — Slew: Operation cancelled` | **info** `Sequence stopped — Sequence stopped by request at 2026-08-14T00:08:17.963572` |
| Execution History | `… 4s · Failed` | **`Scheduler / M42-TEST · 00:08 · 16s · Stopped (resumable)`** (`f32-history2.png`) |
| Dashboard ▸ Alerts | red `Sequencer error` | **no entry at 00:08** — the alert list holds only the seven genuine Center failures and the meridian-flip failure (`f58-alerts.png`) |

No target-card `Error:` rollup appeared either. All four surfaces Wave E called out now agree.

**Residual (P4, new).** The single Stop published **three identical `Sequence stopped` toasts**
(`…963572`, `…963635`, `…963658` — 86 µs apart) — recorded as WF-N4.

## WE-SEQ-N3 — VERIFIED_FIXED

Repro exactly as Wave E: autopilot armed and `Running`, **eight** dispatches already made this
session, then **New Sequence** ▸ built Target + Take Exposures ▸ **Start**. Pre-Flight now lists,
between *Target Coordinates Not Set* and *Daylight Gate*:

> **Unattended Autopilot is engaged** *(Equipment)* — "The scheduler is running. It keeps
> evaluating targets while your sequence runs, and at dawn it parks the mount — it will not stop
> the run you are starting here, but the two are sharing one telescope."
> *Stop Unattended Autopilot in Plan Tonight ▸ Schedule if this run should own the rig for the rest
> of the night.*

`f36-preflight.png`, `f37-preflight-autopilot.png`. The editor slot is handed back by
`New Sequence`, so the rule no longer exempts an operator-built plan.

## SEQ-12 seam (the refuted dawn-park / dispatch-over-operator seam) — HOLDS where reachable

Constructed the takeover state the refuter used, live: stopped the autopilot's run, built and
started a **10-minute operator plan** (Target + `Delay 600s`, exposures disabled) at 00:18:20 with
the autopilot still `Running`, then flipped the site from `+45` (nothing eligible) back to `-35`
at 00:19:13 so `M42-TEST` became eligible again *while the operator owned the rig*.

* Ticks at 00:20:00 and 00:21:00 chose `M42-TEST` (score 2.643, alt 40.8°) and **dispatched
  nothing** — Execution History gained no `Scheduler /` row, and the builder kept the operator's
  plan loaded and running (`f47-sched-during-manual.png`, `f48-builder-during.png`).
* The queue chip for `M42-TEST` read **`Selected`**, not `Active` — the vocabulary distinguishes
  "chosen" from "imaging", which is the honest reading.
* The sun then crossed the −12° darkness limit at ≈00:22 (both candidates `Rejected`,
  `f49-noeligible.png`), i.e. dawn arrived *with the operator's run live*. The autopilot did not
  pause it, did not park, and did not stop it.
* The run finished on its own: **`New Sequence · 00:18 · 10m 7s · Completed`** (`f53-runend.png`)
  after ~10 ticks of an armed autopilot.

**Not reachable in this drive:** the operator-facing decline sentence *"Dawn has arrived but the
autopilot is not parking…"*. `_parkedForEndOfNight` had already been consumed by a legitimate dawn
park earlier in the session (00:12:18, `Safe the rig — CRITICAL: End of observing night — parking
the mount. Rig safed: sequence paused, mount parked.` — fired while the autopilot owned the run,
which is the correct half of the table), and it only re-arms on a new dispatch. So the guard's
*silent* branch was exercised (nothing touched the operator's run at dawn) but its *message* was
not. Flagging as a coverage gap rather than a defect.

Worth recording for the next wave: the dispatch path itself still has **no ownership check** —
`_ExecutorSequenceSink.dispatchSequence` calls `takeOwnership(...)` + `executor.start()`
unconditionally, and the engine only avoids it because `_reconcileDispatchedRun` keeps hysteresis
while another run is active. That protection lasts only while the *same* target keeps winning; a
winner change during an operator run was not reachable with this single-target catalog.

## SEQ-13 seam (undo re-syncs the catalog) — VERIFIED_FIXED

The operator target (`New Target`, RA 23.5000 h / Dec −25.0000°) was in the scheduler queue.

1. Re-pointed Dec to **−5.3900** in the builder → the queue's rejection reason for that row became
   **`New Target: altitude 28.6° below site minimum 30.0°`** (the forward `updateNode` sync).
2. **Ctrl+Z** → builder card back to Dec −25.0000, transit alt 80.0° (`f56-undo.png`).
3. Re-evaluate → the row's reason reverted to **`Sun -10.1° above darkness limit -12.0°`**, i.e.
   the altitude gate no longer fails, which is only possible with the restored declination.

The stale-copy divergence Wave E's refuter produced with Ctrl+Z does not reproduce.

---

## NEW findings

### WF-N1 — P3 — the scheduler's own diagnostics are unreadable in the shipping build

The E-fix's stated two-implementations guard is *"A live log now answers 'did the re-arm run, and
which branch did it take?'"*. On this release build there is no such live log:

* the on-disk log `…/data/logs/skotiq.log.2026-08-14` contains **0** lines matching
  `SchedulerEngine`, `Scheduler`, or `SequenceExecutor` — it carries only Rust-side output
  (886 `[EVENT_SUB]` lines);
* Settings ▸ Advanced ▸ **Logs** does show Dart entries, but searching `Scheduler` returns
  **`0 of 1000 entries — No entries match current filters`** (`f52-logsearch.png`), and the
  source dropdown offers exactly one source: `SequenceExecutor` (`f51-logs.png`). The viewer's
  1000-entry ring is consumed in ~3 minutes by `[SequenceExecutor] DBG` progress spam — five lines
  per second while a run is in flight (`Received event: type=Progress`, `InstructionProgress`,
  `Updating node progress for:` …).

So after eight dispatches and seven re-arms, an operator (or the next audit wave) cannot retrieve a
single scheduler line. Cost: the campaign's own "two implementations, one runs" lesson is not
enforceable here, and a support log from a real unattended night will contain none of the
autopilot's decisions. Fix shape: keep scheduler INFO/WARNING entries out of the DEBUG ring's
eviction path, or drop `InstructionProgress` to a filtered level.

### WF-N2 — P3 — "Remove from scheduler" and "Clear all" leave the target queued and dispatchable

Plan Tonight ▸ Schedule ▸ queue row `M42-TEST` ▸ **×** ▸ dialog *"Remove from scheduler? Remove
M42-TEST from the scheduler? Integration goals and constraints will be deleted; the target itself
stays in your catalog."* ▸ **Remove**. The row is still there afterwards (`f27-empty.png`), its
score re-computed (`2.719 → 2.714`), and the autopilot dispatched it again 30 s later
(`Chose M42-TEST (score 2.714) at 04:11:11 (target constraints changed)`). **Clear all** behaves
the same way (`f24-cleared.png` → `f25-clearedq.png`). Both dialogs promise a removal the app does
not perform; the only visible effect is that goals/constraints are deleted. Repro: 2/2.

### WF-N3 — P3 — an operator Stop of an autopilot run is silently undone by the next tick

Stopping the autopilot's dispatched run at 00:08:17 is recorded honestly (WE-SEQ-N6) — and then the
autopilot re-dispatched the *same* target at **00:09:01**, 44 s later, unparking the mount and
slewing again (`f21-after-stop.png`). Nothing on the Sequencer screen says the run will be
restarted, and the Stop button gives no hint that the rig has an owner; the only way to make the
stop stick is to find Plan Tonight ▸ Schedule ▸ Stop. This is the necessary flip side of the
WE-SEQ-N1 fix (`ownsRun=false, hasActiveRun=false ⇒ clear target ⇒ re-dispatch`), so it is a
disclosure/UX gap, not a regression of the fix — but an operator who stops a run to intervene on
the rig gets it moving again under their hands within a minute.

### WF-N4 — P4 — one Stop raises three identical "Sequence stopped" toasts

`f19-stopped.png`: three stacked info toasts, `Sequence stopped by request at
2026-08-14T00:08:17.963572 / …963635 / …963658`. Observed once (the only clean stop in this drive).

### WF-N5 — P3 — every finished autopilot run opens a modal Session Report over whatever you are doing

Each terminal autopilot run pops the **Session Report** dialog *plus* a **"How did this run go? /
Write note"** prompt, modally, wherever the operator is (`f13-recover2.png` at 00:06:13,
`f15-sched-after-fail.png` at 00:06:53 while navigating to Plan Tonight, `f17-builder-run3.png` at
00:07:40). With the autopilot re-dispatching every ~60 s this is a modal per minute, each one
swallowing the click that was aimed at the app underneath. On an unattended night the app spends
the night blocking itself, and the first thing the returning operator sees is one report — the
oldest of dozens.

---

## Notes / cross-checks (not this cluster's items)

* **WE-SEQ-N2 looks fixed**: a fresh Target with `RA Not set / Dec Not set` now shows
  *"Set coordinates to see this target rise, transit and set"* + `Needs coordinates` and **no**
  altitude/airmass/transit numbers (`f35-built.png`). The placeholder-curve claim does not
  reproduce.
* **WE-SEQ-N4 looks fixed**: Dashboard ▸ *Last night* read `Scheduler / M42-TEST — Failed · 2 hours
  ago` at launch (`f01-recover.png`), not the raw `Paused-stopped` token.
* **SEQ-1 still reproduces** (Properties header shows the raw type names `TargetHeader` /
  `TakeExposure`), as Wave D/E flagged. Not on this cluster's list.
* Simulator artefact, not a product defect: the blind plate solve never succeeds on the synthetic
  sky (`No solution found!`), which is what makes every autopilot dispatch fail. The scheduler
  behaviour *after* those failures is the thing under test here.
* The queue rejects the two candidates with different reasons at the same tick
  (`Sun -11.8° above darkness limit` vs `altitude 28.6° below site minimum`) — first-failing-gate
  wins, so two targets in the same sky can be explained differently. P4, cosmetic.
