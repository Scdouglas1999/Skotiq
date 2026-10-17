# Wave F dryness check — cluster `stop-pipeline`

Verifier: live re-drive of the FRESH release bundle
`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`, via
`tools/ui_audit/drive_linux.py`, display `:82`, profile `waveE-stop-pipeline`.
Nothing was fixed in this pass.

**Bundle freshness.** `lib/libapp.so` mtime **Aug 13 23:56**, i.e. after the E-fix commit
`4723ca202` (Aug 13 23:54). String-grep of `libapp.so` finds every string the E-fix batch
introduced: `stop-classification`, `Stopped by request`,
`Set coordinates to see this target rise`, `Sequence stopped`, `Stopped (resumable)`,
`Show Toolbox`. This is the binary the E-fix landed in.

Profile seeded from `/tmp/ns-audit/waveE-sequencing-autopilot/data` so the Wave-E history and
site (lat +45 / lon +21) were in play. Devices: Simulated Camera / Mount / Focuser connected
via Equipment ▸ Discovery. Screenshots kept in
`reports/release-pass/gui/shots/waveF-stop-pipeline/`; working captures in
`/tmp/ns-audit/waveE-stop-pipeline/`.

**Harness note for the next wave.** On this build the first click after a pointer *move* is
swallowed (Flutter has not processed the hover yet), so `click-xy` alone looks like a dead
control. Every action here used `xdotool mousemove X Y sleep 0.6 click 1`. Screenshots also
lag the app by ~1 s, so a shot taken immediately after a click can show the *pre-click*
state — three "the connect button did nothing" scares in this session were that, not defects.

---

## Verdicts

| ID | verdict |
|---|---|
| WD-SEQ-N1 (operator Stop — full five-surface sweep) | **VERIFIED_FIXED** (3 residuals, recorded as new) |
| WE-SEQ-N4 (no raw `Paused-stopped` token) | **VERIFIED_FIXED** |
| WE-SEQ-N2 (no altitude curve without coordinates) | **VERIFIED_FIXED** |
| WE-SEQ-N7 (900 px palette / properties toggles) | **VERIFIED_FIXED** |
| SEQ-18 (node card N/N after success — fourth look) | **STILL_BROKEN** |

---

## VERIFIED_FIXED

### WD-SEQ-N1 — an operator Stop now tells the stopped story on all five surfaces

Run: `New Sequence` = Target (RA 3.0 h / Dec 0°) → 2 × `Take Exposures` 4 × 15 s = 8 planned.
Started 00:09; the square **Stop** pressed at **00:13:25** local (04:13:25 UTC) with 4 frames
captured. All five surfaces were then read.

| # | surface | Wave E (was) | Wave F (now) |
|---|---|---|---|
| 1 | toast stack | red **"Sequence failed / Sequence aborted at …"** + **"Critical · Sequencer / Sequence cancelled"** | ⓘ INFO **"Sequence stopped / Sequence stopped by request at 2026-08-14T00:13:25.206940."** — no red, no `Critical`, no `failed`, no `aborted` (`f48-toasts.png`) |
| 2 | Dashboard banner | full-width red **"Sequencer — Sequencer error 20:47:53 / Sequence cancelled"** | no banner at all; the header reads **"Sequence ready — start tonight's run."** with a green **Ready** chip (`f55-dash.png`) |
| 3 | Dashboard ▸ RECENT EVENTS | `Sequencer error — Sequence cancelled` | ⓘ `Sequence stopped ×2`, ⓘ `Sequence stopped / Stopped by request`, ⓘ `Decision logged / system_event #14: Sequence cancelled`, ⚠ `Meridian flip aborted / …User requested abort during retry wait`, ⓘ `Progress ×3 / 4 / 8`. No error-level row (`f57-events.png`) |
| 4 | Sequencer target rollup | red **"Error: Sequence cancelled"** on the target card | no error line on the card; the status row reads `15.0s (nominal 15.0s, disabled) / 8 planned exposures • 2m` (`f51-rollup.png` and the two scroll steps above it) |
| 5 | Session Report | already correct in Wave E | still correct: title **"New Sequence - Stopped (resumable)"**, **no** `Errors` section, and the only Warning is the honest *"Meridian flip for 'New Target' was aborted after 3 attempt(s): User requested abort during retry wait. The mount was NOT flipped."* (`f48-stop.png`, and the scrolled tail) |

The E-fix's own instrumentation is visible in the wording: producer 2/2b's replacement copy
**"Stopped by request"** is the body of the feed row, and producer 3 renders an INFO row
rather than escalating. The refuted `contains('cancelled')` predicate did not resurface: the
run's *real* fault-shaped notice (the meridian-flip abort) is still reported, as a warning,
and was not swallowed by the stop classification.

Three residuals are recorded as new findings below (WF-STOP-N3, WF-STOP-N5) rather than as a
failure of this item — none of them cries wolf.

### WE-SEQ-N4 — the Dashboard "Last night" card no longer prints the enum

After an app restart, Dashboard ▸ *Last night* reads

