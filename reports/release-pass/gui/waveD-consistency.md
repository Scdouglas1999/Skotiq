# Wave D verification — cluster: consistency

Adversarial re-drive of the **fresh** release bundle
(`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`, built 18:31, i.e. after the last
fix commit at 18:28) on `SK_AUDIT_DISPLAY=:88`, profile `waveD-consistency`, `start --fresh`
(first-run onboarding). Read-only: no app code, no test, no report other than this file was changed.

Bundle freshness was proved before driving, not assumed: `strings lib/libapp.so` contains
`Close window` (added by the title-bar semantics commit) and no longer contains `Paused-stopped`
(the raw enum label CON-51 reported), so the binary under test carries this branch's fixes.

Scope: verify CON-44 … CON-63 from `reports/release-pass/gui/consistency.md` (wave 2), sample the
AccessibleDropdown semantics on three screens, sweep for regressions the fixes may have introduced,
and record whether the app itself writes into `assets/screenshots/` or `docs/design/goldens/`.

## Verdict

| Verdict | IDs |
| --- | --- |
| VERIFIED_FIXED (3) | CON-44, CON-47, CON-60 |
| STILL_BROKEN (17) | CON-45, CON-46, CON-48, CON-49, CON-50, CON-51, CON-52, CON-53, CON-54, CON-55, CON-56, CON-57, CON-58, CON-59, CON-61, CON-62, CON-63 |

Two of the seventeen are *partly* repaired and are recorded as still broken because the finding's
own expectation is not met: CON-51 (the raw enum name is gone, the four-words-for-one-outcome
vocabulary is not) and CON-61 (the dead account icon now acts, the accessibility half has not
moved at all).

The wave-2 fixes that did land are the structural ones — the tour nudge now floats, the connection
dialog centres and has a button, and the two `[DISABLED]`-panel sites named in CON-47 are now real
enabled buttons. Almost everything that was a *copy* or *design-language* finding is untouched.

## Verified fixed

### CON-44 (P2) — tour nudge in flow → **VERIFIED_FIXED**
Repro run verbatim: `start --fresh` → skip onboarding → Sequencer, nudge still up.
The three-panel workspace now runs the full height of the content area (palette bottom at window
y≈1010 of 1050; wave 2 measured y≈865 with a 147px black band) and the "Sequencer Tour" card floats
over the canvas. Settings half also re-checked with the "Settings Tour" nudge up: the sidebar shows
GENERAL … **ADVANCED**, ADVANCED fully on screen at y≈770, no dismissal required.
Evidence: `/tmp/ns-audit/waveD-consistency/09-sequencer.png`, `04-settings.png`.

### CON-47 (P3) — live control published as a disabled panel → **VERIFIED_FIXED at both reported sites**
Analytics → Diagnostics now reports `button: Learn more about optical diagnostics` (was
`panel: … [DISABLED]`). Settings → Appearance → Theme, opened: the tree exposes
`panel: Popup menu` → `button: Dark`, `button: Light`, `button: Red night`, none flagged
`[DISABLED]` (was all three `[DISABLED]`). The whole page no longer collapses out of the tree
either — wave-1 CON-39's core complaint.
Caveat carried into a new finding below: the *class* of defect survives elsewhere (NEW-C2), and no
option is marked as the selected one (NEW-C4).

### CON-60 (P2) — Connection Status dialog clipped by the window bottom → **VERIFIED_FIXED**
Clicked the crossed-eye title-bar icon at 1600x900. The dialog is centred (card spans y≈354-539 of
900, x≈570-1029), has a visible **Close** button, and the tree reports
`button: Connection Status / Not connected to a server / Close`. Escape still closes it.
Evidence: `/tmp/ns-audit/waveD-consistency/03-conn-dialog.png`.

## Still broken

