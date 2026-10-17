# 06 · Screens

One section per routed screen. Each gives: the mockup to match, the page header contents, the
layout, what is removed, and the files to touch. Routes and providers do not change; this is the
presentation layer. Screens not listed (Weather, Guiding, Analytics tabs, Onboarding, Darkroom
internals) follow the general rules and the notes at the end.

Files are under `packages/skotiq_app/lib/screens/` unless stated.

## Tonight (`/dashboard`) — `dashboard/`

Mockups: `mockups/png/tonight.png` (sequence loaded, devices connected),
`tonight-empty.png` (first run), `tonight-light.png`, `tonight-redNight.png`.

**One layout, three states.** The current split between `CockpitStandby` (briefing) and the zone
cockpit is replaced by a single page whose HERO and CHECKLIST change state; the panel grid below
stays the same shape.

Page header: `moon-star` · "Tonight" · muted date. Actions: ghost "Edit layout" (existing dashboard
layout editor). No tabs.

Body (24 px gutter, 20 px top):

1. **Hero** (no panel; sits on `background`): eyebrow with state dot ("SEQUENCE READY" / "RUNNING
   · 42%" / "NOTHING RUNNING" / "PAUSED"), `display` line (target name + muted "· common name",
   or the night headline "Clear skies after 20:54" when nothing is loaded), one 14 px
   `textSecondary` facts line with 14 px gaps (sequence summary · dark-in · moon). Right: the ONE
   primary action for the state: `start` "Start sequence" / `destructive` "Stop" + `secondary`
   "Pause" / `primary` "Connect equipment" / `primary` "Resume"; plus one `secondary` ("Open in
   Sequencer" / "Plan a target").
2. **Night band** (`NightBand`, 05 §16), present only when a site is set. With no site the band is
   simply absent; checklist step 1 is the ONE place that problem is represented (no banner).
3. **Grid** (12 columns, 16 gap):
   - Row 1: Live preview panel (`c8`, flush): `well`-toned image area with the last frame or the
     `EmptyState(image-off, "No frames yet", "Frames appear here as the sequence captures them")`;
     glass HUD top-right (last sub status) and bottom-left (`ReadoutRow` HFR / Ecc / Stars / RMS);
     thumbnail strip 32 px high beneath. Equipment panel (`c4`): `PanelHead(plug, "EQUIPMENT",
     chip)` + one `DeviceRow` per connected device with `Readout(sm)` values; disconnected devices
     are listed with a muted "Not connected" and no readouts.
   - Row 2: Guiding (`c4`): well chart 96 px + `ReadoutRow` RA/Dec/Total/SNR. Progress (`c4`):
     96 px ring (7 px stroke, `well` track, `primary` arc) with `readoutMd` percentage inside, per-
     filter bars (28 / 1fr / 64 grid, 6 px track), then `ReadoutRow` Integrated / Remaining /
     Rejected. Safety & events (`c4`): `KeyValueList` (clouds, wind, dew margin), hairline, three
     `ListRow` events with mono timestamps.
   - **First-run state** replaces Row 1–2 with: `Checklist` panel (`c7`) titled "READY FOR FIRST
     LIGHT" with the five steps (site, capture folder, connect camera + mount, install catalogs,
     plate solver). Detection: `readinessReportProvider` (`widgets/readiness/readiness_panel.dart`;
     it already reports camera/mount, capture folder and the plate solver) plus
     `annotationCatalogInstalledProvider` for catalogs and the site from `settingsProvider`. The
     next step's button is `secondary sm`; the hero's "Connect equipment" is the page's single
     primary), and a `c5` column: Moon panel (56 px phase disc + `ReadoutRow`), Weather panel,
     Last night panel.

Removed: `DashboardCommandBar` / `CompactDashboardCommandBar` (`widgets/command_bar.dart`,
841 lines) and `dashboard_header_actions.dart` clock; the "Image tonight / Sequencer" action row;
the "No active target — load a sequence" bar; the `---` placeholder strip; the Dashboard Tour
prompt; the Catalog Setup dialog at launch (its job is checklist step 4).