> **New Sequence** — *Stopped (resumable) · 9 minutes ago* — `1m 0s integration` `4 frames`
> `4m 14s duration`

(`f59-lastnight.png`). No `Paused-stopped` anywhere; the same vocabulary as the Session
Report title and the History chip. The Execution History row for the same run also reads
`Stopped (resumable)` (`f79-history.png`).

(The `1m 0s integration` on this card is wrong for a different reason — see WF-STOP-N2.)

### WE-SEQ-N2 — a target with no coordinates gets no altitude curve

A freshly added Target node shows `RA Not set   Dec Not set` and, in place of the chart,
**"Set coordinates to see this target rise, transit and set."** — no `Alt:`, no `Airmass:`,
no plotted curve, no Rise/Transit/Set row (`f07-target.png`, reproduced again after a
restart on a second fresh node). The gate is two-way: entering RA 3.0 h brings the chart
back with `Alt: 54.9° Airmass: 1.22 / Rise 18:03 / Transit 00:05 / Set 06:07`, and RA 6.0 h
moves it to `Alt: 38.4° / Rise 21:03 / Transit 03:05`, so the panel is reading the real
coordinates and not a placeholder.

### WE-SEQ-N7 — at 900 px both panes open and collapse again

`resize 900 900` on Sequencer ▸ Builder: both side panes derive collapsed to single icons
(`f08-900.png`). Then, one click each:

* toolbox icon → the palette opens with `Search nodes…`, `Target`, `Take Exposures`, …
  (`f09-900-toolbox.png`);
* properties icon → the Properties pane opens with `TargetHeader / Target Settings / RA
  (hours) / Dec (degrees)` (`f10-900-props.png`).

Collapsing still sticks: the Properties header's collapse icon closes it
(`f11-900-collapse.png`) and the toolbox header's closes the palette
(`f12-900-collapse2.png`), leaving the canvas full width. The Wave-E symptom — three clicks
on the toolbox icon leaving no `Search nodes…` in the tree — does not reproduce.

One behavioural note, not a defect: collapsing at 900 px writes the pane preference, so the
pane is still collapsed after widening back to 1600 px. That is the operator's own explicit
action, and the *derived* collapse still does not write the preference.

---

## STILL_BROKEN

### SEQ-18 — P2 — a node that captured every planned frame still reads `0 / N`

Fourth look, and the symptom is unchanged. In the 8-frame run above, the **first**
`Take Exposures` node ran to completion: four `Exposure complete` lines in the log, four
`New Target_nofilter_000{1..4}.fits` saved, four rows in `captured_images` against that
node's id `7837c026-e1bb-4f2a-8e0f-1c86dff23e06`, four thumbnails rendered under the card,
and the run header advanced to `Progress 4/8`.

That node's card read, both while the run was still going and after it ended:

> **Exposure: No filter set** … **0 / 4 frames**
> ▢ ▢ ▢ ▢   *(four empty progress boxes)*

(`f46-node1.png` mid-run with the four thumbnails directly below it; `f51-rollup.png` after
the run ended.) The second `Take Exposures` node, which never captured, reads the same
`0 / 4 frames` — so the card cannot distinguish "captured everything" from "captured
nothing", which is the whole point of the counter.

The E-fix's stated mechanism was that the panel would treat *"last planned frame reported
captured"* (`Completed 4/4`) as a second witness of completion. On screen that witness is
not arriving: the count is 0 for a node whose four frames are on disk, in the database, and
in the thumbnail strip six pixels below the empty boxes.

Caveat, stated plainly: the enclosing run in this reproduction was operator-stopped during
the *second* node, so this is a completed node inside a stopped run rather than a completed
run. A second confirmation run could not be started — the profile's site had passed
astronomical dawn and pre-flight then blocks with *"Daylight Gate Will Refuse Every Light
Frame — the Sun is -11.0° … the executor refuses on-sky light exposures above -12.0°."* The
node-level evidence is nevertheless decisive: `nodeStatus` for node 1 was success and its
four frames were all reported captured.

---

## NEW findings

### WF-STOP-N1 — P2 — the first light frame of a node is captured at 5 s, not the configured 15 s

`Take Exposures` was configured **Duration 15.000 s, Count 4**, and the node card showed
`Frame 1/4 (15.0s)` while it ran. The log shows two exposures started on the same camera one
second apart, and the short one wins:

```
04:09:10.792594  Starting 4 (no filter set) x 15.0s exposures
04:09:10.792627  Starting 15.0s exposure on camera sim_camera_1
04:09:10.792638  DeviceManager: camera_start_exposure for sim_camera_1 duration=15
04:09:11.795844  Starting 5.0s exposure on camera sim_camera_1        <-- 1.0 s later
04:09:11.795858  DeviceManager: camera_start_exposure for sim_camera_1 duration=5
04:09:17.098780  Exposure complete: 1920x1080 image, Monochrome sensor
04:09:17.133044  Saving FITS … New Target_nofilter_0001.fits (New Target frame 1 (5.0s, (no-filter)))
```

Frames 2–4 are all 15 s. The database agrees:

