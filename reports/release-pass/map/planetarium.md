# Release-pass map — `skotiq_planetarium`

Subsystem: `packages/skotiq_planetarium/`
Scope: whole package (`lib/`, plus `benchmark/` and `test/` only as caller evidence).
No Rust in this package (`find packages/skotiq_planetarium -name '*.rs'` → empty), so all
Rust-flavoured checks in the brief are N/A here; the Rust twins named below live in other crates
and are listed as cross-package suspects.

All line counts verified with `wc -l`. No generated files exist in this package
(`find . -name '*.g.dart' -o -name '*.freezed.dart' -o -name '*frb_generated*'` → empty), so every
file discussed is hand-written.

---

## 1. Oversized files

Six Dart files exceed ~1000 lines. Nothing is generated.

| File | Lines |
|---|---|
| `lib/src/astronomy/astronomy_calculations.dart` | 1757 |
| `lib/src/catalogs/star_catalog.dart` | 1588 |
| `lib/src/widgets/interactive_sky_view.dart` | 1332 |
| `lib/src/planning/target_scoring.dart` | 1107 |
| `lib/src/rendering/sky_renderer/solar_system_and_markers.dart` | 1084 |
| `lib/src/widgets/object_details_panel/content_sections.dart` | 1012 |

Two more sit just under the bar and are listed at the end as watch-items.

---

### 1.1 `lib/src/astronomy/astronomy_calculations.dart` — 1757 lines

**Why it is big.** One class, `AstronomyCalculations` (line 52), holds *every* static astronomy
routine in the app — 13 self-declared sections (the `// ====` banners at lines 56, 68, 134, 163,
214, 346, 539, 594, 833, 1076, 1533, 1591, 1611): Julian date, sidereal time, refraction, coordinate
transforms, precession/nutation, Sun, twilight, Moon, rise/set/transit, meridian flip, airmass,
angular separation. Four result models (`TwilightTimes` 1667, `MoonTimes` 1698,
`MeridianFlipWindow` 1718, `ObjectVisibility` 1731) trail the class, plus one top-level function
`airmassForTrueAltitude` (line 19).

**Constraint that shapes the split.** Every consumer calls `AstronomyCalculations.foo(...)`, and
Dart cannot spread a class body across `part` files, nor can an `extension` contribute *static*
members reachable as `AstronomyCalculations.foo`. So the only behavior-preserving shape is:
**keep the class as a thin facade of one-line static forwarders; move the bodies to library-private
top-level functions in `part` files** (parts share the library's private namespace, so the private
constants `_deg2rad`/`_rad2deg`/`_epsilon`/`_j2000`/`_obliquityJ2000` at lines 59-65 move to
library-private top-level `const`s and every part sees them unchanged).

**Split plan.**

`lib/src/astronomy/astronomy_calculations.dart` (stays, target ~330 lines)
- keeps `library;` + the `import 'dart:math' as math;`
- keeps `double? airmassForTrueAltitude(...)` (lines 19-49) — already top-level and already
  referenced by name from `AstronomyCalculations.airmass`
- keeps `typedef EquatorialPositionAt` (lines 9-10)
- keeps `class AstronomyCalculations` with **only** the doc comments and one-line forwarders,
  e.g. `static double julianDate(DateTime dt) => _julianDate(dt);`
- adds `part` directives for the six new files below
- adds `export 'visibility_models.dart';` so every existing `import
  '../astronomy/astronomy_calculations.dart'` still resolves `TwilightTimes` etc. unchanged

New files, all `part of 'astronomy_calculations.dart'` except the models file:

1. `lib/src/astronomy/calc/time_and_frames.dart` (~300 lines)
   moves lines 59-65 (constants, as library-private top-level `const`), 72-131 (`julianDate`,
   `fromJulianDate`, `modifiedJulianDate`), 138-160 (`greenwichMeanSiderealTime`,
   `localSiderealTime`), 177-211 (`atmosphericRefraction`, `trueToApparentAltitude`,
   `apparentToTrueAltitude`), 219-343 (`equatorialToHorizontal`, `horizontalToEquatorial`,
   `eclipticToEquatorial`, `galacticToEquatorial`).
2. `lib/src/astronomy/calc/precession.dart` (~200 lines)
   moves lines 355-537 (`nutation`, `meanObliquity`, `precessFromJ2000ToDate`,
   `precessFromDateToJ2000`).
3. `lib/src/astronomy/calc/sun_and_twilight.dart` (~290 lines)
   moves lines 544-831: `sunPosition`, `sunAltitude`, the refraction/limb constants at 599-616,
   `_apparentLimb`, `_findSunAltitudeCrossing`, `calculateTwilightTimes`, `darknessHours`.
4. `lib/src/astronomy/calc/moon.dart` (~240 lines)
   moves lines 838-1073: `moonPosition`, `moonIllumination`, `moonPhaseName`, `moonAltitude`,
   `calculateMoonTimes`, `_refineMoonCrossing`.
5. `lib/src/astronomy/calc/rise_set_transit.dart` (~460 lines)
   moves lines 1084-1509: `_apparentAltitudeOf`, `_refineAltitudeCrossing`, `_findRiseBefore`,
   `nightDateOf`, `calculateObjectVisibility`, `_refineTransit`, `calculateSunVisibility`,
   `calculateMoonVisibility`.
6. `lib/src/astronomy/calc/geometry.dart` (~140 lines)
   moves lines 1511-1663: `objectAltAz`, `hourAngleDeg`, `calculateMeridianFlip`, `airmass`,
   `angularSeparation`, `positionAngle`.
7. `lib/src/astronomy/visibility_models.dart` (~95 lines, a **normal file**, not a part)
   moves lines 1666-1757 verbatim: `TwilightTimes`, `MoonTimes`, `MeridianFlipWindow`,
   `ObjectVisibility`. Re-exported by the facade (above) so no import in any other package changes.

**What must not change:** the public static names and their signatures. Verification is mechanical —
`grep -c 'static ' astronomy_calculations.dart` before/after must be equal, and the existing
`test/rise_set_transit_test.dart`, `test/moon_phase_and_cardinals_test.dart`,
`test/coordinate_system_test.dart` must pass untouched.

---

### 1.2 `lib/src/catalogs/star_catalog.dart` — 1588 lines

**Why it is big.** 62% of the file is embedded *data*, not logic:

| Region | Lines | Content |
|---|---|---|
| 17-461 | 445 | `HygStarCatalog` — load, isolate CSV parse, component naming, queries |
| 462-480 | 19 | constellation name/genitive lookup helpers |
| 482-571 | 90 | `_constellationGenitives` map (88 entries) |
| 573-662 | 90 | `_constellationNames` map (88 entries) — **byte-identical duplicate**, see §2.1 |
| 666-1541 | 876 | `_fallbackBrightStars` — ~100 hard-coded `const Star(...)` literals |
| 1545-1569 | 25 | `NamedStars` — **dead**, see §3.2 |
| 1570-1588 | 19 | `_LoadStarsArgs`, `_HygRow` |

