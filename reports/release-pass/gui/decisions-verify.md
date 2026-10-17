# Owner-decision verification — live drive of the decisions build

**Date** 2026-08-14 · **Driver** live GUI (`tools/ui_audit/drive_linux.py`, profile `decisions-verify`,
display `:77`) · **Role** driver only — nothing was fixed in this pass.

**Binary** `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libapp.so` mtime **Aug 14 10:46**, `lib/libskotiq_bridge.so` **10:45**), built after
`925bac536` *"feat: the ten owner decisions"* (committed 10:44:42).

Shots: `reports/release-pass/gui/shots/decisions-verify/` · working captures, accessibility dumps
and the app log: `/tmp/ns-audit/decisions-verify/`.

## Verdicts

| # | Check | Verdict |
|---|-------|---------|
| 1 | **Decision 1** — operator Stop of an autopilot run PAUSES the autopilot; visible "Autopilot paused — resume?"; Resume restores dispatching | **PASS** |
| 2 | **Decision 3** — a target removed from the scheduler is INELIGIBLE for the autopilot | **PASS** (3 evaluation cycles + persisted row + cross-surface) |
| 3 | **IMG-9** — the looping `Frame Count` counts loop frames and resets per loop | **PASS** |
| 4 | **CON-56** — the time control panel reads "Now"/"Tonight", not ALL-CAPS | **PASS** (pixels + a11y) |
| 5a | Regression — a normal sequence still runs to completion | **PASS** (4/4 frames, 4 FITS on disk) |
| 5b | Regression — one press of Stop is ONE honest feed row | **PASS** (2 episodes, 2 stop surfaces) |
| 5c | Regression — a11y scans of dashboard + run dashboard | **PASS** (0 bad tokens on both) |

Two observations that are **not** decision regressions are recorded at the end (O-1, O-2).

## Bundle freshness, proven by content

The decision commit's own markers are in the driven snapshot. Dart stores any literal containing a
non-Latin-1 character as UTF-16, so the em-dash strings are checked as UTF-16 (the Wave-F trap):

| marker | ascii | utf16 |
|---|---|---|
| `scheduler-operator-pause-banner` (decision 1 banner key) | 1 | — |
| `scheduler-operator-pause-resume` (Resume button key) | 1 | — |
| `pausedByOperatorStop` (status flag wire name) | 1 | — |
| `scheduler_removed_targets` (decision 3 table) | 5 | — |
| `The autopilot will not pick it again` (removal dialog) | 1 | — |
| `Autopilot paused — resume?` | 0 | **1** |
| `No target set — sequence running without a target node.` | 0 | **1** |

## Setup

Profile seeded from the Wave-E `waveE-autopilot-night` database (so the `M42-TEST` catalog target
and a second target, `New Target`, were already present; both at RA 23.5 h / Dec −25.0°). Observing
site set to **−25.0° / +166.53°**, chosen so LST ≈ 23.5 h puts both targets within a degree of the
zenith and the Sun ~60° below the horizon: the app reported `LST 23:30`, `Dark 3h 12m left`, and the
scheduler scored the targets at **alt 89.6°**.

Devices: Simulated **Camera + Mount + Focuser** connected from Equipment ▸ Discovery (11 devices
found); the **Built-in Multi-Star Guider** was connected later for check 3 and disconnected again
before the regression runs. Capture folder inherited from the seeded profile
(`/tmp/ns-audit/waveD-sequencing/captures`).

---

## 1. Decision 1 — an operator Stop pauses the autopilot (PASS)

**The control comes first.** Armed *Run unattended all night* at 14:54:20 UTC (Start Anyway past a
"Review unattended start" dialog — assigned accessories unavailable, weather monitoring disabled).
The engine dispatched `Scheduler / M42-TEST` on the tick and the run **failed** ~40 s later, every
time, because Center Target could not solve on the synthetic sky
(`Center Target failed: Failed to center within 5.0" after 5 attempts`). After each failure the
autopilot re-dispatched on the next tick:

