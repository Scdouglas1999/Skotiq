# Wave D verification — cluster: imaging-spine

Harness: `tools/ui_audit/drive_linux.py`, display `:81`, profile `waveD-imaging-spine`,
release bundle `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(libapp.so + libskotiq_bridge.so both dated Aug 13 18:31 — the fresh build).
Devices: built-in **Sim** driver (Simulated Camera / Mount / Focuser / Filter wheel / Guider).
Optical train re-created to match the original run: 600 mm, 100 mm, 3.76 um -> **1.29 arcsec/px**.

## Verdicts

### IMG-1 — VERIFIED_FIXED (P1, capture-folder validation latch)
Exact repro run. Onboarding step 10, typed `/tmp/ns-audit/waveD-imaging-spine/does-not-exist`,
pressed **Next** -> did not advance, tree showed `panel: That folder does not exist.` **and**
`panel: Pick a capture folder.` (the two-live-errors part of the original finding still shows at
this moment, but only while the bad path stands).
Then the user recovery the finding says was dead: click the field, `ctrl+a`, type `/tmp`, wait —
**without pressing Next the tree flips to `panel: Folder is writable.`** and both error lines are
gone from the tree. **Next** then advances to `Step 11 of 13`. No Back/Next remount was needed.
The latch is gone: the validator now recomputes on edit.

### IMG-2 — VERIFIED_FIXED (P2, FOV scale bar drawn through the histogram card)
Connect All (5/5) -> Imaging -> **Snapshot** (2 s, filter R). 1:1 crop of the bottom-left corner:
`/tmp/ns-audit/waveD-imaging-spine/shots/s15-hist.png`.
The three bottom-left overlays are now stacked in their own bands with no collision:
`HFR 2.74  ECC 0.28  121 ★` strip on top, the `10'` scale-bar bracket in a separate dark strip
beneath it, and the **Histogram** card below that with its plot fully unobstructed. Nothing is
painted across the histogram, and the `10'` label is inside its own strip, not on the card border.

### IMG-3 — VERIFIED_FIXED (P2, compass rose and stats card stacked)
Same frame, 1:1 crop of the bottom-right corner:
`/tmp/ns-audit/waveD-imaging-spine/shots/s16-compass.png`.
The compass rose renders as a complete circle with both the red `N` and blue `E` arrows fully
legible, and the `HFR / Stars / Median / Mean` card sits entirely **below** it with clear space
between. Neither element occludes the other. Full frame: `shots/s14-snap.png` (1600x900 default).

### IMG-4 — STILL_BROKEN (P2, "Found 0 objects" for a failed solve)
Same repro. The top-left viewport chip renders **green with a tick: `Found 0 objects`**
(`shots/s14-snap.png`, chip at image 240,143), while:
- the viewport's own sky readout still reads `Sky --` — the app does not believe it has a position;
- **no `.wcs` is produced**: `ls /tmp/Unknown_R_2026-08-13_0001*` returns exactly the FITS and its
  `.thumb.jpg`, nothing else;
- **neither ASTAP run logs any outcome line** — the log has the two `Running ASTAP:` lines and then
  nothing about success, failure, or a timeout.
So a solve that produced no WCS is still reported to the user in the success treatment. Unchanged.

