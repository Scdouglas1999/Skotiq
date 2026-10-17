# Wave C3 — batch `planetarium-ui`

Scope: `packages/skotiq_planetarium/**` and `packages/skotiq_ui/**`, files >1000 lines.
Baseline: `45bc9d5e4` ("audit: record the stage-2 sweep — 17 fixes, gates green").
Plans followed: `reports/release-pass/map/planetarium.md` §1.1-§1.6 and
`reports/release-pass/map/ui-package.md` §1.1.

All splits move code **verbatim**. No logic edits, no renames of public symbols, no
signature changes. Line counts below are `wc -l` at HEAD vs after.

---

## Re-measure at HEAD (C1/C2 had already shrunk two of the map's candidates)

| File | Map said | HEAD | Action |
|---|---|---|---|
| `planetarium/lib/src/astronomy/astronomy_calculations.dart` | 1757 | 1785 | split |
| `planetarium/lib/src/catalogs/star_catalog.dart` | 1588 | 1480 | split |
| `planetarium/lib/src/widgets/interactive_sky_view.dart` | 1332 | 1336 | split |
| `planetarium/lib/src/rendering/sky_renderer/solar_system_and_markers.dart` | 1084 | 1084 | split |
| `planetarium/lib/src/planning/target_scoring.dart` | 1107 | 1076 | split |
| `planetarium/lib/src/widgets/object_details_panel/content_sections.dart` | 1012 | 1011 | split |
| `skotiq_ui/lib/src/widgets/design_reference_board.dart` | 1092 | 1010 | split |

Nothing in scope was under the threshold at HEAD, so nothing was skipped for size.
`design_system_gallery.dart` (800) and `adaptive_panel_layout.dart` (724) are the next
largest in `skotiq_ui` and are both under the bar — untouched, per the map.

---

## 1. `star_catalog.dart` — 1480 → 228

Three new `part of '../star_catalog.dart'` files under `lib/src/catalogs/star_catalog/`:

| New file | Lines | Moved |
|---|---|---|
| `star_catalog/hyg_parser.dart` | 281 | `_loadStarsInIsolate`, `_nameComponentStars`, `_isUnnamedComponent`, `_componentLetter`, `_parseHygLine`, `_parseCsvLine` |
| `star_catalog/constellation_genitives.dart` | 98 | `_getConstellationGenitive` + the 88-entry `_constellationGenitives` map |
| `star_catalog/fallback_bright_stars.dart` | 880 | the `_fallbackBrightStars` literal list (pure data) |

Visibility change: these were `static` **private** members of `HygStarCatalog`; a Dart class
body cannot be split, so they are now library-private **top-level** declarations in part files.
Same privacy (library), same names, same call sites (all were unqualified). No public symbol moved.
`_getConstellationGenitive` moved with its map because `_parseHygLine` is its only caller.
Doc reference `[HygStarCatalog._nameComponentStars]` retargeted to `[_nameComponentStars]`
(comment text only).

The §2.1/§3.2 deletions the map asked for (duplicate constellation-name map, `NamedStars`)
were already done by C1/C2 — they are gone at HEAD.

## 2. `sky_renderer/solar_system_and_markers.dart` — 1084 → deleted, four parts

Was already `part of '../sky_renderer.dart'`. Replaced its one `part` line in
`sky_renderer.dart` with four:

| New file | Lines | Moved |
|---|---|---|
| `sky_renderer/scene_geometry.dart` | 182 | `_compassPoints`, `MoonPhaseGeometry`, `extension SkyCanvasPainterSceneGeometry` (both public names kept — pinned by `test/moon_phase_and_cardinals_test.dart`) |
| `sky_renderer/markers.dart` | 248 | `_drawCardinalDirections`, `_drawSelectionMarker`, `_drawMountPositionMarker` |
| `sky_renderer/solar_bodies.dart` | 359 | `_drawSun`, `_drawMoon`, `_drawPlanets`, `_drawPlanetDetails`, `_drawSaturnRings`, `_drawJupiterBands`, `_drawMarsPolarCap` |
| `sky_renderer/small_bodies.dart` | 307 | `_drawSatellites`, `_drawVariableStars`, `_drawMinorPlanets`, `_drawMinorPlanetLabel` |

The single `extension _SkyCanvasPainterSolarSystemAndMarkers on SkyCanvasPainter` became three
private extensions (`_SkyCanvasPainterMarkers`, `_SkyCanvasPainterSolarBodies`,
`_SkyCanvasPainterSmallBodies`). Extension names are private and unreferenced by name, so this
is not a public rename. Each new file carries the sibling convention header
`// ignore_for_file: unused_element, unused_field`.

## 3. `object_details_panel/content_sections.dart` — 1011 → deleted, four parts

Was already `part of '../object_details_panel.dart'`. One `part` line replaced by four:

