# Release-pass map — `packages/skotiq_ui` (design system)

Read-only mapping pass. No source file was modified.

Scope: `packages/skotiq_ui/` — 68 Dart files under `lib/`, 22,757 lines
including tests. Nothing in this package is generated (no `*.g.dart`,
`*.freezed.dart`, or `frb_generated`); every file below is hand-written.

The package has been through several prior audits and it shows: animation
lifecycle, focus semantics, tooltip edge clamping and overflow handling are all
carefully done and commented with the incident that motivated them. The
remaining debt is concentrated in **surface area that nothing consumes** and in
**two parallel copies of the responsive/scaling vocabulary**.

Headline numbers:

| Category | Amount |
|---|---|
| Oversized files (>1000 lines Dart) | 1 file, 1092 lines |
| Design-showcase surface exported from the production barrel | 1930 lines (2 files) |
| Dead exported components (no caller anywhere) | ~1830 lines across 7 files |
| Parallel breakpoint/scaling vocabularies | 3 (`SkotiqTokens`, `BreakpointTokens`, `ScaledConfig`) |
| Same-named, different-signature exported functions | 2 × `clampPanelWidth` |
| Unused pubspec dependency | `flutter_riverpod` |

---

## 1. Oversized files

### 1.1 `lib/src/widgets/design_reference_board.dart` — 1092 lines (verified `wc -l`)

**Not generated.** Hand-written. It is a single static "one canvas" render of the
whole design language — semantic palette, 4 domain palettes, the full 29-entry
typography scale, and a component pass — used as the source widget for the
committed golden screenshots.

**Why it is big:** everything is in one file: the public board widget, six
section widgets, and seven private building blocks, plus two large inline data
tables (17 swatch tuples at L211-229, 29 typography specimen tuples at L407-492).

**Who uses it:** only `test/golden/design_gallery_golden_test.dart` (L26, L39,
L52 — light/dark/red-night). No production screen references it. Verified:
`grep -rn "DesignReferenceBoard" --include="*.dart" .` returns only the
definition, its own doc comment, and those three golden-test lines.

**Concrete split plan (behavior-preserving).** Create
`lib/src/widgets/design_reference_board/` and turn the current file into a
3-line `part`-free re-export shell so the barrel export
(`skotiq_ui.dart:69`) and the golden test both keep working unchanged:

| New file | Moves in | Lines (approx) |
|---|---|---|
| `design_reference_board/board_shell.dart` | `SkotiqDesignReferenceBoard` (L37-160) — `build`, `_boardHeader`, `_twoColumn`; imports the section widgets below | 125 |
| `design_reference_board/board_primitives.dart` | `_BoardSection` (L166-198), `_SubLabel` (L905-918), `_Swatch` (L920-972), `_GradientBar` (L974-1008), `_DotChip` (L1010-1052), `_CardSpecimen` (L1054-1092), and the three `_noop*` callbacks (L901-903). Change the leading `_` to no prefix and mark the library `@internal`, or keep `_` and use `part of` — **prefer `part of`** so no new public names appear in the package | 300 |
| `design_reference_board/palette_sections.dart` | `_SemanticPaletteSection` (L204-242) + `_DomainPaletteSection` (L248-393) including `_objectTypeLabel` / `_backendLabel` | 195 |
| `design_reference_board/typography_section.dart` | `_TypographyScale` (L399-515) + `_TypeRow` (L517-564) — this is where the 29-entry specimen table lives | 170 |
| `design_reference_board/component_sections.dart` | `_ComponentsSection` (L570-699), `_StatusAndFeedbackSection` (L705-833), `_LayoutPrimitivesSection` (L839-895) | 330 |

**What stays:** `lib/src/widgets/design_reference_board.dart` keeps only
`library; part 'design_reference_board/…'` × 5 (or plain re-export of
`board_shell.dart` if the private widgets are converted to `part`s of the shell).
Either way `SkotiqDesignReferenceBoard` keeps its current import path, so
`skotiq_ui.dart:69` and `test/golden/design_gallery_golden_test.dart` need
**zero** edits. The golden PNGs under `docs/design/goldens/` must be byte-identical
after the split — that is the acceptance test for "behavior preserving".

