# w7-imaging-fields — Imaging text boxes: vertical centring

Workstream `w7-imaging-fields`, branch `agent/w7-imaging-fields`, base
`d6a1caeb3` (verified with `git rev-parse --short HEAD` before any edit — no
detach needed).

Goal: the digits in numeric `SkotiqTextField`s painted ~2.5 px below the
well centre on the release build, while text/dropdown values painted slightly
high and the unit suffix rode visibly above the digits. Centre numeric and
lowercase ink, put the suffix on the value's baseline, keep the 28/32 px well
heights and the token contract, touch nothing global.

## Root cause (measured, not guessed)

Two stacked bugs, both inside the field's own layout — not the fonts, not DPR,
not text scaling (all verified identical to the test environment: DPR 1.0, no
`MediaQuery` overrides, bundled Hanken Grotesk resolving correctly, strut
line height 14 px, `RenderEditable.preferredLineHeight` = 14 px in the live
app).

1. **`VisualDensity` leaks into the collapsed decorator's baseline math.**
   The single-line path wraps a `TextFormField` in a collapsed
   `InputDecoration`. On Linux the ambient `themeData.visualDensity` is
   `VisualDensity.compact` (−2, −2), and `_RenderDecoration._layout` folds
   that into `baseSizeAdjustment` as −8 px of phantom vertical room. With
   `textAlignVertical.center` that produces `interactiveAdjustment` = +4 px:
   the `RenderEditable` is positioned 4 px below its own 14 px slot,
   overflowing the bottom of the box. Runtime render-tree dump from the
   running release app (temporary instrumentation, since removed):

   ```
   RenderEditable global rect y 433.5, slot top 429.5 → +4.0 low
   _RenderDecoration local y 279.5, editable +4.0 inside its 14px box
   ```

   In widget tests `defaultTargetPlatform` is android → `standard` density →
   offset 0. That is why the defect never reproduced in tests while the
   release app sat the digits +2.5 px low.

2. **`fieldInkOffset` (−1.5) compensated the wrong thing.** With the density
   bug removed, the forced `StrutStyle(fontSize, height: 1.0, leading: 0,
   forceStrutHeight: true, leadingDistribution: even)` already centres the
   cap-height ink geometrically — both bundled fonts have
   (ascent − descent − capHeight)/2 = 0 by construction (Hanken:
   1000/303/697; Spline Sans Mono: 963.5/236.5/727 per 1000 UPM). The −1.5 px
   transform had been tuned against the broken layout and simply added −1.5
   to the +4 density drop → +2.5 net, exactly the measured defect. It was
   also applied to the dropdown label, pushing it 1.5 px high (−1.5
   measured).

3. **The suffix was a separate `Text` in the well's `Row`** — centre-aligned
   on the *caption* line box, not the digits' baseline, so it rode ~5 px
   above the digits' baseline.

## Fix (all scoped to `skotiq_ui`)

`packages/skotiq_ui/lib/src/components/skotiq_text_field.dart`:

- `visualDensity: VisualDensity.standard` on the collapsed decoration. The
  editable now fills its slot identically on every platform (offset 0).
- Same pin on the multiline decoration for consistency.
- Removed `fieldInkOffset` and both `Transform.translate`s — nothing to
  compensate once the layout is honest.
- The unit suffix moved into `decoration.suffix` (an `ExcludeSemantics`'d
  `Text` in `caption` with `height: 1.0`, `leadingDistribution: even`). The
  decorator's `baselineLayout` puts it on the input's alphabetic baseline at
  the trailing edge (`inputGap` = 0 for an unfilled `InputBorder.none`
  decoration) — same x as before, now sharing the value's baseline. The
  `suffix` widget variant (not `suffixText`) keeps the old `ExcludeSemantics`
  so no stray "s" semantics node is published; `_AffixText` still gates
  visibility on `labelShouldWithdraw`, so an empty unfocused field hides the
  unit — canonical Material affix behaviour.
- `suffixWidget` (e.g. capture-bar icon buttons) still renders in the well's
  Row, unchanged.

`packages/skotiq_ui/lib/src/components/skotiq_dropdown.dart`:
removed the `Transform.translate` on the label — the trigger now centres the
label the same way as the fields.

No height, token, or global-Material changes. `fieldHeight`/`fieldHeightDense`
still 32/28; the Row, padding and well chrome are untouched.

## Measurements

Method: raw window capture (`shot --raw`, scale 1.0, 1920×1200) → per field,
detect the well's dark fill rows and the bright-ink rows (>150 luma), offset =
ink centre − well centre, + = low. Suffix judged on baseline equality (ink
bottom row), not centre — a smaller glyph on the same baseline has a higher
ink centre by construction.

### Before (`shots/w7_now.png`, pre-fix build)

| Field | well rows | ink rows | offset |
|---|---|---|---|
| Capture › Exposure `2.0` | 297–326 | 309–319 | **+2.50** |
| Capture › Exposure `s`   | — | 308–314 (bottom 314 vs digits 319: rides high) |
| Files › Format `Light`   | 339–368 | 347–360 | +0.00 |
| Binning `1x1`            | 381–410 | 389–399 | −1.50 |
| Capture › Gain `100`     | 423–452 | 435–445 | **+2.50** |
| Capture › Offset `50`    | 423–452 | 435–445 | **+2.50** |
| Bar › Exposure `2.0`     | 962–991 | 974–984 | **+2.50** |
| Bar › `s`                | — | 973–979 (bottom 979 vs digits 984: rides high) |
| Bar › Gain `100`         | 962–991 | 974–984 | **+2.50** |
| Bar › frame `L`          | 962–991 | 970–980 | −1.50 |

