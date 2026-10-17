# Impl log — core-services-devices

## Item 1 — BUG: Dart `.wcs` parser splits on newlines only (DONE)

Failing test written first:
`packages/skotiq_core/test/services/plate_solve_service_test.dart`
group `.wcs is a raw FITS header, not a text file`:
- `_parseWcsFile reads a terminator-free ASTAP header` — a 13-card, 1040-char
  header with no line terminators.
- `_parseWcsFile still reads a newline-delimited header` — regression guard for
  the existing (and CRLF) fixture shape.

Observed BEFORE fix: `+3 -1`, `Expected: true / Actual: <false>` on the
terminator-free case. The newline case passed, as expected.

Fix: added `_fitsHeaderCards(String)` to `plate_solve_service.dart` (newlines
first via `LineSplitter`, then 80-char card split on any longer segment),
ported from `native/skotiq_native/imaging/src/platesolve.rs`
`fits_header_cards`. `_parseWcsFile` iterates cards instead of
`content.split('\n')`.

Observed AFTER fix: `flutter test test/services/plate_solve_service_test.dart`
→ `00:00 +8: All tests passed!`

## Item 6c — DELETE: the PlateSolve2 solver path (DONE)

Fresh re-proof (not taken from the work order):
- `grep -rn --include='*.dart' "plateSolve2|PlateSolve2" packages apps tools`
  → outside `plate_solve_service.dart` itself, the only hits are two doc
  comments (`app_settings.dart:238`, `app_settings_state.dart:74`, both outside
  my scope) and tests.
- `grep -rn --include='*.dart' "PlateSolverType\." packages apps tools` → the
  only production construction sites are `centering_dialog.dart:943` and
  `slew_dropdown_button.dart:579`, both `.astap`, plus two **string-based
  lookups** in the headless handlers (`framing_handlers.dart:128`,
  `planetarium_handlers.dart:263`):
  `PlateSolverType.values.firstWhere((t) => t.name.toLowerCase() == solverName…,
  orElse: () => PlateSolverType.astap)`. Chased that: the string comes from the
  `plate_solve_solver` setting, which only `seed_data.dart:249` ever writes
  (`'ASTAP'`) — nothing in the repo writes any other value — and the
  `orElse` makes the enum shrink a no-op regardless.
- The type only reaches a solver via `PlateSolveService.solve(path, config)` →
  `_solveLocally`. **No production caller invokes `solve(...)` at all** — every
  one of the 9 production `plateSolveServiceProvider` consumers uses
  `solveWithFallback`/`detect`/`getConfig`/`ensureSolverAvailable`, and
  `CenteringService` drops `solverConfig.type` entirely (it forwards only
  hints/radius/timeout to `solveWithFallback`, lines 1089-1092).
  `_solveWithFallbackInternal` can only construct `astap`/`astrometryNet`.
- No Rust/FRB export: `grep --include='*.rs' "PlateSolverType|PlateSolve2"
  native/` → no matches.

Deleted: `PlateSolverType.plateSolve2`, `_solveWithPlateSolve2`,
`_parsePlateSolve2Output`, the `parsePlateSolve2OutputForTest` seam, the
`_solveLocally` arm; the two parser tests and the
`PlateSolve2 local fallback deletes stale output` lifecycle test (their only
purpose was the deleted path); and the now-orphaned mockito stub in
`centering_service_test.mocks.dart` (hand-removed rather than regenerated, to
avoid a package-wide `build_runner` colliding with concurrent agents).

## Item 2 — DEDUP: PlateSolveResult literals (DONE)

`_failureResult` now has 17 call sites (was 3); added a sibling
`_successResult({ra, dec, pixelScale = 0, rotation = 0})` used by the `.wcs` and
astrometry.net success paths. The 14 remaining failure literals were collapsed
by a script that verified, per site, that all 24 non-`error` fields matched the
canonical zero set before rewriting (2 sites correctly rejected — the two
successes). `plate_solve_service.dart`: **1389 → 850 lines**.

`dart analyze lib/src/services/plate_solve_service.dart` → No issues found.
`flutter test test/services/plate_solve_service_test.dart
test/services/plate_solve_service_lifecycle_test.dart` → `00:02 +14: All tests
passed!`
`flutter test test/services/centering_service_test.dart` (exercises the edited
mocks file) → `00:11 +33: All tests passed!`
`dart analyze` on the two headless handlers that string-match the enum →
No issues found.