**Do this only if the board survives §2.1.** If the board and the gallery are
merged, the split is wasted work — sequence §2.1 first.

### 1.2 Files under the threshold but worth noting

Nothing else in `lib/` exceeds 1000 lines. The next largest are
`design_system_gallery.dart` (838), `adaptive_panel_layout.dart` (718),
`phd2/guide_graph_advanced.dart` (629), `phd2/brain_settings_panel.dart` (563),
`update_dialog.dart` (557). `adaptive_panel_layout.dart` in particular is dense
but cleanly sectioned (state machine, two split builders, phone sheet, segmented
control) and does **not** need splitting.

---

## 2. Duplication inside `packages/skotiq_ui`

### 2.1 Two design-showcase surfaces — 1930 lines total, both exported to production

| | `design_reference_board.dart` | `design_system_gallery.dart` |
|---|---|---|
| Lines | 1092 | 838 |
| Type | `StatelessWidget`, interaction-free | `StatefulWidget`, interactive (`_actionCount`, dropdown, switch, tabs) |
| Renders | palette, domain palettes, full type scale, components, layout primitives | palette, partial type scale, components, chips/status, alerts |
| Consumers | `test/golden/design_gallery_golden_test.dart` only | `test/design_system_gallery_test.dart` only |
| Exported | `skotiq_ui.dart:69` | `skotiq_ui.dart:68` |

Both re-declare the same palette-swatch and typography-specimen widgets:
`_Swatch` (board L920) vs `_PaletteSwatch` (gallery L80+), `_TypeRow`
(board L517) vs `_TypographySpecimen` (gallery L116+), `_BoardSection`
(board L166) vs `_GallerySection` (gallery L74+).

**Canonical survivor: `design_system_gallery.dart`.** It is load-bearing for a
release gate and cannot be moved or renamed — `tools/production/ui_consistency_audit.dart`
hard-codes the path at L468, the barrel-export string at L490, the test path at
L471, and a list of required substrings (`'Buttons'`, `'Cards'`, `'Inputs'`,
`'Tabs'`, `'Chips and Status Pills'`, `'Alerts'`, `'SkotiqButton'`,
`'SkotiqCard'`, `'SkotiqTextField'`, `'SkotiqDropdown'`,
`'SubTabButton'`, `'StatusPill'`, `'StatusPillStatus.success'`,
`'StatusPillStatus.inactive'`, `'SkotiqAlert'`) that must all appear in
**that one file**. `public_release_gate.dart:189` reports its status.

**Merge plan:** keep both widgets (they serve different jobs — deterministic
golden vs interactive QA), but collapse the duplicated primitives. Move
`_Swatch`, `_TypeRow`/`_TypographySpecimen`, and the section shell into the new
`design_reference_board/board_primitives.dart` from §1.1, make them
package-private-but-shared (`lib/src/widgets/_design_showcase_primitives.dart`),
and have the gallery import them. Expected saving ≈ 250 lines. **Hard constraint:
after the merge, `dart tools/production/ui_consistency_audit.dart` must still
report `designSystemGalleryMissing=0`** — verify by running it, not by reading it.

Effort: medium.

### 2.2 Two exported functions both named `clampPanelWidth`, different semantics

- `lib/src/layout/adaptive_layout.dart:22` — top-level
  `double clampPanelWidth(double available, {required double fraction, required double min, required double max})`.
  Pure arithmetic, asserts on inputs. Exported via `skotiq_ui.dart:18`.
- `lib/src/utils/adaptive_dialog_constraints.dart:63` — static
  `AdaptiveDialogConstraints.clampPanelWidth(BuildContext context, {required double designWidth, double minWidth = 200, double? maxWidth, double maxWidthFractionOfViewport = 0.4})`.
  Reads `MediaQuery`, orders bounds before clamping. Exported via `skotiq_ui.dart:24`.

Both are live (`clampPanelWidth` free function: 6+ call sites in
`skotiq_app`; `AdaptiveDialogConstraints`: 74 files reference the class).
A reader who sees `clampPanelWidth(...)` in a screen cannot tell which one it is
without checking the argument shape.

**Recommendation:** keep both implementations (they answer different questions)
but rename the free function to `panelWidthFromFraction` and leave a
`@Deprecated('renamed to panelWidthFromFraction')` alias for one release.
Effort: small.