**Split plan.** `HygStarCatalog` is public and exported from the barrel
(`lib/skotiq_planetarium.dart:12`), and `_fallbackBrightStars` / `_constellation*` are
`static` private members of it. Use `part` files so privacy is preserved with zero API change.

`lib/src/catalogs/star_catalog.dart` (stays, target ~470 lines)
- keeps the imports, adds three `part` directives
- keeps `class HygStarCatalog` lines 17-480 **minus** the two map literals (which become
  library-private top-level `const`s referenced by the same helper methods)
- keeps `_LoadStarsArgs` and `_HygRow`
- **deletes** `NamedStars` (dead — §3.2) and `_constellationNames` (duplicate — §2.1); the two
  callers of `_getConstellationName` switch to `constellationFullName()` from
  `catalogs/constellation_names.dart`

New files (all `part of '../star_catalog.dart'` — put them in `lib/src/catalogs/star_catalog/`):

1. `lib/src/catalogs/star_catalog/hyg_parser.dart` (~230 lines)
   moves lines 101-158 (`_loadStarsInIsolate`), 160-211 (`_nameComponentStars`,
   `_isUnnamedComponent`, `_componentLetter`), 219-379 (`_parseHygLine`, `_parseCsvLine`) as an
   `extension _HygParsing on HygStarCatalog` — no, these are `static`; instead declare them as
   library-private **top-level** functions in the part and leave one-line `static` forwarders on
   the class only where a test references them. Today no test references any of them by name
   (`grep -rn '_parseHygLine\|_loadStarsInIsolate' test/` → no hits outside the source), so plain
   top-level functions are enough and no forwarders are needed.
2. `lib/src/catalogs/star_catalog/constellation_genitives.dart` (~92 lines)
   moves lines 482-571 as `const Map<String, String> _kConstellationGenitives`.
3. `lib/src/catalogs/star_catalog/fallback_bright_stars.dart` (~880 lines)
   moves lines 666-1541 as `final List<Star> _kFallbackBrightStars`. This file is pure data and is
   allowed to stay long; call that out in a header comment so a future audit does not re-flag it.

Result: `star_catalog.dart` ≈ 470 lines of real logic, one ~230-line parser, two data files.

---

### 1.3 `lib/src/widgets/interactive_sky_view.dart` — 1332 lines

**Why it is big.** One `ConsumerStatefulWidget` + one `State` that owns *everything*: 14 public
widget parameters (lines 31-105), 5 `AnimationController`s + a `Ticker` + momentum sampling state
(111-243), lifecycle (245-347), FrameTiming plumbing (348-366), zoom/fly-to/momentum integration
(368-586), a **401-line `build()`** (589-989) that both wires the whole gesture layer inline and
constructs the two-layer painter Stack, painter construction (999-1094), and a 136-line hit-test
(1110-1246) plus its geometry helpers (1265-1323).

It already uses 4 `part` files (lines 25-28), so extending that pattern is the low-risk move.

**One accommodation needed.** `setState` is `@protected`, so an `extension` on
`_InteractiveSkyViewState` calling it trips `invalid_use_of_protected_member`. Add a single
library-private shim on the state class and have the extracted code call it:
```dart
void _setStateFromPart(VoidCallback fn) => setState(fn);
```
Everything else the extracted code touches (`widget`, `ref`, `mounted`, `context`, the private
fields) is reachable from an extension in the same library.

**Split plan.**

`lib/src/widgets/interactive_sky_view.dart` (stays, target ~470 lines)
- imports + `part` directives (existing 4 + 4 new)
- `class InteractiveSkyView` (31-109) unchanged
- `_InteractiveSkyViewState` field declarations, `initState`, `didUpdateWidget`, `dispose`,
  `_handleFrameTimings`, the `_setStateFromPart` shim
- `build()` reduced to: the ~21 `ref.watch` reads, the `ref.listen(flyToRequestProvider)`, the
  animation-state reconciliation (622-661), the `LayoutBuilder` → `Listener` → `GestureDetector`
  → `Stack` tree, with every gesture closure replaced by a named method reference
  (`onScaleStart: _onScaleStart` etc.)
- `class _PanSample` (1327-1332)

New part files under `lib/src/widgets/interactive_sky_view/`:

1. `gestures.dart` (~180 lines) — `extension _SkyViewGestures on _InteractiveSkyViewState`
   moves the four inline gesture closures from `build()` (lines 688-845) into
   `_onScaleStart(ScaleStartDetails)`, `_onScaleUpdate(ScaleUpdateDetails)`, `_onScaleEnd(...)`,
   `_onTapUp(TapUpDetails, Size)`, `_onDoubleTapDown(...)`. Each needs the canvas `Size`, which
   `build()` already has from `LayoutBuilder`; pass it as the last positional argument (the state
   also caches it in `_lastViewSize` at line 667, but keep the explicit argument so behaviour is
   byte-identical). `setState` calls become `_setStateFromPart`.
2. `view_motion.dart` (~260 lines) — `extension _SkyViewMotion on _InteractiveSkyViewState`
   moves lines 172-241 (`_momentumSpeedPx`, `_panByPixels`), 368-406 (`_onZoomAnimation`),
   408-482 (`_onMomentumTick`, `_stopMomentum`, `_calculatePanVelocity`), 483-586 (`_pendingFOV`,
   `_zoomByStep`, `_animateZoom`, `_onFlyToAnimation`, `_startFlyTo`, `_mapMountStatus`).
   The `static const` momentum tuning constants at lines 157-171 become library-private top-level
   `const`s in this part (identical values, identical references).
3. `hit_testing.dart` (~150 lines) — `extension _SkyViewHitTesting on _InteractiveSkyViewState`
   moves lines 1097-1108 (`_handleDoubleTapZoom`), 1110-1246 (`_handleTap`), 1248-1285
   (`_coincidentStarPixels`, `_resolveCoincidentStar`), 1287-1323 (`_screenToCelestial`,
   `_angularDistance`). See §2.2 — `_angularDistance` should be deleted here and replaced with the
   canonical helper as part of the same change.
4. `painter_wiring.dart` (~110 lines) — `extension _SkyViewPainterWiring on
   _InteractiveSkyViewState` moves `_buildSkyPainter` (999-1094) verbatim.

Result: main file ~470 lines; no public API change; the existing widget tests
(`test/sky_view_tap_identity_test.dart`, `test/wheel_zoom_accumulation_test.dart`,
`test/coincident_star_pick_test.dart`, `test/sky_background_layer_test.dart`) must pass untouched.

---

### 1.4 `lib/src/planning/target_scoring.dart` — 1107 lines

**Why it is big.** Six model types (lines 18-172) + one 900-line service class holding **two
parallel scoring pipelines** (instantaneous `scoreTarget` 213-306 and full-night
`scoreTargetForNight` 320-508), five shared axis scorers (548-640), two warning generators
(642-802 and 926-1069) that are near-parallel ladders, and a trailing extension (1073-1107).

**Split plan.** `TargetScoringService` is public and exported. Private helpers can move to
`extension`s in `part` files (parts share privacy, and a private extension method is callable from
the class body when the extension is in scope in the same library).

