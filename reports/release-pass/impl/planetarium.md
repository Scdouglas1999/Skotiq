# Release-pass implementation log — batch `planetarium`

Scope: `packages/skotiq_planetarium/**` (+ its test dir).

## Item 1 — DELETE the evidenced-dead lines

Fresh re-proof, run across `packages apps tools native` with `--include='*.dart'`, `dart_tool` filtered.

### 1a. `framing_view.dart` / `FramingView` — **FALSE POSITIVE**

The work order (§3.1) claims zero consumers. It has one:

```
packages/skotiq_app/lib/screens/sequencer/widgets/framing_assistant_inline.dart:164:
              child: FramingView(
                target: CelestialCoordinate(...),
                onRotationChanged: (value) { ... },
```

That file imports `package:skotiq_planetarium/skotiq_planetarium.dart` (line 24) and does
*not* import `framing_screen.dart`, and the named parameters `target:` / `onRotationChanged:` exist
only on the planetarium's `FramingView` (`framing_view.dart:22-28`) — `skotiq_app`'s own
`FramingView` (`framing_screen.dart:29`) takes `{super.key}` only. Its own header comment says
"Wraps the planetarium's `FramingView` widget".

Corroborating: `planner_screen.dart:7` imports the planetarium barrel with `hide FramingView`,
which is only necessary because the barrel really does export a colliding live symbol.

The name collision the work order flags is real, but the file is load-bearing. No deletion.

### 1b. Confirmed dead and removed

Fresh `grep -rn "<symbol>" --include='*.dart' packages apps tools native | grep -v dart_tool`:

| Symbol | Sole hits before deletion |
|---|---|
| `NamedStars` | `star_catalog.dart:1545` (its own declaration) |
| `targetScoringServiceProvider` / `selectedTargetScoreProvider` | `planning_providers.dart:6,24,28` + barrel export :58 |
| `SurveyImage` / `SurveyImageService` | `survey_image_service.dart:123-198` (declaration + own members) |
| `dsoCatalogProvider` / `dsosProvider` | `catalog_providers.dart:179,207,208` |
| `getBestTargets` | `target_scoring.dart:518` |
| `isMoonTooClose` | `target_scoring.dart:1100`; `getMoonDistance` (`:1089`) called only from it |
| `getStarsByMagnitude` / `getStarsInConstellation` | `star_catalog.dart:411,417`; `_getConstellationAbbr` (`:475`) called only from the latter |
| `FOVOverlayWidget` | `fov_overlays.dart:493` (declaration + own `build`) |

Removed: `lib/src/providers/planning_providers.dart` (whole file, 31 lines) + its barrel line;
the symbols above; `HygStarCatalog._constellationNames` (the byte-identical duplicate, see item 6).
`FOVOverlayPainter` / `FOVIndicator` / `FOVType` were **kept** — `benchmark_scene.dart:122` and
`test/fov_overlay_projection_test.dart:513` use them, and retargeting the benchmark is a file move
this wave forbids.

`dart analyze` on the package: **No issues found!**

## Item 6 — one angular-separation implementation

Four copies existed (two taking RA in *hours*, two in *degrees*; three law-of-cosines, one
haversine). Canonical survivor is `AstronomyCalculations.angularSeparation`, switched to the
haversine form, plus a new `CelestialSeparation.separationDegrees` extension in
`coordinate_system.dart` for the `CelestialCoordinate`-typed callers.

Deleted: `interactive_sky_view.dart:1312` `_angularDistance` (5 call sites rewritten),
`spatial_index.dart:430` `_angularDistance` (1 call site), `source_models.dart:7`
`_angularDistance` (2 call sites in `catalog_loaders.dart` now call the canonical helper).

The two constellation-name maps were verified identical before deleting one: both extracted,
stripped and sorted — 88 lines each, `diff` clean.

New `test/angular_separation_parity_test.dart` (4 tests) pins the survivors against the
law-of-cosines form they replaced and measures the accuracy gain. Measured at 1 arcsec:
haversine error 4.6e-16 deg, law of cosines 7.1e-10 deg — a factor of ~1.5 million, i.e. the
old form was wrong by 2.6 microarcseconds where the coincident-star merge compares.

Run: `flutter test test/angular_separation_parity_test.dart test/angular_measurement_test.dart
test/rise_set_transit_test.dart test/chart_frame_consistency_test.dart` → **+42 All tests passed**.

## Item 3 — the silent empty sky (BUG)

Defect reproduced before any fix, with a scratch test using only the shipped API: a catalog file
that exists but is not valid UTF-8 makes the `compute` isolate throw, and `loadObjects` returned
`[]` from the catch at `star_catalog.dart:87`.

```
OBSERVED: stars.length=0 isUsingFallback=false
```

Black chart, no warning, and nothing cached — so every rebuild re-ran the 120k-row parse to fail
again.