### CON-45 (P3) — four empty-state patterns in one screen → **STILL_BROKEN** (improved)
Fixed: Session no longer duplicates History byte-for-byte and no longer describes *history* — it now
reads "Nothing captured yet / Start a capture or a sequence and this tab fills in as the frames
arrive."
Not fixed: the tabs still disagree on structure and punctuation. Session (centred, full stop) /
History ("No session history" / "Complete an imaging session to see history here" — no stops, and
now *different* copy from Session rather than identical) / Projects (left-aligned, two full stops,
no icon) / Equipment Stats (no empty state at all) / Diagnostics (star glyph, "Select an imaging
session to analyze"). Still none of the five offers an action.
Evidence: trees for all five tabs; `08-analytics.png`.

### CON-46 (P3) — "0" vs "No data" in one card grid → **STILL_BROKEN**
Analytics → Equipment Stats, fresh profile, tree verbatim: Total Exposures `0`, Meridian Flips `0`,
Autofocus Runs `0`, Avg RMS `No data`, **Accepted Integration `No data`**, Avg HFR Achieved
`No data`, Avg Temperature `No data`. Two tokens on no visible rule, and the one **sum** in the grid
is still in the "No data" half.

### CON-48 (P3) — one tab with an H1 and a 90-word paragraph → **STILL_BROKEN**
Analytics → Diagnostics still renders `Optical Train Diagnostics`, the right-aligned
"No sessions available", and the paragraph — now ~95 words, verbatim from
"Optical-train mechanical health — collimation, tilt…" to "Lower tilt and collimation scores are
better." Its four sibling tabs still have neither a page title nor a paragraph.

### CON-49 (P4) — dead "Back" on onboarding step 1 → **STILL_BROKEN**
`start --fresh`, `click-img 01-welcome.png 256 688`: nothing happens, `tree` still reports
`panel: Step 1 of 13`. The tree still reports a plain `button: Back` with **no `[DISABLED]`** —
and the harness does print `[DISABLED]` for this build (it printed it on six other nodes this
session), so this is the app's claim, not a harness gap. Measured label brightness is also
unchanged in kind: the "Back" glyph peaks at luminance 0.64 against "Next" at 0.65, i.e. it is not
rendered in a disabled treatment.

### CON-50 (P3) — a field drawn inside a field, inner one clipped → **STILL_BROKEN**
Sequencer → Templates, `shot --region 340x80+740+250` then a 2x crop: an outer rounded container
holds the magnifier, and a **second bordered rounded rectangle** (the field) sits inside it with its
bottom border cut off by the container edge. Only the placeholder changed ("Search..." now).
Evidence: `10-search-field.png`, `10-search-zoom.png`.

### CON-51 (P3) — leaked run-state machine → **STILL_BROKEN** (partly repaired)
Fixed: `Paused-stopped` is gone from the UI and from the binary; the chip now reads
**"Stopped (resumable)"**.
Not fixed: Sequencer → History still ships seven chips of which **five** are outcomes of "did not
finish" — Failed, Aborted, Stopped, Stopped (resumable), Interrupted — with nothing on screen
saying how they differ, and all of them are live `button:` nodes (no `[DISABLED]`) on a screen whose
own empty state says "No runs yet".

### CON-52 (P3) — three header/punctuation rules across four tabs → **STILL_BROKEN**
Verbatim, this build: Builder — no header. Templates — "Sequence Templates" / "Start with a template
or save your sequences for reuse" (no stop). Sequences — "Sequence Library" / "Browse and load your
saved imaging sequences" (no stop). History — "Execution History" / "Past sequence runs with
statistics and performance data." (stop). Empty states diverge exactly as reported, including the
`Tip: Use "Save Current" to save your sequence` line with straight quotes.

### CON-53 (P2) — Plan Tonight tells you to use Plan Tonight → **STILL_BROKEN**
Plan Tonight → Schedule, Unattended Autopilot card, tree verbatim: "Runs hands-off and re-picks the
best target all night as the sky changes. **For a plan you can see and edit before it runs, use Plan
Tonight instead.**" Unchanged.

### CON-54 (P3) — scheduler internals on screen → **STILL_BROKEN**
Same card, unchanged: title "Unattended Autopilot", body "Autopilot is stopped. Run unattended all
night to begin evaluating targets every 60s.", **"No tick scheduled."**, button "Run unattended all
night", and the comma-joined "Cannot start unattended until: Camera and mount, Observing location,
Capture output path, Disk space." The "Reasoning" box still holds "No candidate targets available".

### CON-55 (P3) — same control, button on one tab and panel on the next → **STILL_BROKEN**
Plan Tonight → Recommendation: `button: Open Settings`. Plan Tonight → Framing:
`panel: Open Settings` — not a button, not focusable. The copy split is unchanged too:
"Location not configured" / "…in Settings" against "No Equipment Profile" / "…in Settings →
Equipment", with "No projects yet" as a third register on the Projects tab.

### CON-56 (P4) — the only two ALL-CAPS buttons in the app → **STILL_BROKEN**
Plan Tonight → Planetarium still exposes `button: NOW` and `button: TONIGHT`, and the HUD still
reads `Bortle: 5 (lim 5.9m)`.

### CON-57 (P3) — three incompatible copy registers → **STILL_BROKEN**
Unchanged, all four strings verified live: Discover → Your Sky "Every photon you capture becomes a
brick in your growing all-sky atlas." + "Your sky is dark — for now"; Sequencer → History "Past
sequence runs with statistics and performance data."; Analytics → Diagnostics the PSF-aberration
paragraph.

### CON-58 (P3) — two contradictory "Projects" screens → **STILL_BROKEN**
Analytics → Projects: "No targets available for project tracking yet." / "Add targets and capture
images to track multi-night progress." — no action (a "Mosaic projects" button is present but is a
different destination). Plan Tonight → Projects: "No projects yet" / "Create a multi-night project
to track targets and integration goals across clear nights." + `button: New Project`. The two still
give opposite instructions for creating a project.

