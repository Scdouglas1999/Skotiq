# GUI release pass — cluster: imaging-spine

Cluster: Imaging, Guiding, Flat Wizard, Polar Alignment (plus the first-run path used to reach them).
Harness: `tools/ui_audit/drive_linux.py`, profile `gui-imaging-spine`, display `:81`, release bundle
`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`.
Devices: built-in Simulator camera / mount / focuser / filter wheel, native Built-in Multi-Star Guider.

---

## IMG-1 — P1 — Capture-folder validation latches: fixing a bad path does not clear the error, onboarding dead-ends

**Screen:** First-run onboarding, step 10 of 13 ("Where should we save captures?")

**Repro**
1. `start --fresh`, walk onboarding to step 10.
2. Type a path that does not exist, e.g. `/tmp/ns-audit/gui-imaging-spine/captures` (before creating it).
3. Click **Next** → step does not advance; field shows `That folder does not exist.`
4. Now correct the mistake the way any user would: select-all and type a path that certainly exists —
   `/tmp`. Wait. Click **Next** again.

**Expected:** the field re-validates on edit (or at the latest on Next) and accepts `/tmp`.

**Actual:** the field still reads `That folder does not exist.` under `/tmp`, and Next stays dead on
step 10. The stale error survived >2 minutes and repeated Next presses. Evidence:
`/tmp/ns-audit/gui-imaging-spine/s08.png` — field contains `/tmp`, error says the folder does not exist.
Additionally a second, contradictory validation line (`Pick a capture folder.`) stays in the a11y tree at
the same time as the "does not exist" line, so two different errors are live for one field.

**Escape hatch (proves it is a latch, not a real check):** click **Back** then **Next** to remount the
step — with the *same* `/tmp` still in the field it immediately flips to `Folder is writable.` and Next
works. So the validator is correct; its result is cached and never recomputed while the step stays mounted.

**Why P1:** this is the first-run wizard of a paid product. The user's natural recovery (retype the path)
does nothing, and nothing on screen hints that Back-then-Next is the cure. The only other ways out are the
Browse dialog or abandoning onboarding entirely.

---

## IMG-2 — P2 — Imaging viewport: the FOV scale bar is drawn through the histogram card

**Screen:** Imaging → viewport, bottom-left corner (any frame on screen)

**Repro**
1. Equipment → Connect All (5/5). Nav → Imaging.
2. Click **Snapshot** (bottom bar) and wait for the frame.
3. Look at the bottom-left of the viewport.

**Expected:** the histogram card and the field-of-view scale bar are laid out beside/above one another.

**Actual:** they are two independently-anchored bottom-left overlays that collide. The scale bar's white
bracket is painted straight across the histogram plot, and its `10'` label lands inside the histogram
card's lower border; the scale bar's own dark strip extends past the card to the right.
Evidence: `/tmp/ns-audit/gui-imaging-spine/s15-hist.png` (1:1 crop), full frame `s14-snap.png`.

---

## IMG-3 — P2 — Imaging viewport: the compass rose and the frame-statistics card are stacked on top of each other

**Screen:** Imaging → viewport, bottom-right corner

**Repro**
1. Same as IMG-2 — connect the sim camera, Imaging, **Snapshot**.
2. Look at the bottom-right of the viewport.

**Expected:** the N/E compass rose and the HFR / Stars / Median / Mean readout occupy separate space.

**Actual:** the stats card is drawn on top of the compass rose. The circle is bisected by the card, the
red `N` arrow is the only part of the rose still legible, and the numeric rows sit over the compass
graphic. Evidence: `/tmp/ns-audit/gui-imaging-spine/s16-compass.png` (1:1 crop).

Both IMG-2 and IMG-3 are permanent — they are not transient/animating overlays, they render this way for
every frame at the default window size (1600x900), which is a size a paid product must handle.

---

## IMG-4 — P2 — Annotate reports a green "Found 0 objects" when the plate solve actually failed

**Screen:** Imaging → viewport overlay chip (top-left) / the `Annotate` toolbar button

**Repro**
1. Connect the sim rig, Imaging, **Snapshot**.
2. Watch the chip that appears top-left of the viewport: `Searching catalogs…` → `Found 0 objects`,
   rendered in the success/green treatment with a tick icon.