```
33|New Target_nofilter_0004.fits|15.0
32|New Target_nofilter_0003.fits|15.0
31|New Target_nofilter_0002.fits|15.0
30|New Target_nofilter_0001.fits| 5.0   <-- configured 15.0
```

Cost on a real rig: the first light frame of every `Take Exposures` node is a third of the
requested integration, filed under the target as an accepted light, and the operator is told
`Frame 1/4 (15.0s)` while it happens. It is only visible afterwards, in the Dashboard
thumbnail strip, where the oldest frame is labelled `5s` beside three `15s` frames
(`f55-dash.png`).

Repro: connect the simulated camera, build Target + `Take Exposures` 4 × 15 s, start, then
read the first `Saving FITS …` line or `select exposure_duration from captured_images`.

### WF-STOP-N2 — P3 — the same run's integration is 50 s on one surface and 1 m 0 s on three others

For the run above (5 + 15 + 15 + 15 = **50 s** of recorded exposure across 4 frames):

| surface | integration |
|---|---|
| Session Report ▸ Integration | **50s** |
| Session Report ▸ target row `New Target 4/4 frames \| 50s` | **50s** |
| Dashboard ▸ Last night | **1m 0s** |
| Sequencer ▸ History row | **1m 0s** |
| Recover Sequence? dialog | `4 frames (1m integration)` |

Three surfaces are computing `frames × planned exposure` instead of summing what was
actually recorded, so they inherit exactly the 10 s that WF-STOP-N1 lost. Four frames that
cannot total 1 m 0 s is provable from the two screens alone, without the database.

### WF-STOP-N3 — P3 — one operator Stop raises three identical toasts and three feed rows

The single Stop at 00:13:25 produced **three** toasts stacked on top of each other, identical
but for the microseconds — `…25.206940`, `…25.207025`, `…25.207109` (`f48-toasts.png`) — and
the same triplication in RECENT EVENTS (`Sequence stopped ×2` plus a third `Sequence stopped`
row). The count matches the number of producers the E-fix taught to reclassify
(`event_classifier`, `event_operations` / `sequence_progress`, `run_dashboard_providers`):
each now emits its own honest notice where previously they emitted one honest and two
alarming ones. The cry-wolf is gone; the duplication that carried it is not.

### WF-STOP-N4 — P2 — a run stalled in a retrying meridian flip reports "Running 50%" with an ETA that has already passed

With the mount connected and the target at RA 3 h (on the meridian), the executor started a
meridian flip after frame 4. Its plate-solve step failed and it entered exponential retry:

```
04:10:43.815  ✗ Plate solving and centering FAILED: Plate solve failed
04:10:43.815  Retry 2/4 scheduled in 60 seconds...
04:11:51.795  ✗ Plate solving and centering FAILED: Plate solve failed
04:11:51.795  Retry 3/4 scheduled in 120 seconds...
```

Throughout, every operator-facing surface said the run was healthy: status chip **Running**,
`Progress 4/8 · 50%`, telemetry `Mount: Tracking`, and a countdown reading
`~1m 8s · done ~00:12:13` that was still displayed unchanged at 00:12:53 and 00:13:24
(`f44.png`, `f47-done.png`) — i.e. the promised finish time came and went while the run had
not captured a frame for two and a half minutes. Nothing on the Sequencer screen mentioned a
flip, a failed solve, or a retry; the only honest account of it appeared *after* the Stop, in
the Session Report warning.

The flip failure itself is a simulator artefact (blind solve on the synthetic sky). What is
not a simulator artefact is that a run frozen in a retry loop presents as a run that is 50 %
done and one minute from finishing.

### WF-STOP-N5 — P4 — operator copy still carries machine tokens

Two leaks survived the reclassification:

* the stop toast body is `Sequence stopped by request at 2026-08-14T00:13:25.206940.` — a raw
  ISO-8601 local timestamp with microseconds and no zone, in a sentence written for a person.
  Wave E flagged the same shape in the red toast it replaced;
* RECENT EVENTS carries `Decision logged — system_event #14: Sequence cancelled`, which
  surfaces both an internal row id and the raw `Sequence cancelled` notice string that the
  whole batch exists to translate. It is INFO-level, so it does not cry wolf — it just reads
  like log output.

---

## Notes / non-findings

* Properties still titles a target node `TargetHeader` and an exposure node `TakeExposure`
  (SEQ-1, already tracked, not on this cluster's list).
* "Recover Sequence?" lists `Completed  4 frames (1m integration)` — `Completed` is the row
  label, not a status claim (same call Wave E made). Its `1m` is WF-STOP-N2.
* Execution History files a run timestamped `Aug 14, 2026 00:09` under the day header
  `Thursday, Aug 13, 2026`. That is observing-night grouping and is correct.
* Readiness ▸ Critical devices ▸ **Connect mount** appeared to do nothing (two clicks, no log
  line, no dialog), but the Discovery-row Connect for the same device also needed several
  attempts before one registered, so this is **not** reported as a defect — the harness's
  swallowed-first-click behaviour cannot be separated from a dead button without a build that
  logs the tap.