## Item 5 — DEDUP: the byte-identical slot-id twins (DONE)

`event_handling.dart`'s `_trackedDeviceIdFor` deleted; its one caller
(`_disconnectEventOwnsSlot`) now calls `connections.dart`'s `_slotDeviceIdFor`.
Both are extensions on `DeviceService` in the same library (`part of
'../device_service.dart'`), so the cross-extension call resolves.
`dart analyze lib/src/services/device_service.dart` → No issues found.

## Item 6a/6b — DELETE: `setMaxSamples`, `_RegressionFit.sampleCount` (DONE)

Fresh re-proof: `grep -rn "setMaxSamples|set_max_samples|maxSamples"
--include='*.dart' --include='*.rs' --include='*.json' --include='*.js'
--include='*.html' packages apps native tools` → the only `setMaxSamples` hit is
the definition. No test, no headless handler (`focus_model_handlers.dart` calls
`listModels`/`updateConfig`/`clearSamples`/`exportModel`/`getModel`/
`evaluateForFilter` only), no UI, no wire route.
`_RegressionFit.sampleCount`: the sole `_fitRegression` caller
(`predictive_af_service.dart:643`) reads `slope`/`referenceTemp`/`intercept`/
`rSquared` and nothing else.
`dart analyze lib/src/services/predictive_af_service.dart` → No issues found.

## Item 4 — REFACTOR: `_lastTestFrameOutcome` field → returned record (DONE)

`captureTestFrame` now returns `({double? adu, FlatFrameCapture? outcome})`;
the field is gone and both solvers destructure the record. `outcome` stays
nullable so an ADU-injecting test double keeps its exact previous semantics
(a null outcome + non-null adu = ordinary completed measurement).

## Item 3 — BUG: imaging exposure listener had no device correlation (DONE)

Failing test written first (`imaging_service_test.dart`, group
`ImagingService Capture Pipeline`):
`a second camera on the shared stream cannot settle our exposure`.

Fix: `ImagingService._eventNamesCamera` (mirrors
`FlatWizardService._deviceIdKeys` / `_classifyExposureEvent`, including the
"reject if ANY present id key mismatches" rule) applied once at the top of the
`EventCategory.imaging` branch, so it covers progress as well as the three
terminal event types.

Red/green proof (the guard was commented out, the test run, then restored):

    RED   00:00 +0 -1: ImagingService Capture Pipeline a second camera on the
          shared stream cannot settle our exposure [E]
          Unexpected calls: … MockBackend.cameraGetLastImage(test-camera-1) …
          test/services/imaging_service_test.dart 912:20

    GREEN 00:02 +69: All tests passed!   (full imaging_service_test.dart)

Note the RED failure is `verifyNever(cameraGetLastImage)` firing — i.e. the
guide camera's completion really did drive the download in mid-exposure.

## Verification summary

All run from `packages/skotiq_core`:

| Suite | Result |
|---|---|
| `plate_solve_service_test.dart` + `..._lifecycle_test.dart` | `00:02 +14: All tests passed!` |
| `centering_service_test.dart` | `00:11 +33: All tests passed!` |
| `imaging_service_test.dart` | `00:02 +69: All tests passed!` |
| `flat_wizard_capture_test.dart` | `00:00 +7: All tests passed!` |
| `flat_wizard_e2e` + `_service` + `_timeout` + `residual_service_fixes` + `predictive_af_service` + `device_disconnect` + `device_slot_handover` | `00:02 +85: All tests passed!` |
| `device_service_test` + `_p0` + `_connect_all` + `_filter_wheel` + `_environmental_status` | `00:15 +88: All tests passed!` |

`dart analyze` clean on every edited lib file; `dart format
--set-exit-if-changed` clean on all 12 touched files.
Repo-wide grep for `plateSolve2` / `parsePlateSolve2OutputForTest` /
`_lastTestFrameOutcome` / `setMaxSamples` / `_trackedDeviceIdFor` → no hits.

## Left untouched (per the work order's adjudication)

- The seven production-unreachable public methods and the sequential
  profile-connect path (owner decisions).
- No file splits: `capture_pipeline`, the `connections.dart` split, the
  `centering_geometry` extraction, and the `DeviceTypeRegistry` consolidation
  are all deferred.
- `app_settings.dart:238` / `app_settings_state.dart:74` still document
  `'PlateSolve2'` as a legal `plateSolver` string. Nothing maps that string onto
  anything now (and nothing did before — see item 6c), but both files are
  outside this batch's scope, so the stale doc comment is left for whoever owns
  the settings models.