Keep: the widget registry + Edit layout mode (`dashboard/widgets/dashboard_widget_registry.dart`,
`dashboard/widgets/zone_layout.dart`) so users can rearrange Row 1–2 panels; the glance-mode toggle moves into
Settings › Appearance (mockup `settings.png`).

## Imaging (`/imaging`) — `imaging/`

Mockup: `mockups/png/imaging.png`, `narrow.png` (< 768).

Page header: `camera` · "Imaging" · underline tabs **Live view** / **Live stack** / **Session
frames (count chip)**. Imaging has no tabs today: Live view = the current viewer; Live stack =
the existing `imaging/widgets/stacking_panel.dart` promoted from a side-panel tab to a full tab;
Session frames = a `ListRow` list over the same provider `dashboard/widgets/cockpit_recent_frames.dart`
reads (no new data). Actions: ghost "Immersive" (`maximize-2`, existing immersive mode), icon
button `panel-right` (toggles the side panel).

Body (flush):
- **Viewer** fills everything left of the side panel. A 44 px viewer toolbar on top: left = mono
  12 meta (`6248 × 4176 · Bin 1×1 · Zoom 55% · Sky 19.8 mag/″²`, values in `textPrimary`); right =
  `SkotiqToolbar` with groups [Overlays ▾, Annotate] [crosshair, zoom in, zoom out, fit,
  fullscreen] (28 px buttons).
- **Canvas** edge to edge under the toolbar (no border, no padding, no inner card). Crosshair and
  centre ring in `primary` 35–50%. Glass elements: top-left `ReadoutRow` (HFR, Ecc, Stars, Median,
  Mean); top-right last-frame status line with dot; bottom-right histogram (220 wide, 44 px bars,
  "Stretch: auto" caption); bottom-centre **capture bar**: `[primary Snapshot] [secondary Loop] |
  [field 2.0 s] [field G 100] [field filter ▾] | [ghost Save] Stretch [switch]`, 32 px controls in a
  glass panel with `spaceSm` padding and gap.
- **Side panel** (`SidePanel`): strip sections Capture, Camera, Focus, Guiding, Mount, Filter
  wheel, Rotator, Annotations (the eight current tabs, now icons with tooltips). Capture section
  = `SectionTitle(camera, "Capture", chip temp)` + `FormRow`s (Exposure, Frame type, Binning,
  Gain / offset) + `SectionTitle(folder, "Files")` + rows (Format, Save to, Name) +
  `SectionTitle(activity, "Session")` + `ReadoutRow` (Captured, Integration, Free).

Removed: the annotation info banner (catalog problem → checklist + a single `SkotiqBanner`
inside the Annotations section of the side panel); the in-image "No catalogs installed" box; the "Annotation
Catalogs Required" modal on first snapshot; the bottom "Snapshot / Loop / Save / Dur / G100 /
Stretch" bar (now the glass capture bar); the 4 × 2 tile tabs; the separate Histogram card and
HFR/Stars box (merged into HUD); the Imaging Tour prompt.

Narrow: viewer on top, 28 px status strip under the header, side panel becomes a bottom sheet with
a horizontal section chip strip and two full-width buttons (Loop / Snapshot).

Files: `imaging/imaging_screen.dart`, `imaging/imaging_screen/imaging_screen_actions.dart`,
`imaging/widgets/*` (the tab panels move under `SidePanel` unchanged internally),
`imaging/widgets/stacking_panel.dart` (becomes the Live stack tab body).

## Sequencer (`/sequencer`) — `sequencer/`

Mockup: `mockups/png/sequencer.png`.

Page header: `list-ordered` · "Sequencer" · tabs **Builder / Templates / Saved / History** (rename
"Sequences" → "Saved"; the keyboard-shortcut hint icon button is removed, shortcuts live in the
help popover). Actions: ghost "Preflight" with a warning count chip, `start` button "Start"
(becomes `destructive` "Stop" + `secondary` "Pause" while running). No run-state chip here: the
instrument bar shows it.

