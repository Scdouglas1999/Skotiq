# Wave E dryness check — cluster `sequencing-autopilot`

Verifier: live re-drive of the FRESH release bundle
`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libapp.so` mtime **Aug 13 20:33**, i.e. after the D-fix commit `baddf35fd`), via
`tools/ui_audit/drive_linux.py`, display `:81`, profile `waveE-sequencing-autopilot`.

Bundle freshness proved by string-grep of `libapp.so`: `No filter set`, `(current)`,
`AutopilotArmedRule`, `ownsRun` all present (all introduced by the D-fix batches).

Devices: Simulated Camera / Mount / Focuser / Filter Wheel connected via Equipment → Discovery.
The scratch profile was seeded from the Wave-D profile's database so the same catalog target
(`M42-TEST`) and history were in play.

Site configurations used (machine clock 20:3x–21:2x EDT = 00:3x–01:2x UTC):

| config | lat / lon | M42-TEST altitude | purpose |
|---|---|---|---|
| N45 | +45 / +21 | RA 23.5 h / Dec +45° ⇒ **87–89°** | eligible; autopilot dispatches |
| S35 | −35 / +21 | same target ⇒ **9.8°** | above horizon, below the 30° site minimum ⇒ *nothing eligible* |

Screenshots kept in `reports/release-pass/gui/shots/waveE-sequencing/`; working captures in
`/tmp/ns-audit/waveE-sequencing-autopilot/`.

---

## Verdicts

| ID | verdict |
|---|---|
| SEQ-12 (hardened ownership) | **VERIFIED_FIXED** |
| SEQ-13 (edited coords used by Re-evaluate) | **VERIFIED_FIXED** |
| SEQ-19 (one filter story) | **VERIFIED_FIXED** |
| SEQ-20 (elapsed in seconds) | **VERIFIED_FIXED** |
| WD-SEQ-N6 (armed-autopilot warning) | **VERIFIED_FIXED** (one residual, WE-SEQ-N3) |
| SCI-43 (pre-flight copy) | **VERIFIED_FIXED** |
| SEQ-18 (node card N/N after success) | **STILL_BROKEN** |
| WD-SEQ-N1 (operator Stop is not an error) | **STILL_BROKEN** (partial — report fixed, banners/alerts not) |
| WD-SEQ-N2 (900 px builder) | **VERIFIED_FIXED** (one regression, WE-SEQ-N7) |
| WD-SEQ-N4 (“Below horizon” at +9.8°) | **STILL_BROKEN** |

---

## VERIFIED_FIXED

### SEQ-12 — autopilot ownership is now hardened, at the tick boundary too

Config S35, so the armed autopilot reports **“No eligible target right now.”** with
`No eligible candidates at 2026-08-14T01:02:13Z (engine start)` /
`M42-TEST: altitude 9.8° below site minimum 30.0°` — ticks land on **:13** of each minute.

* Pre-flight for the hand-started run was opened while the autopilot was armed, and
  **Start Anyway was clicked at 21:03:11 — two seconds before the 21:03:13 tick**, i.e. the
  dispatch/stop race window the Wave-D refuter used.
* The run survived that tick and the next one (`2/4 done` at 21:03:44, `3/4 done` at 21:04:03)
  and finished **Completed, frames accepted 4/4** (`e34-manualdone.png`).
* The autopilot stayed `Running` throughout and never touched the run.

The complementary direction is also right: when the autopilot *does* own the rig it takes it
explicitly — the builder header changes to **“Scheduler / M42-TEST”** with the generated
Slew → Center → Expose plan (`e27-builder-after.png`).

### SEQ-13 — a re-pointed target is scheduled at its new coordinates

Config N45. Catalog row `M42-TEST` had been left at the Wave-D coordinates. In the builder the
target was re-pointed to **RA 23.5000 h / Dec +45.0000°** and nothing else was touched.

Immediately afterwards, without a run:

* Plan Tonight ▸ Recommendation: **“AUTOPILOT WILL RUN — M42-TEST … (score 4.552)”** (it had said
  *“Nothing eligible right now”* before the edit).
* Plan Tonight ▸ Schedule ▸ Reasoning: `Chose M42-TEST (score 4.552) … altitude … alt 89.1°` —
  89.1° is the altitude of the **new** coordinates at that LST (23:35), not the old ones.
* Scheduler queue row: `M42-TEST 4.552 Selected`, one row (the sync updates the row, it does not
  create a second one).

The Wave-D failure (builder −19.4° vs scheduler 86.3°) does not reproduce.

### SEQ-19 — the card no longer denies the filter the run used