- `plate_solve_service.dart:1`'s `// ignore_for_file: unused_local_variable` is
  NOT stale as §3.5 suspected: `cdelt2` in `_parseWcsFile` is assigned and never
  read. Left in place.

## Resume pass — independent re-verification of the whole batch

The session that wrote everything above was killed; this pass re-proved each
item from the pristine baseline (`b07d91c9d`) rather than trusting the log.

**Item 1 — RED re-proved by me.** Reverted `_parseWcsFile` to
`content.split('\n')` in place, ran the suite, restored:

    00:00 +2 -1: .wcs is a raw FITS header, not a text file
      _parseWcsFile reads a terminator-free ASTAP header [E]
      Expected: true / Actual: <false>

The newline case stayed green under the reverted parser, confirming the fixture
shape that hid the defect. `_fitsHeaderCards` was diffed line-for-line against
`fits_header_cards` in `native/.../imaging/src/platesolve.rs` — same
newline-first, then 80-char split, same card constant.

**Item 2 — behaviour equivalence proved mechanically, not asserted.** Parsed
every `PlateSolveResult(` literal out of the baseline file (25 of them; 2 remain
today, both helper bodies) and checked each failure literal field-by-field
against the canonical zero set: all 22 reported `OK`, so no site carried a
non-zero field the helper would drop. Then diffed the ordered list of `error:`
arguments against today's ordered `_failureResult(...)` arguments: 21 baseline
failure sites → 14 collapsed + 7 deleted with the PlateSolve2 path, and the two
surviving baseline `_failureResult` calls, giving exactly today's 16 call sites
with every string preserved verbatim. Added the parity tests the DEDUP item
calls for, `every result carries the full 25-field shape`:
- `a failure result is fully zeroed and names its reason`
- `a local-parser success carries position but no CD/SIP`

**Item 3 — RED re-proved by me.** Disabled the guard in place
(`if (false && !_eventNamesCamera(...))`), ran the single test, restored:

    00:00 +0 -1: ImagingService Capture Pipeline a second camera on the shared
      stream cannot settle our exposure [E]
      Unexpected calls: … MockBackend.cameraGetLastImage(test-camera-1) …

i.e. the guide camera's completion really did drive the download mid-exposure.

**Item 5 — identity re-proved.** Diffed the two baseline bodies with the names
normalised: `BODIES IDENTICAL`. Parity coverage is the existing
`device_disconnect_test.dart` group (`a Disconnected event for a DIFFERENT
focuser/camera must not clear the live one`, plus the empty-slot no-op), which
exercises `_disconnectEventOwnsSlot` — the one caller — and passes unchanged.

**Item 6 — zero callers re-proved fresh** across `packages apps native tools`
(`.dart`/`.rs`/`.json`/`.js`/`.html`/`.yaml`): `setMaxSamples`,
`parsePlateSolve2OutputForTest`, `_lastTestFrameOutcome` and `_trackedDeviceIdFor`
return nothing at all; `PlateSolve2` survives only as prose in
`app_settings.dart:238` / `app_settings.freezed.dart` / `app_settings_state.dart:74`
(all out of scope). `PlateSolverChoice` — the enum the settings UI actually binds
— never had a PlateSolve2 member, so nothing was orphaned. `_solveLocally`'s
switch is exhaustive over the two remaining arms, and the two headless handlers
that resolve the type by string (`framing_handlers.dart`,
`planetarium_handlers.dart`) analyze clean.

**Suites re-run on this pass** (all from `packages/skotiq_core`):

| Command | Result |
|---|---|
| `plate_solve_service_test` + `_lifecycle_test` | `00:03 +14: All tests passed!` |
| `plate_solve_service_test` (with the 2 new parity tests) | `00:00 +8: All tests passed!` |
| `imaging_service` + `centering_service` + `flat_wizard_capture` + `flat_wizard_e2e` + `flat_wizard_service` + `residual_service_fixes` + `predictive_af_service` | `00:12 +155: All tests passed!` |
| `device_service` + `_p0` + `_connect_all` + `device_disconnect` + `device_slot_handover` + `_filter_wheel` + `_environmental_status` | `00:15 +120: All tests passed!` |

`dart analyze` on all 13 touched files → `No issues found!`;
`dart format --set-exit-if-changed` → `0 changed`. No stray `*.tmp.*` in scope.