`lib/src/planning/target_scoring.dart` (stays, target ~380 lines)
- imports + 4 `part` directives
- `typedef HorizonMask` (15)
- `class TargetScoringService`: fields + ctor (174-202), `_effectiveMinAltitude` (206-210),
  `scoreTarget` (213-306), `scoreTargetForNight` (320-508), `scoreTargets` (511-515),
  `debugScoreAltitude` / `debugScoreMoonDistance` (528-546)
- **delete** `getBestTargets` (518-526) — dead, §3.3

New files under `lib/src/planning/target_scoring/`:

1. `models.dart` (~160 lines) — a **normal file**, not a part, so it can be imported directly by
   `tonight_ranking.dart` and by `skotiq_core`'s scheduler. Moves lines 18-172:
   `ScoringWeights`, `TargetScore`, `TargetVisibilityInfo`, `WarningType`, `WarningSeverity`,
   `TargetWarning`. `target_scoring.dart` adds `export 'target_scoring/models.dart';` so every
   existing import path keeps resolving these names.
2. `axis_scores.dart` (~120 lines, part) — `extension _AxisScores on TargetScoringService`
   moves lines 548-640 (`_scoreAltitude`, `_scoreMoonDistance`, `_scoreTransitProximity`,
   `_scoreDarkness`, `_scoreAirmass`) and 866-923 (`_scoreTransitProximityForNight`,
   `_scoreImagingWindow`).
3. `warnings.dart` (~300 lines, part) — `extension _Warnings on TargetScoringService`
   moves lines 642-802 (`_generateWarnings`), 807-855 (`_moonProximityWarnings`), 857-859
   (`_formatTime`), 926-1069 (`_generateNightWarnings`). See §2.3 for the de-duplication that
   should land in the same change.
4. `checks.dart` (~40 lines, part) — moves `extension TargetCheckExtensions` (1073-1107) verbatim,
   minus `isMoonTooClose`/`getMoonDistance` if §3.3 is taken.

---

### 1.5 `lib/src/rendering/sky_renderer/solar_system_and_markers.dart` — 1084 lines

**Why it is big.** It is already a `part of '../sky_renderer.dart'` (registered at
`sky_renderer.dart:27`) but carries four unrelated concerns in one file: shared scene geometry
(`_compassPoints` 10-25, `MoonPhaseGeometry` 26-80, `extension SkyCanvasPainterSceneGeometry`
81-184), screen markers (186-428), solar-system body rendering (429-783), and small-body rendering
(784-1084).

**Split plan.** Purely mechanical: four `part of '../sky_renderer.dart'` files, each declaring its
own `extension _X on SkyCanvasPainter`, with four `part` lines replacing line 27 of
`sky_renderer.dart`. No symbol renames; the extension names are private so splitting them costs
nothing.

1. `lib/src/rendering/sky_renderer/scene_geometry.dart` (~185 lines)
   moves lines 1-184: `_compassPoints`, `class MoonPhaseGeometry` (public — keep the name; it is
   pinned by `test/moon_phase_and_cardinals_test.dart`), `extension
   SkyCanvasPainterSceneGeometry` (public, `cardinalScreenPositions` /
   `moonBrightLimbScreenAngle` are read by the same test).
2. `lib/src/rendering/sky_renderer/markers.dart` (~245 lines)
   moves 186-428: `_drawCardinalDirections`, `_drawSelectionMarker`, `_drawMountPositionMarker`.
3. `lib/src/rendering/sky_renderer/solar_bodies.dart` (~355 lines)
   moves 429-783: `_drawSun`, `_drawMoon`, `_drawPlanets`, `_drawPlanetDetails`, `_drawSaturnRings`,
   `_drawJupiterBands`, `_drawMarsPolarCap`.
4. `lib/src/rendering/sky_renderer/small_bodies.dart` (~300 lines)
   moves 784-1084: `_drawSatellites`, `_drawVariableStars`, `_drawMinorPlanets`,
   `_drawMinorPlanetLabel`.

Add `// ignore_for_file: unused_element, unused_field` to each new file, matching the existing
header convention of the sibling part files.

---

### 1.6 `lib/src/widgets/object_details_panel/content_sections.dart` — 1012 lines

**Why it is big.** One `extension _ObjectDetailsPanelContentSections on ObjectDetailsPanel`
(line 3) with 16 `_build*` methods covering four unrelated panel regions. It is already a
`part of '../object_details_panel.dart'` (registered at `object_details_panel.dart:10`).

**Split plan.** Four part files, each with its own private extension on `ObjectDetailsPanel`;
replace line 10 of `object_details_panel.dart` with four `part` lines.

1. `object_details_panel/header_sections.dart` (~250 lines)
   moves `_buildHeader` (4-63), `_buildHeaderWithThumbnail` (64-151), `_buildThumbnail` (740-796),
   `_thumbnailFovDeg` (797-...), plus the DSO icon/colour helpers used only by those.
2. `object_details_panel/catalog_sections.dart` (~210 lines)
   moves `_buildCoordinatesSection` (152-196), `_buildCatalogSection` (197-253),
   `_buildPhysicalPropertiesSection` (254-301), `_buildInfoRow` (633-...).
3. `object_details_panel/visibility_sections.dart` (~470 lines)
   moves `_buildVisibilitySection` (302-349), `_buildVisibilityGraph` (350-390),
   `_buildAirmassChart` (391-433), `_buildAirmassLegendDot` (434-451),
   `_buildRiseTransitSetSection` (452-524), `_buildTimeColumn` (525-553), `_buildQuickStats`
   (849-975), `_buildVisibilityIndicator` (976-1012). This is the file the §4.1 perf fix lands in.
4. `object_details_panel/action_sections.dart` (~80 lines)
   moves `_buildActionButtons` (554-632).

---

### 1.7 Watch-items (under the bar, do not split now)

- `lib/src/planning/target_scoring.dart`'s sibling `lib/src/catalogs/catalog_manager/unified_catalog_api.dart`
  (780 lines) — will shrink materially if §2.4 is taken.
- `lib/src/providers/planetarium_providers/object_search.dart` (752) and
  `lib/src/rendering/sky_renderer/render_cache.dart` (737) are cohesive; leave them.
- The constellation-figure and variable-star data files
  (`constellation_art/figures_early.dart` 795, `figures_late.dart` 791,
  `constellation_data/boundaries.dart` 786, `line_figure_sets/figures_0*.dart` 603-672,
  `variable_star_catalog/star_data_part*.dart` 555/563) are pure data already chunked; leave them.

---

## 2. Duplication (inside this package)

### 2.1 The IAU constellation-name table exists twice, byte-for-byte

- Canonical: `lib/src/catalogs/constellation_names.dart:8-97`
  `const Map<String, String> kConstellationNamesByAbbreviation` + `constellationFullName()`
  (:102-105). Exported from the barrel (`lib/skotiq_planetarium.dart:15`) and used by
  `lib/src/catalogs/catalog.dart:335` and
  `packages/skotiq_app/lib/screens/planner/planner_screen_parts/_filter_controls.dart:265,325`.
