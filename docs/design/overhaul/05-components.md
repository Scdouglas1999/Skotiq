# 05 · Components

Every component lives in `packages/skotiq_ui` and is exported from `skotiq_ui.dart`. Each
one added or changed here MUST also get a section in `design_system_gallery.dart` (the
`design_system_gallery_missing` audit rule fires otherwise) and a golden in
`docs/design/goldens/`. Visual reference for all of them: `mockups/png/components.png`
(dark) and `components-light.png`.

Notation: **New** = create the file. **Change** = edit the existing widget in place, keep its
name and constructor parameters unless a parameter is listed under "Remove".

Naming rule: every public widget is prefixed `Skotiq` when a Flutter/Material class of the
same name exists (`SkotiqBanner`, `SkotiqFilterChip`, `SkotiqToolbar`); otherwise the
bare name is fine. Never ship a name that forces `hide` clauses in screens.

Files (all new files go under `packages/skotiq_ui/lib/src/components/` unless stated):
`skotiq_panel.dart` (SkotiqPanel, PanelHead), `readout.dart` (Readout, ReadoutRow,
KeyValueList), `segmented_control.dart`, `skotiq_toolbar.dart`, `form_row.dart`,
`list_rows.dart` (ListRow, DeviceRow), `candidate_row.dart`, `skotiq_banner.dart`,
`glass.dart`, `checklist.dart`, `night_band.dart`, `section_title.dart`, `instrument_pill.dart`,
`skotiq_icon_button.dart`; `layout/side_panel.dart`.

## 1. `SkotiqPanel` — New (`components/skotiq_panel.dart`)

Replaces `SkotiqCard` for every container that is not tappable.

```dart
SkotiqPanel({
  required Widget child,
  Widget? head,            // a PanelHead, see §2; rendered with 12 px gap below
  EdgeInsets padding = SkotiqTokens.paddingLg,   // 16
  bool flush = false,      // true → zero padding, clipped to radius (image panels)
  bool selected = false,   // 1 px primary@50% ring
})
```

Decoration: `SkotiqDecorations.panel(colors)` (03 §5). No hover. No onTap: a tappable container
is a **row** or a **candidate** (§9), not a panel.

`SkotiqCard` **Change**: keep for tappable cards (`onTap != null`) only; `CardVariant.elevated`
and `.subtle` become no-ops mapped to standard (delete their branches); `enableHover` remains but
hover = `surfaceHover` fill, not a border change. Add `@Deprecated` on `variant`.

## 2. `PanelHead` — New

One row: `[icon 15 muted] [eyebrow] … [trailing widgets gap 8]`. Height 20. Eyebrow is
`SkotiqTypography.eyebrow` in `textMuted`. Use for every panel label ("EQUIPMENT", "GUIDING").

## 3. `Readout` — New (`components/readout.dart`)

```dart
Readout({ required String? value, required String label, String? unit,   // null → "—" in textMuted
          ReadoutSize size = ReadoutSize.md,   // lg 28 / md 20 / sm 14
          Color? valueColor })
ReadoutRow({ required List<Readout> children, double gap = 28 })   // horizontal, top-aligned
KeyValueList({ required List<(String key, String value)> rows })    // 13 px key textSecondary / mono value right-aligned
```

Rules: value uses `readoutLg/Md/Sm`, label `readoutLabel` muted, unit at 60% size muted attached
with 2 px gap. `value == null` renders "—" muted. Always tabular figures.

## 4. Tabs — Change `AdaptiveTabBar` → underline style

- Tab: label 14 / 500, `textMuted` at rest, `textSecondary` hover, `textPrimary` selected; optional
  leading icon 15; optional trailing count chip (18 px high).
- Selected indicator: 2 px `primary` bar, square corners, spanning the label width plus 2 px on
  each side (the tab's 2 px horizontal padding), at the bottom of the 56 px header (it overlaps
  the header hairline by 1 px).
