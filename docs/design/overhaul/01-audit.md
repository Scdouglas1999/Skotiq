# 01 · Audit of the shipped UI (7.0.0, 2026-09-09)

Everything below was observed in the RUNNING desktop app (release bundle of 7.0.0, driven with
`tools/ui_audit/drive_linux.py` on a 1600×900 window, fresh profile, simulated camera/mount/focuser,
Boston observing site). Screenshots are in `audit/`. Each finding names the screenshot that shows it.

This is the "why" behind every decision in 02–06. Implementing agents: read it once so you
understand what a change is fixing, then work from 03–07.

## What is already good (keep, do not "improve")

- **Palette discipline.** Every text/status colour clears WCAG AA on every surface, in all three
  themes, and the reasoning is documented in `skotiq_colors.dart`. Red night is a real
  wavelength constraint (G == B on every colour), not a tint. The overhaul keeps this and adds a
  checker (`tools/check_tokens.py`).
- **Type choices.** Hanken Grotesk + Spline Sans Mono, bundled offline. Right fonts, wrong scale.
- **Icons.** Lucide everywhere (3,189 uses vs 34 stray Material icons). Keep Lucide.
- **The planetarium** (`audit/23_planetarium.png`) is the one screen that already feels premium:
  edge-to-edge canvas, floating time control, compass, quiet labels. It is the model for Imaging.
- **Buttons and cards are already migrated** (`SkotiqButton` 847 uses, `SkotiqCard` 291;
  raw `ElevatedButton`/`OutlinedButton` at 0). The remaining debt is shape and type literals:
  110 raw `BorderRadius.circular(n)` + 29 `Radius.circular(n)` (979 more already go through the
  value-named `radiusInline*` tokens that a later pass must fold onto the semantic scale),
  2,420 raw `TextStyle(`, 120 `Color(0x…)`, 178 raw `IconButton(` in `skotiq_app/lib`.
- **Sequencer templates page** (`audit/30_seq_templates.png`) is close: clear cards, good copy.
- **Bottom status bar** as an idea (instrument apps have one). Its content is the problem.

## Findings

Severity: **S1** = makes the app look amateur or confuses navigation; **S2** = visible polish debt;
**S3** = defect found along the way.

> **The Resolved column is PROVISIONAL as written (2026-09-09).** Its verdicts come from reading
> the code at the wave-4 base and from the main loop's drives of each merged integration build,
> which are recorded in `reports/observatory/merge-log.md` with their screenshots in
> `reports/observatory/integration-3/`. The `final/<theme>-<screen>-<width>.png` names in the
> column are **forward references**: they are the evidence set wave 4 item 4 will capture, not
> files anyone has taken yet. When that set exists, each row is re-checked against its own image
> and this note comes out. Until then, read the column as a claim with its reasoning attached, not
> as a citation. Most rows now also carry a real source from that drive — see
> `reports/observatory/integration-3/INDEX.md`, which maps every capture to its screen, state,
> theme and width. Two rows have no image behind them yet: F4 (a tooltip that no longer stays
> painted — a test proves it, a screenshot cannot) and F5 (onboarding, which that drive did not
> capture).

The **Resolved** column records, for each finding, whether the overhaul closed it: resolved,
partially (with what is left and where it lives), or open. The final screenshot set follows the
same drive protocol as the audit above — release bundle, 1600 × 900 and 700 × 900, Boston site
(42.36 / 71 3 36 W / 40), simulated camera / mount / focuser, one snapshot taken — in dark, light
and red night. Two findings resolve to something no screenshot can show, a tooltip that no longer
stays painted (F4) and a deleted file (E1); those cite the test or the commit instead.

### A. Chrome: too much of it, and it repeats itself (S1)