```
14:54:20  Slewing to RA 23.5000h Dec -25.0000°   (dispatch 1)  -> Failed
14:55:20  Slewing ...                            (dispatch 2)  -> Failed
14:56:20  Slewing ...                            (dispatch 3)
```

Three dispatches, ~60 s apart, on failed endings. That is the behaviour the decision deliberately
keeps: **a failure must not pause the night.**

**Then the operator's press.** At **14:56:38.088 → 14:56:41.060 UTC** the mini-player's
`Press and hold to stop the sequence` control was held once (a single mousedown/mouseup pair). The
app log carries exactly **one** `Stopping sequence execution`, at `14:56:40.799760Z` — one press,
one request — and the toast read *"Sequence stopped — Sequence stopped by request at 10:56."*

At the moment of the stop the autopilot still read **Running / Next target check in 36s**. The pause
lands on the following evaluation, and it landed:

* **11:57:19 local (14:57:19 UTC)** — the accessibility tree of the Schedule tab now carries, verbatim:

```
button: Resume
button: Stop
panel: Autopilot paused — resume?
panel: You stopped the run it had started, so it is leaving the rig alone instead of picking another target.
button: Resume autopilot
```

  and the panel badge flipped `Running` → **`Paused`** (`14-after45s.png`).

* **No re-dispatch.** From the stop at 14:56:40 to 14:59:13 — **2 min 32 s**, well past the ~44 s
  window the decision was written against and past two tick boundaries — the log shows **zero** new
  `Slewing to RA` lines and the dispatch counter (`Center attempt 1/5`, one per dispatch) stayed at
  **3**. `Last evaluation` froze at `10:57:19`: a paused engine does not even evaluate
  (`15-after2min.png`).

* **Resume restores dispatching.** One press of **Resume autopilot** at 14:59:25 and the panel went
  back to `Running`, the banner disappeared, the mini-player returned with
  `Running · Scheduler / M42-TEST`, and the reasoning block named its own cause:
  `Chose M42-TEST (score 4.426) at 2026-08-14T14:59:25.499009Z (engine resume)`. A slew followed at
  `14:59:28.104357Z` — dispatch 4 (`16-resumed.png`).

The discriminating evidence is that both arms were exercised in the same session on the same rig:
**five failed endings re-dispatched, one operator-evidenced stop paused.**

## 2. Decision 3 — removal means ineligible (PASS)