- Gap between tabs `space2xl` (24). No fills, no borders, no pills.
- Keep the existing overflow/scroll behaviour and `collapseLabelsWhenTight`.
- Delete `SubTabButton` (pill style; it has zero call sites in `skotiq_app` today). Where a screen needs a second-level switch INSIDE a panel
  (Sequencer palette: Nodes / Snippets / Targets), use `SegmentedControl` (§5).

## 5. `SegmentedControl` — New

Row of 13 / 500 labels, each 30 px high, padding 0 10, radius 6. Selected = `surfaceHover` fill
+ `textPrimary`; others `textMuted`. No outer container, no border. Only inside a panel or a
side panel, never in a page header.

## 6. Buttons — Change `SkotiqButton`

| Variant | Fill | Ink | Border | Hover |
|---|---|---|---|---|
| `primary` | `primary` | `onPrimary` | none | `accent` |
| `secondary` (rename of `outline`) | transparent | `textPrimary` | 1 px `borderHighlight` | `surfaceHover` fill |
| `ghost` | transparent | `textSecondary` | none | `surfaceHover` fill, `textPrimary` ink |
| `destructive` | transparent | `error` | 1 px `error` | `error` 14% fill |
| `start` **(new)** | `colors.startFill` | `colors.onStart` | none | lighten 4% |

Sizes: `small` 28, `medium` 32, `large` 40. Padding 10 / 12 / 18. Icon 15 (16 in large), gap 7.
Radius `radiusSm`. Text `button` / `buttonSm`. Disabled = 40% opacity, no colour change. Loading =
spinner replaces icon, label stays.

Add `SkotiqIconButton({icon, tooltip, size = IconButtonSize.md, selected})` with sizes
`md` 32 (top bar, page header, capture bar), `sm` 28 (toolbars), `strip` 36 (side-panel strip):
square, ghost styling, `selected` = `primary` at `opacityAccentTint` + `primary` icon. Every
`IconButton(` in screens (178 today) migrates to this in WAVE 3, screen by screen, so tooltips
become mandatory (the constructor requires `tooltip`).

Keep `ButtonVariant.outline` as a deprecated alias of `secondary` for one wave.

## 7. `SkotiqToolbar` — New

`SkotiqToolbar(groups: [[w, w], [w], …])`. Groups are separated by a 1 × 14 hairline with 6 px padding
either side. Children are `SkotiqIconButton(size: 28)` or small ghost buttons with labels. A
toolbar shows labels on the two or three most-used actions and icons-only for the rest; an
`overflow` parameter takes actions that go behind a `more-horizontal` menu when the width is
tight (measured with `LayoutBuilder`, not by count).

## 8. Fields — Change `SkotiqTextField`, `SkotiqDropdown`

Height 32 (28 with the NEW `dense: true` parameter). `field` decoration: `well` fill, radius 6,
1 px ring at `opacityPanelOutline` at rest, 1 px `primary` on focus, 1 px `error` on error. Leading icon 14 muted. Trailing unit 12 muted
(`suffix`). Numeric fields use `inputMono` with tabular figures. Label sits to the LEFT in a
`FormRow(label, child)` with a 84–104 px label column (`textSecondary` 13), not above the field.
Dropdown trailing chevron 14 muted; the open list uses `popover` decoration with 32 px rows.

## 9. Lists, rows, candidates

- `ListRow`: 13 px, 8 px vertical padding, hairline between rows, leading icon 15 muted, trailing
  mono timestamp muted. Hover `surfaceHover` when tappable.
- `DeviceRow` (Tonight → Equipment panel): `[icon 15] [name 14/500] … [ReadoutRow(size: sm, gap 18)]`.
- `Candidate` (Plan): a `SkotiqPanel` with a 6-column grid: score badge 44 × 44 radius 8
  (`success` 14% / `warning` 14% fill, 16 px mono 600), name + one muted line, two `Readout(sm)`,
  a window bar (8 px `well` track, `primary` span, 2 px `textPrimary` "now" tick), one button.
  Selected = `panelSelected` ring.

