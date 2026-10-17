# 03 · Tokens

`design-tokens.json` is the source of truth. This file explains each value and gives the EXACT
Dart edit for every token so an implementing agent never has to interpret. Run
`python3 docs/design/overhaul/tools/check_tokens.py` after any change to the JSON; it fails the
build if any text or status colour drops below WCAG AA 4.5:1 on any surface.

All Dart paths are under `packages/skotiq_ui/lib/src/`.

## 0. JSON → Dart name map (read this before mirroring anything)

The JSON uses short, CSS-friendly keys. The Dart names differ. Mirror by THIS table, never by
key name.

| JSON key | Dart name | Notes |
|---|---|---|
| `palettes.*.bg` | `SkotiqColors.background` | |
| `palettes.*.well` | `SkotiqColors.well` | new field |
| `palettes.*.surfaceAlt` | not in JSON | deprecated; value in §1.1 |
| `palettes.*.borderStrong` | `SkotiqColors.borderHighlight` | |
| `palettes.*.onPrimary` | derived by `useDarkOnPrimary` | do not add a field |
| `palettes.*.startFill` / `onStart` | `SkotiqColors.startFill` / `onStart` | new fields (Start button) |
| `palettes.*.accentSwatches` | `AppearanceAccents.forTheme(mode)` | new const list in `skotiq_theme.dart` |
| `palettes.*.bands.*` | `SkotiqColors.bandDusk/bandTwilight/bandDark/bandDawn` | new fields (NightBand) |
| `palettes.*.brandWarm` | `SkotiqColors.brandWarm` | brand/decoration only — never status, never a control |
| `typography.styles.pageTitle` | `SkotiqTypography.pageTitle` | NOT `h1`; `h1` (32) stays and is deprecated |
| `typography.styles.sectionTitle` | `SkotiqTypography.sectionTitle` | NOT `h2` |
| `typography.styles.*` other | same name | `readoutXs`, `readoutBadge`, `monoCaption`, `buttonLg` are new |
| `space.1/2/3/4/5/6/8/12` | `spaceXs/Sm/Md/Lg/Xl/2xl/3xl/4xl` | values unchanged |
| `radius.xs/sm/md/lg/xl` | `radiusXs/Sm/Md/Lg/Xl` | 4/6/6/8/12 — same keys, same meaning |
| `shell.topBarHeight` | `ShellChromeMetrics.titleBarHeight` | |
| `shell.instrumentBarHeight` | `ShellChromeMetrics.statusBarHeight` | |
| `shell.railWidthCollapsed/Expanded` | `SkotiqTokens.sidebarCollapsed/Expanded` | |
| `shell.railItemSize` | `ShellChromeMetrics.railItemSize` | new |
| `shell.pageHeaderHeight`, `sidePanelWidth`, `windowControlWidth` | same names on `ShellChromeMetrics` | first two new |
| `shell.iconButtonSize/Sm/Strip` | `SkotiqTokens.iconButtonSize/iconButtonSizeSm/iconButtonSizeStrip` | new |
| `shell.narrowBottomNavHeight` | `BottomNavMetrics.barHeight` | |
| `motion.hoverMs/stateMs/panelMs` | `durationFast/durationNormal/durationSmooth` | see §4 |
| `motion.easing` | `Curves.easeOutCubic` | the bezier IS easeOutCubic |
| `opacity.*` | `SkotiqTokens.opacity*` | see §5.1 |
| `elevation.*` | `SkotiqDecorations.popover/dialog/glass` | shadows live in the factories, no token |

## 1. Colour

### 1.1 Dark palette (default)