With the autopilot running and `M42-TEST` **Active**, its queue row's `Remove M42-TEST from
scheduler` button was pressed at 15:00:48. The confirmation states the contract:

> **Remove from scheduler?** Remove M42-TEST from the scheduler? The autopilot will not pick it
> again; its integration goals and constraints are deleted, and the target itself stays in your
> catalog.

Confirmed at 15:01:04. Immediately:

* the queue dropped to a single row, `New Target 4.418 Active`;
* the reasoning re-ran with its cause named — `Chose New Target (score 4.418) at
  2026-08-14T15:01:04.009234Z (target constraints changed)`;
* the mini-player relabelled itself `Running · Scheduler / New Target` (`19-removed2.png`).

**Watched for three further evaluation cycles** (11:01:04, ~11:02:2x, 11:03:25) and three further
dispatches (15:01:03, 15:02:28, 15:03:28 slews). A full accessibility dump of the Schedule tab at
15:03:39 contains **zero** occurrences of the string `M42-TEST` — not in the queue, not as Active
target, not in the reasoning, not in "other candidates considered". The winning-target row reads
`New Target 4.407 Active`.

*(Both targets sit at identical coordinates, so the slew log cannot distinguish them; identity here
is taken from the UI's own naming, which is what the operator reads.)*

**Persisted, and only for the target removed.** The decision's new table holds exactly one row:

```
sqlite> select * from scheduler_removed_targets;   -> 1|1786719663      (= 15:01:03 UTC)
sqlite> select id,name from targets;               -> 1|M42-TEST   2|New Target
```

The target stays in the catalog, exactly as the dialog promised.

**Cross-surface.** Plan Tonight ▸ Recommendation — the surface that had read
`AUTOPILOT WILL RUN · M42-TEST` before the removal — now reads `AUTOPILOT WILL RUN · New Target`,
`Chose New Target (score 4.300) at 2026-08-14T15:22:41Z (preview)`, with **0** mentions of
`M42-TEST`. Removal is honoured by the preview path as well as the dispatch path.

## 3. IMG-9 — the looping Frame Count counts loop frames (PASS)

Surface: **Guiding ▸ Star Statistics** during a Built-in-Guider *Loop Exposures* run (this is the
row IMG-9 names; the imaging screen has no such readout).

Connecting the built-in guider first produced an honest refusal — *"Your equipment profile is
missing a value … Enter the Focal Length of the scope you are guiding with"* — so the profile's
Optical Train was filled in (focal length 550 mm, aperture 100 mm) and the guider connected.

| moment | SNR | Star Mass | **Frame Count** |
|---|---|---|---|
| loop 1, ~10 s in (15:08:56) | 405.3 | 172391 | **6** |
| loop 1, ~35 s in (15:09:23) | 404.9 | 171760 | **31** |
| loop stopped (15:09:3x) | — | — | **0** |
| **loop 2**, ~8 s in (15:09:51) | 404.4 | 171914 | **8** |
| loop 2, ~13 s in (15:10:0x) | 404.9 | 171988 | **13** |

It counts while looping, it clears to `0` with SNR and Star Mass when the loop stops (all three rows
tell the same story rather than one contradicting the others), and the second loop **starts over**
rather than resuming at 31. Read from the accessibility tree and confirmed in pixels
(`crop-starstats.png`).

## 4. CON-56 — the time transport is not shouting (PASS)

Plan Tonight ▸ Planetarium, time control panel. Pixels read **`Now`** and **`Tonight`**
(`crop-timectl.png`). The accessibility dump of that screen lists every button, and **not one**
multi-letter all-caps label appears among them:

```
button: Aug 14, 2026   button: Pause time   button: Slower   button: Faster
button: Back 1 hour    button: Forward 1 hour
button: Now            button: Tonight
```

## 5. Regressions

### 5a — a normal sequence runs to completion (PASS)

Sequence: one `Take Exposures`, **4 × 5 s** on the simulated camera. Started 15:14:12 UTC on
*Start Anyway* (pre-flight *Ready with Warnings*: no target defined). Session report opened by
itself (`47-run2.png`):

```
New Sequence - Completed        Aug 14, 2026 11:14 - 11:14
Wall clock 26s   Integration 20s   Effective imaging 76.9%
Downtime   6s    Frames accepted 4/4   Frames rejected 0
Targets: Untargeted — 4/4 frames | 20s   (Att. 4 · Acc. 4 · Rej. 0 · HFR 5.51 · FWHM 11.02 · Stars 145)
Diagnostics: Cooler Out of Setpoint Band — drifted outside its setpoint band on 1 samples.
```

The tally agrees across three independent surfaces: **4 FITS written to disk**
(`untargeted_nofilter_0001_001 … _0003_001`, `_0004`, 4,150,080 B each, all stamped 11:14),
`Frames accepted 4/4` in the report, and 4 new thumbnails in the dashboard filmstrip.
20 s integration / 26 s wall clock = 76.9%, which is the figure printed.

### 5b — one press of Stop is one honest row (PASS, two episodes)

**Episode A — sequence-builder Stop (single click).** A 4 × 90 s run, stopped 45 s in.
One click at **15:16:34.999 → 15:16:35.536 UTC**; the log carries exactly one
`Stopping sequence execution` (`15:16:35.125126Z`, 126 ms after the click; session count 1 → 2).
Dashboard RECENT EVENTS, verbatim from the tree:

```
Sequencer  Sequence stopped     11:16:35   Stopped by request
Sequencer  Progress       ×2    11:16:35   0 / 4
Imaging    Exposure progress    11:16:34   42% · 52s remaining
Imaging    Exposure progress    11:16:32   40% · 54s remaining
Imaging    Exposure progress    11:16:30   38% · 56s remaining
```

One "Sequence stopped" row (`grep -c` = 1), the operator message, **no** ×N badge on it (the ×2
belongs to Progress), **no** "Decision logged" row (`grep -c` = 0), and the three preceding
exposure-progress rows survive in order. The session report read
**"New Sequence - Stopped (resumable)"**, `Frames accepted 0/0`,
*"No accepted light frames recorded."* — honest about an exposure abandoned in flight.

**Episode B — dashboard cockpit Stop (press-and-hold).** Same node, run restarted, one frame
graded. A 5.0 s hold (**15:21:38.158 → 15:21:43.465**) produced exactly one
`Stopping sequence execution` (count 2 → 3):

```
Sequencer  Sequence stopped     11:21:41   Stopped by request
Sequencer  Progress             11:21:41   1 / 4
Imaging    Exposure progress    11:21:40   94% · 6s remaining
```

The `1 / 4` on the stop row agrees with the `Frame 1: accepted (HFR 2.97, ecc 0.21, 126 stars)` the
quality panel was showing at the moment of the press. Session totals: **3** presses across the
session, **3** `Stopping sequence execution` lines, **2** `Exposure cancelled` WARNs (the third
press landed on a Center Target, which logged `Center Target cancelled` instead).

### 5c — accessibility scans (PASS)

Full `tree` dumps scanned for `error`, `exception`, `overflow`, `NaN`, `Infinity`, `null`,
`undefined`:

| surface | tree lines | bad tokens | dump |
|---|---|---|---|
| Dashboard, idle | 130 | **0** | `tree-dash-idle.txt` |
| Dashboard, live run (1 frame graded) | 145 | **0** | `tree-rundash.txt` |
| Dashboard after the second stop | — | **0** | `tree-dash-stop2.txt` |
| Schedule tab, idle / paused / after removal | — | **0** each | `tree-sched-idle.txt`, `tree-after45s.txt`, `tree-after-removal.txt` |
| Planetarium | — | **0** | `tree-planetarium.txt` |

The one token the first dashboard dump did produce was the alert card `Sequencer error` carrying the
real dither failure of 11:12:23 — a truthful disclosure, not a rendering defect; after *Dismiss all*
the dump is clean at 0.

**Log.** Across the 30-minute session (6,363 lines) the app log contains **0** occurrences of
`RenderFlex overflowed`, `EXCEPTION CAUGHT BY`, `Another exception was thrown`, `Failed assertion`
or `Unhandled exception`. Every ERROR is attributable and stated on screen: 37 ASTAP non-zero exits
and 7 `Center Target failed` (the synthetic-sky blind solve), plus the one dither failure of O-1.

The live-run dashboard also shows the commit's glance-line fix working: with a run in flight and no
target node, the cockpit reads **"No target set — sequence running without a target node."** rather
than the old "load a sequence to begin" while offering Pause/Stop/Skip (`59-rundash-live.png`).

---

## Observations (not decision regressions, not fixed here)

**O-1 — a connected-but-idle guider turns a dither into a run-ending failure.** Run at 15:12 with
the built-in guider *connected* but not guiding ended
`New Sequence - Failed … Dither failed after frame 3/4: Built-in guider dither requires active
guiding; not guiding` after 3 of 4 frames. With **no** guider connected the same node logs
`WARN Dither requested after frame 3/4 but no guider is configured — skipping` and the run completes
4/4. Both messages are honest; the asymmetry is the point — the harder-to-diagnose configuration
(guider present, guiding not started) is the one that ends the run. Pre-existing; not touched by any
of the ten decisions. Evidence: `43-completed.png`, log 15:12:23 vs 15:14:36.

**O-2 — the field-scale hint could not be re-tested after the profile was filled in.** Every plate
solve in this session ran *before* the optical train was given a focal length, so all 37 carry
`Plate solve has no field-scale hint (focal length unknown, pixel pitch unknown)`; the last is at
15:04:02 and the profile was saved at ~15:07:5x. Whether the saved focal length now reaches the
solver is **untested** by this drive.

*(For the record: `AUTOPILOT WILL RUN` on the Recommendation tab is an ALL-CAPS section eyebrow, not
a button label. CON-56 and its regression test are scoped to the planetarium transport's button
labels, so this is out of that item's scope and is noted only so a later reader does not mistake it
for a miss.)*
