# Impl log — batch `ui-package`

Scope: `packages/skotiq_ui/**` (+ its test dir) + running
`tools/production/ui_consistency_audit.dart`. Baseline = `b07d91c9d`.

Resumed onto a partial tree left by a killed predecessor. Every item below was
re-verified against the baseline code before being kept; two pieces of the
predecessor's work were wrong and were corrected (see §4 and §5).

---

## 1. DELETE sweep

Re-proved zero callers freshly across `packages/ apps/ tools/ native/`
(`grep -rn "\b<Symbol>"`, `/build/` excluded) with the deletions applied — every
symbol below returns **0** references repo-wide:

`AccessibilityExampleScreen`, `FocusTraversalScaffold`, `FocusOrderedWidget`,
`ErrorMessageHelper`, `HistogramDisplay`, `CompactHistogramDisplay`,
`AnimatedValue`, `InterpolatedValue`, `ValueAnimationStyle`,
`AnimatedIconButton`, `AnimatedIconButtonGroup`, `AnimatedIconButtonItem`,
`FocusBuilder`, `WithTooltip`, `SkeletonCircle`, `CollapsibleSidebar`, and the
file stems `accessibility_example`, `histogram_display`, `animated_value`,
`animated_icon_button`, `focus_traversal_scaffold`, `collapsible_sidebar`.

Deleted (1745 lines of `lib/` + 124 lines of test):

| File / class | Lines |
|---|---|
| `lib/src/widgets/accessibility_example.dart` | 423 |
| `lib/src/components/histogram_display.dart` | 456 |
| `lib/src/components/animated_value.dart` | 273 |
| `lib/src/components/collapsible_sidebar.dart` | 213 |
| `lib/src/components/animated_icon_button.dart` | 180 |
| `lib/src/widgets/focus_traversal_scaffold.dart` | 80 |
| `ErrorMessageHelper` (in `error_dialog.dart`) | 78 |
| `FocusBuilder` (in `focus_ring.dart`) | 77 |
| `WithTooltip` (in `skotiq_tooltip.dart`) | 25 |
| `SkeletonCircle` (in `shimmer_loading.dart`) | 22 |
| `test/collapsible_sidebar_test.dart` | 124 |

`test/collapsible_sidebar_test.dart` existed only to exercise the deleted
component, so it went with it. Barrel exports removed one line at a time from
`lib/skotiq_ui.dart` (5 lines).

`flutter_riverpod` dropped from `pubspec.yaml` — `grep -rn riverpod` over
`packages/skotiq_ui` (lib + test + yaml) returns nothing.

### `scaled_config.dart` — NOT deleted (blocked)

`ScaledConfig.of` / `.maybeOf` are indeed unreferenced, but the file is not dead:
`ScaledConfigProvider` is mounted in production at
`packages/skotiq_app/lib/app.dart:196`. Deleting the file requires that
`skotiq_app` edit, which is outside this batch's scope, so the item is left
untouched and recorded blocked rather than half-done.

## 2. `SkotiqColors` value equality

`operator ==` / `hashCode` over all 19 fields.

`test/skotiq_colors_equality_test.dart` — 5 tests. Against baseline
`skotiq_colors.dart`, 3 fail (identical-field equality, full-`copyWith`
round trip, and the `ThemeData`-carrying-equal-palettes case that is the actual
rebuild-storm mechanism).

## 3. `SkotiqTheme` caching

`.dark` / `.light` / `.redNight` are `static final`; `darkWithAccent` /
`lightWithAccent` keep an LRU-of-1 per brightness keyed on the accent colour.

`test/skotiq_theme_caching_test.dart` — 6 tests. Against baseline
`skotiq_theme.dart`, 4 fail.

## 4. Showcase-primitive dedup

New `lib/src/widgets/_design_showcase_primitives.dart` (163 lines, deliberately
NOT exported) holds `ShowcaseSection` (`.plain` / `.boxed`) and `ShowcaseSwatch`
(`.gallery` / `.board` / `.boardCompact`); the board and the gallery both import
it. `design_system_gallery.dart` keeps its path and barrel string.

Two corrections to the predecessor's version:

- It had **added a fourth "Custom body" card** to the gallery's Cards grid. That
  is not behaviour-preserving — the extra grid row pushed the page down and
  `test/design_system_gallery_test.dart` could no longer hit the "View" button
  (tap landed at y=2259 in a 2200px tree). Removed.
- It had also merged the card specimen into the shared file. That removed the
  last literal `SkotiqCard` from `design_system_gallery.dart`, and the
  release gate requires that substring in **that** file:
  `dart tools/production/ui_consistency_audit.dart` reported
  `design_system_gallery_missing: 1`
  (`…:0:design_system_gallery_missing:component_marker:SkotiqCard`).
  The card specimen was moved back out into each file's own private class.

Verification:
- `dart tools/production/ui_consistency_audit.dart` → `design_system_gallery_missing`
  no longer appears; findings 120 → 119, remainder is the pre-existing
  `raw_material_color: 119`.
- Golden PNGs regenerate **byte-identical** to the committed ones
  (`git status docs/design/goldens` clean after `flutter test test/golden`) —
  that is the behaviour-preservation proof for the reference board.

## 5. `FocusRing` node ownership + tooltip show-delay