| Role | Value | Was | Used for |
|---|---|---|---|
| `background` | `#0B0D12` | #0A0C0F | window canvas, top bar, rail |
| `surface` | `#12151B` | #111418 | panels, instrument bar, side panels |
| `well` **(new field)** | `#0E1116` | — | insets inside a panel: charts, image areas, empty areas, number fields |
| `surfaceAlt` | `#161A21` | #181C22 | **deprecated**; kept so existing call sites compile; migrate to `well` (inset) or `surface` (container). Never use in new code |
| `surfaceHover` | `#1A1E26` | #212630 | hover fill for rows, rail items, ghost buttons, segmented control selected |
| `surfaceElevated` | `#1C2129` | #252A32 | popover menus, dropdown lists, tooltips |
| `surfaceOverlay` | `#222831` | #2A3038 | dialogs, command palette |
| `border` | `#232830` | #2E353F | hairline dividers ONLY (page header bottom, list rows, rail edge). Not panel outlines |
| `borderHighlight` | `#343B46` | #3A424E | outline of secondary buttons, filter chips, dashed empty slots |
| `textPrimary` | `#EDEFF3` | #E8EAED | content, values, titles |
| `textSecondary` | `#B3BAC5` | #9AA3AD | descriptions, key labels in key/value lists, rail labels |
| `textMuted` | `#8E97A4` | #9099A6 | eyebrows, readout labels, timestamps, placeholders, icons at rest |
| `primary` | `#A48CF2` | #6EB3EC | primary button fill, selected state, links — the brand violet; the old blue survives as the second Appearance swatch and as `info` |
| `accent` | `#B9ABFF` | #8FC7F5 | primary hover fill only |
| `onPrimary` | `#0B0D12` (via `useDarkOnPrimary: true`) | same | ink on primary/accent fills |
| `success` | `#43B67A` | #3DAA6D | connected, done, safe |
| `warning` | `#E0A53E` | #D49A3A | attention, unsaved, session-only |
| `error` | `#E86A6A` | #D85C5C | failed, disconnected, stop |
| `info` | `#6EB3EC` | equals old primary | keeps the old blue so status stays distinct from a violet selection |
| `brandWarm` **(new)** | `#FFD9A8` | — | the mark's warm lane/pole star, the "now" marker, the running step's progress highlight — decoration only, held ΔE00 ≥ 15 from `warning` and (outside red night) `error` (light `#8A3200`, red night `#FF9A9A`) |
| `startFill` **(new)** | `#43B67A` | — | Start-sequence button fill (light `#1E7A47`, red night = primary) |
| `onStart` **(new)** | `#06140B` | — | ink on `startFill` (light white, red night `onPrimary`) |
| `bandDusk/bandTwilight/bandDark/bandDawn` **(new)** | `#3A3F66 / #151A2C / #0D1015 / #4A4160` | — | NightBand gradient; light `#C9CFE8 / #4A5680 / #1B2238 / #E2C9C0`; red night `#3A1414 / #140808 / #0A0000 / #3A1414` |

Contrast (from `check_tokens.py`): textMuted worst 5.02:1 on surfaceOverlay; error worst 4.73:1
on surfaceOverlay; onPrimary on primary 7.04:1; brandWarm 11.12:1 worst surface, ΔE00 15.61
from warning. All pass.

### 1.2 Light palette

| Role | Value | Was |
|---|---|---|
| `background` | `#F3F5F8` | #F4F6F8 |
| `surface` | `#FFFFFF` | same |
| `well` | `#EEF1F5` | — |
| `surfaceAlt` (deprecated) | `#F7F8FA` | #EEF1F4 |
| `surfaceHover` | `#E6EAEF` | #E4E8EC |
| `surfaceElevated` / `surfaceOverlay` | `#FFFFFF` | same |
| `border` | `#DCE1E7` | #D8DEE4 |
| `borderHighlight` | `#C6CED8` | #C8D0D8 |
| `textPrimary` / `textSecondary` / `textMuted` | `#14181F` / `#4F5966` / `#616873` | #141820 / #5C6672 / #616873 |
| `primary` | `#6A4FD1` | #256F9E (the brand violet, 5.27:1 as text on background; the old blue stays as `info` and a swatch) |
| `accent` | `#5B41C4` | #1F5F88 (hover still DARKENS in light; white ink 7.00:1) |
| `success` / `warning` / `error` / `info` | unchanged `#277549` / `#8F5D14` / `#BC3838` / `#256E99` | |
| `useDarkOnPrimary` | `false` | same |