*(Related improvement seen in passing, not a finding: the solver now copies the frame into a
per-attempt scratch dir `/tmp/skotiq-solve-<pid>-N/` instead of writing `.ini` debris beside the
user's images — that is the SCI-48 shape, and it is fixed.)*

### IMG-14 (related detail: hinted solves) — PARTIALLY FIXED
The log now shows the **position hint** on the first attempt:
`Running ASTAP: … -f /tmp/skotiq-solve-1491575-0/Unknown_R_2026-08-13_0001.fits
 "-ra" "0.000000" "-spd" "90.000000" "-r" "30.00" "-z" "2" "-d" … "-wcs"`
preceded by `Plate solving near RA:0.00°, Dec:0.00°`, and the blind attempt is now the **fallback**
(second), not the first. That is the ordering the finding asked for.
**But there is still no field-scale hint anywhere**: `grep -i "fov" app.log` returns nothing, and
neither ASTAP invocation carries `-fov` (or any equivalent), even though the app computed and stored
`1.29 arcsec/px` during onboarding and shows it on the profile card (`f/6.0 · 1.29"/px at 3.76µm`).
Half of "the same blind-solve-with-no-hints call" is closed; the scale half is not.

### IMG-8 — VERIFIED_FIXED (P1, guider never leaves "Settling"; status bar contradicts it)
Exact repro (Loop Exposures -> Stop -> Start) on the Built-in Multi-Star Guider.
Sampling the header state chip every 3 s from the moment of Start gives a real state machine:
`Calibrating` -> `Calibrating` -> `Settling` -> `Settling` -> `Settling` -> `Settling` -> `Guiding`,
and it stays `Guiding` for every subsequent sample (8 more samples over 32 s).
At steady state all three surfaces agree — header chip `Guiding`, right-rail state card `Guiding`,
bottom status bar `Guider **Guiding**` — with `RA 0.17 px / Dec 0.16 px / Total 0.23 px` and
`Frame Count` climbing (27 -> 45 -> …). Evidence: `shots/s23-pause.png`.
The contradiction is gone and the transition genuinely happens.

### IMG-9 — PARTIALLY FIXED, one residual (P2, Loop Exposures runs blind)
Repro: Guiding -> **Loop Exposures**, waited 35 s, read the left column.
Fixed: the guide-star badge now reads **`SNR: 445.4`** (was `SNR: 0.0`), and `Star Statistics`
shows **`SNR 445.5`** and **`Star Mass 206760`** live and updating during the loop.
Residual: **`Frame Count` still reads `0` for the whole loop** — it only starts counting once
guiding proper begins (27 after 30 s of guiding). Two of the three fields the finding named now
populate; the frame counter still shows nothing while frames are visibly looping.
(If Frame Count is deliberately "guide frames", the label needs to say so — the two rows above it
are per-loop-frame measurements, so a user reads all three as describing the same loop.)

**IMG-9 adjacent — STILL_BROKEN.** **Auto Select** still produces no visible change and no
dedicated log line: clicking it while looping added only the loop's own
`[STAR_DETECT] Measured 117 sources …` / `camera_start_exposure` lines, and nothing on screen moved.

### IMG-10 — STILL_BROKEN (P2, Guiding "Pause" does nothing observable)
Repro: guiding at steady state (`Guiding`, Frame Count climbing), clicked **Pause**, waited 7 s,
then repeated and screenshotted at 2 s (`shots/s23-pause.png`).
Nothing changes. The button still reads `Pause` in **normal enabled styling** (identical treatment
to `Loop Exposures` beside it — 1:1 crop `shots/s22-controls.png`), the state chip stays `Guiding`,
the status bar stays `Guider Guiding`, `Frame Count` keeps incrementing (45 and rising), no toast
or snackbar appears, and the 35 new log lines are all the guide loop's own exposures.
The one thing that changed since the original run is a **hover tooltip** now attached to the
button — the a11y name is `Pause — Pause is a PHD2 feature. The built-in guider has no pause — use
Stop to suspend guiding.` That is the right explanation in the wrong place: it fires only on hover,
so the user who clicks still gets silence, and the button is **not marked `[DISABLED]` in the a11y
tree** and is not visually disabled, so both a sighted clicker and a screen-reader user are told it
is a live control. Disabling the button (with that text as the reason) would close this; a tooltip
alone does not.

### IMG-12 — VERIFIED_FIXED (P1, Polar Alignment "Stop" ignored)
Repro exactly: Equipment -> Polar Alignment -> Open -> **Start Alignment** (North, 5 s, defaults),
waited until the status read `Plate solving point 1/3...`, clicked **Stop**.
Two seconds later the footer reads **`Polar alignment stopped`**, the primary button is back to
`Start Alignment`, the wizard has returned to its intro/ready state, and the state is identical at
+8 s. No 30 s solver timeout, no `Error Occurred` state, nothing left running.

### IMG-13 — PARTIALLY FIXED, the contradiction moved to the slew step (P2)
Sampled the Status panel every 3 s through a whole run. The capture/solve phases are now consistent
— headline and detail always name the same phase and the same point:
`Capturing point 1/3...` + `Capturing point 1 of 3`; `Plate solving point 1 of 3` +
`Plate solving point 1/3...`; `Capturing point 2 of 3` + `Capturing point 2/3...`.
The original stale `Capturing Point 1` that survived into the solve is gone.
**But the slew step is off by one and disagrees with itself.** Two consecutive samples, 3 s apart,
both read:
`panel: Slewing to point 1 of 3` (status headline) **and** `panel: Slewing to point 2...`
(detail + footer bar) at the same instant. The mount is slewing to point 2, so the headline is also
factually wrong, not just inconsistent. Same defect shape, relocated one step.

### IMG-14 — FIXED in substance, but the refusal is silent (P2, run starts with the mount parked)
Decisive A/B on the same screen:
- **Mount Parked** (Equipment MOUNT card `00:00:00 +00:00:00 Parked`), observing location set:
  clicking **Start Alignment** does **nothing at all** — no run, no toast, no message, not one new
  line in the log (1439 -> 1439), and the footer keeps saying `Ready to start polar alignment`.
- **Then Unpark and click the same pixel**: the run starts immediately (`Settings are locked while
  aligning`, `Point 1/2/3` progress, `Slewing to point 1 of 3`).
So the gate is real and it is the parked mount — the wizard no longer blind-solves a field 50° from
the pole with a parked mount. That closes the finding's substance.
**Residual (new, worth filing):** the refusal is completely silent. Nothing says *why*, the footer
actively claims `Ready to start polar alignment` while it is not ready, and the button is **not
marked `[DISABLED]` in the a11y tree** (1:1 crop `shots/s38-startbtn.png` shows only a muted
treatment). The finding asked it to "refuse with a specific message"; it refuses with none.
*(Separately, a genuinely good new preflight did appear: with no site set the screen shows
"No observing location set. Polar error is measured relative to your site latitude — set an
observing location in Settings before aligning.")*

### IMG-16 — STILL_BROKEN, and it now contradicts the panel beside it (P3, bullseye marker)
Three states measured, 1:1 crops:
1. **Never started** (`shots/s32-bullseye-nodata.png`) — a marker is **still drawn dead centre**
   (now a hollow grey ring rather than a solid blue dot) while Azimuth/Altitude/Total read
   `-- / -- / --`. The caption "After you start, this bullseye shows live azimuth and altitude
   error…" softens it, but the centre marker is still there.
2. **Live adjust phase, real data** (`shots/s45-bullseye-live.png`) — correct: two real markers
   plotted off-centre, no "no measurement" caption, matching `Azimuth: Left 6.5" / Altitude:
   Down 3.1" / Total 7.2"`.
3. **After a completed run** (`shots/s42-tppa-done.png`, crop `s43-bullseye-done.png`) — the
   worst case, and it is new: the bullseye prints **"No measurement yet"** and puts the marker
   back at dead centre, while **the numeric row directly beneath it reads
   `Azimuth 3.2" · Altitude 0.6" · Total 3.2"`** and the centre panel says
   **"Alignment Complete — Final error: 3.2""**. Three elements in one screen, two of them saying
   a measurement exists and the third saying none does.

### IMG-18 — VERIFIED_FIXED (P2, "No flat captured yet" through the whole run)
Repro: Equipment -> Flat Wizard -> Open -> Quick Capture, filter **Ha**, **Start Capture**,
`Save Location Required` -> `/tmp/ns-audit/waveD-imaging-spine/flats` -> **Continue**.
`No flat captured yet` is present only at `0/30`, before the first frame exists — which is true.
From frame 1 onward it is gone from the a11y tree, and the panel shows **the actual flat frame**
(vignetted flat field) with a readout strip `FILTER Ha · EXPOSURE 7.86s · ADU 32584 · FRAME 6/30`.
Evidence `shots/s53-flatrun.png`. After stopping it does **not** revert: the panel keeps the frame,
the chip reads `Partial 12/30`, and `find … -name '*.fits' | wc -l` returns exactly **12**.

### IMG-19 — VERIFIED_FIXED (P2, Visualizations row clipped, active filter off-screen)
Same Ha run at 1600x900. The row now **auto-scrolls to the filter being captured**: `Ha` is fully
visible, outlined in blue, and carries the live data (`7.86s`, `9/30`) while `L` has scrolled off to
the left (`shots/s53-flatrun.png`, 1:1 crop `shots/s54-viz-scrolled.png`).
A **horizontal scrollbar is now drawn beneath the row** — the missing affordance the finding named —
and scrolling it brings `OIII` and `SII` into the tree. All seven filters are reachable and the
active one is visible without any user action.

### IMG-21 — VERIFIED_FIXED (P3, "Stop Capture" gives no acknowledgement)
Repro: clicked **Stop Capture** during a 7.86 s flat exposure and sampled every 3 s.
The button flips to **`Stopping…`** immediately and stays there for exactly the in-flight exposure
(`CAPTURING: 7.0s remaining` -> `3.8s` -> `0.7s`), then returns to `Start Capture` with the honest
`Partial` outcome at `12/30`.
Two things the finding asked for are both there: the `Stopping…` state exists, and **no fresh
exposure is started after the click** — the frame counter freezes at 12/30 for the whole wind-down
(the original run started another 7.86 s exposure after Stop). 12 FITS on disk matches 12/30.

*(Also fixed in passing, from IMG-22: the bit-depth readout now renders in full —
`~32768 / 65535 ADU · 16-bit`, no ellipsis.)*

### SCI-27 — VERIFIED_FIXED (Stacked Preview renders black)
Repro: Imaging -> right rail **Stack** -> Live Stacking **Start** -> picked reference
`/tmp/Unknown_R_2026-08-13_0001.fits` -> **Loop** (2 s) with `Save loop frames` ON, let the stack
run, scrolled the rail to **Stacked Preview**.
The preview now renders **a stretched sky**: a grey background with white point sources across the
frame, matching the viewer beside it. 1:1 crop `shots/s62-preview.png`. Not black.

### SCI-28 — VERIFIED_FIXED (Stop destroys the stack with no confirmation, nothing on disk)
Clicking **Stop** now raises a modal **`Keep this stack?`**:
> "Stopping releases the stacker, and the 1 stacked frame accumulated so far cannot be recovered
> afterwards. Save the stacked master first, or discard it and stop."
with **Cancel / Discard / Save master** (`shots/s63-keepdlg.png`).
**Save master** opens a Save File chooser and genuinely writes the master:
`/tmp/ns-audit/waveD-imaging-spine/stack_master.png` — `PNG image data, 1920 x 1080, 16-bit
grayscale`, 1.8 MB — and the log confirms `PNG file saved: …` then `Live stacker stopped and
resources released`. Only after the save do the statistics reset to `0 frames` / `No data`, which is
now correct rather than destructive.
**Residual worth noting:** I typed the filename as `stack_master.fits` and the app silently wrote
`stack_master.png` instead. 16-bit depth is preserved, but a "stacked master" saved as PNG carries
no FITS header, no WCS and no integration metadata, and the extension change is not disclosed.

---

## New defects found while verifying (adversarial sweep)

### ND-1 — P1 — Live Stacking's frame counters freeze at 1 while the stacker really consumes 68 frames
Imaging -> Stack -> Live Stacking running, camera looping 2 s with `Save loop frames` ON.
The native side logs `Adding frame to stack: /tmp/Unknown_Ha_2026-08-13_00NN.fits` for frames
**0002 through 0069** — 68 additions over ~6 minutes, and 69 FITS on disk — while the panel reports
`Stacked Frames **1 frames**` and `Total Attempted **1 frames**` for the entire run, unchanged, with
`Rejected (Alignment) 0 frames`. The preview *does* update (SCI-27 is genuinely fixed), so the stack
is accumulating; only the counters are stuck. Every derived readout inherits the lie: the Stop
dialog says "the **1** stacked frame accumulated so far cannot be recovered", so a user is told they
are about to lose one frame when they are about to lose sixty-eight.
This is the frames-vs-integration cross-check failing inside one panel: preview advancing +
counter frozen cannot both be right.

### ND-2 — P2 — The polar wizard plate-solves the same sim sky that Imaging's Annotate reports as unsolvable
Same session, same camera, same ASTAP install. Polar Alignment solved all three points and reported
`Plate Solved / RA: 00h 00m 0.5s / Dec: +00° 00' 3"`, then `Alignment Complete — Final error 3.2"`.
Imaging -> Snapshot -> Annotate on a frame of the *same* field produced no `.wcs`, no outcome line,
`Sky --`, and the green `Found 0 objects` chip (IMG-4). So IMG-4 is **not** "solving is broken on
this host" — it is specific to the Imaging/annotate path, which is a much cheaper bug to find than
the original report implies.

### ND-3 — P2 — "Alignment Complete" and "Improvement: Worse" on the same card
`shots/s42-tppa-done.png`. A completed TPPA run shows a green tick and **"Alignment Complete —
Final error: 3.2""**, and directly beneath it the Alignment Summary reads
`Before 3.2" (Az 3.1" / Alt 0.5")` -> `After 3.2" (Az 3.2" / Alt 0.6")` with the Improvement bar
empty and a red **`Worse`** chip. The headline celebrates a run that the summary says made the
alignment worse, and both numbers round to the same 3.2" so the delta is inside the noise.

### ND-4 — P2 — The Imaging bottom capture bar has no narrow-width behaviour
`resize 900 900`, Imaging (`shots/s70-narrow-imaging.png`). The bottom bar is cut off after
`Dur 2 s`: the gain chip, all seven filter chips and the `Stretch` toggle are past the right edge
with **no scrollbar, arrow or overflow menu**. The controls are still in the a11y tree, so they are
laid out and simply not reachable — the exact shape IMG-19 was filed for, in a different bar.
The filter chips also disappear from the tree entirely at this width.
No `RenderFlex`/`overflowed by` lines in the log for the whole session (count: **0**), so a log scan
will not catch it. The rest of the Imaging layout survives 900 px: the HUD strip wraps to two lines
and the scale bar, histogram, compass and stats card all stay clear of each other.

### ND-5 — P3 — Semantics states on the Imaging bottom bar are still partly wrong
At 1600x900 with the rig connected:
- Fixed: filter chips are now `button: L … button: SII` (were `panel: … [DISABLED]`), and
  `Stretch` is a real `toggle button … [off]`.
- Still wrong: **`panel: G100 [DISABLED]`** — the gain chip is reported disabled while it is live;
  and the two primary actions expose as **`panel: Loop`** / **`panel: Snapshot`**, not buttons.
- The filter chips carry **no selected/checked state**, so with `Ha` active the tree gives a screen
  reader no way to know which filter is in the beam.
Also on the Guiding screen: `panel: Time: 5m [DISABLED]` and `panel: Scale: ±2" [DISABLED]` for the
Guide Graph's two dropdowns, both of which open when clicked.

### ND-6 — P3 — Auto Select (Guiding) is still silent
Recorded under IMG-9 above: no visible change, no dedicated log line, in either looping or stopped
state.

---

## Not re-filed (checked, held up)

- **Connect All receipt is honest.** With a PHD2 guider in the profile it reported
  `Connect All at 18:37: 4 of 5 succeeded` with a red `guider Failed` chip and the specific reason
  ("PHD2 connection lost and automatic relaunch failed after 3 attempts"). After switching the
  profile to the Built-in Multi-Star Guider it reported 5 of 5.
- **Polar Alignment Restart** returns the wizard to its ready state cleanly.
- **Equipment STATUS column ordering** is severity-first: red blockers (`Critical devices`,
  `Observing location`) above amber (`Profile devices`, `Dark library`) above the tool cards
  (`Polar Alignment`, `Flat Wizard`), and items disappear as they are satisfied.
- **Flat Wizard exposure search** still converges sensibly (to 7.86 s / 32584 ADU against a
  32768 ±10 % target) and writes to `<root>/<date>/<filter>/`.
- **Live Stacking Statistics** now group under `FRAMES` and `PIXELS REJECTED BY SIGMA CLIPPING`
  headings with `frames` / `px` units — the SCI-47 shape is closed.
- **Plate-solve scratch files** no longer land in the capture folder; each attempt gets
  `/tmp/skotiq-solve-<pid>-N/` (the SCI-48 shape).
- **No layout exceptions** anywhere in the session: `RenderFlex` / `overflowed by` count **0**,
  at both 1600x900 and 900x900.

## Still visible but outside my assigned IDs (for whoever owns them)
- **IMG-17** — the bullseye's outermost ring label still renders `120` clipped at the panel edge
  (`shots/s37-polar2.png`, `s43-bullseye-done.png`).
- **SCI-7** — Live Stacking **Start** still opens a bare GTK `Open File` chooser with no
  explanation, and the panel reads `Status Idle` / `Starting...` at the same moment.
- **SCI-31** — the Narrator toast still truncates mid-word (`Best seeing of the night — FWHM …`,
  and at 900 px it degrades to `Br…`).
- **IMG-11** — Guiding still labels RMS `px` (`RA 0.17 px / Total 0.23 px`) while the Equipment
  GUIDER card labels the same numbers arcsec (`0.28"` RMS Total, `RA: 0.19"`).