Builder body (flush), three columns 264 / 1fr / 300:
- **Palette** (left): `SegmentedControl` Nodes / Snippets / Targets at the top (8 px padding), a 30 px
  search field, then eyebrow-labelled groups of node rows (26 px icon square in `well`, name 13,
  description 12 muted, trailing `plus` muted). Rows are draggable as today.
- **Canvas** (middle): a 44 px bar: sequence name 15 / 600 (never truncated: it gets the space
  before the meta chips, and the chips shrink first), muted "· unsaved changes", error/warning
  count chips, summary chip ("1 target · 27 nodes · ~2 h 54 m"), then a `SkotiqToolbar` [undo, redo]
  [Timeline, Map] [save, more]. Below, 16 / 20 padding: steps as `SkotiqPanel`s (8 px gap):
  header row `[28 px icon square] [title 14/500] [mono 12 muted detail] … [chips, more]`; the
  target step gets the `panelSelected` ring, a `well` altitude chart (96 px) and its children as
  `well` rows (icon 14, text 13, right-aligned mono count and an 80 × 4 progress track). Last
  row: muted "+ Drop a node here, or double-click one in the palette".
- **Properties** (right): `SectionTitle(sliders, node name, chip)` + `FormRow`s; hairline;
  eyebrow "ESTIMATE" + `ReadoutRow`; a `SkotiqBanner(tone: warning)` pinned to the bottom when the plan
  overruns astro dawn. Empty: `EmptyState(mouse-pointer-click, "Select a node", "Its settings
  appear here")`.

Removed: the "Sequence Builder / Assemble the instructions…" title block (`SequencerScreen`
header); the 20-icon toolbar (its actions are distributed: file actions → canvas bar `more`;
Start/Stop/Skip/Reset → page header + run-state chip menu; the six unlabeled view toggles → Timeline
/ Map buttons); the Sequencer Tour prompt.

Templates tab: keep the current design, restyled with `SkotiqPanel`, `pageTitle`, chips, and
the filters as `SegmentedControl` (All / Beginner / Intermediate / Advanced / Specialized).

Files: `sequencer/sequencer_screen.dart`, `sequencer/widgets/sequence_toolbar.dart` (→ canvas bar),
`sequencer/widgets/node_palette*.dart`, `sequencer/widgets/*properties*.dart`.

## Equipment (`/equipment`) — `equipment/`

Mockup: `mockups/png/equipment.png`.