**Expected:** if no astrometric solution was obtained, the app says so ("Plate solve failed — cannot
annotate"), because "found 0 objects" is a statement about the sky, not about a failure.

**Actual:** the plate solve produced no WCS at all, and the UI reports the benign result.
Proof the solve failed rather than genuinely finding nothing:
- ASTAP is launched twice on the same file (blind, then hinted) —
  `Running ASTAP: … -f /tmp/Unknown_R_2026-08-11_0001.fits -z 2 -d … -wcs` and
  `… -ra 0.000000 -spd 90.000000 -r 30.00 …` — and **neither run logs any outcome line**.
- No `.wcs` file is produced: `ls /tmp/Unknown_R_2026-08-11_0001*` returns only the FITS and its
  thumbnail.
- The viewport's own sky readout stays at `Sky --` (no coordinates) both before and after — so the app
  itself does not believe it has a position, while the chip implies the catalog search completed.

This is the failure-presented-as-success shape: a user who trusts the chip concludes their field is empty,
not that solving is broken.

---

## IMG-5 — P3 — The same frame gets two different HFR / star-count numbers, one on screen and one in the pipeline

**Screen:** Imaging → viewport HUD (bottom-left `HFR 2.74 ECC 0.28 121 ★` and the stats card)

**Repro**
1. Connect the sim rig, Imaging, **Snapshot** (2 s, filter R).
2. Read the on-screen HUD, then `log --tail 600`.

**Expected:** one number for one frame, or a label that says which statistic is which.

**Actual:** the HUD says **HFR 2.74 / 121 stars**; the native star detector logs, four separate times for
the identical file, **`Detected 128 stars, median HFR: 2.40`**. The HUD label is a bare "HFR", so there is
no way for the user to know they are looking at a different statistic (or a different detector) from the
one the rest of the app records. HFR is the number an imager uses to judge focus, so two unlabelled
answers 14 % apart is a real trust problem.

**Adjacent (same evidence):** that single snapshot re-reads the FITS from disk six times and re-runs star
detection four times inside three seconds — visible in the log as repeated
`Reading FITS file: …` / `Detecting stars in: …` pairs at 14:12:51 and 14:12:53.

---

## IMG-6 — P3 — Imaging screen: filter chips and the Frame Type / Binning dropdowns are invisible to accessibility

**Screen:** Imaging → bottom bar filter chips (L R G B Ha OIII SII), gain chip `G100`; right rail
`Frame Type` and `Binning`

**Repro**
1. Connect the sim rig, Imaging.
2. `tree` and read the nodes for the filter row and the exposure panel.

**Expected:** interactive controls expose a button/combobox role and an operable state.

**Actual:** every filter chip appears as `panel: Ha [DISABLED]`, the gain chip as `panel: G100 [DISABLED]`,
and both dropdowns as `button: Light [DISABLED]` / `button: 1x1 [DISABLED]` — yet they all work when
clicked: clicking the `Ha` chip logs
`[API] api_filterwheel_set_position called: device_id=sim_filterwheel_1, position=4`. So the app tells
assistive tech that its primary imaging controls are disabled while they are in fact live. A screen-reader
or keyboard user cannot change filter, gain, frame type or binning from the Imaging screen.

---

## IMG-7 — P3 — The persistent status bar reads "Idle" while the camera is mid-exposure

**Screen:** bottom status bar (present on every screen), during an Imaging capture loop

**Repro**
1. Connect the sim rig, Imaging, set `Dur 2 s`, click **Loop** (button flips to **Stop** — the loop is
   genuinely running).
2. While it runs, sample the tree repeatedly: the viewport shows `20% / Exposing…`.
3. Read the two status chips: the global pill at the far left of the status bar and the last chip on the
   right (after `TC`).

**Expected:** the chrome that is visible on every screen reflects that the camera is exposing.

**Actual:** both read `Idle`, continuously, through every exposure —
evidence `/tmp/ns-audit/gui-imaging-spine/s18-statusbar.png` captured mid-exposure
(`Focus 25000 ● | TC ● Idle`). Neither chip carries a label or tooltip, so the user cannot even tell
*what* is idle; the unlabelled ambiguity is part of the defect. The in-viewport `Exposing…` indicator is
the only truthful state on screen, and it is not visible from any other screen.

**Positive control (works, no defect):** Loop→Stop mid-exposure is clean — the button flips back, the
`Exposing…` overlay clears, the last frame's stats stay stable (HFR 2.76 / 121 stars), and nothing hangs.

---

## IMG-8 — P1 — Guiding never leaves "Settling"; the same screen's status bar simultaneously says "Guiding"

**Screen:** Guiding — header chip, right-rail state card, and the bottom status bar

**Repro**
1. Connect the sim rig (Equipment → Connect All → 5/5). Nav → **Guiding**.
2. Click **Loop Exposures**, wait ~5 s, click the primary button (now **Stop**) to stop looping.
3. Click the primary button again (**Start**). Guiding begins: the star is tracked, the graph draws, RMS
   populates.
4. Leave it running and watch the state chip.

**Expected:** the guider reports `Settling` briefly, then `Guiding`, once the settle criteria are met.

**Actual:** after **127 frames / ~2.5 minutes** with RMS **0.17 px RA / 0.20 px Dec / 0.26 px total**
(well inside any settle threshold) the header chip and the right-rail card both still read **`Settling`**
— it never transitions. Worse, at the same instant the bottom status bar of the same screen reads
`Guider **Guiding**`. Evidence: `/tmp/ns-audit/gui-imaging-spine/s24-guiding-settling.png` — both states
visible in one frame.

**Why P1:** "settled" is the gate every automated flow waits on (post-slew, post-dither, post-flip). A
guider that reports `Settling` forever either stalls those flows or proves the state machine's published
state is meaningless — and a user watching the screen is told their guiding has not started yet while it
has been guiding for minutes.

---

## IMG-9 — P2 — Loop Exposures runs blind: SNR reads 0.0 and Frame Count stays 0 for the whole loop

**Screen:** Guiding → `Guide Star` card badge, `Star Statistics` card

**Repro**
1. Guiding, guider connected, click **Loop Exposures**.
2. Wait 35 s (roughly 30 loop frames) and read the left column.

**Expected:** the loop's per-frame measurements appear — that is the entire point of looping before you
pick a star.

**Actual:** the guide-star thumbnail updates and clearly contains a bright star, but the badge on it reads
**`SNR: 0.0`**, and `Star Statistics` shows `SNR —`, `Star Mass —`, `Frame Count 0` — unchanged for the
whole loop. Meanwhile the native detector logs a fresh measurement for every frame:
`[STAR_DETECT] Measured 119 sources (eccentricity <= 0.95) … 110 usable`.
Evidence: `/tmp/ns-audit/gui-imaging-spine/s23-guideloop.png`.

The same fields populate correctly the instant guiding proper starts (`SNR 445.9`, `Star Mass 206997`,
`Frame Count 1`), so this is confined to the Loop Exposures path, and it is the one mode where a user is
supposed to judge star quality and exposure length by eye.

**Adjacent:** **Auto Select** (Star Selection) produces no visible change and no log line at all, in
either looping or stopped state — there is no feedback that it did anything.

---

## IMG-10 — P2 — Guiding "Pause" does nothing observable anywhere in the app

**Screen:** Guiding → right rail `Guiding Controls` → **Pause**

**Repro**
1. Start guiding as in IMG-8 (frames accumulating, RMS live).
2. Click **Pause**. Wait 6 s. Re-read the screen and the status bar.

**Expected:** the button becomes Resume (or gains a pressed state), and some state readout says paused.

**Actual:** nothing changes anywhere. The button still reads `Pause` with default styling
(`/tmp/ns-audit/gui-imaging-spine/s26-controls.png`), the header chip still reads `Settling`, the bottom
status bar still reads `Guider Guiding` (`s25-guiderchip.png`), the frame counter keeps incrementing, and
no line is written to the log. The user has no way to tell whether corrections are suspended — which is
the one thing pause exists to tell them.

---

## IMG-11 — P2 — The same guide RMS number is labelled "px" on the Guiding screen and arcsec on the Equipment card

**Screen:** Guiding → Guide Graph header vs Equipment → GUIDER device card

**Repro**
1. Run guiding to steady state (IMG-8).
2. Read Guiding: `RA: 0.17 px   Dec: 0.20 px   Total: 0.26 px`
   (`/tmp/ns-audit/gui-imaging-spine/s24-guiding-settling.png`).
3. Nav → Equipment, read the GUIDER card: `0.26"` RMS Total, `RA: 0.17"` RA/Dec RMS
   (`/tmp/ns-audit/gui-imaging-spine/s27-equip3.png`).

**Expected:** one unit for one quantity, or a genuine conversion between the two screens.

**Actual:** identical numerals, contradictory units. With this profile's image scale (1.29 arcsec/px,
computed by the app itself in onboarding) 0.26 px is 0.34", so the two labels cannot both be true — one
screen is mislabelling guide performance by a factor of ~1.3. Guide RMS is the number users compare
against their seeing and their pixel scale, so an unreliable unit makes it worthless.