- Duplicate: `HygStarCatalog._constellationNames`, `lib/src/catalogs/star_catalog.dart:573-662`.

Evidence: extracting both regions and `diff`ing them shows **zero** differing lines across all 88
entries (only the trailing `};` / next-declaration lines differ, which are outside the literal).

**Canonical survivor:** `kConstellationNamesByAbbreviation` / `constellationFullName`.
**Merge:** delete `star_catalog.dart:573-662`; rewrite `_getConstellationName` (`:470-472`) as
`constellationFullName(abbr)`; rewrite `_getConstellationAbbr` (`:475-480`) to scan
`kConstellationNamesByAbbreviation.entries` instead. Effort: **small**.

Note the *genitive* map (`:482-571`) has no twin — it stays, and moves to its own file per §1.2.

### 2.2 Four hand-rolled great-circle angular-separation helpers

| Location | RA units | Formula |
|---|---|---|
| `lib/src/astronomy/astronomy_calculations.dart:1615-1631` `angularSeparation` | degrees | spherical law of cosines |
| `lib/src/widgets/interactive_sky_view.dart:1312-1323` `_angularDistance` | hours | spherical law of cosines |
| `lib/src/catalogs/spatial_index.dart:430-441` `_angularDistance` | hours | spherical law of cosines |
| `lib/src/catalogs/catalog_manager/source_models.dart:7-27` `_angularDistance` | degrees | haversine |

The two `hours` variants are line-for-line identical apart from a comment. The haversine variant in
`source_models.dart` is numerically *better* at small separations and is what `catalog_loaders.dart:95`
and `:224` use for cone search — so the two families can disagree at arcsecond scale, which matters
for the coincident-star merge at `interactive_sky_view.dart:1270` (a 2-pixel threshold).

**Canonical survivor:** one implementation in `AstronomyCalculations`, switched to the haversine
form (strictly more accurate, same result to double precision at large separations), plus a
`CelestialCoordinate`-typed convenience in `lib/src/coordinate_system.dart` (which today has *no*
separation helper — `grep -n 'separation' lib/src/coordinate_system.dart` → no hits):
```dart
extension CelestialSeparation on CelestialCoordinate {
  double separationDegrees(CelestialCoordinate other) => AstronomyCalculations.angularSeparation(
    ra1Deg: raDegrees, dec1Deg: dec, ra2Deg: other.raDegrees, dec2Deg: other.dec);
}
```
**Merge:** delete `interactive_sky_view.dart:1312-1323` and `spatial_index.dart:430-441`, replace
their 6 call sites (`interactive_sky_view.dart:1139,1162,1190,1214,1277`; `spatial_index.dart:396`)
with `a.separationDegrees(b)`; delete `source_models.dart:7-27` and point
`catalog_loaders.dart:95,224` at `AstronomyCalculations.angularSeparation`.
Effort: **small**. `lib/src/sky_view.dart:413` is *not* part of this — it is a projection, not a
separation helper; leave it.

### 2.3 The two target-scoring pipelines duplicate their warning ladders

`TargetScoringService` runs two parallel pipelines that share axis scorers but fork on warnings:

- `_generateWarnings` (`target_scoring.dart:642-802`) — altitude ladder at 651-687, airmass ladder
  at 690-708.
- `_generateNightWarnings` (`:926-1069`) — altitude ladder at 939-969, airmass ladder at 972-990.

The two ladders use the **same thresholds** (0 / 15 / 30 deg; 2.0 / 2.5 airmass) and the **same
severities**, differing only in message wording ("Low altitude" vs "Low peak altitude") and one
`suggestion` string. The moon ladder was already factored out to `_moonProximityWarnings` (:807),
which proves the shape is factorable.

**Canonical survivor:** one parameterised pair of helpers on the service:
```dart
List<TargetWarning> _altitudeWarnings(double alt, {required bool isPeak, ObjectVisibility? v});
List<TargetWarning> _airmassWarnings(double airmass, {required bool isBest});
```
called from both generators, with the wording chosen from the flag. Behaviour-preserving as long as
the exact strings are kept per branch — `test/planning/target_scoring_parity_test.dart:107` already
pins moon-warning parity between the two entry points, so extend it to the altitude/airmass ladders
in the same change. Effort: **medium** (the strings are asserted in several tests).

### 2.4 Two independent catalog download/install pipelines

`CatalogManager` carries two complete, separately-maintained implementations of "fetch a catalog,
verify its SHA-256, decompress it, write a metadata sidecar":

- **Legacy** (`catalog_manager/legacy_catalog_io.dart`): `_downloadCatalog` (:34), `_fetchCatalogCandidate`
  (:208), `_promoteTempFile` (:339), `_saveMetadata` (:400), `_importCatalog` (:442). Public entry
  points `downloadStarCatalog`/`downloadDsoCatalog`/`importCatalog`/`deleteCatalogs`
  (`manager.dart:477-505`). **This is what the desktop/mobile GUI uses**
  (`skotiq_app/lib/screens/settings/catalog_settings_screen.dart:262,271`,
  `skotiq_app/lib/widgets/catalog_setup_dialog.dart:66,90`,
  `skotiq_planetarium/lib/src/providers/catalog_providers.dart:125,137`).
- **Unified** (`catalog_manager/unified_catalog_api.dart`): `_downloadAndInstallCatalog` (:169),
  `_fetchUnifiedCandidate` (:395), `_installCatalogFromFile` (:523). Public entry points
  `downloadAndInstall`/`installFromFile`/`listAvailable`/`uninstall`/`verify`
  (`manager.dart:537-574`). **This is what the headless REST surface uses**
  (`apps/desktop/lib/headless_api/handlers/catalog_handlers.dart:223,366,178,488,134`).

The *registry* was already unified (`manager.dart:323-348` derives `CatalogDescriptor`s from the
legacy `CatalogSource` constants, and both write the same sidecar filenames), but the *pipelines*
have visibly drifted:

| | legacy | unified |
|---|---|---|
| sidecar keys | `source`(short name), `version`, `package`, `objectCount`, `installedDate`, `sha256` (`legacy_catalog_io.dart:428-436`) | `source`(display name), `name`, `version`, `sha256`, `objectCount`, `sizeBytes`, `installedDate`, `downloadUrl` (`unified_catalog_api.dart:295-306`) |
| `installedDate` | local time (`DateTime.now()`, :434) | UTC (`DateTime.now().toUtc()`, :294) |
| `CatalogEvent` stream | never emitted | emitted at :213, :315, :349, :361 |
| non-gzip transfer | streams to disk, chunked SHA (:301-327) | buffers whole file, then `readAsBytes` (:434, :489) |
| gzip buffering | `BytesBuilder(copy: false)` (:278) | `<int>[]` + `addAll` (:435, :445) — see §4.2 |

Practical consequence: a catalog installed from the desktop GUI produces a sidecar the headless
`GET /api/catalog/status` reads with `name`/`sizeBytes`/`downloadUrl` absent, and no client watching
the catalog event stream ever learns the install happened.

