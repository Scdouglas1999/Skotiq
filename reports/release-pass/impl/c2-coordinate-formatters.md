# C2 — coordinate-formatters

Topic: the ~39 private RA/Dec sexagesimal formatter copies (Wave A cross-cutting
cluster 7). Survivor: `packages/skotiq_core/lib/src/utils/coordinate_format.dart`
(`CoordinateFormat`), whose C1 seconds-carry fix is the canonical base — not forked.

Baseline: commit b07d91c9d, tree green.

## What the canonical gained

`CoordinateFormat` was parameterised further so it can reproduce the real
presentation shapes byte-for-byte instead of the migration stopping at two styles.

New `SexagesimalStyle` values (separator × which fields are zero-padded):

| style | RA | Dec |
| --- | --- | --- |
| `paddedLetters` (existing) | `05h 30m 0.0s` | `+45° 30' 0.0"` |
| `paddedColons` (existing) | `05:30:00` | `+45:30:00` |
| `compactLetters` | `05h30m00s` | `+45°30'00"` |
| `plainLetters` | `5h 30m 0s` | `+45° 30' 0"` |
| `leadPlainLetters` | `5h 30m` | `+45° 30'` |
| `compactLeadPlainLetters` | `5h30m00s` | `+45°30'` |

New `SecondsPrecision.oneDecimalPadded` (`toStringAsFixed(1).padLeft(4,'0')` —
`00.0`); integer seconds now follow the style's padding rule (padded everywhere
except `plainLetters`), which is what the retired copies did.

New entry points:

* `raHm` / `decDm` + `MinutesPrecision {rounded, floored}` — the two-field
  `HHh MMm` / `±DD° MM'` shapes, quantized at the minute so a rounded 60th
  minute carries structurally (the retired copies special-cased `if (m == 60)`).
* `raFromDegrees` / `raHmFromDegrees` — **the unit hazard fix**. 15 of the
  retired helpers were named `_formatRa` while taking degrees, not hours, with
  no type to tell them apart. The canonical now names the unit in the method.
* `decDecimal(dec, {fractionDigits})` — the `+45.3°` decimal-degree shape three
  copies carried.
* `wrapHours` on `ra` / `raHm`.

Wrap correctness note: the fold happens **before** quantizing. Folding after
(taking `floor()` of the magnitude and reflecting it around a day) is not the
same function — it renders `-0.005h` as `0h 0m` instead of `23h 59m`. That was a
real bug in the first cut of this change; the parity sweep caught it.

## Call sites re-pointed (27 helper pairs across 4 packages)

`skotiq_core`
* `providers/framing_provider/support.dart` — `CoordinateUtils.formatRA/formatDec`
  (3 external callers) now delegate.
* `services/device_service/mount_controls.dart` — `_formatRA`/`_formatDec` deleted,
  the one call site formats inline.
* `services/science/narrator/detectors/first_light_detectors.dart` — both delegate.

`skotiq_app`
* `screens/analytics/widgets/mpc_export_panel.dart` (RA only)
* `screens/dashboard/widgets/mount_control_card.dart`
* `screens/imaging/centering_dialog.dart`
* `screens/imaging/widgets/overlay_painters/celestial_grid_painter.dart`
* `screens/polar_alignment/polar_alignment_screen_parts/_measurement_panel.dart` (RA only)
* `screens/sequencer/tabs/templates_tab_parts/_save_template_dialog.dart`
* `screens/sequencer/widgets/node_properties_panel_parts/_motion_rich.dart`
* `screens/sequencer/widgets/quick_start_wizard_dialog.dart` (RA only)
* `screens/sequencer/widgets/run_dashboard/run_dashboard_format.dart`
* `screens/sequencer/widgets/target_header_card.dart`
* `screens/sequencer/widgets/target_preview_tooltip.dart`
* `screens/suggestions/widgets/transient_alerts_panel.dart`
* `screens/your_sky/sky_atlas_format.dart`
* `services/finder_chart_service.dart`
* `utils/coordinate_format_utils.dart` (`formatRA`, `formatRACompact`,
  `formatRAShort`, `formatDec`)
* `widgets/annotation_overlay/object_info_tooltip.dart`
* `widgets/catalog_overlay_widget/details_panel.dart`
* `widgets/first_light/first_light_flow_dialog.dart` (RA only)

`apps/mobile`
* `screens/dashboard/tabs/devices_tab.dart`
* `screens/dashboard/tabs/mount_tab.dart`

Each retired helper became a one-line delegation (or was deleted where it had a
single caller), so no call site changed and the math lives in one file.

## Method — how parity was established

A scratch harness (`dart` script, not committed) held a verbatim copy of every
retired implementation next to the canonical and swept:

* RA hours: 24 000 points at 0.001h + the wrapping formatters over 4 800
  negative points and `24.0 / 25.5 / 30.25 / 47.9`.
* RA degrees: 36 000 points at 0.01°.
* Dec: 18 000 points at 0.01° over ±90.

Every surviving mismatch was then machine-classified (carry / off-by-one-unit /
other). The `other` bucket was inspected exhaustively and contains only two
things: an off-by-one that crosses a field boundary (`1h 11m 59s` → `1h 12m 0s`)
and `object_info_tooltip`'s broken wrap (`01h 1440m 00.0s` → `01h 00m 00.0s`).
So every surviving mismatch falls into one of the three classes below, all of
them the legacy being wrong; nothing else diverged.

## Deliberate behaviour corrections (NOT preserved)

