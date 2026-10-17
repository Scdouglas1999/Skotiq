# Wave D verification — Sequencing cluster

Verifier: adversarial re-drive of the FRESH release bundle
(`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`, `libapp.so` mtime Aug 13 18:31)
via `tools/ui_audit/drive_linux.py`, display `:82`, profile `waveD-sequencing`, `--fresh`.
Devices: Simulated Camera / Mount / Focuser / Filter Wheel connected via Equipment → Discovery.
Capture folder `/tmp/ns-audit/waveD-sequencing/captures`.

Two site configurations were used so both the day and the night branches could be exercised
against the same wall clock (machine clock 18:3x–19:0x EDT = 22:3x–23:0x UTC):

| config | lat / lon | sun | target M42-TEST (RA 21.42 h, Dec −35°) |
|---|---|---|---|
| A "daytime" | −35 / +148 | +18.9° | −5° |
| B "night" | −35 / +21 | deep night | +88° (zenith) |
| C "night, nothing eligible" | +45 / +21 | deep night | +9.8° (below the 30° site minimum) |

Screenshots referenced below are preserved in
`reports/release-pass/gui/shots/waveD-sequencing/` (originals were in `/tmp/ns-audit/waveD-sequencing/`).

---

## Verdicts

| ID | verdict |
|---|---|
| SEQ-12 | **VERIFIED_FIXED** |
| SEQ-3 | **VERIFIED_FIXED** |
| SEQ-14 | **VERIFIED_FIXED** |
| SEQ-15 | **VERIFIED_FIXED** |
| SEQ-16 | **VERIFIED_FIXED** |
| SEQ-6 | **VERIFIED_FIXED** |
| SEQ-17 | **VERIFIED_FIXED** |
| SEQ-13 | **STILL_BROKEN** |
| SEQ-18 | **STILL_BROKEN** |
| SEQ-19 | **STILL_BROKEN** |
| SEQ-20 | **STILL_BROKEN** (partial — target card fixed, run readout not) |
| SCI-43 | **STILL_BROKEN** (partial — wizard fixed, pre-flight not) |

---

## VERIFIED_FIXED

### SEQ-12 — P0 — autopilot no longer kills a manually started run

Exact original conditions reproduced: config C, so the Schedule panel reads
**Unattended Autopilot — Running — "No eligible target right now." — "next eval in 54s"**
(reasoning box: `No eligible candidates at 2026-08-13T22:56:00.098041Z (engine start)`,
i.e. ticks land on **:00** of every minute).

With autopilot in that state I started a 12 × 15 s sequence by hand at **18:57:23**.

Polled every 45 s:

| clock | sequencer | autopilot |
|---|---|---|
| 18:58:15 | Sequence Running | Running (tick at 18:58:00) |
| 18:59:01 | Sequence Running — Progress 6/12 | Running (tick at 18:59:00) |
| 18:59:46 | Sequence Running — Progress 9/12 | Running |
| 19:01:32 | Session Report: **Completed**, wall clock 3m 15s, **frames accepted 12/12**, rejected 0 | Running, `No eligible candidates at 2026-08-13T23:02:00Z (tick)` |

The run crossed **three** autopilot evaluation boundaries (18:58:00, 18:59:00, 19:00:00) and
finished 12/12. Twelve new FITS landed in the capture folder. The autopilot was still `Running`
after the run finished, so this was not an accidental control (evidence: `s58.png`).

A second, harder case also passes: when autopilot *does* have an eligible target it takes the rig
explicitly — the builder header changes to **"Scheduler / M42-TEST"** and shows the generated
Slew → Center → Expose plan, and the tick that lands during its own run is annotated
`(coalesced)` in the reasoning box rather than restarting anything (`s52.png`).

Residual, not enough to fail the finding but recorded below as NEW-6: nothing in the Sequencer or in
pre-flight still says that autopilot is armed.

### SEQ-3 — P1 — pre-flight now blocks a run the daylight gate would refuse

Config A. Sequencer → Builder → **Start**:

* header: **"Cannot Start Sequence — Please fix 1 error(s) before starting"** (1 error, 4 warnings, 2 info)
* the error is categorised `Timing`: **"Daylight Gate Will Refuse Every Light Frame — The Sun is 18.9°
  above the horizon at your site, and the executor refuses on-sky light exposures above −12.0°.
  Started now this sequence would fail on its first exposure with zero frames captured."**
  with the remedy *"Start after dark, or add a Wait node set to a twilight condition… Daytime flats,
  darks and bias frames are unaffected."*
* the green **Start Anyway** button is replaced by a greyed **Start Sequence**; clicking it does
  nothing — the dialog stays up and the tree still reports "Cannot Start Sequence".