### 2.3 Three dialog-sizing helpers with two different viewport fractions

- `AdaptiveDialogConstraints.hybrid` / `.dialogSize` — `0.92` width, `0.85` height
  (`utils/adaptive_dialog_constraints.dart:12-13`).
- `dialogMaxWidth(context, designMax)` — `0.92` width, no height
  (`layout/adaptive_layout.dart:39-42`).
- `Responsive.dialogConstraints(...)` — `0.9` width, `0.85` height defaults
  (`utils/responsive_utils.dart:195-203`).

A dialog sized with `Responsive.dialogConstraints` is 2% narrower than one sized
with `AdaptiveDialogConstraints.hybrid` at the same design width, for no stated
reason. **Canonical survivor: `AdaptiveDialogConstraints`.** Point
`dialogMaxWidth` at `AdaptiveDialogConstraints.defaultWidthFraction` and change
`Responsive.dialogConstraints`'s `maxWidthPercent` default from `0.9` to that
same constant. Effort: small. (This one changes pixel output — regenerate any
affected goldens deliberately.)

### 2.4 `ScaledConfig` is a memoized clone of `Responsive` — and nothing reads it

`lib/src/utils/scaled_config.dart` (208 lines) re-implements, as an
`InheritedWidget`, five helpers that already exist as statics on `Responsive`:

| `ScaledConfig` | `Responsive` |
|---|---|
| `spacing(base)` L104 | `Responsive.spacing(ctx, base)` L306 |
| `fontSize(base)` L107 | `Responsive.fontSize(ctx, base)` L315 |
| `iconSize(base)` L113 | `Responsive.iconSize(ctx, base)` L328 |
| `edgeInsets({...})` L116 | `Responsive.edgeInsets(ctx, {...})` L337 |
| `gridColumns({minItemWidth, maxColumns})` L183 | `Responsive.gridColumns(ctx, {...})` L443 |

See §3.5 — the reading half of this API has zero callers, so this is a delete,
not a merge.

### 2.5 Legacy `ResizablePanel` vs unified `AdaptivePanelLayout`

`lib/src/widgets/resizable_panel.dart` is described by
`adaptive_panel_layout.dart:42-43` as the "old" split that `AdaptivePanelLayout`
replaces. Both are still exported (`skotiq_ui.dart:19` and `:63`) and both
are still used in `skotiq_app`: `ResizablePanel` at
`planetarium_screen/layouts.dart:639`, `settings_screen.dart:446`,
`sequencer_screen_parts/collapsible_panel.dart:148`,
`equipment_screen/sidebar_onboarding.dart:115`; `AdaptivePanelLayout` in
imaging/framing/planetarium. The migration is genuinely half-finished, not
abandoned.

**Canonical survivor: `AdaptivePanelLayout`.** This is a `skotiq_app` work
item, not a `skotiq_ui` one — the design system's job is to stop advertising
both. Recommendation for this package: mark `ResizablePanel` `@Deprecated` with
a pointer to `AdaptivePanelLayout(phoneStrategy: …)` so the remaining 4 call
sites surface as analyzer warnings. Effort: small here, medium downstream.

### 2.6 `CollapsibleSidebar`: design-system version unused, app has a private clone

`lib/src/components/collapsible_sidebar.dart` (213 lines, exported at
`skotiq_ui.dart:53`) has exactly one consumer: its own test
(`test/collapsible_sidebar_test.dart:31`). Meanwhile
`packages/skotiq_app/lib/screens/equipment/equipment_screen/sidebar_onboarding.dart:10`
declares a **private `_CollapsibleSidebar`** with the same name and the same
shape (`didUpdateWidget` at L55, used at `equipment_screen.dart:229`).

Someone re-implemented the component rather than importing it. Either adopt the
design-system one in `sidebar_onboarding.dart` or delete the design-system one —
but do not ship both. Effort: small.

---

## 3. Dead code

Method for every item below: `grep -rn "<Symbol>" --include="*.dart" packages apps tools`
with `/build/` excluded, then subtract the defining file's own lines. Where a
symbol survives only inside its own file (a second widget in the same file
referencing the first) that is called out.