In light, panels DO get a 1 px `border` outline (white on off-white has no tone contrast). Dark
panels do not. See `SkotiqDecorations.panel` in §5.

### 1.3 Red night palette

Unchanged except: `well: #0F0404`, `borderHighlight: #3A1A1A`, `primary: #EF3B3B` (was #DC2626,
4.29:1 under dark ink → 5.29), `accent: #FF5A5A` (hover lightens; was #B91C1C, 3.20:1), `error:
#EF5252` (was #EF5350, which was off the red axis by 3 in blue). Every colour keeps G == B —
including `brandWarm: #FF9A9A`, a pale red folded onto the axis, ΔE00 18.34 from warning.

### 1.4 Custom accent

`darkWithAccent` / `lightWithAccent` keep working. `_prefersDarkInk` stays. The swatches offered
in Settings › Appearance are PER THEME (`accentSwatches` in `design-tokens.json`), because a
dark-safe accent is not light-safe: #6EB3EC is 8.1:1 as link text on the dark canvas but 2.4:1
on white. `check_tokens.py` validates every swatch both as a fill (with the ink
`_prefersDarkInk` would pick) and as link text on `bg` and `surface`.

| Theme | Swatches |
|---|---|
| dark | `#A48CF2 #6EB3EC #43B67A #E0A53E #E86A6A #E77FB3 #4FC3C8` |
| light | `#6A4FD1 #256F9E #277549 #8F5D14 #BC3838 #B03A7A #1B7278` |
| red night | none (accent picker hidden; the palette is fixed by the wavelength rule) |

Violet leads each list — it is the brand accent and each palette's own primary; the old blue
stays second so the previous look remains one tap away. Each swatch renders the Trails mark in
that accent (`SkotiqMark` tone `theme` + `themeAccent`), so the row previews the logo each
choice produces.

Dart: the swatch list in the Appearance settings section becomes a `switch` on the active
`AppThemeMode`; store the chosen hex as today. If a stored accent fails the text-contrast floor
for the current theme (user switched theme after choosing), fall back to that theme's first
swatch for TEXT uses only (`SkotiqColors.primary` stays the chosen fill; add
`SkotiqColors.link` = the contrast-safe variant, computed once in `resolveSkotiqThemeData`).

### 1.5 Dart edits — `theme/skotiq_colors.dart`

1. Add `well`, `startFill`, `onStart`, `bandDusk`, `bandTwilight`, `bandDark`, `bandDawn` as
   `final Color` fields on `SkotiqColors`, required in the constructor, in `copyWith`, `lerp`,
   `==`, `hashCode`. `darkWithAccent`/`lightWithAccent` leave all seven untouched.
2. Replace the three `static const` palettes with the values in 1.1–1.3 (keep the explanatory
   comments; update the measured numbers by running `check_tokens.py`).
3. Keep `surfaceAlt` but add `@Deprecated('Use well (inset) or surface (container). Removed in wave 4.')`.
4. Tests: extend `test/light_contrast_test.dart` and `test/red_night_contrast_test.dart` to the
   six surfaces including `well`; create `test/dark_contrast_test.dart` with the same floors; create
   `test/design_tokens_sync_test.dart` that parses `docs/design/overhaul/design-tokens.json` and
   asserts every palette value equals the Dart constant via the §0 map (so JSON and Dart cannot
   drift), and asserts G == B for every red-night colour including bands.

## 2. Typography

Fonts stay: Hanken Grotesk (UI) and Spline Sans Mono (readouts). What changes is the scale and
what each style is FOR.

| Style name (Dart) | Size / weight / line-height / tracking | Family | Use |
|---|---|---|---|
| `display` **(new)** | 28 / 600 / 1.2 / −0.4 | sans | the Tonight hero line only |
| `pageTitle` **(new)** | 20 / 600 / 1.3 / −0.2 | sans | screen title in the page header |
| `sectionTitle` **(new)** | 15 / 600 / 1.4 / 0 | sans | section titles inside side panels and settings pages |
| `eyebrow` **(new)** | 11 / 600 / 1.4 / +0.7, UPPERCASE | sans | panel labels, rail group labels, list column headers |
| `body` | 14 / 400 / 1.5 | sans | default text (raised from the de-facto 13) |
| `bodyStrong` **(new)** | 14 / 600 / 1.5 | sans | names in lists, checklist titles |
| `bodySm` | 13 / 400 / 1.45 | sans | dense lists, table cells, chips |
| `caption` | 12 / 400 / 1.4 | sans | hints, timestamps, help under settings rows |
| `readoutLg` **(new)** | 28 / 500 / 1.15 / −0.6, tabular | mono | hero numbers (camera temp on Equipment, HFR in HUD when glance mode) |
| `readoutMd` **(new)** | 20 / 500 / 1.2 / −0.3, tabular | mono | standard readout |
| `readoutSm` **(new)** | 14 / 500 / 1.3 / 0, tabular | mono | readouts in dense rows and key/value lists |
| `readoutLabel` **(new)** | 11 / 500 / 1.3 / +0.5, UPPERCASE | sans | label under a readout |
| `readoutXs` **(new)** | 12 / 500 / 1.3 / 0, tabular | mono | instrument-bar clock and LST, chip counts |
| `readoutBadge` **(new)** | 16 / 600 / 1.2 / 0, tabular | mono | Plan score badge, checklist step number |
| `monoCaption` **(new)** | 11 / 400 / 1.3 / 0, tabular | mono | NightBand legend, `kbd` hints, thumbnail timestamps, discovery "sim/ascom" tags |
| `button` | 14 / 500 / 1.4 | sans | buttons, rail labels, settings nav items, tab labels |
| `buttonSm` | 13 / 500 / 1.4 | sans | small buttons, segmented control |
| `buttonLg` **(new)** | 15 / 500 / 1.4 | sans | large buttons (hero Start) |

Rules:
- A readout is ALWAYS `readout*` for the value plus `readoutLabel` for the label. Never a bare
  `TextStyle(fontFamily: mono)`.
- Units inside a readout: same style at 60% size, `textMuted`, weight 400, 2 px gap. Glyphs the
  bundled fonts carry: `°`, `×`, `—`. NOT carried: `′`, `″`, thin space — use `'`, `"`, and no
  thousands grouping.
- Unknown values render `—` (U+2014) in `textMuted`, never `---` or `--:--`.
- There are NO other sizes. 13.5, 12.5, 9 and 16 do not exist: rail labels and settings items
  are `button` (14), settings descriptions are `caption` (12), dialog and empty-state titles are
  `sectionTitle` (15), checklist titles are `bodyStrong`. `.copyWith(fontSize: …)` is forbidden the
  same as `TextStyle(fontSize: …)`; extend `design_tokens_audit.dart` to match both.
- `h1`…`h6`, `label*`, `statValue`, `statLabel` REMAIN for compilation; they are deprecated. The
  `ui_consistency_audit.dart` rule `deprecated_text_style` (new, see 07) flags them.

### 2.1 Dart edits — `theme/skotiq_typography.dart`

Add the eight new `static const TextStyle` members with exactly the numbers above (`letterSpacing`
in logical px, `height` = line-height ratio, `fontFeatures: [FontFeature.tabularFigures()]` on all
`readout*`). Change `body` to 14 if it is not already; change `bodySm` to 13. Mark
`h1..h6, statValue, statLabel` with `@Deprecated('Use pageTitle/sectionTitle/display/readout*')`.
Leave the `textTheme()` Material mappings UNCHANGED (Material widgets such as `AlertDialog` and
`ListTile` read `titleLarge`; remapping it would resize every one of them). The new styles are
used directly by Skotiq widgets.

## 3. Space, radius, size

### 3.1 Spacing (unchanged scale, restated with roles)

| Token | px | Role |
|---|---|---|
| `spaceXs` | 4 | icon-to-text gap inside chips |
| `spaceSm` | 8 | gap between controls, chip padding |
| `spaceMd` | 12 | button horizontal padding, list row vertical padding + 2 |
| `spaceLg` | 16 | panel padding, panel gap, side-panel padding |
| `spaceXl` | 20 | page body top padding |
| `space2xl` | 24 | page gutter (left/right/bottom) |
| `space3xl` | 32 | section gap on settings pages |

### 3.2 Radius (VALUE change only, no call-site edits)

| Token | New | Was | Role |
|---|---|---|---|
| `radiusXs` | 4 | 3 | chips, badges, thumbnails, kbd |
| `radiusSm` | 6 | 5 | buttons, fields, wells, segmented control |
| `radiusMd` | 6 | 6 | inputs (same as Sm on purpose; both mean "control") |
| `radiusButton` | 6 | 7 | alias of Sm |
| `radiusLg` | 8 | 10 | panels, rail items, device cards, score badges |
| `radiusXl` | 12 | 13 | dialogs, popovers, command palette |
| `radiusInline2` | 4 | 2 | fold into Xs |
| `radiusInline4` | 4 | 4 | = Xs |
| `radiusInline8` | 8 | 8 | = Lg |
| `radiusInline9/11/12/…` | nearest of 4/6/8/12 | | see `docs/design/overhaul/archive/token-migration-map.md`; round 9→8, 11→12, 12→12, 14+→12 |

Edit: `theme/skotiq_tokens.dart`, change the constants. Because 979 call sites in
`packages/skotiq_app/lib` already reference `SkotiqTokens.radiusInline*` / `radius*`, the
value change reaches them with no edit. The remaining literals are: 110 `BorderRadius.circular(<n>)`
and 29 `Radius.circular(<n>)`. Wave 0 replaces those by value: `(8)` → `borderRadiusLg`, `(6)` →
`borderRadiusSm`, `(4)` and `(2)` → `borderRadiusXs`, `(12)` and larger → `borderRadiusXl`,
`(10)` → `borderRadiusLg`, others → nearest. Wave 4 then sed-replaces `radiusInline2/4` →
`radiusXs`, `radiusInline8` → `radiusLg`, `radiusInline9` → `radiusLg`, `radiusInline11/12` and
above → `radiusXl` (979 mechanical edits, one commit) and deletes the `radiusInline*` constants.

### 3.3 Component sizes (applied in wave 2, not wave 0 — they change layout)

| Token | New | Was |
|---|---|---|
| `buttonHeight` | 32 | 40 |
| `buttonHeightSm` | 28 | 32 |
| `buttonHeightLg` | 40 | 48 |
| `inputHeight` | 32 | 40 |
| `sidebarCollapsed` | 64 | 72 |
| `sidebarExpanded` | 220 | 220 |
| `minTouchTarget` | 48 (touch only; desktop pointer targets may be 28–32) | 48 |
| `iconButtonSize` / `iconButtonSizeSm` / `iconButtonSizeStrip` **(new)** | 32 / 28 / 36 | — |

### 3.4 Shell metrics — `tokens/shell_chrome_metrics.dart` (applied in wave 1, not wave 0)

| Constant | New | Was |
|---|---|---|
| `titleBarHeight` | 44 | 40 |
| `statusBarHeight` | 32 | 36 |
| `statusBarHeightCompact` | **deleted** (no instrument bar below 768 px; the 28 px strip is inside the Tonight/Imaging page headers) | 40 |
| `contentStackBottomChromeHeight()` | returns `BottomNavMetrics.barHeight` only below 768 px, `statusBarHeight` above | nav + compact status bar |
| `windowControlWidth` | 46 (unchanged) | 46 |
| `pageHeaderHeight` **(new)** | 56 | — |
| `sidePanelWidth` **(new)** | 320 | — |
| `sidePanelStripWidth` **(new)** | 44 | — |
| `railItemSize` **(new)** | 40 | — |
| `BottomNavMetrics.barHeight` | 64 | 78 |
| `BottomNavMetrics` slot breakpoints | unchanged; the slot LIST is `ShellNavigation.bottomNavigationDestinations` (see 04 §3.3) | |

## 4. Motion

`skotiq_tokens.dart` already has `durationMicro/Fast/Quick/Normal/Smooth/Slow/Cinematic/
Sluggish/Shimmer/Pulse`. Change the VALUES; keep the names so call sites compile:

| Token | New ms | Was | Use |
|---|---|---|---|
| `durationMicro` | 80 | 100 | icon colour on hover |
| `durationFast` | 120 | 100 | hover fills |
| `durationQuick` | 160 | 150 | alias of Normal |
| `durationNormal` | 160 | 200 | selected state, switch, chip |
| `durationSmooth` | 220 | 300 | rail expand, side panel, discovery drawer, dialog in |
| `durationSlow` | 300 | 300 | immersive mode enter/exit only |
| `durationCinematic` / `durationSluggish` | 300 | 400 / 500 | deprecated, alias of Slow |
| `durationShimmer` / `durationPulse` | unchanged | | loading shimmer only |

Curve: `Curves.easeOutCubic` everywhere. `skotiq_tokens.dart` has eight named curves
(`curveSnappy`, `curveAccelerate`, `curveBounce`, `curveSettle`, …): set every one of them to
`Curves.easeOutCubic` in wave 0 and delete all but `curveStandard` (new alias) in wave 4. The JSON
`motion.easing` bezier (0.215, 0.61, 0.355, 1) IS `easeOutCubic`. No bounce, no overshoot, no
spring. The only continuous animation is the loading shimmer. The live
dot's 3 px halo is static (`opacity 0.22`), not pulsing. Respect `MediaQuery.disableAnimations`.

## 5. Elevation and decoration — `theme/skotiq_decorations.dart`

### 5.1 Opacity tokens — `theme/skotiq_tokens.dart`

| Dart name | Value | Was | Use |
|---|---|---|---|
| `opacityAccentTint` **(new)** | 0.12 | — | selected rail item, selected strip item, selected settings item |
| `opacityAccentTintHover` **(new)** | 0.18 | — | checklist "next" disc, hover on selected |
| `opacityStatusFill` | 0.14 | 0.15 | chip fills, score badges, checklist "done" disc |
| `opacityDisabled` | 0.40 | 0.38 | |
| `opacityHairline` **(new)** | 0.08 | — | dividers (white on dark, black on light) |
| `opacityHairlineStrong` **(new)** | 0.22 | — | NightBand dashed verticals and "now" line on charts |
| `opacityPanelOutline` **(new)** | 0.04 | — | the almost-invisible 1 px ring on dark panels and fields |
| `opacitySelectedRing` **(new)** | 0.50 | — | `primary` ring on a selected panel/step/candidate |
| `opacityLiveHalo` **(new)** | 0.22 | — | the static 3 px halo on a live dot (in `success`) |
| `opacitySubtle`, `opacityMedium`, `opacityStrong`, `opacityTint`, `opacityBorderMedium`, `opacityEmphasisBorder`, `opacityHalf`, `opacityHoverBorder`, `opacityBadgeBorder`, `buttonHoverLighten`, `buttonBorderDarken` | keep values | | deprecated; deleted in wave 4 |

### 5.2 Decoration factories

Add these named factories; each returns a `BoxDecoration`. The EXISTING factories stay in wave 0
as thin deprecated wrappers (table at the end) and are deleted in wave 4.

| Factory | Dark | Light | Notes |
|---|---|---|---|
| `panel(colors)` | fill `surface`, radius `radiusLg`, 1 px ring white at `opacityPanelOutline` (4%, almost invisible: tone does the work), NO shadow | fill `surface`, 1 px `border`, radius `radiusLg` | replaces `SkotiqCard` standard |
| `well(colors)` | fill `well`, radius `radiusSm` | fill `well`, radius `radiusSm` | inset; never nested in another well |
| `panelSelected(colors)` | panel + 1 px ring `primary` at `opacitySelectedRing` (as `border`) | same | selected candidate, selected step |
| `railItemSelected(colors)` | fill `primary` at 12%, radius `radiusLg` | same | icon + label in `primary` |
| `chip(colors, tone)` | fill tone at 14% alpha, radius `radiusXs`, no border; text in tone | same | tone ∈ neutral(surfaceHover)/success/warning/error/primary |
| `filterChip(colors)` | transparent, 1 px `borderHighlight`, radius `radiusSm` | same | |
| `field(colors)` | fill `well`, 1 px ring white at `opacityPanelOutline` (focus: 1 px `primary`; error: 1 px `error`), radius `radiusSm` | fill `well`, 1 px `border` | |
| `popover(colors)` | fill `surfaceElevated`, radius `radiusXl`, shadow `0 8 24 rgba(0,0,0,.45)` + 1 px ring white at `opacityHairline` | fill white, shadow `0 8 24 rgba(20,24,31,.14)` + 1 px `border` | menus, dropdowns, tooltips, toasts |
| `dialog(colors)` | fill `surfaceOverlay`, radius `radiusXl`, shadow `0 24 64 rgba(0,0,0,.6)` + ring | fill white, shadow `0 24 64 rgba(20,24,31,.22)` | |
| `glass(colors)` | fill `SkotiqColors.dark.surface` at 72% + `BackdropFilter(blur 12)`, 1 px white 10% border, radius `radiusLg` | SAME as dark (glass is anchored to the image, which is dark in every theme; contents use the dark text ladder); red night uses its own surface at 78% with a red 14% border | ONLY over imagery. Wrap in `RepaintBoundary` OUTSIDE any animation gate (see memory: animation-gate-repaint-boundary-order) |
| `hairline(colors)` | 1 px `border` | | dividers; use `Divider(height: 1, thickness: 1)` |

Existing factories → replacement (wave 0 makes each a deprecated wrapper; wave 4 deletes):

| Existing (`skotiq_decorations.dart`) | Becomes |
|---|---|
| `iconChip` | `well` fill, radius `radiusSm` (the 26–36 px icon squares) |
| `emphasisSurface` | `panel` |
| `tintedBadge` / `statusChip` / `kpiBadge` | `chip(tone)` |
| `selectedSurface` / `cardSelected` | `panelSelected` |
| `navSelected` | `railItemSelected` |
| `cardHover` | none: a panel has no hover; a tappable ROW gets `surfaceHover` fill |
| `dragFeedback` | `popover` |
| `filledButton` | none: `SkotiqButton` paints itself; buttons have no border |

`elevationLevel1/2/3`, `elevationLevel1to2`, `elevationInset`, `shadowSm/Md/Lg` live in
`skotiq_tokens.dart` (not decorations): keep as deprecated in wave 0, delete in wave 4;
their only legitimate successors are `popover` and `dialog`.

## 6. Icons

Lucide, unchanged. Sizes: 18 in rail and page-title, 15–16 in buttons and panel heads, 13 in chips
and instrument pills, 28 in empty states. Colour at rest `textMuted` (in panel heads, fields) or
`textSecondary` (rail, toolbar); on hover `textPrimary`; selected `primary`. Never `Icons.*`.
The equipment-profile icon is `LucideIcons.aperture` (there is no telescope glyph in the bundled
Lucide 0.257). No emoji anywhere in chrome.