| New file | Lines | Moved |
|---|---|---|
| `object_details_panel/header_sections.dart` | 336 | `_buildHeader`, `_buildHeaderWithThumbnail`, `_getObjectIcon`, `_getTypeColor`, `_getTypeString`, `_getConstellation`, `_buildThumbnail`, `_thumbnailFovDeg`, `_getDsoIcon`, `_getDsoColor` |
| `object_details_panel/catalog_sections.dart` | 153 | `_buildCoordinatesSection`, `_buildCatalogSection`, `_buildPhysicalPropertiesSection` |
| `object_details_panel/visibility_sections.dart` | 423 | `_buildVisibilitySection`, `_buildVisibilityGraph`, `_buildAirmassChart`, `_buildAirmassLegendDot`, `_buildRiseTransitSetSection`, `_formatTime`, `_buildTimeColumn`, `_buildQuickStats`, `_calculateVisibilityScore`, `_buildVisibilityIndicator` |
| `object_details_panel/action_sections.dart` | 108 | `_buildActionButtons`, `_buildInfoRow` |

`extension _ObjectDetailsPanelContentSections` became four private extensions on the same type.

## 4. `astronomy_calculations.dart` — 1785 → 508 (facade) + 6 parts + 1 models library

The map's facade shape, applied mechanically by script
(`scratchpad/split_astro.py`, kept out of the repo):

- Every **public** `static` on `AstronomyCalculations` stays, with its doc comment, as a
  one-line forwarder with the **identical signature**, e.g.
  `static double julianDate(DateTime dt, {bool includeMilliseconds = true}) => _julianDate(dt, includeMilliseconds: includeMilliseconds);`
- Each body moved verbatim to a library-private top-level function `_<name>` in a part file.
- Every **private** `static` moved as a top-level function/const under its existing name.
- The three **public** `static const`s (`civilTwilightAngle`, `nauticalTwilightAngle`,
  `astronomicalTwilightAngle`) stayed in the class — a const cannot be forwarded. The part that
  reads them now qualifies them as `AstronomyCalculations.civilTwilightAngle`.
- The five private constants (`_deg2rad`, `_rad2deg`, `_epsilon`, `_j2000`, `_obliquityJ2000`)
  moved to library-private top-level consts in the facade file.

| New file | Lines |
|---|---|
| `astronomy/calc/time_and_frames.dart` | 228 |
| `astronomy/calc/precession.dart` | 160 |
| `astronomy/calc/sun_and_twilight.dart` | 274 |
| `astronomy/calc/moon.dart` | 231 |
| `astronomy/calc/rise_set_transit.dart` | 375 |
| `astronomy/calc/geometry.dart` | 108 |
| `astronomy/visibility_models.dart` | 99 |

`visibility_models.dart` is a normal library (not a part) holding `TwilightTimes`, `MoonTimes`,
`MeridianFlipWindow`, `ObjectVisibility` verbatim; the facade both imports and **re-exports** it,
so every existing `import '../astronomy/astronomy_calculations.dart'` still resolves those names
with no edit anywhere.

Verification of "no public API moved": the `static` member-name set of the class before vs after
differs only by the 15 private members that left (`_apparentAltitudeOf`, `_apparentLimb`,
`_deg2rad`, `_epsilon`, `_findRiseBefore`, `_findSunAltitudeCrossing`, `_j2000`,
`_moonRiseSetAltitude`, `_obliquityJ2000`, `_rad2deg`, `_refineAltitudeCrossing`,
`_refineMoonCrossing`, `_refineTransit`, `_refractionAtHorizon`, `_sunRiseSetAltitude`).
All 35 public statics are still declared on the class.

`sun_and_twilight.dart` carries `// ignore_for_file: unused_element` to preserve the
`// ignore_for_file: unused_field` that the original single file used for the already-unused
`_refractionAtHorizon` — `ignore_for_file` does not cross into part files.

## 5. `target_scoring.dart` — 1076 → 380 + 1 models library + 3 parts

| New file | Lines | Moved |
|---|---|---|
| `planning/target_scoring/models.dart` (normal library) | 166 | `HorizonMask`, `ScoringWeights`, `TargetScore`, `TargetVisibilityInfo`, `WarningType`, `WarningSeverity`, `TargetWarning` |
| `planning/target_scoring/axis_scores.dart` (part) | 161 | `_scoreAltitude`, `_scoreMoonDistance`, `_scoreTransitProximity`, `_scoreDarkness`, `_scoreAirmass`, `_scoreTransitProximityForNight`, `_scoreImagingWindow` |
| `planning/target_scoring/warnings.dart` (part) | 368 | `_generateWarnings`, `_moonProximityWarnings`, `_formatTime`, `_generateNightWarnings` |
| `planning/target_scoring/checks.dart` (part) | 18 | `extension TargetCheckExtensions` verbatim |