I checked and **cleared** several tempting candidates: `SkotiqTouchTarget`
(9 call sites — the class is named `SkotiqTouchTarget`, not `TouchTarget`),
`shortcutLabel` (planetarium search header + 3 tests), `showAdaptiveModal` /
`PhoneModalMode` (6+ sheets), `EmptyState` (5+ screens),
`clampPanelWidth`/`dialogMaxWidth` (6+ each), `SkeletonBox` (51),
`SkotiqToast`/`SkotiqToastHelper` (1/10 — thin but live). None of those
are dead.

### 3.1 `lib/src/widgets/accessibility_example.dart` — 423 lines, **not even exported**

Declares `AccessibilityExampleScreen` (L19). It is absent from
`skotiq_ui.dart` entirely, and `grep -rn "accessibility_example\|AccessibilityExample"`
across `--include="*.dart" --include="*.md"` returns **only the six lines inside
the file itself**. It is a demo screen that ships in the package source and is
unreachable from every entry point.

Delete the file. It is also the only thing keeping §3.2 and §3.3 alive, so
delete it first.

### 3.2 `FocusTraversalScaffold` + `FocusOrderedWidget` — `lib/src/widgets/focus_traversal_scaffold.dart` (80 lines)

Exported at `skotiq_ui.dart:67`. Total repo references: 5 — the two class
declarations, the file's own doc comment, and `accessibility_example.dart:138`
and `:230/278/287/296/305`. Once §3.1 is deleted, zero callers remain.

### 3.3 `ErrorMessageHelper` — `lib/src/widgets/error_dialog.dart:207`

Sole caller is `accessibility_example.dart:101`. Note that `ErrorDialog` itself
(same file, L13) **is** live (`stacking_panel.dart:272`, `:283`, and others), so
delete the helper class only, not the file.

### 3.4 `HistogramDisplay` + `CompactHistogramDisplay` — `lib/src/components/histogram_display.dart` (456 lines)

Exported at `skotiq_ui.dart:47`. All 8 repo references are inside the file:
the `HistogramDisplay` declaration/state/`didUpdateWidget`, and
`CompactHistogramDisplay` (L398) instantiating `HistogramDisplay` at L442.
No test, no screen. The imaging screen draws its own histogram elsewhere.

Includes three `CustomPainter`s (`_GridPainter` L191, `_HistogramPainter` L~230,
`_RgbHistogramPainter` L~330) and hard-coded RGB constants at L8-10 that bypass
the token system — a second reason to remove rather than adopt.

### 3.5 `ScaledConfig` (the reading half) — `lib/src/utils/scaled_config.dart` (208 lines)

`ScaledConfigProvider` **is** mounted in production at
`packages/skotiq_app/lib/app.dart:196`. But
`grep -rn "ScaledConfig\.of\|ScaledConfig\.maybeOf"` returns **only three doc-comment
lines inside `scaled_config.dart` itself** (L7, L17, L46). Nothing anywhere reads
the `InheritedWidget`.

So the app pays for an extra `InheritedWidget` + `MediaQuery` dependency in the
root tree to publish a value no descendant consumes. Delete the file and remove
the `ScaledConfigProvider` wrapper at `app.dart:196` (a `skotiq_app` edit —
hand that half to the app owner). See §2.4: everything it computes is already on
`Responsive`.

### 3.6 `AnimatedValue`, `InterpolatedValue`, `ValueAnimationStyle` — `lib/src/components/animated_value.dart` (273 lines)

Exported at `skotiq_ui.dart:48`. All references are inside the file
(declarations, `didUpdateWidget`, and a `[AnimatedValue]` doc link at L176). Zero
consumers, zero tests.

### 3.7 `AnimatedIconButton`, `AnimatedIconButtonGroup`, `AnimatedIconButtonItem` — `lib/src/components/animated_icon_button.dart` (180 lines)

Exported at `skotiq_ui.dart:46`. All 11 references are inside the file; the
only non-declaration one is `AnimatedIconButtonGroup` instantiating
`AnimatedIconButton` at L160. Zero external consumers. Note `AccessibleIconButton`
(`widgets/accessible_icon_button.dart`) is the one the app actually uses — 6+
call sites — so this is a redundant second icon-button as well as dead.