Exposure node with **Filter = (None)** in Properties, run through the wheel's `R`:
the exposure panel header now reads **“Exposure: R (current)”** (`e17-nodecard.png`,
`e20-banners.png`), matching the telemetry strip (`Filter: R`), the `R` thumbnails, the
`M42-TEST_R_*.fits` filenames and the Session Report's per-filter row `R`.

### SEQ-20 — the live elapsed readout is in seconds

4 × 15 s run, target card readouts sampled during the run:
`0/4 done • 0s / 1m` (t≈8 s) → `1/4 done • 15s / 1m` → `2/4 done • 30s / 1m`,
against the panel above it reading `~34s · done ~20:45:36`. No `0m / 1m` anywhere.

### WD-SEQ-N6 — pre-flight now says the autopilot is armed

Autopilot `Running` (config S35, nothing eligible), operator plan loaded, Sequencer ▸ Start:

> **Unattended Autopilot is engaged** *(Equipment)* — “The scheduler is running. It keeps
> evaluating targets while your sequence runs, and at dawn it parks the mount — it will not stop
> the run you are starting here, but the two are sharing one telescope.”
> *Stop Unattended Autopilot in Plan Tonight ▸ Schedule if this run should own the rig for the
> rest of the night.*

Residual recorded as **WE-SEQ-N3** below: the warning is suppressed once the autopilot has
dispatched a plan in this session, even for a plan the operator built afterwards.

### WD-SEQ-N2 — the builder is usable at 900 px

`resize 900 900` on Sequencer ▸ Builder (`shots/waveE-sequencing/wdseqn2-900px-fixed.png`):
both side panes collapse to a single icon each and the canvas takes the full ~610 px. Every
Wave-D artefact is gone — no bare `×` on its own row, no clipped `Total`, `+ Add note` renders
whole, the target rollup is not truncated, and the three instruction cards
(`Slew to M42-TEST` / `Center on M42-TEST` / `Expose 1 × 30s 1x1`) render complete.
1600 × 900 is unchanged. The collapse does not write the user's pane preferences: widening back
to 1600 restored the palette exactly as it was.

### SCI-43 — the pre-flight hint names a screen that exists

Sequencer ▸ Start ▸ Pre-Flight ▸ *Missing Dark Frames* now reads
“…Open **Settings → Equipment → Dark Library** to schedule them…”. `Calibration →` no longer
appears; Settings ▸ EQUIPMENT is a real group in the live Settings tree.

---

## STILL_BROKEN

### SEQ-18 — P2 — a fully successful run still leaves the node card at 0 / N

Reproduced **twice** on this build, both times after a Session Report that said
`Frames accepted 4/4`:

* run at 20:44–20:45 → node card reads **“Exposure: R (current) — 0 / 4 frames”** with four
  EMPTY progress boxes directly above four `R`-labelled thumbnails
  (`shots/waveE-sequencing/seq18-still-0of4.png`);
* run at 21:03–21:04 (4/4 accepted) → same card, same `0 / 4 frames`.

The stop path still behaves correctly: after the run stopped at frame 2 the same card read
**“2 / 4 frames”** with two filled boxes (`e20-banners.png`), so the zeroing remains specific to
the success path. The D-fix's "remember the last non-null progress" retention does not change
what the operator sees here.

### WD-SEQ-N1 — P2 — an operator Stop is still reported as an error (3 of 4 surfaces)

Started a 4 × 15 s run, pressed the square Stop at 20:47:53 with 2 frames captured.

**Fixed:** the Session Report titles itself *“New Sequence - Stopped (resumable)”*, has **no**
`Errors` section, and states *“You stopped this run. Everything captured before the stop is
saved.”*

**Not fixed** — the same action, at the same second:

| surface | text |
|---|---|
| toast stack (Sequencer) | red **“Sequence failed / Sequence aborted at 2026-08-13T20:47:53.241493”** (`e19-stopped.png`) |
| toast stack | **“Critical · Sequencer / Sequence cancelled”** (a11y tree) |
| Dashboard, full-width red banner | **“Sequencer — Sequencer error 20:47:53 / Sequence cancelled”** (`shots/waveE-sequencing/wdseqn1-stop-error-banner.png`) |
| Dashboard ▸ RECENT EVENTS | `Sequencer error — Sequence cancelled` beside `Sequence stopped` and `manual_intervention #8: Operator: stop` |
| Sequencer target rollup | **“Error: Sequence cancelled”** in red on the target card (`e20-banners.png`) |

So the app records the deliberate operator action correctly *and also* raises a Sequencer **error**
alert for it, on a persistent Dashboard banner rather than only a toast. The D-fix's own note
(“the two banner instances come from `notification_router.dart` 527/590, outside this batch's
scope”) is accurate as far as it goes, but the target-card rollup (`Error: Sequence cancelled`)
is a *third* surface that was not recorded.