Fix: `StarCatalogLoadOutcome { notLoaded, loaded, fileMissing, parseFailed }`; `isUsingFallback`
now derives from it (true for both failing outcomes); a failed parse serves `_fallbackBrightStars`
and caches it, and records `loadError`. `loadObjects` also now shares one in-flight `Future`
instead of the 100 ms `while (_isLoading)` poll, which was the mechanism by which a losing
concurrent caller got `[]`.

New `test/star_catalog_load_failure_test.dart` (4 tests) → **+4 All tests passed**.

FOLLOW-UP FOR THE PARENT (out of my scope): `skotiq_app/lib/screens/planetarium/widgets/
star_catalog_fallback_banner.dart:28` titles the warning "Star catalog not installed". That is now
reachable for a *corrupt* catalog too. `starCatalogLoadOutcomeProvider` is exported so the banner
can distinguish the two; the copy change belongs to whoever owns `skotiq_app`.

## Item 4 — one HYG load chain

`starCatalogProvider` is now the single `HygStarCatalog(magnitudeLimit: 12.0)`;
`loadedStarsProvider` delegates to `starsProvider`, which reads that instance. One parse, one
retained list, and `starCatalogFallbackProvider` now describes the catalog the renderer draws.
`planetarium_providers.dart` gained `import 'catalog_providers.dart';` (no cycle:
`catalog_providers.dart` imports no provider libraries).

Depth check: the old `starCatalogProvider` was mag 15 and answered only a boolean; the surviving
depth is the renderer's mag 12. The one production consumer of the deeper instance,
`guide_star_overlay.dart`, filters at `_guideStarMagnitudeLimit = 10.0`, so mag 12 is still a
superset — no guide star is lost.

New `test/star_catalog_single_chain_test.dart` (3 tests) → **+3 All tests passed**.

---

# Resume — second session

The tree was found mid-flight. Items 1, 3, 4 and 6 were complete and are re-verified below;
items 2, 5 and 7 were partial. Everything above this line was re-checked, not taken on trust.

## Re-verification of the first session's items

**Item 1 (deletions).** Re-proved fresh across `packages apps tools`, `--include='*.dart'`,
`.dart_tool`/`build` filtered. `NamedStars`, `SurveyImage`, `SurveyImageService`, `dsosProvider`,
`dsoCatalogProvider`, `getBestTargets`, `isMoonTooClose`, `getMoonDistance`, `getStarsByMagnitude`,
`getStarsInConstellation`, `FOVOverlayWidget`, `targetScoringServiceProvider`,
`selectedTargetScoreProvider` — **zero hits**, monorepo-wide. `planning_providers.dart` is gone and
the only surviving mention of the name is a doc-comment reference in `catalog_astronomy.dart:337`.

`framing_view.dart` / `FramingView` — **FALSE POSITIVE confirmed independently.**
`skotiq_app/lib/screens/sequencer/widgets/framing_assistant_inline.dart:164` constructs it with
`target:` / `onRotationChanged:`. That file's imports (lines 20-25) include
`package:skotiq_planetarium/skotiq_planetarium.dart` and do **not** include
`framing_screen.dart`, and `skotiq_app`'s own `FramingView` (`framing_screen.dart:29`) takes
`{super.key}` only — so the call can only resolve to the planetarium widget.
`planner_screen.dart:7` imports the barrel with `hide FramingView`, which would be a no-op if the
barrel's symbol were dead. Not deleted.

**Item 3 (silent empty sky).** Baseline code confirmed via `git diff b07d91c9d --`: the isolate
catch was `developer.log(...); return [];` — no `_usingFallback`, no cache write. The fix's
`StarCatalogLoadOutcome` and shared in-flight `Future` are on the tree and
`test/star_catalog_load_failure_test.dart` is green.

**Item 6 (angular separation + constellation map).** Swept the package: the only great-circle
separation implementations left are `AstronomyCalculations.angularSeparation` (haversine, verified
by reading the body) and the `CelestialCoordinate.separationDegrees` extension that forwards to it;
`spatial_index.dart:396`, the five hit-test sites in `interactive_sky_view.dart` and
`catalog_loaders.dart:95,229` all route through them. One constellation-name table remains
(`constellation_names.dart:8`), read by `catalog.dart:335` and `star_catalog.dart:358`.
(`milky_way_data.dart:143` `_angularDistanceOnPlane` is a galactic-longitude helper, not a
separation helper — deliberately untouched.)

## Item 2 — download timeouts and a Cancel that works (BUG) — COMPLETED

Found half-built: `_guardCatalogTransfer` opened with `final bounded = body; if (true) return
bounded;`, so the guard was a no-op and `_sendCatalogRequest` was a bare `client.send(request)`.
That state is behaviourally identical to the baseline, which made it the pre-fix measurement.

PRE-FIX (`flutter test test/catalog_download_stall_test.dart`, guard neutered):

