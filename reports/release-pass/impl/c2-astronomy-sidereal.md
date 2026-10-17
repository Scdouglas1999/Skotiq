# C2 — astronomy / sidereal consolidation

Work order: cross-cutting map Cluster 4 ("Local sidereal time / Julian date
implemented 14 times, P1"), plus adjudication delta 1 (this is a Wave C2
cross-package consolidation).

Rule in force: behaviour-preserving. Every re-point below is **bit-identical**
on doubles, proved by parity tests that assert `==` rather than `closeTo`.
Where two copies genuinely disagreed, they were either parameterized to
reproduce both exactly, or left alone with the reason recorded — the
`robust_stats.rs` `mad_sigma` non-adoption note is the standard being met.

---

## What actually differed

The map called out three JD algorithms. Measured, on this tree:

| form | where | vs Meeus |
|---|---|---|
| Meeus Gregorian (`365.25(y+4716) + 30.6001(m+1) + d + b − 1524.5`) | all of `skotiq_core`, `skotiq_hub`, Rust `meridian.rs` | — |
| Fliegel–Van Flandern (`(153m₂+2)/5 + 365y₂ + …  − 32045 − 0.5`) | all of `skotiq_planetarium`, Rust `scheduling/astronomy.rs` | disagree on 3 of 50 000 random ms-bearing instants, worst 4.66e-10 d |
| Unix epoch (`ms/86 400 000 + 2 440 587.5`) | `science_export_hub.dart` | ~1e-10 d |

Two further axes turned out to matter more than the algorithm:

* **Day-fraction precision.** Some copies end at whole seconds, some add
  `millisecond/86 400 000`. Up to 1.2e-8 d apart — nothing on the sky, but not
  the same double, and scheduler goldens are pinned to it.
* **Wrap order.** GMST for a modern date is ~3.4e6°. Wrapping it to [0,360)
  before adding the site longitude, versus adding first and wrapping once,
  changes the answer by ~1e-9°. Four call sites disagreed about which.

So the survivor exposes the *polynomial* (`gmstDegreesRaw`) rather than a
finished LST, and takes the precision as a parameter. Each call site keeps its
own one-line wrap, which its own tests already pin. Verified by
`sidereal time the two wrap orders are NOT interchangeable`, which fails if the
gap ever closes (at which point the wraps really could be unified).

---

## Consolidated

### `skotiq_core` — survivor `SkyCalculations` (`services/scheduler/sky_calculations.dart`)

Added to the survivor:
* `julianDate(dt, {bool includeMilliseconds = true})` — the flag reproduces the
  two retired precisions exactly (`false` makes the sub-second term a literal
  `0`; `x + 0` is exact for finite doubles).
* `gmstDegreesRaw(jd)` — the IAU polynomial, unnormalized.
* `wrap360` / `wrap180` — public wrappers of the existing private helpers.
* `altitudeDegrees({hourAngleDegrees, declinationDegrees, latitudeDegrees})`.
* `altAzDegrees({raHours, decDegrees, latitudeDegrees, lstHours})`.

`localSiderealTimeHours` and `sunAltAz` now build on `julianDate` /
`gmstDegreesRaw` instead of re-typing them inline; unchanged numerically.

Re-pointed (7 call sites, 11 retired definitions):

| file | retired | now |
|---|---|---|
| `services/scheduler_service.dart` | `_julianDate`, `_calculateLST`, the alt/az body in `calculateAltAz` | `julianDate(…, includeMilliseconds: false)`, `localSiderealTimeHours`, `altAzDegrees` |
| `services/night_analysis_service.dart` | `_julianDate`, `_localSiderealTime`, alt body in `_altitude` | same three |
| `database/daos/targets_dao.dart` | `_julianDate`, GMST polynomial, alt body | `julianDate`, `wrap360(gmstDegreesRaw(...))`, `altitudeDegrees` |
| `services/coimaging/coimaging_session_service.dart` | `_julianDate`, GMST polynomial | `julianDate`, `gmstDegreesRaw` (own single wrap kept) |
| `services/planning/forecast_planning_service.dart` | GMST polynomial, alt body | `gmstDegreesRaw`, `altitudeDegrees` |
| `services/scheduler/scheduler_engine/astronomy_helpers.dart` | inline JD in `_moonPosition`, alt/az body | `julianDate(…, includeMilliseconds: false)`, `altAzDegrees` |

`dart:math` became unused in `targets_dao.dart` and
`forecast_planning_service.dart` and was removed.

### `skotiq_planetarium` — survivor `AstronomyCalculations`

`julianDate` gained the same `includeMilliseconds` flag. Re-pointed:

* `astronomy/planetary_positions.dart:julianDate` — was byte-identical.
* `catalogs/minor_planet_catalog.dart:_julianDate` — was byte-identical bar the
  `toUtc()`; its only caller already passes `time.toUtc()`, so exact.
* `catalogs/variable_star_catalog.dart:_julianDate` — whole-second variant.

### Rust — survivor `sequencer::meridian`

`bridge/src/unified_device_ops.rs` carried private `julian_day` /
`local_sidereal_time` (lines 2133 / 2159) that were byte-for-byte copies of
`meridian.rs`'s. Deleted; the file now imports them. Note line 3047 of the same
file *already* called `skotiq_sequencer::meridian::julian_day` directly, so
the file was importing and re-typing the same function.

Every other Rust caller (executor, instructions, solar, polar-align, node,
flat-wizard, expressions, drift-math, sim-gate, epoch, mount ops) was already
on `meridian::julian_day` before this pass.

---

## NOT consolidated, and why