**Third surface, same instant (makes the Guiding screen the outlier):** with guiding live, Imaging → right
rail `Guiding` tab shows `RMS 0.25″ / SNR 445` and the Imaging bottom bar shows `0.25"`, while the Guiding
screen shows `Tot: 0.25 px`. Two screens say arcsec, one says px, for one number.

---

## IMG-11b — P3 — Onboarding tells the user to open Polar Alignment "from the side nav"; there is no such entry

**Screen:** onboarding step 12 (Review & save) → footer note; then the app's side nav

**Repro**
1. Finish onboarding. On the Review & save step read: *"Need polar alignment? Open Polar Alignment from
   the side nav after finishing."*
2. Go to the app and read the side nav: Dashboard, Equipment, Imaging, Sequencer, Guiding, Weather,
   Plan Tonight, Analytics — eight entries, no Polar Alignment, and the rail has empty space below
   Analytics so nothing is scrolled out of view (`/tmp/ns-audit/gui-imaging-spine/s10-dash.png`).

**Actual:** Polar Alignment lives on the **Equipment** screen's status column, as a tool card with an
`Open` button, several cards down and below the fold until the tour dialog is dismissed
(`s27-equip3.png`). The first instruction a new user is given about the feature points at the wrong place.
Flat Wizard is in the same place and is not mentioned at all.