Evidence `s17.png`. Under config B (sun down) the same sequence pre-flights as
"Ready with Warnings" with no timing error, so this is condition-driven and not a blanket block.

### SEQ-14 — P1 — "This Week" reports real darkness

Config B, Plan Tonight → Schedule → *This Week*: the seven cards read
`7.0 / 10.4h clear`, `10.0 / 10.4h clear`, `0.0 / 10.3h clear` … — hours of darkness with a clear-hours
numerator, and the empty-project state is now stated honestly as **"No targets up"** instead of the
false astronomical claim. No card says "No astronomical darkness" and no sun icon appears
(`s37.png`). Under config C the same strip re-computed to `6.0 / 6.0h` for latitude 45 (`s59.png`),
so the numbers track the site rather than being a constant.

### SEQ-15 — P1 — Slew to Target confirms, warns and locks

**Repro A (below the horizon, idle).** Config A, target at Alt −5.1°. The toolbar paper-plane now
opens a modal:

> **Slew to M42-TEST?** The mount will move now. `RA 21:25:12.00  Dec -35:00:00.00` — *Altitude −5.1°* —
> ⚠ **M42-TEST is below the horizon. The mount would point at the ground.** [Cancel] [Slew now]

(`s19.png`). Only after **Slew now** does the mount move — Equipment then reads
`RA 21:25:12 / Dec -35:00:00` (`s20.png`).

**Repro B (during a run).** With a sequence running, the a11y tree reports
`button: Slew to Target (locked while sequence is running)` alongside its nine neighbours, and
clicking it opens no dialog and moves nothing.

One caveat on the "logs" half of the finding: the fix adds `logger.info('Slewing to …')` via
`loggingServiceProvider`, but that sink is in-memory/UI only — `grep -ic slew` over
`data/logs/skotiq.log.*` and over the app's stdout still returns **0**. The user-visible part of the
complaint (silent, unconfirmed, unlocked) is fixed; a post-mortem log grep still will not find the slew.

### SEQ-16 — P1 — pre-flight flags a mount that is not on target

Config A, mount parked at RA 0h, target 50° away, sequence contains no Slew/Center. Pre-flight now
raises, in the `Targets` category:

> **Mount Is Not Pointing At M42-TEST** — "The mount is 50° away from M42-TEST and this target has no
> Slew or Center instruction, so the run would expose wherever the mount happens to be and file every
> frame under M42-TEST." → *"Add a 'Slew to Target' or 'Center Target' instruction under the target, or
> slew there first with the toolbar button."*

After slewing the mount onto the target the warning disappears from the next pre-flight (`s30.png`),
so it is computed, not boilerplate. It is a warning rather than a hard error, which matches the
finding's stated expectation ("pre-flight should flag …").

### SEQ-6 — P2 — outcome vocabulary is product English

Started a 12 × 15 s run, **Pause** (chip PAUSED) → **Resume** (header returns to Sequence Running) →
**Stop** while running. Session Report title: **"New Sequence - Stopped (resumable)"** (`s35.png`,
reproduced again in `s64.png`). No occurrence of `paused-stopped` anywhere in the UI.

History filter chips are now: `Completed`, `Failed`, `Aborted`, `Stopped`, `Stopped (resumable)`,
`Interrupted`, `Running`, and the two rows in the list are labelled `Stopped (resumable)` and
`Completed`. (The same stop path does still raise a red *error* banner — see NEW-1.)

### SEQ-17 — P2 — the two queues are named apart

* Builder → **Queue** tab empty state now reads: *"Your target queue is empty. Add targets from
  **Plan Tonight → Planetarium**, then drag them into the sequence tree to start a plan. This queue is
  the builder's own — the autopilot runs the separate scheduler queue in Plan Tonight → Schedule."*
  Both dead destinations from the original text ("Tonight tab", bare "planetarium") are gone.
* Plan Tonight → Schedule: the table is now headed **"Scheduler queue"**, not "Target queue".
* Plan Tonight → Recommendation: the card is **"AUTOPILOT WILL RUN / M42-TEST / Live scheduler pick —
  what the rig would slew to next (score 4.43)"** with an **Open Scheduler Queue** button (`s36.png`).