Answer to the assigned question about the bell: this build has no bell/notification-centre control
in the app chrome (top bar is night-vision / remote / account / settings only); the persistent
notification surface is the Dashboard **Alerts** card, and it carries the critical entry above.

### WD-SEQ-N4 — P3 — the queue STATUS chip still says “Below horizon” at +9.8°

Config S35, Plan Tonight ▸ Schedule (`shots/waveE-sequencing/wdseqn4-below-horizon-at-9.8deg.png`):

```
M42-TEST      3.055   [ Below horizon ]     No integration goals
altitude 9.8° below site minimum 30.0°
```

Verbatim the Wave-D symptom. The D-fix landed in the **engine** —
`packages/skotiq_core/lib/src/services/scheduler/scheduler_engine/evaluation.dart:503-517`
now produces `too low (9.8° < site minimum 30.0°)` — but the chip the operator reads is rendered
by `packages/skotiq_app/lib/screens/scheduler/widgets/target_score_row.dart:175-198`, whose
`_statusLabel()` still maps *any* reason containing `altitude` + `below` to the literal
`'Below horizon'`, and that file is untouched. Two implementations of the same label; the fixed
one is not the one on screen.

---

## NEW findings

### WE-SEQ-N1 — P1 — one failed run ends the unattended night, while the panel keeps saying “Running / Active”

With Unattended Autopilot armed and an eligible target, the autopilot dispatched its own
`Scheduler / M42-TEST` plan (Slew → Center → Expose). The run **failed**
(`Center Target: Failed to center within 5.0" after 5 attempts`) 35 s later. From that moment:

* the executor stays `Failed` and **no further run is ever dispatched**;
* the autopilot keeps ticking every 60 s and keeps *choosing the same target* —
  `Chose M42-TEST (score 4.501) at 00:52:51Z (tick)`, `… 4.496 at 00:53:51Z`,
  `… 4.491 at 00:54:51Z`, `… 4.486 at 00:55:51Z`;
* the panel reports **Unattended Autopilot — Running — Active target M42-TEST**, and the scheduler
  queue's STATUS chip reads **Active** — i.e. “this target is being imaged right now” — while the
  status bar six inches away reads **Failed**
  (`shots/waveE-sequencing/e26-stuck-autopilot.png`).

Reproduced twice (runs failing at 20:51:26 and ~21:07:30); the second time it was still
`Running / Active target / Next target check in 54s` four minutes later with nothing imaging.
It recovers only if the winning target changes or the engine is restarted: after the site was
moved to S35 (nothing eligible) and back to N45, the very next evaluation dispatched again.

This matches the mechanism the Wave-D refuter documented and the D-fix did not close:
`packages/skotiq_core/lib/src/providers/scheduler_provider.dart:120-131` maps **only**
`SequencerEvent_Completed` to `sequenceCompleted` and returns null for Stopped/Failed/Aborted, so
`currentTargetId` stays pinned to the target of a run that is over. The D-fix hardened `stop()`
and `_handleNoEligibleTarget` against that stale state; the *dispatch* path still trusts it.

Cost: the headline unattended feature silently images nothing for the rest of the night after a
single failed centre, and every surface says it is on target. Repro: arm the autopilot with an
eligible target whose plan fails (plate solve failing is enough), then watch three ticks.

### WE-SEQ-N2 — P3 — the target card plots a full altitude curve for a target whose coordinates are “Not set”

A freshly added Target node shows, in the same card:
`RA Not set  Dec Not set` and a footer `Needs coordinates` — *and* an Altitude panel reading
`Alt: 44.7°  Airmass: 1.42`, a plotted curve, and `Rise: 15:03 / Transit: 21:06 / Set: 03:08 /
Transit alt: 45.0°` (`e08-target.png`). Those are the numbers for RA 0 h / Dec 0° at latitude 45 —
the placeholder the Properties panel explicitly warns about (“Coordinates not set — this target
still points at the 0h/+0° default”). One half of the card says there is nothing to compute; the
other half quietly computes it and presents it as the target's visibility.

### WE-SEQ-N3 — P3 — the armed-autopilot warning is suppressed after the autopilot has dispatched once (WD-SEQ-N6 residual)

Sequence: autopilot armed with an eligible target ⇒ it dispatches `Scheduler / M42-TEST` ⇒ that run
ends ⇒ operator presses **New Sequence** and builds their own Target + Take Exposures ⇒ **Start**.
Pre-flight lists *Target Coordinates Not Set*, *Disk space*, *Missing Dark Frames* — and **no**
“Unattended Autopilot is engaged” entry, although the scheduler is `Running`.