---

## IMG-12 — P1 — Polar Alignment "Stop" is ignored: the run continues to its own timeout

**Screen:** Polar Alignment (Equipment → Polar Alignment → Open) → footer **Stop**

**Repro**
1. Equipment → Connect All → Polar Alignment card → **Open**.
2. **Start Alignment** (defaults: North, 5 s, step 15°, bin 2).
3. Once the status reads `Plate solving point 1/3…`, click **Stop**.
4. Watch for 5 s, then for another 12 s.

**Expected:** the run aborts; the screen returns to the ready state (or says "Stopped"), and nothing keeps
running.

**Actual:** Stop is completely ignored. Five seconds after the click the status is still
`Plate solving point 1/3…`, the elapsed counter is still climbing (28 s), the button still says `Stop`,
and no acknowledgement of any kind appears — not even a `Stopping…` state. The run then runs out its own
30 s solver timeout and ends in the **error** state (`Error Occurred / Error: Plate solve timed out after
30.0 seconds for point 1`) rather than a stopped state. The log records no stop request at all.

**Why P1:** on real hardware this wizard slews the mount between three points. A user who realises the
run is wrong — cloud, wrong hemisphere, wrong target, cable snag — presses Stop and nothing happens, with
no indication that the app even received the click.

---

## IMG-13 — P2 — Polar Alignment shows two contradictory statuses at once ("Capturing Point 1" + "Plate solving point 1/3…")

**Screen:** Polar Alignment → `Status` panel during a run

**Repro**
1. Start a TPPA run as above.
2. Read the Status panel at 13 s and again at 28 s elapsed.

**Expected:** one current status.

