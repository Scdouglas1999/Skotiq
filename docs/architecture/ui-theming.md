# UI Theming — Architecture Guide

Skotiq's design system lives in `packages/skotiq_ui`. Widgets resolve colors at runtime from the active `ThemeData`; do not pass palette objects down the tree unless a parent already holds them for layout reasons (e.g. settings scaffolding).

## The design contract

**`docs/design/overhaul/` is the design contract.** It is the "Observatory" design: the values, the components, the shell and the screen layouts the app is built to. This file explains the *mechanism* — where the layers live and how a widget reaches a colour. What a value should BE is decided over there, and where the two disagree, `docs/design/overhaul/` wins.

| File | What it decides |
|---|---|
| [`overhaul/README.md`](../design/overhaul/README.md) | Reading order, scope and non-goals, how to regenerate the mockups |
| [`overhaul/01-audit.md`](../design/overhaul/01-audit.md) | The shipped-UI findings the overhaul answers, with screenshot evidence and what is now resolved |
| [`overhaul/02-design-language.md`](../design/overhaul/02-design-language.md) | The five rules, the vocabulary (panel, well, readout, rail, instrument bar), the signature moments |
| [`overhaul/03-tokens.md`](../design/overhaul/03-tokens.md) | Every colour, type, space, radius, size, motion and opacity value, and the JSON → Dart name map |
| [`overhaul/04-shell.md`](../design/overhaul/04-shell.md) | Top bar, rail, page header, instrument bar, narrow layout, command palette |
| [`overhaul/05-components.md`](../design/overhaul/05-components.md) | Every shared component: API, sizes, states, what it replaces |
| [`overhaul/06-screens.md`](../design/overhaul/06-screens.md) | Screen-by-screen layout and removals |
| [`overhaul/07-implementation-waves.md`](../design/overhaul/07-implementation-waves.md) | The wave plan, the rules for every wave, the verification protocol, what shipped |

`docs/design/overhaul/design-tokens.json` is the machine-readable source of truth for the values; `tools/check_tokens.py` validates it (WCAG AA on every surface, the red-axis rule) and emits the mockups' CSS. `test/design_tokens_sync_test.dart` in `skotiq_ui` fails if the JSON and the Dart drift apart.

Three rules from 02 that everything below assumes: depth comes from **tone, not lines** (`background → surface → surfaceElevated → surfaceOverlay`, plus a darker `well` for data), nesting stops at **panel → well**, and a measurement is a **`Readout`**, never body text.

## Layer stack (bottom → top)

| Layer | Location | Role |
|-------|----------|------|
| **Colors** | `theme/skotiq_colors.dart` | Semantic palette (`SkotiqColors`) registered as a `ThemeExtension` |
| **Tokens** | `theme/skotiq_tokens.dart` | Spacing, radii, component sizes, motion, opacity |
| **Shell metrics** | `tokens/shell_chrome_metrics.dart`, `tokens/breakpoint_tokens.dart` | Chrome heights and widths (top bar, instrument bar, rail, page header, side panel) and the breakpoints |
| **Typography** | `theme/skotiq_typography.dart` | Type scale derived from the active colors |
| **Theme** | `theme/skotiq_theme.dart` | Assembles `ThemeData` + `ColorScheme` from the colors; `AppearanceAccents` per-theme swatches |
| **Decorations** | `theme/skotiq_decorations.dart` | Reusable `BoxDecoration` factories (panel, well, field, popover, dialog, glass); shadows live in these factories, not in a token |
| **Components** | `lib/src/components/`, `lib/src/layout/` | Panels and wells, readouts, buttons, fields and form rows, chips and pills, banners, list rows, side panel, night band, checklist |
| **Domain `*Colors`** | e.g. `theme/skotiq_chart_colors.dart`, `theme/annotation_type_colors.dart` | Fixed hues, or theme-derived colors, for charts, annotations and protocol badges |

Barrel exports: `skotiq_theme_system.dart` for the theme layers, `skotiq_ui.dart` for the components.

Radii are 4 / 6 / 8 / 12 and nothing else — chips and badges / controls, fields and wells / panels and rail items / dialogs and popovers. Do not add a value; use the nearest token. A raw `BorderRadius.circular(<number>)`, a raw `TextStyle(fontSize: <number>)`, or a `Color(0x…)` outside painters, charts and imagery is an audit finding, not a style choice: `tools/production/ui_consistency_audit.dart` and `tools/production/design_tokens_audit.dart` enforce this.

## Resolving colors in widgets

**Rule:** use `SkotiqColors.of(context)` (or `context.skotiqColors`) — not prop-drilling.

```dart
final colors = SkotiqColors.of(context);
// or
final colors = context.skotiqColors;
```

`SkotiqTheme` registers `SkotiqColors` on `ThemeData.extensions`. Presets: `SkotiqColors.dark`, `.light`, `.redNight`, plus `darkWithAccent` / `lightWithAccent` for custom accent colors.

Do **not** import static presets inside leaf widgets unless building a theme variant. Do **not** thread `SkotiqColors colors` through every constructor when `BuildContext` is available.

## Switch components — when to use which