**Canonical survivor:** the **unified** pipeline (it is the one with events, per-name addressing and
`verify`), **after** it adopts the legacy transfer code (which is strictly better — §4.2).
**Merge:** reimplement `_downloadCatalog`/`_importCatalog` as thin adapters that map
`(CatalogSource, type, CatalogPackage)` → descriptor name and call `_downloadAndInstallCatalog` /
`_installCatalogFromFile`, translating `CatalogInstallResult` back into the `bool` +
`DownloadProgress` shape the GUI expects. Delete `_fetchCatalogCandidate` only after moving its
streaming/chunked-hash body into `_fetchUnifiedCandidate`. Keep
`test/catalog_manager_legacy_io_test.dart` and `test/catalog_manager_install_test.dart` green as the
contract. Effort: **large**.

### 2.5 Two independent HYG star-load chains run simultaneously

Two separate `HygStarCatalog` instances load and retain the full ~120k-row HYG CSV at once:

- Chain A — `catalog_providers.dart:174` `starCatalogProvider = HygStarCatalog()` (default
  `magnitudeLimit = 15.0`, `star_catalog.dart:29`) → `starsProvider` (:184) →
  `starCatalogFallbackProvider` (:195). Forced alive in the running app by
  `skotiq_app/lib/screens/planetarium/widgets/star_catalog_fallback_banner.dart:20` and
  `.../star_chart_depth_notice.dart:24`.
- Chain B — `planetarium_providers/catalog_astronomy.dart:7` `loadedStarsProvider =
  HygStarCatalog(magnitudeLimit: 12.0)` → `starSpatialIndexProvider` (:22) →
  `fovFilteredStarsProvider` (:72) → `combinedStarsProvider`
  (`deep_star_providers.dart:138`) → what `interactive_sky_view.dart:597` actually draws.

Neither instance's cache is shared (`_cachedStars` is per-instance, `star_catalog.dart:21`), so the
CSV is parsed twice in two `compute` isolates and two full `List<Star>` are retained for the process
lifetime — the *deeper* of the two (mag ≤ 15) existing only to answer the boolean
`isUsingFallback`. Chain A also means the fallback banner reports on a catalog object that is **not**
the one on screen.

**Canonical survivor:** chain B (`loadedStarsProvider`), which the renderer and the search both use.
**Merge:** make `starCatalogProvider` return the same instance chain B uses (hoist a single
`HygStarCatalog(magnitudeLimit: 12.0)` provider and have `loadedStarsProvider` read it), then
redefine `starsProvider` as `ref.watch(loadedStarsProvider)` and `starCatalogFallbackProvider` on
that instance. Delete `dsosProvider`/`dsoCatalogProvider` (dead, §3.5) at the same time.
Effort: **medium** — verify `star_catalog_fallback_banner_test.dart` and
`star_chart_depth_notice_test.dart` still pass (both override the provider, so they should).

### 2.6 Three FOV-overlay renderers, one of them production-dead

- `lib/src/widgets/interactive_sky_view/fov_overlay_painter.dart` — `_FOVOverlayPainter` +
  `SkyFovProjector`. **Live**: `interactive_sky_view.dart:911`.
- `lib/src/widgets/multi_fov_overlay.dart` — `MultiFovOverlay`, uses `SkyFovProjector`.
  **Live**: `skotiq_app/.../layouts.dart:104,409`, `.../planetarium_shell.dart:141`.
- `lib/src/rendering/fov_overlays.dart` (535 lines) — `FOVType`, `FOVIndicator`,
  `FOVOverlayPainter`, `FOVOverlayWidget`. **No production caller**: `FOVOverlayPainter` appears
  only in `benchmark/src/benchmark_scene.dart:122` and `test/fov_overlay_projection_test.dart:513`;
  `FOVOverlayWidget` appears only at its own definition (`:493`) and its own body (`:523`).

**Canonical survivor:** `SkyFovProjector` + `_FOVOverlayPainter` + `MultiFovOverlay`.
**Merge/removal:** `FOVOverlayWidget` can be deleted outright. `FOVOverlayPainter` /
`FOVIndicator` / `FOVType` are load-bearing only for the benchmark and one test, so either
(a) move the whole file into `benchmark/src/` and drop it from the barrel
(`lib/skotiq_planetarium.dart:39`), or (b) delete it and retarget
`benchmark_scene.dart:122` at `MultiFovOverlay`'s painter. Option (b) is the right one — the
FrameTiming lab currently spends part of its measured budget on a painter production never runs,
which makes the benchmark number optimistic about the wrong thing. Effort: **medium**.

---

## Cross-package duplication suspects (one line each, for the cross-cutting agent)

- `TargetScoringService._scoreAltitude` / `_scoreMoonDistance` (`target_scoring.dart:548,556`) vs the
  Rust twin `skotiq_sequencer::scheduling::scoring::{score_altitude, score_moon_distance}` — the
  source's own comment at `:538-543` records that the Rust copy silently diverged for months.