### CON-59 (P4) — five duration formats in one card grid → **STILL_BROKEN**
Sequencer → Templates → Starters, verbatim: "~1 hr 15 min", "~3 min capture", "~3 hr 30 min",
"~10 min capture". The trailing "capture" still appears on two of the six.

### CON-61 (P2) — title bar absent from a11y; one icon dead → **STILL_BROKEN** (half repaired)
Fixed half: the person icon now does something — `click-img 1124 15` opens **Settings → Equipment
Profiles** (tree confirms the Settings surface and its 12 groups).
Not fixed half, and this is the P2: `tree --all` on the Dashboard returns **68 nodes** and
`grep -iE "equipment|sequencer|guiding|weather|analytics|collapse|settings|notification|account|
minimi|close|connection"` matches only the dashboard's own "Connect equipment" button. Neither the
four title-bar icons nor the three window controls nor the nine nav-rail destinations are in the
tree — not even their label text ("Overview & status", "Connect devices" … do not appear).
This is not harness blindness: clicking the bell opens a popup that the very same dump reports as
`panel: Popup menu` → `button: Transient Alerts / No active alerts / View all alerts`, i.e. the
app's semantics do reach AT-SPI — the control that opens it still does not. Note for whoever fixes
this: `title_bar.dart` does now wrap its buttons in `Semantics(button: true, label: tooltip)` and
that string ships in the bundle, so the fix is present in source and absent at runtime;
`side_navigation.dart` contains no `Semantics` at all, so the nav rail was never addressed.

### CON-62 (P3) — three button treatments and two capitalisations in one Settings list → **STILL_BROKEN**
Settings → Help & Tutorials, unchanged: rows "First Night Walkthrough" (Start), "Capture your first
light" (Start), "Re-run equipment setup" (Re-run), "Re-run onboarding tour" (Re-run), "Generate
Diagnostic Dump" (Open) — Title Case and sentence case in one five-row list, three verbs for one
action, filled-blue against dark-outlined treatments in the same column, plus the pale "Start"
buttons on the Tutorial Tours list below.
Evidence: `06-help-flows.png`.
(Improvement worth recording: the Tutorial Tours rows now announce state —
`button: Equipment Setup tutorial, Not started`.)

### CON-63 (P4) — crossed-out eye for "not connected to a server" → **STILL_BROKEN**
The leftmost title-bar glyph is still an eye with a slash, still drawn with a filled "selected"
background unlike its three neighbours, and still opens "Connection Status — Not connected to a
server".
Evidence: `icons-zoom.png` (2x crop of the icon row).

## AccessibleDropdown semantics — three sampled screens

| Screen | Closed control | Open menu |
| --- | --- | --- |
| Settings → Appearance | `button: Theme / Dark, Light, or Red night — … / Dark`; same shape for Font size and UI scale | `panel: Popup menu` → `button: Dark`, `button: Light`, `button: Red night`, all enabled |
| Imaging → Exposure Settings | `button: Light` and `button: 1x1` — **value only**; the label and the hint are separate sibling `panel:` nodes | six enabled option buttons |
| Sequencer → Sequences (sort) | `panel: Last Modified [DISABLED]` — **not a button, marked disabled** | opens `button: Last Modified / Date Created / Name / Node Count` — so it is fully interactive |

So the sweep is real but uneven: one screen is exemplary, one announces no label, and one is still
the exact defect CON-47 described. Details as new findings below.

## New findings (adversarial sweep)

### NEW-C1 (P3) — the Sequencer palette tab strip clips its outer labels at 1000px
`resize 1000 900` → Sequencer → Builder. The palette tab row renders **"\odes"** (the "N" cut off
its left edge) and **"Queu"** (the "e" cut off behind the collapse button); only the middle tab,
"Snippets", is whole. At 1600x900 all three fit. Repro is a plain window resize; nothing else on the
screen misbehaves at that width.
Evidence: `16-seq-narrow.png`, `16-tabs-zoom.png` (2x crop).