`AutopilotArmedRule` returns early when `activePlanOwnerProvider == ActivePlanOwner.autopilot`
(correct in itself — the scheduler must not be warned about itself), but that ownership is not
handed back when the operator starts a brand-new plan, so the warning is missing in exactly the
case where two owners have already contended for the rig. With a fresh app state and no prior
dispatch, the warning does appear (verified above).

Reproduced twice — the second time with the autopilot panel confirmed **Running / Active target
M42-TEST / Next target check in 57s** sixty seconds before pressing Start.

### WE-SEQ-N4 — P3 — the Dashboard “Last night” card prints the raw status token `Paused-stopped`

Dashboard ▸ *Last night*: **“New Sequence / Paused-stopped · 1 hour ago”** (`e01-recover.png`,
a11y tree line `panel: Paused-stopped · 1 hour ago`). SEQ-6 replaced this vocabulary everywhere
Wave D looked (History chips, Session Report title = `Stopped (resumable)`); this card still
renders the enum.

### WE-SEQ-N5 — P2 — the autopilot's own plan has no Unpark, so every dispatch after a safing park fails instantly

At 21:14 the safety layer fired **“Safe the rig — CRITICAL: Astronomical dawn is approaching.
Rig safed: mount parked.”** (`e36-sched3.png`). Two minutes later the autopilot dispatched a plan
for the same target and it failed in 0 s with
**“Error: Slew: Mount is parked. Please unpark the mount before slewing.”**
(History row `Scheduler / M42-TEST  Aug 13, 2026 21:16  0s  Failed`).

The generated plan is exactly `Slew to <target>` → `Center on <target>` → `Expose`
(`e27-builder-after.png`) — there is no Unpark step, and nothing in the dispatch path unparks.
Any safing that parks the mount (dawn here, but weather-safe or a manual park is the same shape)
therefore makes every later autopilot dispatch fail on its first instruction. Combined with
WE-SEQ-N1 that is one failure away from a dead night.

### WE-SEQ-N6 — P2 — the same Stop button records the autopilot's run as **Failed** and shouts CRITICAL

Pressed the square Stop on an autopilot-dispatched run while it was slewing (21:18:42):

* toast: **“Critical · Sequencer — Slew: Operation cancelled”**
  (`shots/waveE-sequencing/wdseqn1-autopilot-run-stop-critical.png`);
* target card: red **“Error: Slew: Operation cancelled”**;
* run state: **Failed**, and Execution History records it as
  `Scheduler / M42-TEST · Aug 13, 2026 21:18 · 4s · Failed`.

The identical action on the hand-started run 30 minutes earlier is recorded
`New Sequence · Aug 13, 2026 20:47 · 42s · Stopped (resumable)`
(`shots/waveE-sequencing/weseqn6-history-stop-vs-failed.png`). Two verdicts for one deliberate
operator action. The differentiator is either the plan's owner or the instruction in flight
(a Slew/Center returns *cancelled* and is escalated to a run failure, while a stop during an
exposure is classified honestly) — both readings are consistent with what was observed, and
either way the operator gets “Failed + Critical” for pressing Stop. Same family as WD-SEQ-N1,
on the path the D-fix did not look at.

### WE-SEQ-N7 — P3 — at 900 px the node palette and Properties cannot be opened at all (WD-SEQ-N2 regression)

At 1600 px the toolbox icon toggles the palette normally (`Search nodes…` present / absent, and
the pref survives a resize). At 900 px the palette and the Properties pane are collapsed and
**clicking either icon does nothing** — three clicks on the toolbox icon and one on the
properties icon left the a11y tree with no `Search nodes…` and no `Target Settings`
(`e42-900.png`, `e45-toggle.png`). The derived collapse outranks the user's pref with no escape
hatch, so in a 900 px window a plan can be read but no node can be added and no node property
edited. Before the fix the panes were cramped but reachable; this is the cost the fix introduced.

---

## Notes / non-findings

* “Recover Sequence?” at launch lists `Completed  0 frames (0m integration)` — `Completed` is the
  row LABEL, not a status claim. Not a defect.
* WD-SEQ-N3 (palette tabs announcing `[DISABLED]`) is fixed: the a11y tree now reports
  `panel: Nodes / Tab 1 of 3` with no `[DISABLED]` on any of the three.
* SEQ-1 still reproduces on this build (Properties heading shows the raw type names
  `TargetHeader` / `TakeExposure`), as Wave D flagged. Not on this cluster's list.
* Pre-flight's Simulation strip shows `Issues 0` directly under a header that says
  `2 warning(s) found`; the two counters mean different things but read as a contradiction. P4.
* The centring failure that exposes WE-SEQ-N1 is a simulator artefact (blind solve on the
  synthetic sky); the *scheduler behaviour after* a failed run is not.