Page header: `plug` · "Equipment" · tabs **Devices / Profiles (count) / Optical train** (the Optical train tab hosts the existing optical section of the profile editor, `equipment/dialogs/profile_editor_dialog/optical_and_devices.dart`, as a page instead of a dialog). Actions:
`chip(success, "5 connected")`, `secondary sm` "Disconnect all", `primary sm` "Scan for devices" (the page's single primary).

Devices tab body (flush), two columns 1fr / 320:
- **Device grid**: 3 columns, 16 gap, 20 / 24 padding, `align-content: start`. Each device is a
  `SkotiqPanel` (16 padding): top row `[32 px icon square in well] [role eyebrow 11 +
  name 14/600] … [status chip]`; `ReadoutRow` (values relevant to the device, 20 px mono); action
  row of `secondary sm` buttons + a ghost settings icon button. A device connected but not in the
  profile shows a `warning` chip "Session only" and ONE 12 px muted line "Connected but not in this
  profile. [Add to profile]" (link) instead of the amber paragraph. An empty slot is a dashed
  `borderHighlight` panel: `plus` + "Add rotator, dome, flat panel, weather…".
- **Discovery drawer** under the grid, in the same column: it is a `Column` child with
  `Expanded(grid)` above it, so it PUSHES the grid and never overlays it (fixes F1/F2). 44 px head
  row `[radio icon] [eyebrow "DISCOVERED DEVICES"] [muted "11 found · scanned 2 min ago"] …
  [ghost Rescan] [chevron toggle]`; rows in two columns (32 gap), each `[icon] [name] [mono
  "sim"/"ascom"/"indi" 11 muted] … [ghost Connect] [secondary "Add to profile"]`. Max height 44%
  of the column; collapses to the head row.
- **Side panel** (no strip): profile block (36 px `primary` 14% icon square, name 14/600, muted
  "Default profile · 5 devices · 2 unsaved"), `secondary sm` "Save N devices to profile" when
  unsaved, `SectionTitle(list-checks, "Readiness", chip)` + blocker rows (dot + title + detail +
  `secondary sm` action), `SectionTitle(activity, "System health", chip)` + `KeyValueList`.

Removed: the green device-card borders; the amber "This session only" paragraphs; the 🔭 emoji
(→ `LucideIcons.aperture`); the "PROFILES" left column (→ Profiles tab); the
"My Equipment" title bar with its own Idle chip and gear; the "No devices assigned" hero (→ the
empty-slot panels + the checklist on Tonight); the Equipment Tour prompt.

Files: `equipment/equipment_screen.dart`, `equipment/equipment_screen/layout_rail.dart` (→ side panel), `equipment/widgets/equipment_readiness_panel.dart`, `widgets/connected_device_card.dart` (the device card),
and the discovery widgets under `equipment/`.

## Plan (`/planner`) — `planner/`

Mockup: `mockups/png/plan.png`.

Page header: `compass` · "Plan" · tabs **Tonight / Projects / Schedule / Framing / Planetarium /
Your sky** ("Recommendation" → "Tonight"; "Discover" and its three sub-tabs → "Your sky" with
Constellation and Collaborate as a `SegmentedControl` inside it). Actions: chips "Moon 3%" and
"Dark 20:54 – 04:51".

Tonight tab body (flush), two columns 1fr / 380:
- Filter row (12 / 24 padding, bottom hairline): 300 px search field, `SkotiqFilterChip`s (Type, Min
  altitude, Fits my FOV, More), right-aligned "Sort: Score".
- Candidate list (12 / 24 padding, 8 gap): a header row using the same 6-column grid with eyebrows
  (count · Transit · Imageable · Window tonight), then `Candidate` rows (05 §9). The top candidate
  is selected and carries `secondary sm` "Image tonight"; others `secondary sm` "Add". The page's single primary is "Build sequence" in the detail column.
- Detail column (left hairline, 16 / 20 padding): 150 px `starfield`/DSS preview with the FOV
  rectangle in `primary` 80%; name 20 / 600 + muted line; `ReadoutRow` (Alt now, Transit,
  Window, From moon); 110 px `well` altitude chart; `KeyValueList`; bottom-pinned button pair
  `secondary "Frame it"` / `primary "Build sequence"`.
- Empty states: no site → `EmptyState(map-pin, "Set your observing site", …, "Open settings")`;
  no catalog → `EmptyState(download, "Install the object catalog", "OpenNGC lets the planner score
  13 000 targets", "Download 60 MB")`. ONE of them, never a stack of cards. (An `EmptyState` on a screen that cannot function without the thing is not a "banner" under the one-banner rule; that rule forbids REPEATED nags on screens that still work.)

Removed: the "AUTOPILOT STANDING BY" amber card and the Transient Alerts card from this tab (they
move to Schedule and to the alerts popover respectively); the "Next steps" list.

Planetarium tab: unchanged except chrome tokens; it is already the reference.

## Settings (`/settings`) — `settings/`

Mockup: `mockups/png/settings.png` (+ light, redNight).

Page header: `settings` · "Settings". Actions: ghost "Backup".
Two columns 240 / 1fr. Left: 30 px search field, eyebrow groups **General** (General, Appearance,
Location, Files & storage), **Observing** (Equipment, Imaging, Automation & safety, Science),
**System** (Notifications & remote, Advanced, Help & about); items 34 px, icon 15, `button` text,
selected = `primary` at `opacityAccentTint`. Right (24 / 32 padding, max 880): `pageTitle` + ONE `bodySm` lead
line (allowed here because it carries real information, e.g. the red-night explanation), then
eyebrow-labelled groups of `SkotiqPanel(flush)` containing `SettingRow`s (12 / 16 padding,
hairlines, title `body` 500, description `caption` `textSecondary`, control right-aligned: 160 px
dropdown / switch / swatches / theme cards).

Theme picker becomes three 132 px preview cards (dark / light / red night) with a check on the
selected one. Accent swatches 22 px with a 2 px ring on the selected, per theme (03 §1.4). The existing **UI scale** row keeps its five stored values ('Auto', 'Small (0.8x)', 'Normal (1.0x)', 'Large (1.2x)', 'Extra Large (1.4x)', `app.dart:37-48`) relabelled Auto / Compact 0.8× / Comfortable 1.0× / Large 1.2× / Extra large 1.4×. New row:
**Glance mode** (moved from the dashboard).

## Guiding (`/guiding`), Weather (`/weather`), Analytics (`/analytics`), Darkroom (`/darkroom`)

Apply the general rules; no dedicated mockup.
- Guiding: page header `crosshair` · "Guiding" · chip (PHD2 state) · actions [`secondary` Connect,
  ghost settings]. Three columns 224 / 1fr / 300: left panels (Guide star well, Target display
  well, Star statistics `ReadoutRow`); centre graph panel with a 40 px options row (RA/Dec/Tot as
  `Readout(sm)`, Time and Scale as small dropdowns) and the chart in a `well`; right side panel
  (Controls, Star selection, Dither, Calibration as `SectionTitle` blocks). Calibration warning =
  one `SkotiqBanner(tone: warning)`, not a bordered hero.
- Weather: page header `cloud-sun` · "Weather" · chip (Safe / Unsafe / Not monitored) · actions
  [ghost refresh, ghost settings]. Radar fills the body edge to edge with glass HUD for conditions;
  no site → single `EmptyState`.
- Analytics: page header `bar-chart-3` · "Analytics" · tabs Session / History / Projects / Equipment
  / Science / Diagnostics. Empty → single `EmptyState`. Charts inside `well`s, chart colours from
  `SkotiqChartColors` (unchanged).
- Darkroom: page header `aperture` · "Darkroom" · tabs Recipes / Sessions / Masters. Landing state
  (no `?master=` / `?recipe=`) lists recipes and sessions as `Candidate`-style rows; the workbench
  keeps its current structure with glass HUD over the image and the right column as a `SidePanel`.
  Session review (`/session-review`) and stack result (`/stack-result`) highlight Darkroom in the
  rail.

## Onboarding (`/onboarding`)

Keep the flow. Layout: centred 720 px column on `background`, step list as a 220 px left rail-
style list (single line per step, done = check), content as a `SkotiqPanel` sized to content
(no full-height empty card), progress "Step 1 of 13" as an eyebrow, `primary` Next bottom-right,
ghost "Skip" top-right. Fix F5.

## Copy rules for every screen

- Sentence case everywhere ("Frame type", not "Frame Type"), including tab labels and buttons.
- Buttons are verbs: "Connect", "Download", "Build sequence". Never "OK" alone.
- Numbers use figures. No thousands separator — not in readouts ("25000"), not in prose
  ("13000 targets"): the bundled fonts have no thin space (U+2009), and one grouping style across
  the app beats two. Units: `°C`, `×`, `²` (all three are in the fonts), and ASCII `'` and `"` for
  arcminutes and arcseconds (12' 30") — the fonts have NO prime glyphs (U+2032/U+2033 render as
  tofu), and no `▲` either (U+25B2); the night band's now marker is a Lucide chevron.
- Unknown = "—". Never `---`, `--:--`, `N/A`.
- No exclamation marks, no "Welcome to…", no "Learn how to…" in chrome.