**Actual:** the panel simultaneously shows the headline `Capturing Point 1` and the detail
`Plate solving point 1/3…` — and it keeps showing both for the whole solve. The log proves the capture
finished long before (`Exposure complete` at 14:30:16, then `Plate solving point 1/3...`), so
`Capturing Point 1` is a stale line that is never cleared. At 28 s elapsed the app is still telling the
user it is capturing point 1.

---

## IMG-14 — P2 — Polar Alignment starts a three-point run with the mount parked and no preflight check

**Screen:** Polar Alignment → **Start Alignment**

**Repro**
1. Fresh connect; leave the mount as it comes up — the Equipment MOUNT card reads
   `00:00:00 +00:00:00 **Parked**` (`/tmp/ns-audit/gui-imaging-spine/s27-equip3.png`).
2. Open Polar Alignment. Its own on-screen checklist says "Point the telescope near the celestial pole"
   and "Ensure camera and mount are connected".
3. Click **Start Alignment**.

**Expected:** the wizard checks the two preconditions it just listed — mount unparked, pointing anywhere
near the pole — and refuses with a specific message, since it knows both facts.

**Actual:** it starts anyway, exposes for 5 s, blind-solves a field 50° from the pole, and 35 s later
fails with `Plate solve timed out after 30.0 seconds for point 1`. The user is given a solver error for
what is actually a parked mount. Nothing in the failure mentions the mount at all.

**Related detail worth fixing with it:** the solve is issued as `Blind plate solving` —
`astap_cli -f … -z 2 -d … -wcs` with no position hint and no field-scale hint, even though the app knows
the mount's RA/Dec, the hemisphere the user selected, and the image scale it computed during onboarding
(1.29 arcsec/px). The same blind-solve-with-no-hints call is what fails behind IMG-4.

---

## IMG-15 — P3 — Polar Alignment error state: generic title, doubled message, no next step, and the progress panel vanishes

**Screen:** Polar Alignment after a failed run — `/tmp/ns-audit/gui-imaging-spine/s30-polar-err.png`

**Actual:**
- Title is the placeholder-grade **"Error Occurred"**.
- The message `Error: Plate solve timed out after 30.0 seconds for point 1` is printed **twice** on one
  screen (centre panel and footer bar), and it prefixes itself with "Error:" under a heading that already
  says an error occurred.
- No remedy is offered (check pointing, raise exposure, verify solver) — only `Restart` / `Done`.
- The `Progress / Point 1 · 2 · 3` panel disappears entirely on failure, so the screen no longer shows how
  far the run got.

---

## IMG-16 — P3 — The polar-alignment bullseye always draws a marker dead centre, including before any measurement and after a failure

**Screen:** Polar Alignment → bullseye panel (right)

**Repro:** open the screen (never started) — `s28-polar.png`; or fail a run — `s30-polar-err.png`.

**Expected:** no marker, or an explicit "no measurement yet" treatment, when Azimuth / Altitude / Total
all read `--`.

**Actual:** a solid blue dot sits exactly at the centre of the 30"/60"/120" rings in both states, which
reads as "your polar error is zero". The numeric row directly beneath it says `-- / -- / --` at the same
time. The Guiding screen's Target Display has the identical problem: a red × pinned at 0,0 while the
guider is Stopped with no data.

---

## IMG-17 — P3 — Bullseye ring label `120"` is clipped by the panel edge

**Screen:** Polar Alignment → bullseye, outermost ring label

**Repro:** open Polar Alignment at the default 1600x900 window; read the three ring labels.

**Actual:** they render `30"`, `60"`, `120` — the outermost label is cut off at the panel's right edge and
loses its arcsecond mark, so it reads as a bare number in a panel whose own caption promises
`30", 60", and 120" error zones`. 1:1 evidence: `/tmp/ns-audit/gui-imaging-spine/s29-rings.png`.

---

## IMG-18 — P2 — Flat Wizard's preview panel says "No flat captured yet" through the entire run and after it

**Screen:** Flat Frame Wizard (Equipment → Flat Wizard → Open) → the large preview panel (top right)

**Repro**
1. Equipment → Flat Wizard → **Open** → Quick Capture tab.
2. **Start Capture** → in the `Save Location Required` dialog type `/tmp` → **Continue**.
3. Let the exposure search converge (it walks 1.0 s → 2.4 s → 5.7 s → 7.86 s) and the run begin.
4. At frame 7/30, 13/30, and after stopping, read the preview panel.

