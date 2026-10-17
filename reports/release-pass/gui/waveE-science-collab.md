# Wave E dryness check — cluster: science-collab

**Date:** 2026-08-13 (late evening). **Harness:** `tools/ui_audit/drive_linux.py`, display `:86`,
profile `waveE-science-collab` (`--profile` after the subcommand).
**Binary:** `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop` with
`lib/libapp.so` and `lib/libskotiq_bridge.so` both timestamped **20:33**, i.e. built
*after* the D-fix commit `baddf35fd` (20:30:48). Freshness cross-checked by string-grep:
`Quick captures (no session)` and `Optical Train Diagnostics` are both present in
`libapp.so`, so the D-fix Dart is in the binary under test.

**State built for the repros:** Skip onboarding ▸ Equipment ▸ *I'll do it manually* ▸
Discovery ▸ Expand ▸ Connect **Simulated Camera** + **Simulated Mount** ▸ Settings ▸
Location (lat 40, lon +40 — put the site in darkness so the daylight gate would not refuse
the run) ▸ Files & Storage ▸ Image output = `/tmp/ns-audit/waveE-science-collab/data/captures`
▸ Imaging ▸ Save on ▸ **Loop** 2 s → **12 standalone light frames** ▸ Sequencer ▸ Builder ▸
Take Exposures 3 s × 4 ▸ Start ▸ Start Anyway → a **completed** run, 4/4 frames. Two mosaic
projects created through the wizard. Screenshots and tree dumps in
`/tmp/ns-audit/waveE-science-collab/` (`01`–`79`).

---

## Verdicts on assigned items