```
02:20 +2 -6: Some tests failed.
  a stalled transfer is abandoned legacy star download gives up instead of waiting forever
  a stalled transfer is abandoned a server that never sends headers hits the connect timeout
  a stalled transfer is abandoned the unified install path gives up too
  a stalled transfer is abandoned the annotation download gives up too
  Cancel works while the transfer is stalled legacy star download reports cancelled
  Cancel works while the transfer is stalled the unified install path reports cancelled
  Cancel works while the transfer is stalled the annotation download reports cancelled
```
Every failure was `TimeoutException after 0:00:20` — the test's own bound firing, i.e. the hang.

Fix, both in `catalog_manager/source_models.dart`:
- `_guardCatalogTransfer` now applies `Stream.timeout(idleTimeout)` (raising
  `CatalogDownloadStalled`) and, when a token is supplied, wraps the body in a controller whose
  `Timer.periodic(cancelPollInterval)` polls it independently of chunk arrival. A throwing token
  errors the stream rather than becoming an unhandled timer error.
- `_sendCatalogRequest` bounds `Client.send` with `CatalogManager.connectTimeout`, which is the
  window a bare `await client.send(...)` left unbounded before any stream existed to watch.

POST-FIX: **00:02 +8: All tests passed!** — and the wall time for the file dropped from 2:20 to
0:02, which is the defect measured directly.

## Item 5 — the object-details panel's per-second visibility solves (PERF) — COMPLETED

Found built (`objectVisibilityProvider` + `ObjectVisibilityKey` in `catalog_astronomy.dart`, both
call sites and the panel root switched) but with a compile error left behind —
`content_sections.dart:880` still read `obsTime.time` after `obsTime` became a `DateTime`.
`dart analyze` on the package reported it; fixed.

Checked for behaviour drift: `_buildQuickStats` previously omitted `minAltitude`, and
`calculateObjectVisibility`'s default is `minAltitude = 0` (`astronomy_calculations.dart:1239`), so
the explicit `minAltitude: 0` at the new call site preserves it exactly.

New `test/object_details_visibility_memo_test.dart` (3 tests). The observation clock is driven
deterministically: `setTime` leaves real-time mode, after which each 1 Hz tick advances it by
exactly one second from 22:00:00.
- *a second of wall clock does not re-solve visibility* — counts evaluations of the memo provider
  across five ticks; the count after the ticks must equal the count after the first frame.
- *the panel subtree is not rebuilt by the 1 Hz clock* — captures a `Text` instance and asserts it
  is `identical` five seconds later. A rebuild constructs a new `Text`, so this is the assertion
  that pins the panel root to `observationMinuteProvider`.
- *crossing a minute does re-solve, on the new minute* — 61 ticks; the key is anchored on the
  night, so no new solve, and the minute provider is asserted to have really advanced to 22:01.

Baseline proof: reverting only the panel root to `ref.watch(observationTimeProvider).time` fails
the second test (`00:00 +2 -1`, `the panel subtree is not rebuilt by the 1 Hz clock`). The first
test still passes under that revert — honestly, the memo alone already removes the expensive part,
and the root switch removes the rebuild churn; the suite separates the two. Restored after the
measurement. POST-FIX: **00:00 +3: All tests passed!**

## Item 7 — wiring the renderer's cache release (FIX) — COMPLETED

Found complete on the tree: `SkyCanvasPainter.releaseRenderCaches()` (calling
`_PaintCache.clearCaches()`, `_projectionCache.clear()` and resetting `_baseLabelRects`), the
`_liveViews` refcount so the last sky view to unmount releases, `didHaveMemoryPressure`, and the
two `@visibleForTesting` probes.

Baseline proof: emptied `releaseRenderCaches()`'s body and re-ran
`test/render_cache_release_test.dart` → **00:00 +0 -3: Some tests failed** (all three). Restored;
**+3 pass**.

## Suite

`dart analyze` (package): **No issues found!**
`flutter test` (whole package): **531 passed, 1 failed** —
`test/benchmark/golden_compare_test.dart: benchmark golden checkpoints (compare)`.

That failure is **PRE-EXISTING**, proven rather than asserted: the package's `lib/` was replaced
with the `b07d91c9d` tree extracted via `git show` (105 files, `planning_providers.dart` present)
and the test re-run. It produced byte-identical numbers:

```
00-wide-start:   maxDelta=218 changed=4.4271% (limit 0.20%) FAIL
01-mid-pan:      maxDelta=245 changed=4.3601% FAIL
02-deep-zoom:    maxDelta=219 changed=3.9958% FAIL
03-time-advanced:maxDelta=245 changed=1.9008% FAIL
04-wide-return:  maxDelta=255 changed=3.7117% FAIL
```

Identical at baseline and at HEAD-of-branch, so nothing in this batch moved it. (Consistent with
the standing note that the goldens are Windows-captured and do not reproduce on Linux.) The
working tree was restored from a pre-experiment copy and re-verified against `git status`: the same
25 paths, no others.

No `*.tmp.*` files existed in scope.

## Not done, deliberately

- §2.4 / §4.2 (unify the two catalog install pipelines; the boxed `List<int>` buffering in
  `unified_catalog_api.dart`) — excluded by the batch instructions.
- All §1 file splits — excluded by the batch instructions.