1. **The impossible 60th second/arcminute.** ~0.4–4% of inputs, every
   field-by-field helper: `5.6h` printed `05h 35m 60.0s` — a time
   `CoordinateParser` itself rejects. Canonical: `05h 36m 0.0s`.
2. **Double-truncation loss.** Helpers that floored the seconds field after two
   float subtractions lost a whole second/arcsecond on ~7% (RA) / ~33% (Dec)
   of inputs: `0.015h` is exactly 54s but printed `53s`; `89.99°` is exactly
   `89°59'24"` but printed `23"`. Affects `target_preview_tooltip`,
   `finder_chart_service`, `CoordinateFormatUtils.formatRAShort/formatDec`,
   `transient_alerts_panel`, `first_light_detectors`.
3. **Negative / out-of-range RA.** The retired helpers took `.floor()` of the
   signed value (`-0.5h` → `-1h 30m`) and `object_info_tooltip` wrapped only the
   hours field, printing `23h -1440m 00.0s` for a negative degree. The canonical
   renders a signed magnitude, or folds into the day at the wrapping entry
   points. No production path feeds a negative RA.

All three are pinned in the parity test so a revert to field-by-field
decomposition fails.

## Left alone (divergent — recorded, not unified)

* `skotiq_core/services/science/mpc_export_service.dart` `_formatRa/_formatDec`
  — the MPC **wire** format: fixed 12-character fields, `59.995 → 59.99` clamp
  instead of a carry (a carry would change the degree field of a submitted
  observation), `assert(result.length == 12)`. Not presentation; keep separate.
* `screens/analytics/widgets/mpc_export_panel.dart` `_formatDecBrief` — uses `d`
  as the degree glyph (`+45d30'00"`) to mirror the MPC field. RA migrated, Dec
  not.
* `screens/sequencer/widgets/quick_start_wizard_dialog.dart` `_formatDec` —
  `+45d 30' 0"`, same `d` glyph, unpadded.
* `widgets/first_light/first_light_flow_dialog.dart` `_formatDec` — uses PRIME
  `′` (U+2032) for arcminutes where every other site uses `'`.
* `screens/polar_alignment/.../_measurement_panel.dart` `_formatDec` — degrees and
  arcminutes zero-padded but the seconds field `toStringAsFixed(0)` unpadded
  (`+45° 30' 0"`). A shape no other site shares; parameterising for one caller
  would cost a sixth style.
* `CoordinateFormatUtils.formatDecCompact` (`+45°`, degrees only) and
  `formatAltitude/formatAzimuth/formatFOV/formatLatLon/formatRADecPrecise` —
  already a single shared util, not sexagesimal.
* `skotiq_planetarium/src/rendering/sky_renderer/coordinate_layers.dart`
  `_formatRaLabel/_formatDecLabel` — grid labels whose field count varies with
  the grid spacing; also blocked (below).

## Blocked

`packages/skotiq_planetarium` (`src/coordinate_system.dart` `formatRA`/
`formatDec`, `src/rendering/sky_renderer/coordinate_layers.dart`) cannot use the
canonical: the package has **no dependency on `skotiq_core`** and is
deliberately a leaf (the standalone planetarium lab app depends on that). Both
`skotiq_app` and `apps/mobile` depend on it, so adding a core dependency
would invert the layering. Options for a later wave: extract `CoordinateFormat`
into its own leaf package both can depend on, or leave the planetarium's two
copies as the accepted cost of the leaf boundary. `coordinate_system.dart`'s
`formatRA(compact:)`/`formatDec(compact:)` are exactly `compactLetters` +
`plainLetters`, so the extraction is mechanical when the boundary is settled.

## Tests

* `packages/skotiq_core/test/utils/coordinate_format_parity_test.dart` (new,
  23 tests) — one group per retired shape pinning its exact strings, plus the
  three correction classes and the non-finite behaviour.
* `packages/skotiq_core/test/utils/coordinate_format_test.dart` — unchanged,
  still green (its `SecondsPrecision.values` round-trip loop now also covers
  `oneDecimalPadded`).
* `packages/skotiq_app/test/screens/your_sky/sky_atlas_format_test.dart` —
  unchanged, still green (it pins `formatRaDeg`/`formatDecDeg` output directly).

Suite runs after the change:

* `packages/skotiq_core` — 5730 passed, 0 failed.
* `apps/mobile` — 239 passed, 0 failed.
* `packages/skotiq_app` — 3303 passed, **42 failed**. All 42 are whole-screen
  golden pixel diffs (1.4%–81% of pixels) from `captures_landscape_test` /
  `captures_fold_cover_test` / `public_screenshots_test`. Not attributable to
  this batch: the failing set includes `settings`, `weather`, `onboarding`,
  `stack_result`, `flat_wizard`, `diagnostics`, `equipment` and `guiding`, none
  of which render an RA/Dec string, and this batch touched **zero** files under
  any of those screens. A coordinate-string change produces a sub-0.1% diff on
  coordinate-bearing screens only. This is the known Windows-captured-goldens-
  fail-on-Linux debt. Full log kept at
  `<scratch>/app_full.log` for the verify wave.

`NaN`/infinity: unchanged from the retired helpers, which all called
`.floor()`/`.round()` on the raw double and therefore threw. `CoordinateParser.
formatRaHms/formatDecDms` remain the non-finite-safe entry points. Pinned in the
parity test; not "fixed" here (behaviour-adjacent, would need a repro first per
the standing rule).