## 10. Chips and status

`SkotiqChip` **Change**: add `tone: ChipTone.neutral|success|warning|error|primary`
(default neutral), `dot: bool`, `icon`; keep `selected/onTap/enabled`. 22 px high, padding 0 8,
`radiusXs`, `buttonSm`-weight 12 px text. Fill: neutral = solid `surfaceHover`; other tones = the
tone colour at `opacityStatusFill`, text and dot in the tone colour. `StatusDot` **Change**: 7 px;
`live: true` adds the static 3 px halo in `success` at `opacityLiveHalo`.

`SkotiqFilterChip` **New**: 28 px, `filterChip` decoration, label + trailing chevron, opens a
menu.

### 10b. `InstrumentPill` — New

`InstrumentPill({IconData? icon, ChipTone? dotTone, required String value, VoidCallback? onTap,
bool live = false})`: 22 px high, padding 0 8, `radiusXs`, icon 13 `textMuted`, dot 7, value in
`bodySm` 500 `textPrimary`; hover `surfaceHover`. The instrument bar is built ONLY from these plus
`InstrumentSeparator` (1 × 14 hairline). `StatusPill` (icon + label + value + status enum) is
deprecated; `StatusPill` call sites outside the status bar migrate to `SkotiqChip`.

## 11. Banners, help and the end of tour toasts

`SkotiqAlert` **Change** → rename to `SkotiqBanner({required String title, String?
message, BannerTone tone = info, Widget? action, VoidCallback? onDismiss})`: inline block, 8 / 12
padding, `radiusSm`, fill = tone colour at `opacityHairline` (8%; `primary` for info), icon 16 in
tone, `title` in `bodySm` 600 `textPrimary` followed on the same line by `message` in `bodySm`
`textSecondary`, actions right-aligned (at most one `secondary sm` or `primary sm`, optional
dismiss `x`). Never floating, never stacked, never a toast. Global rule: ONE banner per problem across the app
(the catalog banner appears on Imaging OR the checklist, not both; see 06 §Tonight).

`ContextualTourPrompt` and `ContextualTourPromptOverlay` (`widgets/contextual_tour_prompt.dart`,
13 referencing files) are **deleted in wave 1** together with the help popover that replaces them
(both are shell work; 07 wave 1 step 3). The tours themselves (`TutorialOverlay`) stay and are launched from the top-bar
help button: clicking `help-circle` opens a `popover` with "Tour this screen", "Keyboard shortcuts",
"Open the manual for <screen>". First-run guidance is the checklist on Tonight.

`NotificationToastOverlay` stays for transient events (exposure complete, alert). Toasts: bottom-
right, `popover` decoration, 12 px radius, max 360 wide, auto-dismiss 6 s, max 3 stacked, never
for setup nags.

## 12. `EmptyState` — Change

Icon 28 `textMuted`, 6 px, title `sectionTitle`, 4 px, body `bodySm` `textSecondary` (one
sentence, max two lines), 10 px, ONE button (`secondary sm` unless it is the screen's main
action). Centred in its container, `max-width 360`. No panel around it unless the surrounding
layout is a grid of panels. Keep `EmptyState.compact`; REMOVE the `padding` parameter (padding is
internal: 24 all round, 16 in compact) and fix its callers.

## 13. Dialogs — Change `SkotiqDialog`

`dialog` decoration, widths 480 (confirm) / 640 (form) / 960 (wizard), padding 24, title
`sectionTitle`, body `bodySm` `textSecondary`, footer right-aligned with 8 px gap: `[ghost Cancel] [secondary alt]
[primary confirm]`. No icon square beside the title. Destructive confirm uses `destructive`.
Scrim `rgba(0,0,0,0.5)`. Enter confirms, Esc cancels. Below 768 px: full-width bottom sheet.

## 14. `Glass` — New