**Expected:** the panel shows the most recent flat (that is what "see preview" means), or at minimum stops
claiming nothing has been captured.

**Actual:** it reads **`No flat captured yet` / `Start capture or test exposure to see preview`** for the
entire run and after it — while the app is writing frames to disk:
`Saving FITS … to: /tmp/2026-08-11/Ha/Flat_Ha_20260811_103451_6.fits`, and `ls /tmp/2026-08-11/Ha | wc -l`
returns **13**. The panel is the largest element on the screen and it is the only thing on it that is
false. Evidence: `/tmp/ns-audit/gui-imaging-spine/s33-flatrun.png` (frame 7/30),
`s35-flatstopped.png` (after stop, 13 frames on disk).

---

## IMG-19 — P2 — Flat Wizard: the per-filter Visualizations row is clipped and the filter being captured is off-screen

**Screen:** Flat Frame Wizard → `Visualizations` row

**Repro**
1. Run the Quick Capture flow above with filter **Ha**.
2. Look at the per-filter cards along the bottom.

**Expected:** all seven profile filters (L R G B Ha OIII SII) are reachable, and the one currently being
captured is visible.

**Actual:** the row is cut off by the window's right edge after `B` (a fifth card is sliced in half), with
no scrollbar, arrow, or any other affordance that more cards exist. `Ha` — the filter with live data
(`Ha / 7.86s / 13/30`, confirmed in the a11y tree) — plus `OIII` and `SII` are entirely unreachable at the
default 1600x900 window. Evidence: `s33-flatrun.png`, `s35-flatstopped.png`.

---

## IMG-20 — P3 — Flat Wizard: the ADU Convergence chart plots a negative-ADU axis and collides its bottom two tick labels

**Screen:** Flat Frame Wizard → `ADU Convergence` chart

**Repro:** run a Quick Capture until the chart has points; read the y axis.
1:1 evidence: `/tmp/ns-audit/gui-imaging-spine/s34-aduaxis.png`.

**Actual:** ticks are `40k`, `21k`, `0k`, `-2k`. ADU cannot be negative, so the axis extends below the
physical floor of the quantity purely to pad the plot, and the resulting `0k` and `-2k` labels sit ~12 px
apart (the other ticks are ~65 px apart) so they read as one smudged label. The tick interval is also
irregular (19k, 21k, 2k).

---

## IMG-21 — P3 — Flat Wizard: "Stop Capture" gives no acknowledgement for the length of the in-flight exposure

**Screen:** Flat Frame Wizard → **Stop Capture** during a run

**Repro:** during a 7.86 s flat exposure, click **Stop Capture**; watch for 4 s.

**Actual:** nothing changes — the button still says `Stop Capture`, the status still says `Capturing`, the
frame counter still advances (13/30), and a fresh 7.86 s exposure is even started after the click. The
stop lands ~8 s later (`Exposure cancelled` in the log) and the button returns to `Start Capture`. The
behaviour is correct; the missing piece is any `Stopping…` state, so for eight seconds the app looks like
it ignored the click — which is exactly what the Polar Alignment wizard genuinely does (IMG-12).