* **`sequencer/src/scheduling/astronomy.rs`** (Fliegel, millisecond) is kept
  separate from `meridian.rs` (Meeus, whole-second). Its entire purpose is to
  return the same doubles the Dart planetarium returns so the scoring parity
  test can assert numeric equality. Pinned by
  `meridian::tests::scheduling_astronomy_is_a_deliberately_separate_julian_date`,
  which shows the two coinciding exactly on a whole-second instant and
  diverging as soon as sub-second time is present — i.e. they cannot be merged
  by inspection. Non-adoption note added to the function's rustdoc.

* **`skotiq_planetarium` vs `skotiq_core`.** Not merged into one
  module. They use different JD algorithms whose outputs are not bit-identical,
  each side's goldens are pinned to its own, and the dependency runs
  `skotiq_core → skotiq_planetarium` (planetarium is the leaf), so the
  shared module could only live in the leaf. Cost without benefit.

* **`server/skotiq_hub/.../follow_the_night.dart`.** Blocked, structurally:
  `skotiq_hub` is a pure-Dart server package and `skotiq_core` /
  `skotiq_planetarium` are Flutter packages. There is no import path. It
  also builds its day fraction by nested division
  (`(h + (m + (s + ms/1000)/60)/60)/24`) rather than as independent terms, a
  third rounding. **Applied the map's item (3):** `_julianDay` now calls
  `.toUtc()` on the way in. Both existing call sites already normalize, so this
  is a provable no-op today; it exists so a third caller cannot shift LST by the
  site's UTC offset.

* **`coimaging_session_service.observerAltitudeDegrees`.** Left carrying its own
  copy of the altitude formula. It converts through `const d2r = pi/180` and
  un-converts by *dividing* by it; the shared helper multiplies by `180/pi`.
  Measured: those differ in the last bit for ~27% of inputs (55 031 / 200 000
  random radians). Re-pointing it would move numbers its longitude-baton tests
  are pinned to. Note added in-file.

* **`science_export_hub.dart:_julianDate`.** Left as the exact epoch form. It
  carries a submission's millisecond timestamp into published photometry with
  no calendar arithmetic in between; the Meeus form is a different double.
  Single call site, self-contained. Note added in-file.

* **`skotiq_planetarium/lib/src/coordinate_system.dart:_julianDate`** —
  left alone, and it is a **suspected P1 bug, not a duplicate**. It omits both
  the `.toUtc()` and the trailing `- 0.5`, so it returns JD **+ 0.5**. Half a
  day is 180.49° of GMST ≈ 12 sidereal hours. `coordinate_system_test.dart:33`
  asserts the +0.5 value and claims "the offset cancels out in toHorizontal()",
  which it does not — the GMST polynomial is a function of JD, not of a JD
  difference. Live caller: `src/sky_view.dart:213,272,277,319`. Re-pointing it
  would be a 12-hour behaviour change, and the standing rule is that behaviour
  changes are reproduced in the running app first. **Recorded for a follow-up
  wave**, with an explanatory note added in-file.

* **`sgp4.dart:julianDate`** (Vallado `367y − …` form) and
  **`mpcorb.dart:_julianDateFromYmd`** (takes year/month/fractional-day, not a
  `DateTime`) — different algorithms and different signatures. Left.

* **Dead Rust copies** at `bridge/src/sequencer_ops.rs:1579` and
  `real_device_ops.rs:2846`: not touched. The map records them as dead and
  adjudication delta 2 has them inside a pending ~6 500-line dead-stack delete;
  editing them now would only conflict with that.

---

## Parity tests added

* `packages/skotiq_core/test/services/scheduler/sky_calculations_parity_test.dart`
  — 17 tests. Every retired body transcribed verbatim, compared with `==`.
  Samples walk the Jan/Feb month rollback, leap day, the century and 400-year
  Gregorian corrections, midnight, the last millisecond of a year, J2000
  itself, a non-UTC `DateTime`, and longitudes past the antimeridian in both
  directions (so the wrap loops run more than once). Includes negative
  declination/latitude down to ±89.9°, hour angles from −720° to +400°, and
  guards that the `includeMilliseconds` flag is really wired (both branches
  would otherwise pass their own parity test while collapsing to one).
* `packages/skotiq_planetarium/test/astronomy_julian_date_parity_test.dart`
  — 11 tests, same construction.
* `sequencer/src/meridian.rs` — 4 new tests: bit-identity against the deleted
  bridge `julian_day` / `local_sidereal_time`, LST range, and the
  astronomy.rs-stays-separate pin.

## Gates run

| gate | result |
|---|---|
| `flutter test` — full `skotiq_core` | 5707 passed, 4 skipped |
| `flutter test` — full `skotiq_planetarium` | 549 passed, 1 failed |
| `dart test` — full `skotiq_hub` | 205 passed |
| `cargo test -p skotiq_sequencer -p skotiq_bridge` | 1341 passed, 0 failed |
| `flutter test` — `skotiq_app` analytics + LST widget tests | 1 pre-existing failure, rest pass |
| `dart analyze` on every touched Dart file | clean |
| `dart format` / `cargo fmt --check` on touched files | clean |

Two failures, both proved **pre-existing** by restoring the touched files from
`HEAD` and re-running:

* `skotiq_planetarium/test/benchmark/golden_compare_test.dart` — pixel-diff
  of the sky renderer. At `HEAD` it reproduces the identical numbers
  (`00-wide-start: maxDelta=218 changed=4.4271%`, `01-mid-pan: 245 / 4.3601%`,
  …). The known Windows-captured-goldens-on-Linux failure.
* `skotiq_app/test/screens/analytics/captures_landscape_test.dart` — hangs
  ~9m45s then SIGTERMs the shell. Identical behaviour at `HEAD` with all eight
  touched `skotiq_core` / `skotiq_app` files restored.

Neither can be caused by this work: every planetarium and core re-point is
bit-identical, and `science_export_hub.dart` took a doc comment only.