| # | Finding | Evidence | Resolved |
|---|---|---|---|
| A1 | Three status surfaces show the same facts. Clock + LST appear in the Dashboard command bar AND the bottom bar. "Idle" appears three times on the Dashboard (command bar, bottom-left, bottom-middle). | `audit/19_dashboard_connected.png` | **Resolved**, verified. `DashboardCommandBar` is gone (wave 1); the instrument bar is the only status surface and "Idle" appears once. `integration-3/p_tonight_connected.png`, and `final/dark-tonight-1600.png` when captured |
| A2 | The Dashboard command bar (Idle / No Target / Temp / Focus / HFR / RMS / clock / Local / Edit Dashboard) exists ONLY on the Dashboard, so global status vanishes on every other screen. It is a screen header pretending to be shell chrome. | `audit/03_dashboard.png` vs `audit/10_equipment.png` | **Resolved.** Status is shell chrome now: the instrument bar is on every screen and the top bar carries the global command field. `integration-3/a06.png` + `a17.png` (the same bar on Tonight and on Imaging); `final/dark-tonight-1600.png`, `final/dark-equipment-1600.png` |
| A3 | Sequencer stacks three header layers before content: tab bar (48 px) + "Sequence Builder / Assemble the instructions tonight's run executes." title block (70 px) + 20-icon toolbar (48 px). Content starts 166 px down, 23% of a 720 px viewport. The title repeats the selected tab. | `audit/10_sequencer.png` | **Resolved.** One 56 px `PageHeader` (title + underline tabs + actions); the canvas bar tiers its own content by width instead of adding a row. `integration-3/a24.png`; `final/dark-sequencer-1600.png` |
| A4 | Imaging stacks an info banner (40 px) + viewer toolbar + capture bar + status bar. The image, which is the point of the screen, gets ~65% of the height. | `audit/21b_imaging_image.png` | **Resolved.** Edge-to-edge canvas under a single 44 px toolbar, readouts in the glass HUD, no info banner. `integration-3/a17.png`, `a18.png`; `final/dark-imaging-1600.png` |
| A5 | Narrow window (< 768 px) stacks the status bar ON TOP of the bottom nav: 110 px of bottom chrome on a 900 px window. | `audit/42_narrow_imaging.png` | **Resolved.** `statusBarHeightCompact` deleted; below 768 px the bottom nav is the only bottom chrome and the 28 px strip lives inside the page header. `integration-3/n01.png` (700 × 900); `final/dark-imaging-700.png` |
| A6 | Title bar wastes its centre; the wordmark, four icon buttons and window controls are all it holds. | every screenshot | **Resolved.** The centre is the command field. `integration-3/p00.png` (the field filtered to "weath"); `final/dark-tonight-1600.png` |

### B. Surfaces: everything is a bordered box, so nothing has hierarchy (S1)