| Widget | Package | Use when |
|--------|---------|----------|
| **`SkotiqSwitch`** | `skotiq_ui` | Bare toggle only — table cell, toolbar, compact inline control |
| **`SkotiqSwitchRow`** | `skotiq_ui` | Label (+ optional tooltip) + switch, standing on its own inside a panel |
| **`FormRow`** | `skotiq_ui` | The default for any labelled control: label in the LEFT column, control on the right (05 §8). A switch in a form is a `FormRow` holding a `SkotiqSwitch` |
| **`SettingsSwitch`** | `skotiq_app` | Settings persistence: wraps `SkotiqSwitch` with 300 ms debounced `onChanged` so rapid toggles coalesce before DB writes |
| **`SettingRow`** | `skotiq_app` | Full settings row: leading icon, title, trailing control (compose with `SettingsSwitch`, `SettingsDropdown`, etc.) |

Prefer `SkotiqSwitch` over Material `Switch`. Theme `SwitchThemeData` exists only as a fallback via `SkotiqSwitchStyle.switchThemeData`. Explanatory prose does not go under a control: the help popover (05 §11) is where that lives.

## Domain color classes vs core palette

Add to **`SkotiqColors`** when the color is **semantic and theme-wide** — surfaces, borders, status (success/warning/error), primary/accent, text roles.

Add a **domain `*Colors` class** when:

- The hue is **fixed by domain meaning** (e.g. galaxy vs nebula annotation types, chart series indices)
- Multiple unrelated features share the same specialized palette (PSF heatmap gradients, backend protocol badges)
- The color **derives from** `SkotiqColors` for interactive states but is not a general UI token (`AnnotationStatusColors`, `SkotiqChartColors.selectedFrame`)

Keep domain classes in `packages/skotiq_ui/lib/src/theme/` and export them from `skotiq_theme_system.dart`.

The filter palette (L / R / G / B / Ha / OIII / SII) is a domain palette: legal in charts and thumbnails, never on chrome. The same rule is why a handful of `Color(0x…)` literals survive the audit — equipment-profile identity swatches, a diverging ramp endpoint, a fixed-palette annotation dialog. Those are data. Making them follow the theme would turn a data colour into a chrome colour, which is worse than the literal.

## Red night vision mode

`SkotiqColors.redNight` sets `useDarkOnPrimary: true` so switch thumbs and primary buttons use `background` (dark red-black) instead of white — white on red would ruin dark adaptation. Dark and light themes use white `onPrimary`. Red night is a wavelength constraint, not a tint: G == B on every colour, `check_tokens.py` fails if a value leaves the red axis, and `AppearanceAccents.forTheme(AppThemeMode.redNight)` returns an empty list so the accent picker is hidden rather than offering a hue that would break the constraint.

**Platform dialogs are outside the theme, and this is a stated limitation.** Every window Skotiq paints itself is red under red night — measured on the Darkroom flow, where sampling the whole window with the image viewport masked out found zero chrome pixels outside hue 335°–25°. A window the *platform* paints is not: `file_selector` on Linux hands off to the GTK file chooser, and the chooser that opens behind `Import .skrecipe` renders blue-grey with light text (≈24% of its sampled pixels at hue ≈225°, measured on this build). Nothing in `skotiq_ui` can retint it — it is not a Flutter surface. So red night preserves dark adaptation across the app's own surfaces, and a file chooser is a bright interruption of it. Replacing that hand-off with an in-app path picker for the flows that use it is an owner decision, not something this document claims is done.

**Image data is exempt, by design.** Chrome takes the theme; pixels do not. The Darkroom viewport, image previews, thumbnails and every other surface that paints *captured data* render their true colours under every theme, red night included — retinting them would falsify the very pixels the operator is judging, and a colour cast the theme invented is indistinguishable from one the stack introduced. Everything drawn *around* the image — labels, overlay strokes, histograms, controls — is chrome and takes the theme as usual. The one thing an app-drawn glyph must never be is a colour emoji: the platform's emoji font paints those, no theme can retint them, and a literal `🔭` in the status bar was the only non-red cluster in a red-night window. Use a `SkotiqIcons` glyph with a theme colour instead. An emoji the *operator* typed (a profile badge, a note) is their data and is printed as typed.

The bundled fonts have their own hole: no `′`, no `″`, no thin space (U+2009). Write arcminutes and arcseconds with ASCII `'` and `"`, and do not group thousands — `13000`, never `13 000`.

## Visual QA

Use **`SkotiqDesignSystemGallery`** (`lib/src/widgets/design_system_gallery.dart`) to preview the kit across themes. Every component in 05 has a section there — the `design_system_gallery_missing` audit rule fires otherwise. Widget tests in `packages/skotiq_ui/test/design_system_gallery_test.dart` pump the gallery in dark, light and red night.

Its goldens — `docs/design/goldens/gallery-observatory-{dark,light,rednight}.png` — are captured on **Linux** and may be regenerated there. Every other golden in the repo (screens, surfaces, morning report) is **Windows**-captured: regenerate those on the rig, and never commit a Linux re-render of one. See [`docs/testing/golden-tests.md`](../testing/golden-tests.md).

## Theme selection (app layer)

Desktop **`SkotiqApp`** reads the persisted theme from `appSettingsProvider` (`settings.theme`: `dark`, `light`, `redNight`) and the optional accent color. The swatches Settings › Appearance offers come from `AppearanceAccents.forTheme(mode)`, so each theme shows the set that clears contrast against its own surfaces. See the comments on the providers in `skotiq_theme.dart`.