`target_scoring.dart` re-exports `models.dart`, so all existing import paths keep resolving.
The private scorers/warning generators are now private `extension`s on `TargetScoringService`
(`_TargetAxisScores`, `_TargetWarnings`); unqualified calls from the class body resolve through
implicit-`this` extension lookup, so **no call site changed**.

The §2.3 warning-ladder de-duplication and the §3.3 dead-method deletions are NOT part of this
batch — they are behaviour/API work, not a mechanical split, and are left for their own change.

## 6. `interactive_sky_view.dart` — 1336 → 735 + 3 parts

Already had 4 part files; three more added.

| New file | Lines | Moved |
|---|---|---|
| `interactive_sky_view/view_motion.dart` | 291 | momentum tuning consts, `_momentumSpeedPx`, `_panByPixels`, `_onZoomAnimation`, `_onMomentumTick`, `_stopMomentum`, `_calculatePanVelocity`, `_pendingFOV`, `_zoomByStep`, `_animateZoom`, `_onFlyToAnimation`, `_startFlyTo`, `_mapMountStatus` |
| `interactive_sky_view/painter_wiring.dart` | 108 | `_buildSkyPainter` |
| `interactive_sky_view/hit_testing.dart` | 221 | `_coincidentStarPixels`, `_handleDoubleTapZoom`, `_handleTap`, `_resolveCoincidentStar`, `_screenToCelestial` |

Private extensions `_SkyViewMotion`, `_SkyViewPainterWiring`, `_SkyViewHitTesting` on
`_InteractiveSkyViewState`. The three `static const` momentum thresholds and
`_coincidentStarPixels` became library-private top-level consts, because `build()` (which stays
in the main file) reads `_momentumMinLaunchFraction` directly.

**Deviation from the map:** the map also proposed pulling the four inline gesture closures out of
`build()` into a `gestures.dart` part. That requires rewriting `build()`'s gesture wiring rather
than moving code verbatim, and the file is already under the threshold without it, so it was not
done. Consequently the `_setStateFromPart` shim the map called for was not needed — no moved code
calls `setState` (all 4 `setState` sites are inside `build()`, which did not move).

## 7. `design_reference_board.dart` — 1010 → 167 + 4 parts (`skotiq_ui`)

| New file | Lines | Moved |
|---|---|---|
| `design_reference_board/palette_sections.dart` | 204 | `_SemanticPaletteSection`, `_DomainPaletteSection` |
| `design_reference_board/typography_section.dart` | 172 | `_TypographyScale`, `_TypeRow` |
| `design_reference_board/component_sections.dart` | 332 | `_ComponentsSection`, `_StatusAndFeedbackSection`, `_LayoutPrimitivesSection` |
| `design_reference_board/board_primitives.dart` | 144 | `_noop`/`_noopBool`/`_noopNullableBool`, `_SubLabel`, `_GradientBar`, `_DotChip`, `_CardSpecimen` |

`part of` was used exactly as the map preferred, so no new public names appear in the package.
`SkotiqDesignReferenceBoard` keeps its file path, so `skotiq_ui.dart:64` and
`test/golden/design_gallery_golden_test.dart` needed **zero** edits.

---

## Verification

- `dart analyze packages/skotiq_planetarium` → **No issues found.**
- `dart analyze packages/skotiq_ui/lib` → **No issues found.**
  (`dart analyze packages/skotiq_ui` reports 24 pre-existing `deprecated_member_use` infos in
  `test/`, unrelated and unchanged.)
- `dart analyze packages/skotiq_app/lib` → no errors, so the downstream consumer of both
  packages still resolves every moved/re-exported name.
- `flutter test` in `packages/skotiq_planetarium` with `--exclude-tags golden`:
  **549 passed, 0 failed.** No test file was edited — not even an import line.
- The `golden`-tagged `test/benchmark/golden_compare_test.dart` fails on this Linux host both
  before and after: it is excluded from `melos run test` by design ("Baselines are host-specific",
  file header lines 1-4) and its baselines were captured on another host.
- `flutter test` in `packages/skotiq_ui`: 296 passed, 1 failed — and the failure is a
  **compile error in another package, from another agent's in-flight work**:
  `skotiq_core/lib/src/services/stack_and_share_service.dart:331` `_rejectionReason` /
  `:377,:515` `_dominantReason` are undefined. `git status` shows that file modified with a new
  untracked `stack_and_share_service/` directory alongside four other core services in the same
  state. Nothing in this batch touches `skotiq_core`.
- `packages/skotiq_ui/test/golden/` passes (3/3) and, decisively for §1.1's acceptance test,
  `git status docs/design/goldens/` is **clean** after the run — the re-rendered board PNGs are
  byte-identical to the committed baselines.
- Per-file member-set diffs (HEAD vs the union of each split's outputs) show no lost declaration
  for any of the seven files.
- `dart format` run on the touched files only.