| ID | Verdict | Evidence |
|----|---------|----------|
| WD-SCI-N1 | **VERIFIED_FIXED** | With 12 quick captures **and** a completed run present, **Analytics ▸ Session** shows `Reviewing / Quick captures (no session selected)` and its menu lists **both** `button: Quick captures (no session)` and `button: New Sequence · Aug 13, 2026 20:53 · 4 frames`. Selecting the run switches the tab to it (`MEDIAN HFR 5.70`, 4 exposures); re-opening the menu still offers Quick captures; selecting it returns the Quick Capture panel (12 exposures, 24 s, median HFR 2.14). Survives navigating to History and back. **Analytics ▸ Science** ("Analysing") behaves identically, and selecting Quick captures there renders the real products (Differential Photometry, `Grade 12 frames`, Anomalies). Diagnostics offers the same entry with the same label, so the three pickers agree. |
| WD-SCI-N2 | **VERIFIED_FIXED** | Analytics ▸ Science ▸ quick captures ▸ `tree`: `button: Photometry`, `button: Field Quality`, `button: Anomalies` — button role, no `[DISABLED]`. Previously `panel: … [DISABLED]`. |
| WD-SCI-N3 | **STILL_BROKEN** (recorded blocked by D-fix) | Sequencer ▸ Start with 3 warnings: siblings are `button: Re-check` and `button: Cancel`, while the green primary prints as **`panel: Start Anyway`** — no role, no state. Clicking it does start the run, so this is announcement-only. Unchanged from Wave D. |
| WD-SCI-N4 | **STILL_BROKEN** (recorded blocked by D-fix) | `resize 900 760` ▸ Analytics: the right chevron paints **on top of** the Science tab, which renders `S › ce` (`52-narrow.png`, 4× crop `56-chev.png`). After clicking it, the left chevron paints over History (`Hi ‹ y`) and the right one clips Diagnostics (`Diagnostic ›`) — `58-tabs.png`. Not reproducible at 1600×900. |
| WD-SCI-N5 | **VERIFIED_FIXED** (disclosure only — see NEW-E5) | Session Report ▸ Review & Integrate ▸ Narrative: under the 100/100 verdict there is now a warning row reading *"The verdict above found no session-level problem, but the frame grader marks all 4 subs POOR (median HFR 5.7). Open Workbench before treating this night as clean."* (`45-narrative.png`). The claim is **true**: Analytics ▸ Session with the run selected reports `Good: 0 · Needs Review: 0 · Poor: 4 · Total: 4`, and the DB gives `hfr` 5.69–5.74 / `quality_score` 35.3–35.4 for `captured_images` 13–16 against 2.19–2.22 / 84 for the quick captures. |
| WD-COL-N1 | **VERIFIED_FIXED** | Ran the repro twice. First project: list read "No mosaic projects yet" before, and after Create ▸ Back the row **Mosaic 0.00h 0.0° · 3 wide × 3 high · 9 panels · Planning** is there. Second project created the same way: after Back the list holds **two** `button: Mosaic 0.00h 0.0°` rows — the exact case Wave D recorded as failing. |
| WD-COL-N2 | **STILL_BROKEN** (recorded blocked by D-fix) | With "Panel size unknown" in force, `tree` reports plain `button: Create mosaic project` and `button: Load into Sequencer`, no `[DISABLED]`; clicking each leaves the dialog open and changes nothing (`Mosaic Wizard` still present in the tree after both). Neither is visually dimmed (`24-wizard.png`). |
| WD-COL-N3 | **STILL_BROKEN** (recorded blocked by D-fix) | Fresh wizard ▸ Advanced (numerical) ▸ click Panel width, type `50` ▸ click Panel height, type `35`. Height reads **40.0** (`27-fields-crop.png`) and Plan summary reads `Panel size: 0.83° × 0.67°` = 50 × 40. Reproduced a second time with width `30` → height auto-filled 40.0, summary `0.50° × 0.67°`. |
| WD-COL-N4 | **STILL_BROKEN** (recorded blocked by D-fix) | `resize 900 760`: status bar renders "Simulated Cam" **cut mid-word** with the thermometer glyph painted straight against it and no separator; the Mount / Guider / Focus items vanish with no overflow affordance (`55-sb.png`). At 1600×900 the same bar reads Camera / Mount / Guider / Focus in full. |
| COL2-3 | **STILL_BROKEN** (D-fix recorded it out of scope — confirmed) | Settings ▸ Imaging ▸ Catalogs ▸ Deep-Star Tier: "Tileset base URL" empty, `button: Download` with **no** `[DISABLED]` (the harness does print `[DISABLED]` in this session — `2 connected [DISABLED]`, `Advanced (numerical) [DISABLED]`). Clicking it produced no snackbar, no inline error, no field highlight, **no new log line** (`app.log` 75 lines before and after) and no new node in the tree. |
| COL2-13 | **VERIFIED_FIXED** | Switch **off**: the row now reads *"Add bright new transients to your targets automatically. Turn this on to set the cutoff."* — no number asserted. Switch **on**: subtitle becomes *"Automatically adds transients brighter than mag 10.0 to targets"* **and** a dedicated `slider: 10.0` with a `<= 10.0` readout appears beside it, plus *"Alerts fainter than the magnitude threshold (9.5) are filtered out before auto-queue sees them."* (`21-autoqueue-slider.png`). Adversarial drag of Magnitude Threshold to 9.5 makes the warning fire correctly instead of leaving two contradictory numbers. |
| CON-45 | **VERIFIED_FIXED** | Fresh profile, all five tabs, verbatim from `tree`: Session — *Nothing captured yet* / *Start a capture or a sequence and this tab fills in as the frames arrive.* / `button: Go to Imaging`. History — *No session history* / *Complete an imaging session to see history here.* / Go to Imaging. Projects — *No targets available for project tracking yet* / *Add targets and capture images to track multi-night progress.* / Go to Imaging. **Equipment Stats — now has one at all**: *No equipment history yet* / *Capture some frames and this tab reports what your camera, mount and guider actually did.* / Go to Imaging. Diagnostics — *Select an imaging session to analyze* / *Optical diagnostics require plate-solved frames with PSF and residual data.* / Go to Imaging. One icon, title without a stop, one-sentence body with a stop, one action — in all five. The D-fix's own regression guard also holds: with data present, Equipment Stats renders the real grid (`Total Exposures 16`, `Accepted Integration 36s`, `Avg HFR 3.05`) rather than the empty state. |
| CON-48 | **VERIFIED_FIXED** (in the Analytics tab) | Analytics ▸ Diagnostics no longer renders the `Optical Train Diagnostics` H1, and the paragraph is one line: *"Optical-train health across the whole session: collimation, tilt, backfocus and field flatness. Lower scores are better."* (~20 words, was ~95). `button: Learn more about optical diagnostics` still sits beside it. I could not reach the standalone `/diagnostics` shell from the desktop GUI, so the `showTitle: true` half is unverified here. |
| NEW-C2 | **VERIFIED_FIXED inside the scoped directories; STILL_BROKEN outside** | Swept all five Analytics tabs with data and the Science sub-tabs: the only `[DISABLED]` string anywhere in those dumps is the shared status-bar chip (see NEW-E4). Outside the batch: Imaging's `panel: G100 [DISABLED]` is now `button: Exposure settings, gain 100`, but `panel: Overlays [DISABLED]` survives; the Sequencer palette tabs have lost `[DISABLED]` yet are still role-less `panel: Nodes / Tab 1 of 3` etc.; the mosaic wizard still exposes `panel: Advanced (numerical) [DISABLED]`. |
| NEW-C3 | **STILL_BROKEN** (recorded blocked by D-fix) | Imaging ▸ `tree`: `button: Light` and `button: 1x1` with the words in adjacent, unassociated `panel: Frame Type` / `panel: Binning` nodes. Settings ▸ Appearance still exposes the paired form `button: Theme / <hint> / Dark`. |
| NEW-C4 | **VERIFIED_FIXED** for `SkotiqDropdown` | Settings ▸ Appearance ▸ Theme menu: `button: Dark [ON]`, `button: Light [off]`, `button: Red night [off]`. Font size menu: `Small [off]`, `Medium [ON]`, `Large [off]`. Residual: the Analytics session pickers are `PopupMenuButton`s, not this component — they highlight the current row visually (`47-picker.png`) but publish no checked state. |