### 3.8 `FocusBuilder` — `lib/src/components/focus_ring.dart:152` and `WithTooltip` — `lib/src/components/skotiq_tooltip.dart:381`

Zero references outside their own files. `FocusRing` (same file, 8 external
refs) and `SkotiqTooltip` (18) are both live — delete only the unused
sibling class in each file.

### 3.9 `SkeletonCircle` — `lib/src/components/shimmer_loading.dart:190`

Zero external references. `ShimmerLoading` (27), `SkeletonBox` (51) and
`SkeletonText` (10) are all live. Small; bundle with §3.8.

### 3.10 `flutter_riverpod` is an unused dependency

`pubspec.yaml` declares `flutter_riverpod: ^2.5.1` as a **runtime** dependency.
`grep -rn "riverpod" --include="*.dart"` across the whole package (lib + test)
returns **nothing**. Remove the dependency. This also removes a false
architectural signal — the design system should not be able to reach for
providers.

**Dead-code total: ~1830 lines across 7 files plus 4 orphan classes, and one
dependency.** Ordering matters: §3.1 → §3.2/§3.3, then the rest are independent.

Caveat for the implementer: this is a `publish_to: 'none'` internal package with
no external consumers, so "no caller in this repo" is sufficient evidence of
dead. There are no headless routes, FRB exports, or registry lookups in this
package (verified: no `dart:ffi`, no route tables, no reflection).

---

## 4. Performance risks

### 4.1 A custom accent color makes the whole app rebuild on every root frame — HIGH

Chain, all verifiable:

1. `packages/skotiq_ui/lib/src/theme/skotiq_colors.dart:6` —
   `class SkotiqColors extends ThemeExtension<SkotiqColors>` declares
   **no `operator ==` and no `hashCode`**. (Confirmed: the file has `copyWith`
   at L194 and `lerp` at L254 and nothing else.) Instances therefore compare by
   identity.
2. `skotiq_colors.dart:138` — `darkWithAccent(Color)` returns
   `dark.copyWith(primary: …)`, i.e. **a fresh instance on every call**.
   Same for `lightWithAccent` at L147.
3. `skotiq_theme.dart:114` / `:122` — `SkotiqTheme.darkWithAccent` /
   `lightWithAccent` call those and build a whole new `ThemeData` via
   `_buildTheme` (L129), including a fresh `TextTheme` from
   `SkotiqTypography.textTheme(colors)`.
4. `skotiq_theme.dart:58-64` — `resolveSkotiqThemeData` routes to the
   `*WithAccent` variants **whenever `accentColorHex` parses**.
5. `packages/skotiq_app/lib/app.dart:121` calls `resolveSkotiqThemeData`
   **inside `build()`** of the root `ConsumerWidget`, which watches ~10 providers
   (`app.dart:100-114`) — sequence-library sync, remote editor sync, master
   mirror, narrator, settings.

Result: for any user who has picked an accent color, every one of those provider
ticks produces a `ThemeData` whose `extensions` map holds a **new**
`SkotiqColors`. `ThemeData.==` compares extensions by value, which is
identity here, so it returns false; `Theme`'s `updateShouldNotify` fires; and
every widget depending on the theme rebuilds. `context.skotiqColors` /
`SkotiqColors.of(...)` appears at **1043 sites** across `packages/` and
`apps/` — that is the blast radius.

On the default (no accent) path `SkotiqColors.dark` is a `static const`
(L68), so it is canonicalized and the comparison succeeds — which is exactly why
this has stayed invisible: it only bites users who changed the accent color.

Fix direction: add `operator ==` / `hashCode` to `SkotiqColors` (19 fields),
**and** memoize `resolveSkotiqThemeData` on `(themeSetting, accentColorHex)`
so the `ThemeData` is not reallocated per frame either. The `==` is the design
system's responsibility; the memo can live in either package.

Verification for the implementer: set an accent color, then instrument
`_InheritedTheme.updateShouldNotify` (or count rebuilds of any leaf that reads
`context.skotiqColors`) while a sequence is running. Before the fix it
should tick with the providers; after, it should not.

### 4.2 Root theme reconstruction even without an accent — MEDIUM