| # | Finding | Evidence | Resolved |
|---|---|---|---|
| B1 | Boxes inside boxes inside boxes. Dashboard Guiding card → bordered chart well → bordered "No guide data" inset. Frame card → bordered "Waiting for first frame" bar → bordered empty area. Three 1 px borders of the same colour at three depths. | `audit/19_dashboard_connected.png` | **Resolved.** Nesting is capped at panel → well, and the well carries no border. `integration-3/p_tonight_connected.png`; `final/dark-tonight-1600.png` |
| B2 | Every panel, card, chip, tab, field and toolbar button uses the same 1 px `border` (#2E353F). The eye cannot tell a container from a control. | all | **Partially.** On the eleven wave-3 screens `border` is a divider token and containers separate by tone (dark panels carry a 4% ring, light panels a hairline) — `integration-3/a14.png`, `l05.png`. Surfaces still on the old bordered kit at the time of that drive: the pre-flight and profile-editor dialogs (`integration-3/g_preflight.png`, `g_profile.png`) and Settings › Catalogs (`k01.png`, `k05.png`). `final/dark-equipment-1600.png`, `final/light-equipment-1600.png` |
| B3 | Equipment device cards have a full green border (status), an amber inset warning box, a stat row AND a button row. Four competing emphases per card; the same amber "session only" paragraph is repeated on all three cards. | `audit/18_equipment_connected.png` | **Resolved.** A device is a panel with a status dot, readouts, at most two actions plus an overflow menu, and the session-only note as one chip. `integration-3/a16.png`; `final/dark-equipment-1600.png` |
| B4 | Cards with `Card`-style padding around a single line of text ("No runs yet — your first night will appear here.") | `audit/03_dashboard.png` | **Resolved.** One `EmptyState` pattern: centred, short, one button, no card around it. `integration-3/an1.png`; `final/dark-weather-1600.png` |

### C. Type: one size, one weight (S1)

| # | Finding | Evidence | Resolved |
|---|---|---|---|
| C1 | Almost all UI text is 12–13 px regular. Section headings are 11 px uppercase muted. Only page titles are large. Instrument readouts (temperature, RA/Dec, HFR, focus position) render at 12–13 px mono, the same weight as their labels. The most important numbers on screen are the quietest thing on it. | `audit/19_dashboard_connected.png` right column | **Resolved.** Measurements are `Readout`s — `readoutMd`/`readoutLg` mono 500 tabular over an 11 px uppercase label. `integration-3/a18.png` (the glass HUD), `p_tonight_connected.png`; `final/dark-tonight-1600.png` |
| C2 | Page subtitles are filler sentences: "Assemble the instructions tonight's run executes.", "Live cloud tracking and safety monitoring", "Customize how Skotiq looks". They cost 20–28 px of height each and say nothing the title didn't. | `audit/10_sequencer.png`, `audit/10_weather.png`, `audit/12_appearance.png` | **Partially.** Every rail destination, Settings and onboarding use `PageHeader` with no subtitle. Three route-only screens still use the deprecated `ScreenHeader` and its subtitle: `first_light/first_light_view.dart:57`, `science/science_screen.dart:182`, `transients/transients_screen.dart:102`. The other pre-Observatory route-only screens (`integration-3/x_polar.png`, `x_flat.png`, `x_pair.png`) are being rebuilt by the wave-4 routes agent. `integration-3/a06.png`; `final/dark-analytics-1600.png` |
| C3 | Sidebar items are two lines (title + subtitle). The subtitles ("Automation", "Session stats", "Cloud radar") are placeholders, and the two-line rows make the rail read as a settings list rather than navigation. | `audit/03_dashboard.png` | **Resolved.** `NavItem.description` deleted; rail items are one line, grouped Observe / Prepare / Review. `integration-3/a01.png` (collapsed by default), `a06.png`; `final/dark-tonight-1600.png` |

### D. Navigation: eight peers, hidden features, five tab styles (S1)

| # | Finding | Evidence | Resolved |
|---|---|---|---|
| D1 | Eight flat sidebar peers with no grouping. Settings is hidden in the title bar. Darkroom, Session review, Polar alignment, Flat wizard, Live stacking, Mosaic, Catalogs have NO navigation home; they are reached from buttons inside other screens or not at all (`app_router.dart` map in 04-shell.md). | `audit/03_dashboard.png`; router | **Resolved.** Three groups, Darkroom promoted to a destination, Settings reachable from the top bar, and the command palette reaches every route-only screen. `integration-3/a06.png` (the grouped rail), `p00.png` (the palette), `t_dr_sessions.png` (Darkroom as a destination); `final/dark-tonight-1600.png`, `final/dark-darkroom-1600.png` |
| D2 | Five different tab-bar styles: Sequencer pill-in-bar, Plan Tonight outlined pill, Projects/Discover segmented control, Imaging 4×2 tile grid, Settings tree. Plan Tonight has 6 tabs, one of which (Discover) has 3 sub-tabs. Analytics has 6. | `audit/10_sequencer.png`, `audit/22_plan_reco.png`, `audit/26_projects.png`, `audit/10_imaging.png` | **Resolved.** One style: `AdaptiveTabBar` underline in the page header. No app screen uses `SubTabButton` any more (the widget itself is deprecated, deleted in wave 4). `integration-3/a17.png`, `k_plan_targets.png`; `final/dark-plan-1600.png`, `final/dark-imaging-1600.png` |
| D3 | Imaging's side panel uses a 4×2 grid of tile-tabs; the eighth label truncates to "Annotatio…". | `audit/10_imaging.png` | **Resolved.** The side panel is a 44 px vertical icon strip; no labels to truncate. `integration-3/a17.png`; `final/dark-imaging-1600.png` |
| D4 | The Dashboard is two completely different layouts depending on whether equipment is connected ("briefing" with Moon/Targets/Readiness cards vs "cockpit" with frame/guiding/equipment). Same nav item, different information architecture. | `audit/03_dashboard.png` vs `audit/19_dashboard_connected.png` | **Resolved.** Tonight has one information architecture — hero, night band, panels — and first run differs only by the checklist's state. `integration-3/a01.png` (first run) beside `p_tonight_connected.png` (connected) — one architecture, two states; `final/dark-tonight-1600.png` |
| D5 | Sequencer toolbar: 20 unlabeled icon buttons in a row. | `audit/31_seq_loaded.png` | **Resolved.** `SkotiqToolbar` with a tooltip on every button, and the command palette for the rest. `integration-3/a24.png`; `final/dark-sequencer-1600.png` |
| D6 | "Plan Tonight" and Dashboard "Tonight's briefing" compete for the word Tonight. | `audit/03_dashboard.png` | **Resolved.** The rail says Tonight and Plan; only one screen owns the word. `integration-3/a06.png`, `k_plan_targets.png`; `final/dark-tonight-1600.png` |

### E. Noise: nags, tours and placeholders (S1)

| # | Finding | Evidence | Resolved |
|---|---|---|---|
| E1 | Every section fires its own "X Tour" toast in the bottom-right corner on first visit: Dashboard, Imaging, Sequencer, Guiding, Weather, Analytics, Settings, Equipment, Planetarium, Framing. Ten toasts, same spot, covering content (the Session panel in Imaging, Calibration in Guiding). | `audit/10_guiding.png`, `audit/21b_imaging_image.png`, `audit/24_framing.png` | **Resolved.** `contextual_tour_prompt.dart` and its 13 call sites deleted in wave 1; the tours are reachable from the help popover. `integration-3/a01.png` (fresh profile, no toast), `p02.png` (the help popover); `final/dark-tonight-1600.png` |
| E2 | One missing catalog produces FOUR nags: Catalog Setup dialog at launch, info banner across Imaging, an in-image warning box, and a modal ("Annotation Catalogs Required") on the first snapshot. Plus a card on Plan. | `audit/02_after_skip.png`, `audit/21_imaging_snapshot.png` | **Resolved.** The launch-time Catalog Setup modal is retired; a missing catalog is one `EmptyState` on Plan, one banner on Imaging, and one checklist row. `integration-3/a01.png`; `final/dark-plan-1600.png` |
| E3 | Two competing prompts at first launch: the Catalog Setup dialog AND the Dashboard Tour toast, simultaneously. | `audit/02_after_skip.png` | **Resolved.** Nothing competes at first launch: onboarding, then the checklist. `integration-3/a01.png`; `final/dark-onboarding-1600.png`, `final/dark-tonight-1600.png` |
| E4 | `---` / `--:--` placeholders for every unavailable value (Temp, Focus, HFR, RMS, Moonrise, LST). Eleven dashes on the idle Dashboard. | `audit/03_dashboard.png` | **Partially.** Tonight, the instrument bar and Imaging render `—`. Two holdouts: the top bar's equipment menu still returns `'---'` (`widgets/equipment_status_indicator.dart:241,385,395,405,414,424,436`) and the planetarium overlays return `'--:--'` (`planetarium/widgets/top_overlay.dart:165`, `.../mobile_widgets/top_overlay.dart:100`) — the planetarium is outside the overhaul's scope. `integration-3/a06.png`; `final/dark-tonight-1600.png` **Routed to the wave-4 screens sweep; may close before the final set is captured.** |
| E5 | An emoji (🔭) as the equipment-profile icon, in a Lucide-icon app. | `audit/15_equipment_manual.png` | **Partially.** The equipment-profile icon is a Lucide glyph. One colour emoji is left in chrome: the session-notes sentiment picker (`sequencer/widgets/notes_panel/sentiment_and_prompt.dart:16`, `😊 😐 😞`), which no theme can retint and which paints in full colour under red night. `integration-3/a14.png`; `final/dark-equipment-1600.png` **Routed to the wave-4 screens sweep; may close before the final set is captured.** |

### F. Layout defects (S3, fix during the overhaul)

| # | Finding | Evidence | Resolved |
|---|---|---|---|
| F1 | Equipment content pane stops ~115 px short of the window bottom (black void under the discovery list). | `audit/15_equipment_manual.png` | **Resolved.** The shell grid gives the content pane the full height; no void. `integration-3/a14.png`; `final/dark-equipment-1600.png` |
| F2 | The Discovery panel OVERLAYS the device cards (Focuser card is cut at its button row). | `audit/17b.png`, `audit/18_equipment_connected.png` | **Resolved.** Discovery is a drawer that pushes the device grid instead of covering it. `integration-3/a15.png`, `c14.png`; `final/dark-equipment-1600.png` |
| F3 | Sequence name truncates in its own header ("Mono LRGB M51 (…") while 40% of the bar is empty. | `audit/31_seq_loaded.png` | **Resolved.** The canvas bar drops to a shorter tier before anything ellipsizes. `integration-3/a24.png`; `final/dark-sequencer-1600.png` |
| F4 | Collapsed-rail hover tooltip ("Dashboard / Overview & status") stays painted after the pointer leaves. | `audit/40_red_dashboard.png` | **Resolved.** `SkotiqTooltip` hides on rebuild while hovered; pinned by `packages/skotiq_ui/test/skotiq_tooltip_rebuild_test.dart`. `final/redNight-tonight-1600.png` |
| F5 | Onboarding uses ~30% of a 1600×900 canvas; the rest is an empty bordered card. | `audit/01_first.png` | **Resolved.** Onboarding is a centred, content-sized column with a rail-style step list, not a card in an empty canvas. `final/dark-onboarding-1600.png` |
| F6 | Light theme "Start" button: light green fill on a green-tinted bar, low contrast. | `audit/34_light_dashboard.png` | **Resolved.** The Start button has its own pair — light `startFill` #1E7A47 with white ink at 5.34:1 (`skotiq_colors.dart:199`). `integration-3/l03.png`; `final/light-tonight-1600.png` |

### G. Colour (S2)

| # | Finding | Resolved |
|---|---|---|
| G1 | The accent (#5B9EC4) is desaturated enough that selection, primary buttons and info text all read as "greyish blue". Nothing on screen is allowed to be confident. | **Resolved.** `primary` is #6EB3EC (was #5B9EC4). `integration-3/p_tonight_connected.png`; `final/dark-tonight-1600.png` |
| G2 | Status green is used as a whole-card border (Equipment), which is louder than the status itself. | **Resolved.** Status is a dot and a chip; the panel keeps its neutral tone. `integration-3/a16.png`; `final/dark-equipment-1600.png` |
| G3 | Light theme is competent but flat: white cards with grey borders on grey. Same border-everywhere problem as dark. | **Resolved.** Light gets the same tonal ladder, borders only where white-on-off-white has no tone to work with. `integration-3/l03.png`, `l05.png`; `final/light-tonight-1600.png` |
| G4 | textSecondary (#9AA3AD) and textMuted (#9099A6) are nearly identical, so the three-level text ladder collapses to two. | **Resolved.** `textSecondary` #B3BAC5 and `textMuted` #8E97A4 are three steps apart from `textPrimary` #EDEFF3. `integration-3/p_tonight_connected.png`; `final/dark-tonight-1600.png` |

## What the overhaul changes, in one paragraph

One persistent status surface (the bottom instrument bar) instead of three. A 44 px top bar with a
global search/command field. A 64 px icon rail grouped by night phase (Observe / Prepare / Review)
with Darkroom promoted to a destination and Settings reachable from the rail. One page-header
pattern (title + underline tabs + actions on a single 56 px row; no subtitle sentences). Surfaces
separated by tone, not borders, with a maximum nesting depth of panel → well. A type scale with
loud mono readouts and quiet labels. One accent that is actually an accent. One tab style. One
banner style, one instance per problem. A first-run checklist on Tonight that replaces every nag
and tour toast. Same routes, same providers, same data: this is a presentation-layer overhaul.