### NEW-C2 (P3) — interactive controls still published as `panel … [DISABLED]` outside CON-47's two sites
The `[DISABLED]`-panel class was fixed only where wave 2 pointed. Live instances in this build, each
proved interactive by clicking it:
- Sequencer → Sequences sort: `panel: Last Modified [DISABLED]` → opens a four-option menu.
- Sequencer → Builder palette tabs: `panel: Nodes / Tab 1 of 3 [DISABLED]`,
  `panel: Snippets / Tab 2 of 3 [DISABLED]`, `panel: Queue / Tab 3 of 3 [DISABLED]` — clicking
  "Snippets" switches the palette (tree then shows the Snippets content), so all three are live.
- Plan Tonight → Planetarium: `panel: Search / Ctrl+K [DISABLED]` and `panel: Aug 13, 2026 [DISABLED]`.
- Imaging: `panel: Overlays [DISABLED]` (the overlay menu) and `panel: G100 [DISABLED]` (the gain
  control in the capture bar).
A keyboard or screen-reader user is told each of these is unavailable; a mouse user finds them all
working.

### NEW-C3 (P3) — the same dropdown component announces a label on one screen and only a value on another
Settings → Appearance exposes `button: Theme / <hint> / Dark`. Imaging exposes `button: Light` and
`button: 1x1` with the words "Frame Type" and "Binning" living in adjacent, unassociated `panel:`
nodes. Focusing the Imaging control announces "Light, button" with nothing saying what is Light.
Same widget family, two levels of wiring.

### NEW-C4 (P4) — no dropdown menu marks its current option
Opened Theme (Settings), Frame Type (Imaging) and the Sequences sort menu. Every option is a bare
`button:` with no `[ON]`/selected/checked state, although each menu has a current value the closed
control displays. Wave-1 CON-39 asked for "menu items exposed as selectable nodes **with the current
one marked**" — the first half landed, the second did not.

### NEW-C5 (P4, low confidence) — Analytics → History filter chips are now live over zero rows
`button: All Time` and `button: All Targets` carry no `[DISABLED]` on a tab whose empty state is
"No session history". Wave 2 recorded these two chips as correctly disabled and used them as the
good example against Sequencer → History. Flagged low-confidence because the harness's `[DISABLED]`
rule itself changed between the two passes (commit 80bf6c3), so this may be a reporting difference
rather than a behaviour change; a visual check of the chips would settle it.

## Cross-checks recorded while driving (other clusters' IDs, not verified as my assignment)

- Wave-1 **CON-30** looks fixed: a fresh profile's Weather screen shows no red "Weather Critical"
  banner; it shows a "Location Not Configured" gate plus "Safety Status — Not monitoring — weather
  safety is off, conditions are not being checked". Consequently wave-1 CON-31 (the banner that
  shifts the nav rail) could not be raised at all this pass and remains unverified.
- Wave-1 **CON-23** truncation persists at 1600x900: Imaging's session actions still render
  "View Quic…" and "Clear Sess…", and the eighth tab still renders "Annotatio…" (the tree now
  exposes the full names, so this is visual only).
- Wave-1 **CON-28** persists: the node palette's bottom card ("Photometry Run (template)") is still
  sliced by the floating "Drag nodes or double-click to add" hint bar, and palette descriptions are
  still ellipsised.
- Wave-1 **CON-25** persists: capture bar "Dur 2 s" against Exposure Settings "Exposure 2.0 sec".
- Wave-1 **CON-14** is the nav-rail half of CON-61 above and is untouched.

## Test-asset writer hunt

Baseline and post-session listings of `assets/screenshots/` (13 files) and `docs/design/goldens/`
(22 files) with mtimes are byte-identical (`diff` clean), and `git status --porcelain` shows only
another agent's `reports/release-pass/RELEASE-PASS-2026-08-11.md`. **The running app wrote nothing
into either directory during this session** — its writes stayed under
`/tmp/ns-audit/waveD-consistency/data`. The only repo files touched in the window were
`.dart_tool/`, `build/` and `native/target/` artefacts belonging to other agents' concurrent test
runs, not to the GUI process.

## Harness notes for the next verifier

- `--profile` after the subcommand, as before. The fish `for x in "a b"; set -- $x` splitting trap
  from wave 2 is still real — I lost one round of tab clicks to it; drive one action per invocation.
- **`resize` moves the window to +0+0.** Every `click-img` mapping captured before a resize is then
  wrong by the old offset (+160+150 here) and clicks land on the wrong control while still printing
  "clicked X,Y". Re-`shot` after every resize. `resize --show` prints the current geometry.
- `[DISABLED]` reporting is trustworthy in this build in the sense that it is the app's own claim:
  it appeared on eight nodes and was absent on the theme-menu options that wave 2 saw it on.
- The a11y tree omits the title bar and the nav rail entirely, so navigation must be driven by
  `click-img` off a fresh screenshot.