Independent of §4.1: `SkotiqTheme.dark` / `.light` / `.redNight`
(`skotiq_theme.dart:103`, `:106`, `:110`) are **getters**, not cached
statics. Each read runs `_buildTheme` (L129) building a `ColorScheme`, a full
`TextTheme`, and ~30 sub-themes. Because `app.dart:121` is in `build()`, that
whole construction happens on every root rebuild, and is then thrown away when
`ThemeData.==` (a ~100-field deep comparison) reports equality.

Fix: `static final ThemeData dark = _buildTheme(...)` for the three fixed
themes, and an LRU-of-1 cache keyed on the accent color for the two `*WithAccent`
factories. Low risk — the inputs are compile-time constants.

### 4.3 The guide graph can never skip a repaint — MEDIUM

`lib/src/widgets/phd2/guide_graph_advanced.dart:620` —
`_GraphPainter.shouldRepaint` starts with `data != oldDelegate.data`, a
reference comparison on `List<GuideDataPoint>`; `GuideDataPoint` (L6) has no
`==` either. The sole caller,
`packages/skotiq_app/lib/screens/guiding/guiding_screen_parts/desktop_sections.dart:627-634`,
builds the list with `graphData.map((p) => GuideDataPoint(...)).toList()` **in
`build()`** — a new list identity every frame.

So the graph fully repaints on every rebuild of the guiding panel, including
rebuilds caused by unrelated state (RMS readout, scale dropdown, telemetry
ticks). Each repaint runs `_drawTrace` (L~576) which iterates the **entire**
buffer and `continue`s past out-of-window points rather than starting from the
window — O(total history) per repaint, not O(visible) — plus five `TextPainter`
layouts in `_drawXAxisLabels` and up to five in `_drawYAxisLabels`.

Impact is bounded by how long `graphData` is (the buffer lives in
`skotiq_app`, so this needs a cross-package fix) and by the guiding panel's
rebuild rate. Honest rating: medium, and it is a real repaint the app cannot
avoid today rather than a hypothetical one.

Fix direction, design-system half: give `GuideDataPoint` value equality (or take
an `int revision`/`Listenable` instead of a raw list) so `shouldRepaint` can
return false, and have `_drawTrace` binary-search the first in-window index
instead of scanning from 0.

### 4.4 Not a problem — checked and cleared

Recorded so the next pass does not re-litigate them:

- **Repeating animations.** `OnScreenAnimationGate`
  (`utils/on_screen_animation_gate.dart`) is a well-built paint-observing gate,
  and `status_dot.dart:97-105` explicitly refuses to start the urgent pulse in
  `_applyVariant`, deferring to the gate. `shimmer_loading.dart:44` carries the
  same note. `test/components/idles_at_rest_test.dart` guards it.
- **`CustomPainter.shouldRepaint`.** All 8 painters in the package implement it
  with real field comparisons; none returns a bare `true`. Only §4.3's is
  defeated by its caller.
- **Provider rebuild storms originating in this package.** There are none —
  `skotiq_ui/lib` contains zero riverpod references (§3.10).
- **Sync IO / heavy compute on the UI isolate.** No `dart:io` usage in `lib/`.

---

## 5. Reliability risks

### 5.1 `FocusNode` leak on node swap — `focus_ring.dart:66-73` and `:185-192`

```dart
void didUpdateWidget(FocusRing oldWidget) {
  super.didUpdateWidget(oldWidget);
  if (widget.focusNode != oldWidget.focusNode) {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode = widget.focusNode ?? FocusNode();   // old node dropped, never disposed
    _focusNode.addListener(_handleFocusChange);
  }
}
```

When `oldWidget.focusNode == null` the state **owned** the `FocusNode` it created
in `initState` (L52). On the swap it is replaced without `dispose()`. The
`dispose()` guard at L78 (`if (widget.focusNode == null)`) reads the *current*
widget, so it cannot clean up the abandoned one either. `_FocusBuilderState` has
the identical bug at L187-191 / L197.

Concretely: a widget that starts with `FocusRing(child: …)` (self-owned node) and
later rebuilds as `FocusRing(focusNode: someNode, child: …)` leaks the first
node — and a live `FocusNode` stays registered with `FocusManager`, so this is a
retained-listener leak, not just memory.