- `AstronomyCalculations.airmass` / `airmassForTrueAltitude` (`astronomy_calculations.dart:19,1605`)
  vs `skotiq_imaging::calculate_airmass` and `skotiq_sequencer::scheduling::astronomy::airmass`
  (both named in the file's own doc comments at :15 and :1603).
- `MosaicPlanner.generateRectangularMosaic` (`services/mosaic_planner.dart`) vs `skotiq_core`'s
  `MosaicService` — already has a parity test (`skotiq_core/test/services/mosaic_geometry_parity_test.dart`)
  but remains two implementations.
- `SurveyImageService` + `SurveyImage` (`services/survey_image_service.dart:123,157`, both dead here —
  §3.4) vs the live framing survey-image service in `skotiq_core`
  (`loadCachedSurveyImage` / `saveSurveyImage`, `skotiq_core/lib/src/providers/framing_image_cache_provider.dart:55`).
- `FramingView` (`widgets/framing_view.dart:9`, dead here — §3.1) vs the live
  `FramingView` in `skotiq_app/lib/screens/framing/framing_screen.dart:28` — **same class name,
  both reachable in one import scope**, so this is a latent ambiguous-import hazard as well as dead code.
- `HygStarCatalog.getStarsNear` (`star_catalog.dart:435`) is mirrored by closure-injected twins in
  `skotiq_core/lib/src/services/master_annotation_service.dart:25` and
  `color_calibration_service.dart:15` (their own comments say "Mirrors `HygStarCatalog.getStarsNear`").
- `constellationFullName` (`catalogs/constellation_names.dart:102`) is consumed from
  `skotiq_app`'s planner — confirm no third copy exists in `skotiq_core`'s target library.

---

## 3. Dead code

Evidence method for each: `grep -rn "<symbol>" --include='*.dart' packages apps | grep -v dart_tool`,
run across the whole monorepo (all packages **and** `apps/desktop`, which is where the headless API
routes live). Test-only and benchmark-only callers are called out explicitly rather than counted as
live.

### 3.1 `FramingView` — an entire 640-line widget file with zero consumers
`lib/src/widgets/framing_view.dart` declares `FramingView` (:9) plus `_FramingViewState`,
`_StarFieldPainter`, `_GridPainter`, `_FOVPainter`, `_MosaicOverlayPainter`, `_CrosshairPainter`,
`_ZoomControls`, `_ZoomButton`, `_ScaleIndicator`. It is exported at
`lib/skotiq_planetarium.dart:70`.
Evidence: `grep -rn "framing_view.dart\|FramingViewWidget"` across packages+apps returns **only**
that export line. `grep -rn "\bFramingView\b"` returns only
`skotiq_app/lib/screens/framing/framing_screen.dart` — which declares its **own** unrelated
`FramingView` (:28) and does not import the planetarium one.
Action: delete the file and its barrel export. Note this also removes a name collision.

### 3.2 `NamedStars`
`lib/src/catalogs/star_catalog.dart:1545-1569` — `static final HygStarCatalog _catalog`,
`_loadIfNeeded`, `findByName`, `allNames`.
Evidence: `grep -rn "\bNamedStars\b" --include='*.dart' packages apps` → the class declaration only.
Extra hazard if ever revived: it instantiates a **third** `HygStarCatalog` (`:1546`), compounding §2.5.

### 3.3 Unused public methods on `TargetScoringService`
- `getBestTargets` (`target_scoring.dart:518-526`) — `grep -rn "getBestTargets"` → the definition only.
- `isMoonTooClose` (`:1100-1106`) — `grep -rn "isMoonTooClose"` → the definition only.
- `getMoonDistance` (`:1089-1097`) — only caller is `isMoonTooClose` (`:1102`), so it dies with it.

`isObservable` (`:1077`) is **not** dead — `test/planning/target_scoring_horizon_mask_test.dart:135,144,152`.
`debugScoreAltitude`/`debugScoreMoonDistance` (`:533,545`) are **not** dead — they are `@visibleForTesting`
parity seams used by `test/planning/target_scoring_parity_test.dart:68,99,289,398,411`; keep them.

### 3.4 The whole survey-image cache service
`lib/src/services/survey_image_service.dart:123-155` (`class SurveyImage`, `decodeImage`) and
`:157-198` (`class SurveyImageService`, `_cacheKey`, `isCached`, `getCached`, `cacheImage`,
`clearCache`, `availableSources`).
Evidence: `grep -rn "SurveyImageService\|SurveyImage("` across packages+apps → the declarations only;
`grep -rn "decodeImage\b\|isCached\|cacheImage\|getCached\|availableSources"` → no planetarium hits.
The live thumbnail path builds a URL from `SurveyImageRequest` and hands it straight to
`Image.network` (`object_details_panel/content_sections.dart:741,763`), never touching the service.
`SurveySource`, `SurveyImageRequest`, `FOVCalculator` and `CameraSensorSpecs` in the same file **are**
live; only the two cache classes go.

### 3.5 Dead catalog providers
`lib/src/providers/catalog_providers.dart:179` `dsoCatalogProvider` and `:207` `dsosProvider`.
Evidence: `grep -rn "dsoCatalogProvider"` → the definition and `dsosProvider`'s body; `grep -rn "\bdsosProvider\b"`
→ the definition only. (The live DSO chain is `loadedDsosProvider`,
`planetarium_providers/catalog_astronomy.dart:15`, consumed by
`skotiq_app/lib/screens/planetarium/widgets/catalog_tab.dart:15` and
`skotiq_app/lib/screens/framing/framing_search_provider.dart:59`.)

### 3.6 Dead planning providers
`lib/src/providers/planning_providers.dart` in its entirety (31 lines):
`targetScoringServiceProvider` (:6) and `selectedTargetScoreProvider` (:24).
Evidence: `grep -rn "selectedTargetScoreProvider\|targetScoringServiceProvider"` across packages+apps
returns **only** lines 6, 24 and 28 of that file. Exported at `lib/skotiq_planetarium.dart:56`.
Worth noting for the perf reviewer: because these are dead, the once-per-second re-score they would
otherwise cause (`:8` watches the 1 Hz `observationTimeProvider`) does **not** happen today — do not
report it as a live perf bug.

### 3.7 The renderer's memory-pressure release path is never wired up
`lib/src/rendering/sky_renderer/render_cache.dart:190` `_PaintCache.clearCaches()` — doc says "call
when memory pressure is high". Evidence: `grep -rn "clearCaches()"` across packages+apps → the
definition only. Its only downstream, `SkyCanvasPainter.disposeSpriteAtlas()`
(`sky_renderer.dart:323`), is therefore also unreachable — the baked GPU sprite atlas is never
disposed. Likewise `_ProjectionCache.clear()` (`render_cache.dart:731`): `grep -rn "projectionCache"`
→ only the field (`sky_renderer.dart:151`), `ensurePose` (`paint_lifecycle.dart:27`) and
`_projectObjectCulled` (`projection_and_glow.dart:184`).
This is dead code *and* a reliability gap — see §5.4. Fix by wiring `clearCaches()` to
`WidgetsBindingObserver.didHaveMemoryPressure`, not by deleting it.

### 3.8 Unused `HygStarCatalog` query methods
- `getStarsByMagnitude` (`star_catalog.dart:411-414`) — `grep` → definition only.
- `getStarsInConstellation` (`:417-427`) — `grep` → definition only; its helper
  `_getConstellationAbbr` (`:475-480`) dies with it.

`getStarsNear` (`:435`) is live — `skotiq_app/lib/screens/framing/widgets/guide_star_overlay.dart:72`
and `skotiq_core/lib/src/services/master_annotation_service.dart:241`.

### Explicitly checked and NOT dead (recorded so a later pass does not re-litigate)
`FovRingsOverlay`, `SkyMinimap`, `CompassHud`, `MultiFovOverlay`, `TimeControlPanel`,
`ObjectDetailsPanel`, `AdaptiveSizing`/`FormFactor`, `FOVCalculator`, `CameraSensorSpecs`,
`SurveySource`, `SurveyImageRequest`, `MosaicPlanner`, `targetQueueProvider`,
`starSpatialIndexProvider`/`dsoSpatialIndexProvider`, `HygStarCatalog.fallbackStarCount`,
`HygStarCatalog.isUsingFallback`, `scoreTarget`, `scoreTargetForNight`, `scoreTargets`,
`isObservable` — all have production or headless callers outside this package.

---

## 4. Performance risks

### 4.1 The object-details panel runs two full rise/set/transit solves per second on the UI isolate — **high**
`lib/src/widgets/object_details_panel.dart:76` does `ref.watch(observationTimeProvider)` at the panel
root. `observationTimeProvider` is driven by a 1 Hz `Timer.periodic`
(`providers/planetarium_providers/observer_time.dart:127-134`), so the whole panel subtree rebuilds
every second. Inside that rebuild:
- `content_sections.dart:454` re-watches it, `:460` calls `AstronomyCalculations.calculateObjectVisibility`;
- `content_sections.dart:851` re-watches it, `:854` calls `calculateObjectVisibility` again.

Each call samples altitude every 5 minutes over a 24 h window — 289 samples
(`astronomy_calculations.dart:1253-1260`), each a `localSiderealTime` + `equatorialToHorizontal`
trig chain — plus bisection refinement of every crossing (`_refineAltitudeCrossing`, :1281/:1292)
and a ternary transit search (`_refineTransit`, :1385). Both calls anchor on
`nightDateOf(obsTime.time)` (`:463`, `:857`), a value that changes only at local noon, so ~86,400
consecutive evaluations return an identical result.

Fix: memoise per `(object, nightDate, site)` in a `Provider.family`, and switch the panel root to
`observationMinuteProvider` (`providers/planetarium_providers/catalog_astronomy.dart:180`) — the
"now" marker only needs minute resolution. `chart_painters.dart:70,231` should read the memoised
value too.

### 4.2 The headless catalog install buffers the entire payload in a boxed `List<int>` — **high**
`lib/src/catalogs/catalog_manager/unified_catalog_api.dart`:
- `:435` `final compressedBuffer = isGzipped ? <int>[] : null;`
- `:445` `compressedBuffer!.addAll(chunk);` — a growable `List<int>` of *tagged* elements, ~8 bytes
  per byte on a 64-bit VM, with doubling reallocation copies along the way. The star catalog is
  ~35 MB gzipped (`manager.dart:329` records ~35 MB), so this is on the order of 280 MB resident.
- `:471` `Uint8List.fromList(compressedBuffer!)` — full copy #2.
- `:479` `Uint8List.fromList(gzip.decode(compressed))` — the decompressed payload materialised twice.
- `:489` non-gzip branch: `finalBytes = await tempFile.readAsBytes()` reads the whole installed file
  into memory. The comment at `:492` explicitly contemplates "a multi-GB TAP payload" for GLADE+.
- `unified_catalog_api.dart:283` then runs `sha256.convert(finalBytes)` over the in-memory buffer.

The legacy path already does this correctly: `BytesBuilder(copy: false)`
(`legacy_catalog_io.dart:278`) for gzip, and stream-to-disk with `sha256.startChunkedConversion`
(`:305-320`) for the non-gzip case, never holding the file.

This is the Raspberry Pi appliance's install path. Fix by folding the legacy transfer body into
`_fetchUnifiedCandidate` as part of §2.4, and returning a `File` + digest instead of `Uint8List`.

### 4.3 A second full HYG parse and a second retained 120k-star list — **medium**
See §2.5 for the full evidence. Two `HygStarCatalog` instances (`catalog_providers.dart:174` at
mag ≤ 15, `planetarium_providers/catalog_astronomy.dart:12` at mag ≤ 12) each run
`_loadStarsInIsolate` (`star_catalog.dart:101`) over the same ~120k-row CSV and each retain the
result in `_cachedStars` (`:21`) for the process lifetime. Cost: one extra isolate spawn + CSV
parse at startup, and roughly a doubling of star-catalog resident memory.

### 4.4 The static projection cache pins the catalog after the sky view is gone — **medium**
`SkyCanvasPainter._projectionCache` (`sky_renderer.dart:151`) is a `static final _ProjectionCache`
whose `_entries` (`render_cache.dart:677`) is an unbounded `Map<Object, Offset?>` keyed by the
*catalog object itself* (`_projectObjectCulled`, `projection_and_glow.dart:184-199`, stores an entry
for culled objects too, `:190`). It is emptied only when the pose changes
(`render_cache.dart:711`), and `clear()` (`:731`) has no callers (§3.7). Consequences:
- at a static pose it grows to one entry per object iterated — up to
  `qualityConfig.maxStarsToRender` + DSOs + constellation vertices;
- because entries are strong references to `Star`/`DeepSkyObject` instances, closing the planetarium
  screen does not release them; they survive until some other painter changes the pose.

Fix: call `_projectionCache.clear()` from the same memory-pressure hook that §3.7/§5.4 wires up, and
from `_InteractiveSkyViewState.dispose()`.

### 4.5 Solar-system search positions recompute every minute whether or not search is open — **low/medium**
`providers/planetarium_providers/object_search.dart:313-346` `solarSystemSearchObjectsProvider` is a
plain (non-`autoDispose`) `Provider` that `ref.watch(observationMinuteProvider)` (`:314`) and on every
minute recomputes VSOP87 for all major planets (`:317`) plus
`KeplerianPropagator.computePositions` over the *entire* effective minor-body element set
(`:329-332`, backed by `element_refresh_providers.dart:47`, which unions the bundled catalog with
whatever `Soft00Bright.txt` + `CometEls.txt` supplied). Its only consumer is a `ref.read` inside the
search notifier (`object_search.dart:618`), so once a single search has run the recompute continues
for the rest of the session on the UI isolate.
Fix: make it `Provider.autoDispose`, or compute it lazily at `:618` instead of reactively.
Bounded today by the `H <= 14` filter (`element_refresh_service.dart:56`) — hence "low/medium", not high.

### 4.6 Tap hit-testing is a linear scan of the whole visible star list — **low**
`interactive_sky_view.dart:1138-1156` iterates every star in `combinedStarsProvider`, then
`_resolveCoincidentStar` (`:1265-1285`) iterates them all a second time, then satellites (`:1188`)
and planets (`:1212`). At an imaging FOV with deep-star tiles loaded, `combinedStarsProvider`
(`deep_star_providers.dart:138-147`) can hold `maxStarsToRender` entries. The package already ships
`CelestialSpatialIndex` with a cone query (`spatial_index.dart:396`) that this path does not use.
Per-tap only, so impact is a hitch, not a frame-rate problem.

### Checked and found NOT to be a problem (recorded to prevent re-flagging)
- `rankTonightTargets` (`planning/tonight_ranking.dart:144`) is heavy (a per-target night sampling
  loop plus a 289-sample visibility solve, `:202`, `:263`) but is already run off the UI isolate via
  `compute` (`providers/planetarium_providers/mosaic_targets.dart:187`).
- The `_TextCache` (500 entries, `render_cache.dart:212`), `_ShaderCache` (512,
  `render_cache.dart:252`), `_blurFilters`/`_blurPaints` (64 each, `render_cache.dart:8,105`) and
  `_paintTimings` (60, `sky_renderer.dart:221`) are all explicitly bounded.
- The star draw loop (`sky_renderer/stellar_objects.dart:67-200`) is genuinely well optimised —
  magnitude-sorted early `break` (`:72`, `:81`), cull-before-project (`:84`), reused static scratch
  buffers (`:180`), one `drawRawAtlas` per variant.
- `_shouldRepaint`'s minute-granularity time comparison (`paint_lifecycle.dart:423,477`) does *not*
  miss a whole-hour time jump, because `sunPosition`/`moonPosition` change with it and are compared
  unconditionally at `:483-484`.

---

## 5. Reliability risks

### 5.1 No timeout anywhere on the catalog download streams — a stalled connection is unkillable
Three download paths open a `http.Client`, `await client.send(request)`, then `await for` over the
response stream, with **no** `.timeout(...)` on either the send or the stream:
- `lib/src/catalogs/catalog_manager/legacy_catalog_io.dart:216,225,279,312`
- `lib/src/catalogs/catalog_manager/unified_catalog_api.dart:403,412,438`
- `lib/src/catalogs/catalog_manager/annotation_catalog_io.dart:69,79`

Worse, the cancellation token is polled **only on chunk arrival**: legacy checks `isCancelled` inside
`onChunk` (`legacy_catalog_io.dart:268`), which is called from the stream loop (`:281`, `:315`);
unified checks it at the top of the loop body (`unified_catalog_api.dart:439`). If the TCP connection
stalls with no further chunks, no `isCancelled` poll ever runs, so the Cancel button in
`catalog_settings_screen.dart` / `catalog_setup_dialog.dart` does nothing and the progress bar sits
frozen forever. `grep -rn "\.timeout(" lib/` finds timeouts only in `geolocation_service.dart:31,82`
and `element_refresh_service.dart:592`.
Fix: an inactivity timeout on the stream (`.timeout(const Duration(seconds: 30))` on the
`response.stream` subscription) plus a connect timeout, and poll the cancel token from a periodic
timer rather than from chunk arrival.

### 5.2 A failed star-catalog load is silently reported as an empty sky
`lib/src/catalogs/star_catalog.dart:79-95`: if the `compute` isolate throws, the catch at `:87` logs
and `return []` **without** setting `_cachedStars` and **without** setting `_usingFallback = true`
(`:73` is the only place that flag is set). Consequences:
1. `starCatalogFallbackProvider` (`catalog_providers.dart:195`) stays `false`, so the "catalog not
   installed" banner does not fire — the app renders a black sky and claims the catalog is fine.
2. Because `_cachedStars` stays null, every subsequent `loadObjects()` re-runs the whole 120k-row
   parse.
Fix: distinguish "no file" / "parse failed" / "loaded" in the returned state and surface the failure;
cache the failure so it is not retried on every rebuild.

### 5.3 `loadObjects` uses a 100 ms busy-poll instead of a shared future
`star_catalog.dart:57-63` and the identical pattern in `catalog.dart:52-57`:
```dart
if (_isLoading) { while (_isLoading) { await Future.delayed(const Duration(milliseconds: 100)); }
  return _cachedStars ?? []; }
```
Two concurrent callers therefore differ in what they get: the winner gets the real list, the loser
gets whatever `_cachedStars` happens to be when its poll wakes — `[]` on the failure path of §5.2.
Fix: hold a `Completer<List<Star>>`/shared `Future` and have all callers await it.

### 5.4 There is no memory-pressure release path for the renderer's GPU-backed caches
`_PaintCache.clearCaches()` (`render_cache.dart:190`) — the function that disposes cached
`TextPainter`s (`:243`), shaders (`:284`) and the baked sprite atlas
(`:205` → `SkyCanvasPainter.disposeSpriteAtlas`, `sky_renderer.dart:323`) — has **no callers**
anywhere (§3.7). The sprite atlas is a `ui.Image` produced by `Picture.toImageSync`
(`sky_renderer.dart:198-210` doc, baked in `_atlas`, `:294-310`) and is only ever `dispose()`d when
re-baked at a different DPR/softness (`:303`). On a memory-constrained appliance nothing ever
releases these.
Fix: register a `WidgetsBindingObserver` (or a `ServicesBinding` memory-pressure listener) in the
package that calls `_PaintCache.clearCaches()` and `_projectionCache.clear()`.

### 5.5 Static per-layer state is shared across all `SkyCanvasPainter` instances
`SkyCanvasPainter._baseLabelRects` (`sky_renderer.dart:143`) is a `static` used to hand label
occupancy from the base layer to the overlay layer (written `paint_lifecycle.dart:277`, read `:37`).
`_projectionCache` (`:151`), `_pointScratch` (`:163`), `_atlasTransforms`/`_atlasRects`/
`_atlasColors` (`:260-269`) and the `_paintTimings` window (`:220`) are static for the same reason.
This is sound while exactly one sky view paints, but `SkyCanvasPainter` is also constructed by
`skotiq_app/lib/services/finder_chart_service.dart:180` at a completely different pose and size.
Painting a finder chart while the sky view is on screen will:
- invalidate `_projectionCache` (`render_cache.dart:698-711`), forcing the sky view to re-project
  its entire visible catalog on its next frame;
- overwrite `_baseLabelRects` with the finder chart's occupancy, so the sky view's overlay layer
  seeds star-name layout from a foreign canvas;
- pollute `_paintTimings`/`_overBudgetCount`, which drive the "consider lowering render quality"
  warning at `paint_lifecycle.dart:370-390`.
Fix: key the projection cache and label hand-off on a painter-group identity (e.g. a small
`SkyRenderSession` object the host owns and passes in) rather than on process-global statics.

### 5.6 Grid warm-up runs synchronously on the UI isolate from a detached future
`providers/planetarium_providers/catalog_astronomy.dart:30-42` and `:53-65` schedule
`Future.delayed(400ms, () => index.warmGrid())`. `warmGrid` → `_ensureGrid`
(`spatial_index.dart:41-56`) allocates a `raCells × decCells` nested `List` and appends **every**
catalog object into it — a synchronous O(n) pass over ~120k stars on the UI isolate, in a future
nobody awaits and nobody cancels. If the provider is disposed inside that 400 ms window the work
still runs. The comment correctly says this is a latency optimisation; the problem is only that it
is unawaited and un-cancellable.
Fix: hold the `Timer`/subscription and cancel it in `ref.onDispose`.

### 5.7 Best-effort catches that hide real failures
- `catalog_manager/unified_catalog_api.dart:266`, `:340`, `:373` — bare `catch (_)` inside the
  install path's cleanup/rollback; a failed temp-file delete leaves a partial catalog on disk with
  no trace.
- `catalogs/deep_star_catalog.dart:167` and `catalogs/mpcorb.dart:124,230` — bare `catch (_)`
  around parse paths.
- `catalogs/catalog_manager/legacy_catalog_io.dart:370` and
  `services/element_refresh_service.dart:615` — bare `catch (_)` in temp-file cleanup; these two are
  genuinely best-effort and documented as such, so leave them.

---

## Suggested order of work

1. §3 deletions (framing_view.dart, NamedStars, planning_providers.dart, dsosProvider/dsoCatalogProvider,
   SurveyImageService/SurveyImage, getBestTargets/isMoonTooClose/getMoonDistance,
   getStarsByMagnitude/getStarsInConstellation) — ~800 lines removed with no behavioural surface.
2. §2.1 + §2.2 (constellation map, angular separation) — small, and they shrink `star_catalog.dart`
   and `interactive_sky_view.dart` before the splits.
3. §5.1 (download timeouts) and §5.2/§5.3 (star-load failure honesty) — ship-blocking-adjacent.
4. §2.5/§4.3 (single star-load chain) — one provider rewire, big memory win.
5. §4.1 (details-panel per-second visibility solves).
6. §1 splits, in this order: `star_catalog.dart` (data-only moves, lowest risk) →
   `solar_system_and_markers.dart` (part-file moves) → `content_sections.dart` →
   `astronomy_calculations.dart` (facade) → `target_scoring.dart` → `interactive_sky_view.dart`.
7. §2.4/§4.2 (unify the two catalog install pipelines) — large; do last, behind the tests.