**Score: 8 verified fixed, 8 still broken** — and 7 of the 8 still-broken are the items the
D-fix itself recorded as blocked/out of scope, reproduced here unchanged. Only NEW-C2 is
split (closed inside the batch's directories, alive outside them).

---

## New findings

### NEW-E1 (P3) — Mosaic project detail: the word "Back" is not part of the Back control, and the control has no role

Repro (deterministic, hit three times): Analytics ▸ Projects ▸ Mosaic projects ▸ open a
project. `tree` reports **`panel: Back`** — no button role, no `[DISABLED]` — whereas the
projects *list* screen one route below reports `button: Back`.
Clicking the **word** "Back" (image x=218 and x=227, y=51) does nothing across two attempts
with a 6 s and a 10 s settle; clicking the **chevron** (x=199) pops immediately.
Source confirms the shape: `packages/skotiq_app/lib/screens/mosaic/mosaic_project_screen.dart`
`_BackBar` is an `IconButton` followed by a bare `Text(label)` in a `Row`.
Why it matters: the label reads as part of the affordance and is the larger target; and a
screen-reader user is not told the only way off this screen is a control.

### NEW-E2 (P2) — The Replay screen swallows nav-rail navigation while the rail claims you moved

Repro: Sequencer ▸ History ▸ the run row's replay icon → **Replay — New Sequence**. Click
**Dashboard** in the left rail, wait 6 s → `header: Replay — New Sequence` still. Click
**Analytics**, wait 6 s → still Replay, but the rail now paints **Analytics** as the selected
destination, accent bar and all (`75-rail.png`). Two clicks on the ✕ at the top right
(image 1262,54) also left the screen up; the ← at the top left did leave — and landed on the
Analytics page the rail had been claiming for the previous minute.
Why it matters: this is the "app states something untrue" shape. The chrome reports a
destination the app has not gone to, and the operator's obvious escape (the ✕) appeared inert.

### NEW-E3 (P4) — Replay says "1 of 2 decisions" and renders one

Same screen, `All` filter selected, time-range slider at its full extent
(`Time range: 20:53:44 — 20:54:01`): the header reads **`1 of 2 decisions`** and exactly one
row renders (`20:53:44 System Sequence started`). Nothing on screen accounts for the second.

### NEW-E4 (P3) — The shared status-bar equipment chip is published as a disabled panel and is not

`tree` on every screen this session ends with `panel: 🔭 My Equipment / 2 connected [DISABLED]`.
Clicking it opens a five-entry popup — `button: 🔭 My Equipment / 2 connected`,
`button: Simulated Camera 20.0°C`, `button: Simulated Mount Idle`, `button: Disconnect All`,
`button: Equipment`. This is a live instance of NEW-C2's class in the shared shell chrome,
present on **all** screens, and it is not one of the four sites Wave D named.

### NEW-E5 (P2) — Night Doctor still scores a night of POOR subs 100/100 with "0 findings"

The WD-SCI-N5 fix discloses the disagreement but does not change the verdict, which the D-fix
was explicit about (scoring lives in `skotiq_core`, out of that batch's scope). The state
on one screen at one instant: **100 / 100**, *"A clean night — no problems detected."*,
`Excellent`, `0 findings` — over a run whose every sub the same app grades POOR
(`Good: 0 · Poor: 4`, DB `quality_score` 35.3–35.4, HFR 5.69–5.74 against the panel's 3.5 cull
line). Filed here so the residual is tracked as a defect rather than closed with N5.

---

## Observations (recorded, not filed)

- The three session pickers now share the quick-capture label exactly, but not the *run*
  label: Session and Science print `New Sequence  ·  Aug 13, 2026 20:53  ·  4 frames` while
  Diagnostics prints `New Sequence (Aug 13, 20:53)`.
- History's Quick captures card is an inert `panel:` whose sibling run row is a `button:` with
  a chevron. Its instruction — *"open Analytics ▸ Session to review them frame by frame"* — is
  now followable, so WD-SCI-N1's actual harm is closed; the card itself is still not a link.
- Creating a 3×3 mosaic adds nine `mosaic-panel` targets to Analytics ▸ Projects, which then
  offers "Remove untracked targets (9)". Noted only; not adjudicated.
- SCI-23 and SCI-24 still reproduce in passing (`panel: Plate solve…` ellipsised in an
  otherwise empty banner, and `4 more queued` beside `0 of 4 solved`). Not assigned here.

## Coverage

Analytics ▸ Session / History / Projects / Equipment Stats / Science / Diagnostics — each on
an empty profile and again with 12 quick captures + one completed run; all three session
pickers opened and round-tripped; Session Report; Session Review ▸ Narrative; Mosaic projects
list + wizard (two creations, gated-footer clicks, panel-dimension auto-fill) + project
detail + Back; Plan Tonight ▸ Recommendation ▸ Transient Alerts ▸ settings dialog (both switch
states, both sliders); Settings ▸ Appearance (two dropdown menus) and ▸ Imaging ▸ Catalogs
(Deep-Star card); Sequencer Builder ▸ pre-flight ▸ run ▸ History ▸ Replay. Layout checked at
1600×900 and 900×760.
