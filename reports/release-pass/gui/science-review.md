# GUI release pass — cluster: Analytics / Science / Session Review / Stack Result

**Wave 2** (2026-08-13). Wave 1's report is preserved verbatim at
`reports/release-pass/gui/science-review-wave1.md` (33 findings, SCI-1 … SCI-33).
New findings here continue the numbering at **SCI-34** so no ID ever means two things.

Harness: `tools/ui_audit/drive_linux.py`, profile `gui-science-review`, display `:86`,
fresh scratch profile, release bundle at `apps/desktop/build/linux/x64/release/bundle`.

> **Harness notes for the next agent (not product findings).**
> 1. `--profile` must come **after** the subcommand. `drive_linux.py --profile X start`
>    silently runs the `main` profile, because the subparser re-declares `--profile`
>    with `default="main"` and clobbers the top-level value.
> 2. The bundle's `lib/libskotiq_bridge.so` was **missing** at 08:16 today, so every
>    `start` died with `Bad state: Native bridge failed to initialize`. Fixed by
>    `cargo build --release -p skotiq_bridge` (1m 19s — the sibling rlibs were warm)
>    and copying the result into the bundle's `lib/`. Two of my early launches were also
>    killed from outside (all five sibling `skotiq_desktop` processes died at the same
>    instant); the app itself is stable once left alone.
> 3. Xvfb runs with **no window manager**, so keyboard focus is PointerRoot. A GTK
>    "Choose Directory" dialog will not receive `ctrl+l` until you `click-xy` inside it
>    first. That is how the capture folder gets set without fighting the file chooser.

## Environment for every repro below

Fresh profile ▸ **Skip onboarding** ▸ dismiss the coach-mark ▸ Equipment ▸ *I'll do it
manually* ▸ Discovery ▸ **Expand** ▸ Connect **Simulated Camera** and **Simulated Mount**
▸ Imaging ▸ Save Path = `/tmp/ns-audit/gui-science-review/data/captures` ▸ **Save** on ▸
**Loop** at 2 s ▸ stop at 32 frames. That produces the populated state used below
(32 light frames, HFR 2.08–2.26, sensor 20.0 °C, no guiding, no focuser).

---

## Summary

**15 new findings: 1 P1, 4 P2, 10 P3.** Fifteen of wave 1's findings were re-tested and still
reproduce; three have improved (details at the end).

The ones that matter:

- **SCI-39 (P1)** — a user who skips the optional observing-site step is judged against
  **latitude 0, longitude 0**. The daylight gate then refuses every light frame of the run
  and blames the Sun, quoting an altitude computed for Null Island, while three other
  surfaces say the app has no location at all. In Australia or East Asia local night *is*
  Greenwich daytime, so the whole night is refused.
- **SCI-40 (P2)** — pre-flight demands dark frames at **−10 °C** for an uncooled camera that
  records every frame at **+20 °C**; acting on the warning produces calibration data that can
  never match.
- **SCI-46 (P2)** — "session" means three different things across three Analytics tabs, and
  the only session holding real frames is invisible to two of them, which is what makes
  Diagnostics look broken.
- **SCI-44 (P2)** — Session Review's *selected* tab is styled to look disabled while the
  unselected one looks live.
- **SCI-36 (P2)** — working controls (a Back link, a help link, both History filters and
  their menu items) are announced to assistive tech as **disabled**.

## Findings

### SCI-34 — P3 — Analytics ▸ Session's empty state is the History tab's copy, so the tab tells you to do the thing you just did
Repro: fresh profile ▸ nav **Analytics** (lands on **Session**).
Expected: an empty state about *this session* — e.g. "No frames captured yet".
Actual: the body reads **"No session history"** / **"Complete an imaging session to see
history here"** — verbatim the copy the **History** tab shows, on a tab whose subject is
the session in progress. The two tabs are one click apart and print the identical
sentence, so the Session tab reads as a duplicate of History rather than as a live view.
Evidence: `/tmp/ns-audit/gui-science-review/w2-05-analytics-session.png`; the same string
appears again after clicking **History**.