`FocusRing` has 8 call sites; whether any of them actually flips the node is
untested. Rated as a real defect with an unproven trigger. Fix: track ownership
in a `bool _ownsNode` and dispose the old node when it was self-created.
`FocusBuilder` is dead (§3.8) so only `FocusRing` needs the fix.

### 5.2 Tooltip show/hide races on an unattached overlay — `skotiq_tooltip.dart:94-104`

```dart
void _showTooltip() async {
  if (_overlayController.isShowing) return;
  _isHovered = true;
  await Future.delayed(widget.waitDuration);   // 300 ms, not cancellable
  if (_isHovered && mounted) {
    _overlayController.show();
    await _animController.forward();           // awaited across a possible dispose
  }
}
```

Two issues, both low severity:

- `Future.delayed` is not held in a cancellable handle, unlike the `_dismissTimer`
  (L66) used by the touch path. `dispose()` (L88) cancels the timer but cannot
  cancel this. The `mounted` check at L100 covers it, so this does not crash —
  it just keeps the state object alive for up to 300 ms after disposal.
- `_showTooltip` is `async void` invoked from `MouseRegion.onEnter` (L147); any
  throw inside it becomes an unhandled zone error rather than a framework error.

Recommend replacing `Future.delayed` with a `Timer` stored alongside
`_dismissTimer` and cancelled in `dispose()`. Effort: small.

### 5.3 `AdaptivePanelLayout`'s documented tablet band does not match its code — MEDIUM

`adaptive_panel_layout.dart:45-48` documents:

> * **Desktop** (`w >= 1024`) … * **Tablet** (`600 <= w < 1024`): fixed-ratio columns (no drag handle).

But L189 dispatches on `BreakpointTokens.isAtLeastDesktop(w)`, which
`tokens/breakpoint_tokens.dart:54` defines as `width >= breakpointTablet` = **768**.
So the "tablet" fixed-ratio branch only ever runs for `600 <= w < 768`; a
768–1023 px region gets the desktop resizable split with a drag handle.

The package's own test does not catch this: `test/adaptive_panel_layout_test.dart:194`
is named `'fixed split on tablet (800x1000)'` but only asserts both panels are
present (L197-200) — it never asserts the *absence* of the resize handle, which
the sibling desktop test at L208-212 asserts the presence of. At 800 px the
handle is in fact there.

This is a correctness/intent question a human must settle (is the doc wrong or
the threshold wrong?), so it is listed here rather than as a token cleanup.
Whichever way it goes, extend the 800 px test to assert the handle's
presence/absence so the answer is pinned.

### 5.4 Not a problem — checked and cleared

- `unawaited` futures: none in `lib/` outside §5.2.
- Swallowed errors: the only `catch (_)` is
  `skotiq_theme.dart:30` in `parseSkotiqAccentColor`, which is a
  documented parse-fallback returning `null`. Correct.
- `dispose()` ordering: `AdaptivePanelLayout` (L147), `AdaptiveTabBar` (L~189),
  `OnScreenAnimationGate` (L119-131 — with an explicit comment on
  disposal-order independence), `StatusDot`, `SkotiqTooltip`,
  `SkotiqTextField` all unregister listeners before disposing. Clean.
- `!`/`late` misuse: `themeLabel!` at `design_reference_board.dart:115` is
  guarded by the `!= null` at L102.

---

## 6. Inconsistent tokens

### 6.1 Two breakpoint scales, and `Responsive` straddles both

| | `SkotiqTokens` (`theme/skotiq_tokens.dart:271-283`) | `BreakpointTokens` (`tokens/breakpoint_tokens.dart:23-32`) |
|---|---|---|
| — | `breakpointMobile = 480` | — |
| phone/tablet | — | `breakpointPhone = 600` |
| tablet/desktop | `breakpointTablet = 768` | `breakpointTablet = 768` |
| desktop/wide | `breakpointDesktop = 1024` | `breakpointDesktop = 1024` |
| wide/ultra | `breakpointDesktopLg = 1440` | `breakpointDesktopWide = 1280` |
| ultra | `breakpointUltraWide = 1920` | — |