- `FocusRing` tracks `_ownsNode`; `didUpdateWidget` disposes the node it
  created when an external one replaces it, and `dispose()` keys off ownership
  rather than off the *incoming* widget's `focusNode`.
  `test/focus_ring_node_ownership_test.dart` — 4 tests; the first fails against
  baseline `focus_ring.dart`.
- `SkotiqTooltip`'s 300 ms hover delay is a cancellable `Timer` cancelled in
  `dispose()` / `_hideTooltip()` / the touch path, replacing an `async void`
  `Future.delayed`. `test/skotiq_tooltip_lifecycle_test.dart` — 3 tests;
  "disposing mid-delay leaves no pending timer" fails against baseline.

## 6. `AdaptivePanelLayout` doc vs code — code wins

Doc corrected to say desktop is `w >= 768` (`BreakpointTokens.isAtLeastDesktop`)
and the fixed-ratio tablet band is `600 <= w < 768`. No layout change.
`test/adaptive_panel_layout_test.dart`: the old `fixed split on tablet
(800x1000)` moved to 700x1000 and now asserts the resize handle is **absent**;
a new `800x1000 is the resizable split, not the fixed one` pins the handle's
presence at 800.

## 7. Naming / constant reconciliation

- `clampPanelWidth` → `panelWidthFromFraction`, with a `@Deprecated` alias that
  delegates. No caller inside `skotiq_ui` uses the alias (the parity test
  aside).
- `dialogMaxWidth` and `Responsive.dialogConstraints` now read
  `AdaptiveDialogConstraints.defaultWidthFraction` / `defaultHeightFraction`.
  `dialogMaxWidth` is unchanged in value (0.92); `Responsive.dialogConstraints`
  moves 0.90 → 0.92, so a `Responsive`-sized dialog is no longer 2% narrower
  than an `AdaptiveDialogConstraints`-sized one. `test/responsive_dialog_constraints_test.dart`
  gains `all three dialog-sizing helpers agree at the same viewport`.
- `Responsive.compactPhoneMaxWidth` now reads `SkotiqTokens.breakpointMobile`.

---

## Unplanned fix forced by §3 — `OnScreenAnimationGate` resume oscillation

Caching the three fixed `ThemeData`s made
`test/components/idles_at_rest_test.dart` → "the animation resumes when the
widget comes back on screen" go red. Chased to the bottom rather than papered
over:

1. The assertion is `transientCallbackCount > 0` after two **zero-duration**
   pumps. At baseline each `_host()` call built a *fresh* `ThemeData`, so
   `MaterialApp`'s own `AnimatedTheme` was mid-animation and owned that frame
   callback. The test was reading Material's ticker, not the progress bar's.
   Proved by holding a single `ThemeData` instance across both pumps against
   **baseline** source: the counter reads 0 there too.
2. With time-advancing pumps the bar does resume — but only advances on every
   *other* frame. `_handlePaint`'s post-frame resume calls `_sync()`, which
   opens a fresh unpainted-tick budget and throws away the very paint that
   triggered the resume; the gate then stops on the budget, resumes on the next
   paint, and repeats. One line in `on_screen_animation_gate.dart` restores
   `_paintedSinceLastTick = true` after the resume `_sync()`.

The test now advances time and additionally asserts the indeterminate sweep's
`FractionallySizedBox` alignment actually moves — an assertion no unrelated
ticker can satisfy. That assertion fails against the pre-fix gate.

---

## Verification

- `flutter test` in `packages/skotiq_ui`: **281 passed, 0 failed**
  (baseline for comparison: 279 passed / 2 failed once the theme caching landed).
- `dart analyze` in `packages/skotiq_ui`: 4 issues, all pre-existing
  `deprecated_member_use` infos for `SemanticsFlag.hasFlag` in
  `test/components/skotiq_button_disabled_semantics_test.dart` (untouched).
- `dart tools/production/ui_consistency_audit.dart`: `design_system_gallery_missing`
  absent (=0).
- `docs/design/goldens/gallery-{light,dark,rednight}.png` regenerate identical.

## For the orchestrator (outside this batch's scope)

- 14 free-function call sites in `packages/skotiq_app` now resolve to the
  deprecated `clampPanelWidth` alias and will emit `deprecated_member_use`
  infos: `diagnostics/…/content_layout.dart:106`,
  `imaging/centering_dialog.dart:364`,
  `planner/widgets/scheduler_tab_content.dart:413`,
  `planetarium/widgets/redesign/planetarium_shell.dart:350`,
  `onboarding/steps/filter_wheel_step.dart:255,261`,
  `planetarium/planetarium_screen/layouts.dart:318,324,332`,
  `planner/planner_screen_parts/_candidate_list.dart:358,665`,
  `widgets/catalog_overlay_widget.dart:250,687,752`,
  `widgets/catalog_overlay_widget/details_panel.dart:20`.
- `Responsive.dialogConstraints` widened 0.90 → 0.92; any `skotiq_app`
  golden that sizes a dialog through it will shift by 2% and needs a deliberate
  regeneration.
- `ScaledConfigProvider` at `packages/skotiq_app/lib/app.dart:196` publishes
  an `InheritedWidget` nothing reads; removing it there unblocks deleting
  `packages/skotiq_ui/lib/src/utils/scaled_config.dart` (208 lines).