### SCI-35 — P3 — Analytics ▸ Equipment Stats: four cards in one row have four different heights
Repro: **Analytics ▸ Equipment Stats** (works empty or populated).
Expected: sibling cards in a row share a height, as they do everywhere else in the app.
Actual: Camera carries 3 stat rows, Focuser 2, Mount and Guider 1 each, and each card is
sized to its own content, so the row's bottom edge steps 208 / 171 / 190 / 171 px
(image coords). It reads as a broken grid, not a designed layout.
Evidence: `/tmp/ns-audit/gui-science-review/w2-08-equipstats.png`.

### SCI-44 — P2 — Session Review's active tab is styled to look disabled, and the inactive one looks active
Repro: run any sequence ▸ **Session Report ▸ Review & Integrate** ▸ note the
**Narrative / Workbench** tab pair ▸ click **Workbench** ▸ compare ▸ click **Narrative** ▸
compare again.
Expected: the selected tab reads as selected — the accent-blue treatment every other tab
strip in this app uses (Analytics' six tabs, Sequencer's Builder/Templates/Sequences/History,
Imaging's tool tabs).
Actual: the **selected** tab renders as a grey chip with **dimmed grey text**, while the
unselected tab keeps bright white text. The state is inverted relative to the rest of the
app, so on this screen the tab you are *not* on looks live and the one you *are* on looks
disabled. It reproduces symmetrically: with Workbench open, "Workbench" is the dim one; with
Narrative open, "Narrative" is the dim one.
Evidence: `/tmp/ns-audit/gui-science-review/w2-29a-tab-workbench.png` (Workbench selected)
vs `/tmp/ns-audit/gui-science-review/w2-29b-tab-narrative.png` (Narrative selected) — same
crop, same scale.

### SCI-45 — P3 — Analytics ▸ History's "All Targets" filter is cramped against the panel edge
Repro: **Analytics ▸ History** with at least one run recorded.
Expected: the two filter chips share the same internal padding.
Actual: "All Time" sits in an 84 px chip with even padding; "All Targets" is given the same
width for a longer label, so its chevron is flush with the chip's right border and the chip
itself is flush with the panel edge — no right-hand padding at all, unlike every other
control in the row.
Evidence: `/tmp/ns-audit/gui-science-review/w2-30-history.png`.

### SCI-36 — P2 — Working controls are exposed to assistive tech as **disabled**, so a screen-reader user is told they cannot be used
Repro (four instances, all reproduce with `drive_linux.py tree`):
3. **Analytics ▸ History** ▸ the **All Time** and **All Targets** filter chips are exposed as
   `button: All Time [DISABLED]` / `button: All Targets [DISABLED]`, and every entry of the
   menu they open is `[DISABLED]` too (`All Time`, `This Month`, `This Year`). They are
   fully functional: clicking **This Month** re-labels the chip and re-filters the list.
4. Same screen — this holds whether or not there are sessions to filter, so it is not an
   empty-data state.
Original two instances:
1. **Analytics ▸ Projects ▸ Mosaic projects** — the header's `‹ Back` control is exposed as
   `panel: Back [DISABLED]`. Clicking it **works** (it returns to Analytics), so the
   node is lying about both its role and its state.
2. **Analytics ▸ Diagnostics** — `panel: Learn more about optical diagnostics [DISABLED]`.
   Clicking it **works**: it opens the "Reading optical diagnostics" dialog.
Expected: `button:` / `link:` with an enabled state.
Actual: role `panel`, state `DISABLED`. A screen reader announces a working control as an
inert, disabled one — the user will not attempt it. This is the same family as wave 1's
SCI-3/SCI-4/SCI-19 (icon controls with no node at all) but a distinct failure: the node
exists and actively misreports.
Evidence: tree output; `/tmp/ns-audit/gui-science-review/w2-07-mosaic.png`,
`/tmp/ns-audit/gui-science-review/w2-10-diagnostics.png`.

### SCI-37 — P3 — The per-frame "score" on a captured-image tile is not the quality score the app stored for that frame
Repro: capture the 32-frame session above ▸ **Analytics ▸ Session** ▸ scroll to
**Captured Images** ▸ read the green `NN score` line on the tiles ▸ compare with
`sqlite3 /tmp/ns-audit/gui-science-review/data/skotiq.db "select id, round(hfr,3), quality_score from captured_images order by id;"`
Expected: one score per frame, or two clearly different labels.
Actual: every tile reads **`75 score`** (two of the 32 read `74 score`), while the stored
`quality_score` for the same frames ranges **83.94 – 85.38** and is distinct for every
frame. Two different numbers are both "the score" for one frame; the one the user sees is
not the one the database keeps, and neither is labelled with its scale or its meaning.
Evidence: `/tmp/ns-audit/gui-science-review/w2-19-tile-zoom.png` (tiles),
`/tmp/ns-audit/gui-science-review/w2-17-frames.png` (grid), DB query above.

### SCI-39 — P1 — With no observing location set, the daylight gate silently uses Null Island (0°, 0°) and refuses every light frame of the run — quoting a Sun altitude the app elsewhere says it cannot know
Repro: fresh profile ▸ **Skip onboarding** (so the observing site is never entered) ▸
connect Simulated Camera + Mount ▸ **Sequencer ▸ Builder** ▸ double-click **Take Exposures**
▸ **Start** ▸ **Start Anyway** ▸ let the mount auto-unpark.
Expected: either the run proceeds, or it is refused *for the reason that actually applies* —
"no observing location set, so I cannot tell whether the Sun is up".
Actual: the run fails at the first exposure with
**"Exposure: Daylight gate: refusing light-frame exposure — Sun altitude 69.6° is above the
maximum -12.0° for on-sky light imaging."** That altitude is computed for **latitude 0,
longitude 0** — the startup log records `Loading observer location from settings: lat=0,
lon=0, elev=0`, and 69.6° matches the Sun's true altitude at 0°/0° for that UTC minute
(13:02 UTC, δ☉ ≈ +14.4° → 68.9°). Meanwhile three other surfaces state the app has **no**
location: Equipment ▸ Ready-to-image says *"No observing location set"*, the Dashboard says
*"Set an observing location for twilight times"*, and the run's own pre-flight prints
*"Simulation — Set observer latitude and longitude to simulate target visibility"* as a
low-priority info chip.
Why it costs a night: the gate keys off UTC alone, so a user who skips the optional location
step is judged against Greenwich. In Australia or East Asia, local astronomical night is
Greenwich **midday** — every light frame of the night is refused, with a message that blames
the Sun rather than the missing setting. Pre-flight had just declared the same run
**"Ready with Warnings"**.
Evidence: `/tmp/ns-audit/gui-science-review/w2-26-session-report.png` (Errors section),
`/tmp/ns-audit/gui-science-review/w2-22-preflight.png` (pre-flight verdict),
`/tmp/ns-audit/gui-science-review/app.log`.

### SCI-40 — P2 — Pre-flight demands dark frames at −10 °C for a camera that has no cooler and is sitting at +20 °C
Repro: as SCI-39, up to the **Pre-Flight Validation** dialog ▸ read **Missing Dark Frames**.
Expected: the required dark library entry to match the temperature the lights will actually
be taken at (the sim camera is uncooled and reports 20.0 °C everywhere in the app).
Actual: **"No matching darks found for 1 exposure combination: gain=100, offset=50,
temp=-10.0C, duration=3s, binning=1x1"**, with the remedy *"Capture darks for the missing
combinations."* Every frame this rig produces is recorded at **20.0 °C** — the status bar,
the frame detail dialog (*Sensor temperature 20.0 °C*), and
`select distinct sensor_temp from captured_images` (→ `20.0`) all agree. Darks captured to
satisfy this warning would be at a temperature the camera can never reach, so they would
never match a light frame: the pre-flight sends the user to spend an hour producing
calibration data that is guaranteed to be useless. The duration in the string tracks the
node correctly (it changed 60s → 3s when the node changed), so it is specifically the
temperature that is taken from a default rather than from the camera.
Evidence: `/tmp/ns-audit/gui-science-review/w2-22-preflight.png` and the tree text above.

### SCI-41 — P3 — Session Review's only call-to-action, "Integrate now", is inert on a session it just said has nothing to integrate
Repro: after the failed run above ▸ **Session Report ▸ Review & Integrate** ▸ click
**Integrate now**.
Expected: the button absent, or clearly disabled with the reason attached, or a response.
Actual: the empty state reads *"No finished master yet — This session captured no light
frames, so there is nothing to integrate"* and then renders **Integrate now** as the panel's
focal control. Clicking it produces no visible change, no toast, no progress, no error, and
the accessibility tree lists it as `button: Integrate now` with **no** `[DISABLED]` state —
unlike the sibling nodes on the same screen, which do carry it (`panel: Narrative
[DISABLED]`, `panel: Workbench [DISABLED]`). The screen's primary action is a no-op that
neither the pixels nor the tree admit is unavailable.
Evidence: `/tmp/ns-audit/gui-science-review/w2-27-review.png`.

### SCI-42 — P3 — The Session Report prints the same warning twice, once as a Warning and again as a Diagnostic
Repro: as SCI-39 ▸ read the **Session Report** dialog top to bottom.
Expected: each finding stated once.
Actual: *"No focuser is connected, so automatic refocus is disabled for this run
(HFR-degradation, temperature-shift, focus-drift and interval refocus triggers are all
inert). Focus will not be corrected automatically."* appears **verbatim twice** in the same
dialog — once under **Warnings**, once under **Diagnostics ▸ Noticed but Did Not Fire**.
Evidence: tree of the Session Report;
`/tmp/ns-audit/gui-science-review/w2-26-session-report.png`.

### SCI-43 — P3 — Empty states send the user to screens that do not exist under those names
Repro (two instances):
1. **Sequencer ▸ Quick-Start Wizard ▸ Step 1** ▸ type anything in **Target Name** →
   *"Your target library is empty, so there is nothing to search. Save targets from **Sky**
   or **Planner**, or enter RA/Dec below."*
2. **Sequencer ▸ Start ▸ Pre-Flight ▸ Missing Dark Frames** → *"Open **Calibration → Dark
   Library** to schedule them."*
Expected: the names the navigation actually uses.
Actual: the primary navigation contains Dashboard, Equipment, Imaging, Sequencer, Guiding,
Weather, **Plan Tonight**, Analytics. There is no "Sky", no "Planner" and no "Calibration"
entry, so all three instructions name a destination the user cannot find. This is the same
class as wave 1's SCI-15 ("Science > Grade frames") and SCI-30, on two further screens.
Evidence: `/tmp/ns-audit/gui-science-review/w2-21-wizard.png`,
`/tmp/ns-audit/gui-science-review/w2-22-preflight.png`, nav rail in any screenshot.

### SCI-38 — P3 — The frame detail dialog grades a frame "Good" and then gives a fault as the only reason
Repro: **Analytics ▸ Session ▸ Captured Images** ▸ click any tile.
Expected: "Good" with a supporting reason, or a "Needs review" grade if the star count is
genuinely low.
Actual: the summary line under the preview reads **"Good — Low star count (39)"** on every
frame of a clean session, and the grid simultaneously counts all 32 as `Good: 32,
Needs Review: 0`. The dash-clause reads as the *reason for the grade*, so the app's own
explanation contradicts its verdict.
Evidence: `/tmp/ns-audit/gui-science-review/w2-18-frame-detail.png`.

### SCI-46 — P2 — "Session" means three different things inside Analytics, and the only session that holds frames is invisible to two of them
Repro: capture the 32-frame quick-capture session, then run the (failing) sequence above, so
the profile holds exactly two things the app calls a session. Then visit, in order:
1. **Analytics ▸ Session** → shows **Quick Capture · 32 exposures · 1m 4s**, i.e. the quick
   capture *is* a session, with a full session summary and four charts.
2. **Analytics ▸ History** → lists only **New Sequence — FAILED — 0 frames**. The 32-frame
   session does not exist here.
3. **Analytics ▸ Diagnostics ▸ Select session** → the dropdown offers exactly one entry,
   **New Sequence (Aug 13, 09:02)** — the run that captured nothing. Selecting it correctly
   reports "Not measured … no PSF field tiles for this session".
Expected: one definition of "session", or labels that distinguish them.
Actual: the only frames the app owns (32 lights, HFR/temperature/star data on every one)
cannot be reached from either History or Diagnostics, while a run with **zero** frames is the
sole diagnosable session on offer. Optical diagnostics is therefore unreachable for any user
who images with the manual loop, and History under-reports the night. This is wave 1's
SCI-21 seen from two more screens, and it is the reason Diagnostics looks broken.
Evidence: `/tmp/ns-audit/gui-science-review/w2-16-session-populated.png`,
`/tmp/ns-audit/gui-science-review/w2-30-history.png`,
`/tmp/ns-audit/gui-science-review/w2-36-sess-popup.png`.

### SCI-47 — P3 — Live Stacking's Statistics list mixes frame counts and pixel counts under identically-shaped labels, with no units on either
Repro: **Imaging ▸ Stack ▸ Start** ▸ pick a FITS ▸ **Loop** ▸ let ~36 frames stack ▸ read the
**Statistics** list.
Expected: units, or a visual break between "how many frames" and "how many pixels".
Actual: nine rows in one list read
`Stacked Frames 36` · `Total Attempted 36` · `Rejected (Alignment) 0` ·
`Avg Matched Pairs 39.0` · `Avg Alignment Residual 0.52 px` ·
`Sigma-Rejected (Total) 7.3M` · `Sigma-Rejected (Last Frame) 271.8K` ·
`Rejection Rate (Last Frame) 13.11%` · `Alignment Quality Excellent`.
"Rejected (Alignment): 0" counts **frames**; "Sigma-Rejected (Total): 7.3M" counts
**pixels** (36 × 1920 × 1080 = 74.6 M samples; 7.3 M ≈ 10 %, and 271.8 K / 2.07 M = 13.1 %,
matching the rate row). Nothing on screen says so, so the natural reading of a list headed
"Stacked Frames 36" is that 7.3 million frames were thrown away. Only "Avg Alignment
Residual" carries a unit.
Evidence: `/tmp/ns-audit/gui-science-review/w2-34-preview.png`.

### SCI-48 — P3 — Plate solving leaves its scratch files in the user's capture folder
Repro: set a capture folder ▸ capture light frames ▸ let the automatic plate solver run ▸
`ls` the capture folder.
Expected: the capture folder holds the user's images.
Actual: after 67 frames the folder holds **44 stray `astap` `.ini` files** — one per solve
attempt, named after the frame (`Unknown_NoFilter_2026-08-13_0001.ini`), each containing
`PLTSOLVD=F` and the full solver command line including absolute local paths. They are never
cleaned up and never surfaced in the UI, so the user's night's data directory fills with
solver debris they did not ask for and cannot explain.
Evidence: `ls /tmp/ns-audit/gui-science-review/data/captures | sed -E 's/.*\.//' | sort | uniq -c`
→ `67 fits · 44 ini · 67 jpg`.

---

## Wave 1 findings re-tested against today's build

Tested deliberately, on the same screens, with the populated state described above.

**Still reproduce (unchanged):**

| ID | What still happens |
|----|--------------------|
| SCI-7 | **Stack ▸ Start** still opens a bare GTK **"Open File"** chooser with no explanation, while the panel's Status row still reads `Idle` and the button reads `Starting…` at the same moment. |
| SCI-8 | `Alignment Quality: Excellent` (green, full bar) renders directly beneath the amber `Elevated sigma rejection on last frame — Above 5% rejected`. |
| SCI-9 | The nine-row Statistics list still uses four placeholders for "nothing": `0`, `—`, `--`, `No data`. |
| SCI-10 | ASCII double hyphen still shipped: *"Above 5% rejected **--** seeing, dithering, or alignment may be off."* |
| SCI-12 | Quick Capture still shows `DURATION —` beside `EXPOSURES 32` and `INTEGRATION 1m 4s`. |
| SCI-15 | Captured Images still says *"Science > Grade frames is what rejects frames"*; no such place exists (see SCI-43 for two more instances). |
| SCI-17 | Pre-flight still returns **"Ready with Warnings"** for a run the daylight gate then refuses outright (now quantified as SCI-39). |
| SCI-21 | History still denies the session Analytics ▸ Session is displaying (now generalised as SCI-46). |
| SCI-22 | Science still says *"most science products will stay empty until a solver is reachable"* while the log shows ASTAP 2026.07.16 launching per frame and exiting 1 — the solver is reachable and failing. |
| SCI-23 | The Science header chip still truncates to **"Plate solve…"**. |
| SCI-24 | `24 more queued` still cannot be reconciled with `0 of 32 solved` on the same card. |
| SCI-25 | The science guide still renders step 2 as complete (its number replaced) while step 1 is not. |
| SCI-27 | **Stacked Preview** still renders as a solid black rectangle after 36 successfully aligned frames, while the same frames render a star field in the viewer alongside it. |
| SCI-28 | **Stop** still destroys the stack with no confirmation: 36 stacked frames → `0`, every statistic reset, `Alignment Quality: No data`, and **nothing written to disk** (`find` over the profile shows no stack/master output at any point). |
| SCI-31 | The Narrator still declares *"Best seeing of the night — FWHM…"* minutes into a session — and the toast truncates its own sentence mid-word. |

**Improved since wave 1 — do not re-file:**

- **SCI-13** is fixed: a clean 32-frame session now badges `Good: 32 · Needs Review: 0`,
  where wave 1 saw every frame badged NEEDS REVIEW.
- **SCI-16** is partly fixed: the Session Report for a failed run now prints the executor's
  actual reason under **Errors** (the daylight-gate sentence). The all-zero stat tiles
  wave 1 objected to remain, but they are now accurate — the run really did capture nothing.
- **SCI-20 is stale — treat as a false positive against this build.** With a session present,
  Analytics ▸ Diagnostics shows a working **Select session** dropdown: it opens, lists the
  run, and selecting it renders an honest "Not measured / no PSF field tiles" state. The
  a11y tree still marks it `[DISABLED]` (that part is real, and is folded into SCI-36); the
  control itself is not. The remaining Diagnostics problem is *which* sessions it offers —
  SCI-46.

---

## Coverage

**Screens driven in this wave**

- Analytics ▸ Session — empty **and** populated (32 frames), including Captured Images grid,
  filter chips, and the per-frame detail dialog.
- Analytics ▸ History — empty and with one run; filter menus opened and exercised.
- Analytics ▸ Projects — empty; drilled into **Mosaic projects** and back.
- Analytics ▸ Equipment Stats — empty and populated; cross-checked against Session.
- Analytics ▸ Science — empty and populated (plate-solve health, night story, science guide,
  photometry/field-quality/anomaly cards).
- Analytics ▸ Science ▸ First Light — empty (filter chips read).
- Analytics ▸ Diagnostics — empty, with sessions present, and with a session selected;
  "Reading optical diagnostics" help dialog opened.
- Session Report dialog — for a failed run (all sections, Journal/Diagnostics/Notes).
- Session Review (**Review & Integrate**) — both tabs, Narrative and Workbench.
- Stack Result / Live Stacking — Idle, Starting, Stacking (36 frames), preview, and Stop.
- Supporting screens touched only to reach the above: onboarding step 1, Dashboard,
  Equipment (discovery + connect), Imaging (capture loop, save path), Sequencer builder,
  Quick-Start Wizard step 1, Pre-Flight Validation.

**Not reached**

- **Analytics ▸ Science ▸ Observing Alerts** — reachable, but left to wave 1, which already
  covered its empty state and settings dialog in detail (SCI-3/4/5/29/30).
- **A populated Stack Result after a *successful* sequence run** — blocked by SCI-39: with no
  observing location the daylight gate refuses every light frame, so no sequencer run in this
  environment can produce accepted frames. Quick-capture frames were used instead, which
  covers the stacking path but not "master integrated from a completed run".
- **Session Review of a *successful* run** — blocked by the same cause.
- **Analytics ▸ Projects with data**, and the Mosaic project editor — needs a saved target
  library, which the wizard could not create (empty target library, see SCI-43).