**Credit where due:** the wizard's *outcome* reporting is honest — after stopping at 13 of 30 it shows a
`⚠ Partial` chip with `13/30`, not a success. The gain/offset mismatch warning ("These flats will not
match your light frames (offset 10 vs 50)") is specific and genuinely useful.

---

## IMG-22 — P3 — Flat Wizard: truncated readouts, and Multi-Filter Batch's filter list is not accessible

**Screen:** Flat Frame Wizard → `Histogram Target` readout; `Multi-Filter Batch` tab

**Actual:**
- The bit-depth readout truncates to `~32768 / 65535 ADU · 16-…` in a column with free space beside it
  (`s31-flat.png`, `s35-flatstopped.png`).
- On the **Multi-Filter Batch** tab the seven filters expose as bare `panel: L`, `panel: R`, … with no
  checkbox/selected state in the accessibility tree, so a keyboard or screen-reader user cannot tell which
  filters the batch will capture, let alone change them. Same class as IMG-6.

---

## Things I tried to break that held up (recorded so nobody re-files them)

- **Connect All is not dead.** Two early clicks on it did nothing; that was the harness clicking stale
  coordinates after the tour card dismissal reflowed the column, not the app. Clicked at its real position
  it connects 5/5 and the screen keeps an honest receipt: `Connect All at 10:12: 5 of 5 succeeded` with a
  per-device chip. No finding.
- **Navigating away mid-guide is clean.** Guiding → Imaging → Guiding: the session survives, frame count
  continues (23 and rising), stats stay live, nothing resets.
- **Loop → Stop mid-exposure on Imaging** is immediate and leaves consistent state.
- **Rapid-fire clicking Snapshot** (4 clicks in <1 s) produces exactly 1 capture, and the counters stay
  truthful: `Captured 2 frames / Integration 4s` against exactly 2 files on disk at 2 s each. The
  frames↔integration cross-check passes on the Imaging screen.
- **Flat Wizard outcome honesty** — stopping at 13/30 reports `⚠ Partial 13/30`, and 13 files are on disk.
- **Flat Wizard exposure search** converges sensibly (1.0 → 2.4 → 5.7 → 7.86 s to land 32584 ADU against a
  32768 ± 10 % target) and writes to the date/filter subfolders it promised.
- **No layout exceptions.** `RenderFlex`/`overflowed by` count across the whole session log: **0**. The
  overlaps in IMG-2/IMG-3 are stacked overlays, not unbounded-constraint errors, so a log scan will not
  find them — they have to be looked at.
- **Polar Alignment Restart** correctly returns the wizard to its ready state.

---

## Coverage

**Screens driven live in this cluster**
- First-run onboarding, all 13 steps (Welcome, Drivers, Camera, Mount, Focuser, Filter wheel, Guider,
  Optical train, Camera defaults, Capture folder, Observing site, Review & save, What's next)
- Imaging — viewport, overlays/HUD, histogram, Capture tab, Camera tab (cooling/sensor/gain), exposure
  settings, file settings, session panel, bottom capture bar (Snapshot / Loop / Save / Dur / gain / filter
  chips), Annotate, right-rail Guiding tab
- Guiding — Guide Star, Target Display, Star Statistics, Guide Graph + toolbar, Guiding Controls
  (Start / Stop / Pause / Loop Exposures), Star Selection (Auto Select / Deselect), Dither amount,
  Built-in Guider info card
- Flat Frame Wizard — Quick Capture end to end (settings → save-location dialog → exposure search →
  capture → stop → Partial outcome), Multi-Filter Batch tab, ADU Convergence + per-filter visualizations
- Polar Alignment — TPPA intro, Essential settings, start → capture → solve → failure, Restart, Stop,
  bullseye + error readouts
- Equipment (as the entry point to the two wizards and to connect devices) — profile card, Connect All,
  device cards, STATUS/readiness column

**Not reached, and why**
- **Polar Alignment: All-Sky mode, History, Common/Advanced setting groups.** TPPA never got past point 1
  because every plate solve on this host times out (IMG-4 / IMG-14), so no measurement UI, no adjustment
  loop, and no result/history record could be produced to review.
- **Polar Alignment's live bullseye with real azimuth/altitude error**, and the "adjust the mount" guidance
  it promises — same blocker.
- **Imaging: plate-solve-dependent surfaces** — sky coordinates readout (`Sky --` throughout), annotation
  overlays with actual catalog objects, and anything downstream of a WCS — same blocker.
- **Flat Wizard: Sky Flats tab** — opened only far enough to confirm the tab exists; not driven, as a sky
  flat run needs a twilight sky model that the sun-up sim scene does not provide.
- **Guiding: calibration UI** — the Built-in Guider states "Calibration is managed automatically by
  Skotiq", so there is no calibration flow on this screen to review with this guider.
- **Guiding: dither** — `Dither Now` and `Settle Settings` sit below the fold of a short internally-
  scrolling rail; I could not scroll that rail with the harness (click/key/type only, no wheel).
- **Mid-use device disconnect** — not attempted; deliberately traded for depth on the four screens above.