`Responsive` uses **both**: `phoneMaxWidth` aliases
`BreakpointTokens.breakpointPhone` (`responsive_utils.dart:28`) while `isMobile`,
`isTablet`, `isDesktop`, `isDesktopLarge`, `isUltraWide` (L117-141) all use the
`SkotiqTokens` scale. `breakpoint_tokens.dart:14-18` acknowledges the split
in a comment and declines to reconcile it.

Consequence: `Responsive.isPhone` (600) and `Responsive.isMobile` (768) are
different tiers with confusingly similar names, and the 1280 vs 1440 "wide"
boundary means `BreakpointTokens.isDesktopWide` and `Responsive.isDesktopLarge`
disagree by 160 px.

This is deliberate per the comment, so **do not unify blindly** — it would shift
type-scale breakpoints. Minimum action: pick one scale as canonical in the doc,
and make `BreakpointTokens.breakpointDesktopWide` either equal
`SkotiqTokens.breakpointDesktopLg` or carry a comment explaining why it does
not.

### 6.2 `Responsive.compactPhoneMaxWidth` hardcodes a value that is already a token

`responsive_utils.dart:33` — `static const double compactPhoneMaxWidth = 480.0;`
`skotiq_tokens.dart:271` — `static const double breakpointMobile = 480.0;`

Same number, two declarations, no cross-reference. Point one at the other.
Effort: trivial.

---

## 7. Suspected cross-package duplication (for the cross-cutting agent)

One line each; none of these were chased down.

- `update_dialog.dart` (557 lines: `UpdateAvailableDialog`, `UpdateDownloadDialog`, `UpdateReadyDialog`, `UpdateReceivedBanner`) lives in the design system but its **only** consumer is `packages/skotiq_updater/lib/src/widgets/update_manager_widget.dart` (L179/238/262/392) — this is updater-domain UI misfiled in the shared package.
- `lib/src/widgets/phd2/` (4 files, 2088 lines: guide star view, guide graph, brain settings, calibration) is guiding-domain UI in the design system, consumed only by `packages/skotiq_app/lib/screens/guiding/guiding_screen_parts/{desktop,mobile}_sections.dart` — check whether `skotiq_app` also has guiding widgets that overlap.
- `skotiq_ui`'s `CollapsibleSidebar` vs the private `_CollapsibleSidebar` in `packages/skotiq_app/lib/screens/equipment/equipment_screen/sidebar_onboarding.dart:10` — same name, same shape, no shared code (see §2.6).
- `SkotiqTouchTarget` (`utils/touch_target.dart`) vs `packages/skotiq_app/lib/widgets/touch_target_floor.dart` — the app wraps the design-system helper; check whether the wrapper adds anything or is a pass-through.
- `HistogramDisplay` (dead here, §3.4) vs whatever draws the live histogram on the imaging screen — likely a second histogram implementation in `skotiq_app`.
- `AnimatedIconButton` (dead here, §3.7) vs `AccessibleIconButton` (live, same package) vs any icon-button in `skotiq_app` — three candidate icon buttons.
- `Responsive.gridColumns` / `ScaledConfig.gridColumns` vs `ResponsiveCardGrid`'s own inline column math (`components/responsive_card_grid.dart:19-32`) — three grid-column calculations, one of which is in a dead class.
- `SkotiqToast` / `SkotiqToastHelper` (`skotiq_alert.dart:279`, `:390`) vs whatever `skotiq_app` uses for its toast/snackbar dedup (the memory notes a "toast dedup" fix in the app layer) — possible parallel toast systems.

---

## 8. Suggested order of work

1. §3.1-3.10 — delete dead code (~1830 lines + the riverpod dep). Independent, mechanical, shrinks everything downstream.
2. §4.1 — `SkotiqColors` value equality. Highest user-visible payoff; small, contained diff.
3. §4.2 — cache the three fixed `ThemeData`s.
4. §2.1 — merge the showcase primitives, **then** §1.1 split the reference board. Gate `ui_consistency_audit.dart` must stay green.
5. §5.3 — settle the `AdaptivePanelLayout` 768-vs-1024 question and pin it with a test assertion.
6. §5.1 — `FocusRing` node-ownership fix.
7. §2.2 / §2.3 / §6.2 — naming and constant reconciliation.
8. §2.5 / §2.6 — deprecate `ResizablePanel`, resolve the sidebar clone (mostly downstream work).