`Glass({child, padding})`: `glass` decoration (03 §5). Used ONLY inside an image `Stack`.
**Glass is anchored to the image, not the theme.** Astro frames are dark in every theme, so the
glass fill, border and the text/control colours INSIDE glass always come from the DARK palette
(wrap the child in a `Theme`/`SkotiqColors` override that supplies `SkotiqColors.dark`,
or the red-night palette when `isRedNight`). In the light theme a white glass over a black frame
was tested and rejected: fields went grey-on-grey (`mockups/png/imaging-light.png` before the fix). Contains
`ReadoutRow`, a histogram, a live-status line, or the capture bar. Max 4 glass elements on one
canvas. Corners of the canvas: top-left = frame stats, top-right = last-frame status, bottom-left
= (empty or secondary), bottom-right = histogram, bottom-centre = capture bar.

## 15. `SidePanel` — New (`layout/side_panel.dart`)

`SidePanel({double width = 320, List<SidePanelSection>? sections, required Widget child})`. When
`sections` is given, a 44 px vertical `strip` sits on the outer edge: one
`SkotiqIconButton(size: strip)` per section (selected = `opacityAccentTint` fill), tooltips
on hover; content area = width − 44. Without `sections` (Sequencer properties 300, Guiding 300,
Plan detail 380, Equipment 320) there is no strip and the content area = width. Content padding
16, sections separated by 16, each starting with a `SectionTitle`.

`SectionTitle({IconData? icon, required String title, Widget? trailing})` **New**: `[icon 15
muted] [sectionTitle] … [trailing]`, 8 px gap, 8 px below. Replaces the Imaging 4 × 2 tile grid and the Sequencer properties header.
Collapsible via the page-header `panel-right` button; width animates 220 ms.

## 16. `NightBand` — New (`components/night_band.dart`)

The signature timeline. `NightBand({sunset, astroDark, astroDawn, sunrise, now, moonSet?,
targetAltitudeCurve?, imageableWindow?, events: [(time, label)]})`. 52 px canvas + 30 px legend
inside a `SkotiqPanel(padding: 12/16/12)`. Canvas: horizontal gradient from
`colors.bandDusk` (0%) → `bandTwilight` (14%) → `bandDark` (50%) → `bandTwilight` (86%) →
`bandDawn` (100%), `radiusSm`; dashed 1 px verticals in `textPrimary` at `opacityHairlineStrong`
at astro dark/dawn; target altitude as a 1.5 px `primary` path with a `primary` 16% fill;
imageable window as a 4 px `primary` bar at the bottom; now = 1.5 px `textPrimary` vertical with a
6 px-diameter `textPrimary` dot at the top. Legend: `monoCaption` `textMuted` labels positioned at
their times (first left-aligned, last right-aligned, others centred); the "▲ now hh:mm" label in
`primary` on a second 15 px row so it never collides. Every colour is a token, so light and red
night follow automatically (the red-night bands are on the red axis by construction).

## 17. `Checklist` — New

`Checklist(steps: [ChecklistStep(title, detail, state: done|next|todo, action?)])`. Row: 28 px
numbered disc (`well` fill, `readoutBadge` at 12 px; done = `success` at `opacityStatusFill` +
check icon; next = `primary` at `opacityAccentTintHover` + 4 px `primary` `opacityHairline`
halo), title `bodyStrong` (done = struck through `textSecondary`), detail `bodySm`
`textSecondary`, trailing `secondary sm` button (the page's single primary lives in the hero),
`spaceMd` + 2 = 14 px vertical padding (allowed: it is the row's internal rhythm, rounded from
`spaceLg` − 2 for density), hairlines between rows.

## 18. Gallery and goldens

Add sections to `design_system_gallery.dart`: Panels & wells, Readouts, Underline tabs,
Segmented control, Toolbar, Chips, Banner, Empty state, Dialog, Glass, Side panel, Night band,
Checklist. Regenerate `docs/design/goldens/gallery-{dark,light,rednight}.png` on LINUX only for
the design PR (goldens are otherwise Windows-captured; do not commit Linux goldens for screens,
see memory note "verify-with-full-ci-gates").