Coverage caveat: the *empty* branch of the Recommendation card (the one that asserted "Targets are
queued") could not be reached — the scheduler re-registers the sequence's target on every evaluation,
so the queue was never empty (see NEW-5). The naming half of the finding is verified; the false-premise
copy could not be re-tested and should be re-checked by whoever can force an empty scheduler queue.

---

## STILL_BROKEN

### SEQ-13 — P1 — the scheduler still evaluates the coordinates the user replaced

Config B. M42-TEST had already been run once (registering it with the scheduler) at
RA 21.42 h / Dec −35°. In the builder I then changed the same target to **RA 5.5885 h / Dec −5.39°**
(the original finding's coordinates, used here in the opposite direction).

| surface | same instant | altitude reported |
|---|---|---|
| Builder target card (`s44.png`) | 18:50 | **Alt: −19.4°** |
| Schedule → Reasoning after pressing **Re-evaluate** (`s42.png`) | `Chose M42-TEST (score 4.419) at 2026-08-13T22:49:34.840696Z (preview)` | **alt 86.3°** |
| Scheduler queue row | same | M42-TEST — **Selected** |
| Recommendation card | `Chose M42-TEST (score 4.414) at 2026-08-13T22:50:27Z` | *"**Live scheduler pick** — what the rig would slew to next"* |

86.3° is the altitude of the *old* coordinates. Re-evaluate was pressed twice, ~53 s apart, and the
score drifted 4.419 → 4.414 — so the engine is recomputing, from a stale coordinate snapshot, exactly
as originally reported. The fix did narrow the failure: a **site** change *is* picked up (moving to
lat +45 immediately produced `M42-TEST: altitude 9.8° below site minimum 30.0°`), so what remains stale
is specifically the target's RA/Dec.

This is now worse-labelled than before: the Recommendation card asserts the pick is **"Live"**.

### SEQ-18 — P2 — a fully successful run still leaves the node reading 0 / N

Reproduced twice, on both run lengths:

* 4 × 15 s run → Session Report "Frames accepted 4/4" → node card reads **"Exposure: No Filter — 0 / 4
  frames"**, four empty progress boxes, directly above four thumbnails labelled `R` (`s33.png`).
* 12 × 15 s run → Session Report "12/12" → node card reads **"Exposure: No Filter — 0 / 12 frames"**,
  twelve empty boxes, above twelve `R` thumbnails plus a `+7` overflow chip (`s63.png`).

The stop path is still the correct one: after a run stopped at 1 frame the same card read
**"1 / 4 frames"** (`s46.png`). So the reset remains specific to the success path, unchanged.

### SEQ-19 — P2 — the builder still denies the filter the data path uses

Same run, same screen (`s63.png`, `s32.png`):

| surface | says |
|---|---|
| Properties → Filter | **(None)** |
| Exposure node header | **Exposure: No Filter** |
| Target rollup line | **R 180s** |
| Run telemetry strip | **Filter: R** |
| Thumbnail inspector | `Filter R  Exposure 15.0s` |
| Files on disk | `M42-TEST_R_0001.fits` … `_0012.fits` |
| Session Report per-filter table | one row: **R** |

The "No filters in profile" hint is gone (replaced by `(None)` plus an *Edit filters…* link), and the
target rollup now correctly says `R` — but the exposure node header and the Filter field still say the
opposite, so the contradiction has moved rather than closed: the same card stack now says `R 180s`
two rows above `Exposure: No Filter`.

### SEQ-20 — P3 — partially fixed; the run readout still rounds to minutes

Fixed: with Take Exposures set to 4 × 3 s the target card reads **"4 planned exposures • 12s"** (was
"0m"), the pre-flight footer reads `~1m 8s`, and the Session Summary reports `Wall Clock 1m 5s /
Integration 1m 0s / Overhead 5s`.

Not fixed: during a run the target card's elapsed readout still renders in whole minutes —
**"0/4 done · 0m / 1m"** at 7 s elapsed (`s31.png`), then **"2/4 done · 1m / 1m"** at ~40 s elapsed —
while the panel immediately above it, in the same card, reads **"~34s · done ~18:43:47"**. The original
complaint ("During a run the elapsed readout shows 0m / 1m for the first minute") reproduces verbatim.

### SCI-43 — P3 — one of the two instances is fixed

* **Fixed.** Sequencer ▸ Quick-Start Wizard ▸ Step 1, typing into Target Name now yields:
  *"Your target library is empty, so there is nothing to search. Add one from **Plan Tonight ▸
  Projects**, or enter RA/Dec below."* — Plan Tonight ▸ Projects exists.
* **Not fixed.** Sequencer ▸ Start ▸ Pre-Flight ▸ *Missing Dark Frames* still reads:
  *"Capture darks for the missing combinations. **Open Calibration → Dark Library** to schedule them,
  or run the 'Capture missing darks' action from the pre-flight dialog."* The primary navigation is
  Dashboard, Equipment, Imaging, Sequencer, Guiding, Weather, Plan Tonight, Analytics — there is no
  Calibration entry. Reproduced on every pre-flight run today (`s17.png` and the tree dumps at 18:42
  and 18:56).

---

## NEW findings from the adversarial sweep

### NEW-1 — P2 — pressing Stop reports the run as an error, in three places at once

Immediately after a user-initiated **Stop**, the app raises red banners in the right-hand stack —
in the first run: **"Sequence Error / Sequence cancelled"**, **"Sequence failed / Sequence aborted at
2026-08-13T18:47:00.810041"**, **"Critical - Sequencer / Sequence cancelled"** (`s35.png`); on the
repeat, **"Critical - Sequencer / Sequence cancelled"** (`s64.png`). The Session Report for the same run
simultaneously titles itself **"Stopped (resumable)"** and carries a red **Errors — Sequence cancelled**
section.

So the fix that made the *title* honest left the rest of the surface calling a deliberate user action a
critical failure, and it does so three times over. Repro: start any run, press the square Stop button
while it is running. Same class as the cry-wolf work; and "Sequence failed" is directly contradicted by
the title six inches to its left.

### NEW-2 — P2 — the builder is unusable at a 900 px window width

`drive_linux.py resize 900 900` on Sequencer → Builder (`s62.png`). The three-pane layout
(palette + canvas + properties) does not collapse, so the canvas is squeezed to roughly 180 px:

* the Take Exposures node's inline editors break to one control per line, leaving a bare `×`
  on its own row;
* the exposure panel's `Total 3.0` is clipped mid-value (the `min` unit is cut off);
* the `+ Add note` button is sliced by the pane edge, rendering as `+ Add` with `Add` overlapping;
* the target rollup truncates to `12 planne…`.

The properties pane keeps its full ~250 px and the palette its full ~200 px, so the pane that holds the
document gets the smallest share. 1600×900 is clean.

### NEW-3 — P3 — working controls announce themselves as disabled to a screen reader

The a11y dump reports `[DISABLED]` on controls that demonstrably work — the builder palette tabs
`Nodes / Snippets / Queue` (`Tab 1 of 3 [DISABLED]` … clicking Queue does switch the pane), the
History rows' status chips (`Stopped (resumable) [DISABLED]`, `Completed [DISABLED]`), the equipment
chip `4 connected [DISABLED]`, the scheduler `No integration goals [DISABLED]`, and pre-flight's
category count badges. These nodes carry `selectable` but never `enabled`/`sensitive`, so a screen
reader announces them dimmed. Same class as the already-fixed planner filter chips
(commit a95a1d500), on further widgets.

### NEW-4 — P3 — the scheduler calls a target 9.8° above the horizon "Below horizon"

Config C. The Scheduler queue row's own message is correct — `M42-TEST: altitude 9.8° below site
minimum 30.0°` — but the STATUS column next to it reads **"Below horizon"** (`s55.png`). The target is
above the horizon; it is below the *site minimum*. The same string appears in the original SEQ-13
transcript, so this has been shipping unnoticed.

### NEW-5 — P3 — "Clear all" on the scheduler queue does not stick

Plan Tonight → Schedule → **Clear all** → confirm ("Clear all targets from the scheduler? Integration
goals and constraints will be deleted…"). The table empties, but the Autopilot panel keeps naming
M42-TEST as its Active target, and the very next **Re-evaluate** puts the row back —
`Last evaluation 18:52:46 / M42-TEST 4.402 Selected`. Either the destructive action should persist,
or the button should not promise deletion of something the next tick recreates.

### NEW-6 — P3 — nothing warns that autopilot is armed when you start a run by hand (SEQ-12 residual)

With **Unattended Autopilot — Running** in Plan Tonight, the Sequencer shows no banner, and pre-flight
lists Disk space / Dark Library / Equipment Health but says nothing about autopilot owning the rig
(`s56.png`, `s57.png`). SEQ-12's dangerous behaviour is fixed, so this is now only a
"the user cannot see who owns the mount" gap rather than a data-loss one — but it was part of the
original P0 write-up and remains open.

---

## Notes on coverage

* The pre-flight `Time Sync Check Unavailable` info card (NTP timeout, no internet in the sandbox)
  appeared on the config-A run only and is an environment artefact, not a defect.
* SEQ-17's false "Targets are queued" empty-state copy could not be reached — see the caveat above.
* SEQ-1 (`TargetHeader` / `TakeExposure` in the Properties heading) and SEQ-2 (two name fields on a
  target node) both still reproduce exactly as written (`s14.png`, `s25.png`). They were not on this
  verifier's list; flagging them so they are not assumed closed.