Matches the brief's fixture numbers (+2.7/+1.7/+1.7/+2.8 at the fixture's
~0.8 capture scale → ≈ +2.5 at scale 1.0).

### After (`shots/after.png`, fixed build)

| Field | well rows | ink rows | offset |
|---|---|---|---|
| Capture › Exposure `2.0` | 297–326 | 306–316 | **−0.50** |
| Capture › Exposure `s`   | — | 310–316 — ink bottom 316 = digits' baseline 316 ✓ |
| Files › Format `Light`   | 339–368 | 348–361 | +1.00 (descender-heavy ink; line box centred) |
| Binning `1x1`            | 381–410 | 390–400 | −0.50 |
| Capture › Gain `100`     | 423–452 | 432–442 | **−0.50** |
| Capture › Offset `50`    | 423–452 | 432–442 | **−0.50** |
| Bar › Exposure `2.0`     | 962–991 | 971–981 | **−0.50** |
| Bar › `s`                | — | 975–981 — ink bottom 981 = digits' baseline 981 ✓ |
| Bar › Gain `100`         | 962–991 | 971–981 | **−0.50** |
| Bar › frame `L`          | 962–991 | 971–981 | −0.50 |

Every numeric well: |offset| = 0.5 px, inside the ≤0.5 px tolerance. Suffixes
now sit on the value baseline instead of ~5 px above it. `Light` at +1.00 is
font geometry (the 'g' descender pulls the ink centroid down inside a
correctly centred line box) — same mechanism as lowercase ink generally.

### Widget tests (`packages/skotiq_ui/test/skotiq_text_field_test.dart`)

`tight` selection boxes from `RenderEditable.getBoxesForSelection` plus a
`RepaintBoundary` raster at 4×, bright-row scan — the same measure as the
screenshots:

- `the typed value sits on the well centre, with the unit` — editable centre
  = field centre within 0.5; suffix baseline = editable baseline within 0.5.
- `numeric, lowercase and unit ink centres on the well` — 28 px dense mono
  field: tight line-box offset and rasterised digit ink both ≤0.5 px;
  lowercase 'galaxy' line box ≤0.5 px (raster offset reported: 0.00 px);
  suffix baseline = value baseline ≤0.5 px.

## Commands run (unpiped exit codes)

```
git rev-parse --short HEAD                              → d6a1caeb3 ✓
dart format --output=none --set-exit-if-changed <3 pkgs>  → EXIT=1
  (41 files of pre-existing drift outside my file list — depthlock,
   imaging_screen, title_bar, etc. — not touched. My three files: EXIT=0)
dart analyze  (skotiq_ui, my files only)             → "No issues found!" EXIT=0
dart analyze  (skotiq_app)                           → 895 issues, all
  info-level + 8 warnings, all pre-existing; zero in touched files. EXIT=2
cd packages/skotiq_ui && flutter test --concurrency=4
  → +523, All tests passed!  EXIT=0
cd packages/skotiq_app && flutter test test/screens/imaging --concurrency=3
  → +360, All tests passed!  EXIT=0
flutter test test/widgets --concurrency=3
  → +293 −10  EXIT=1  (see below)
cd apps/desktop && flutter build linux --release && cp libskotiq_bridge.so …
  → ✓ Built build/linux/x64/release/bundle/skotiq_desktop  EXIT=0
tools/ui_audit/drive_linux.py --profile w7fix (SK_AUDIT_DISPLAY=:97, seeded
  /tmp/ns-audit/w7fix/data from the preview data dir) — navigated Continue
  Session → Imaging; captures before: w7_now.png / w7_imaging_raw.png,
  after: after.png
```

### `test/widgets` −10: pre-existing, not from this change

All 10 failures are in
`test/widgets/go_to_position_dialog_test.dart`: `AlertDialog` wraps its
content in `IntrinsicWidth` (`dialog.dart:925`), the dialog's content Column
queries intrinsics, and `_singleLineWell`'s `LayoutBuilder` throws
"LayoutBuilder does not support returning intrinsic dimensions". The
`LayoutBuilder` predates this workstream (present at `d6a1caeb3` and
`HEAD~1`); I reverted my source files and reran — **identical 10 failures on
base**. A real latent defect (any `SkotiqTextField` inside an
`AlertDialog`/`IntrinsicWidth` crashes on intrinsic query) but out of this
workstream's file list — flagged for follow-up, not fixed here.

## Deviations from the brief

- The brief suggested centring cap-height via `contentPadding` or strut
  leading distribution. The actual defect was `VisualDensity.compact` in the
  collapsed decorator; pinning `standard` + the already-present 1.0 strut
  centres the ink with **zero** residual offset arithmetic, so no padding
  hack or constant is needed.
- `suffix` moved from the Row into the decoration — required to share the
  input's baseline exactly; the decorator baseline-aligns affixes natively.
- `dropdown` label: brief allowed touching it "only if the trigger shares the
  defect" — it did (−1.5 measured before, −0.5 after with the transform
  removed).

## Leftover state / follow-ups

- `LayoutBuilder` intrinsic crash (above) — pre-existing, affects any field
  inside `AlertDialog`. Recommend replacing the `LayoutBuilder` in
  `_singleLineWell` with constraint-free expand detection or moving expand
  logic into a custom render object.
- Audit harness left stopped; the seeded `/tmp/ns-audit/w7fix` profile can be
  deleted.
- `debugPrint` in the new test intentionally reports the lowercase raster
  offset (measurement output, like the brief asked for) — not a stray debug
  aid.
