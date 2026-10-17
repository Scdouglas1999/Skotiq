# Wave C3 — batch `core-services`

Scope: `packages/skotiq_core/lib/src/services/**` files over 1000 lines at HEAD
(`sequence_executor.dart` belongs to `core-providers` and was not touched).

Plans followed: `reports/release-pass/map/core-services-devices.md` §1 and
`reports/release-pass/map/core-services-rest.md` §1, re-measured at HEAD before cutting.

## Mechanism actually used, and why it differs from the map in two places

The map plans propose two mechanisms: `part`/`part of`, and "plain sibling library +
re-export". Everything below uses **`part`/`part of` only**. A `part` file is the same
Dart library as its parent, so no import anywhere changes, nothing needs re-exporting,
and privacy is preserved exactly. Directory naming follows the convention already in the
tree (`<parent_basename>/…`, as in `smart_night_service/`, `imaging_service/`,
`scheduler/scheduler_engine/`), not the shorter directory names the map sketches.

Two constraints shaped every cut and are the reason some parents stayed above 1000:

1. **Only private instance members move into an `extension`.** The established idiom in
   this repo (`providers/sequence/sequence_executor/*_operations.dart`,
   `science_processing_service/private_helpers.dart`) is
   `part of '../x.dart';` + `extension _XSomething on X { … }` holding **private**
   methods. Moving a *public* method into an extension is **not** behaviour-preserving:
   extension members are statically dispatched, are invisible to `dynamic` receivers,
   and are not intercepted by `Mock`/`noSuchMethod` subclasses. A first attempt on
   `sky_atlas_service.dart` moved public methods and the analyzer immediately reported
   them as unreferenced (a private extension does not export them); that attempt was
   restored from HEAD and redone with private members only.
2. **`@override` members and instance fields cannot move at all** — an extension cannot
   satisfy an interface and cannot declare state.

Where a moved private method called a private **static** of the same class, one of two
mechanical fixes was applied, both behaviour-identical:

* the static was promoted to a library-private top-level function in a `part` file
  (identifier unchanged, so *every* call site — inside and outside the moved code —
  still resolves textually unchanged); or
* the reference was qualified with `ClassName.` where promotion was not warranted.

**Recorded visibility changes:** none. No symbol became more or less visible outside its
library. The static→top-level promotions keep the leading `_`, i.e. library-private
before and after.

## Trap found and fixed during this batch

The auto-qualifier inserted `ClassName.` at analyzer-reported offsets, and three of those
offsets were inside a `'$identifier'` string interpolation, silently turning
`'… LIMIT $_dumpPageSize …'` into `'… LIMIT $BackupService._dumpPageSize …'` — i.e. a
*text* change to a SQL statement, not a qualification. It was caught by
`backup_service_archive_stream_test.dart`. All three were converted to `${…}`:

* `backup_service/table_registry.dart:143`
* `backup_service/restore_validation.dart:60`
* `centering_service/slew_settle.dart:40`

Every remaining inserted qualification was then re-read individually; all are in ordinary
code positions.

## Results

| file | before | after | new part files |
|---|---:|---:|---|
| `imaging_service.dart` | 1611 | 682 | `imaging_service/{capture_pipeline,exposure_state,naming_internals}.dart` |
| `calibration_library_service.dart` | 1596 | 710 | `calibration_library_service/{remote_acceptance,matchers,sharing,loading,formatting}.dart` |
| `device_service/connections.dart` | 1488 | **deleted** | `device_service/connections/{imaging_chain,guider_and_rotator,environment,environment_codes,switch_device}.dart` + `device_service/device_slots.dart` |
| `flat_wizard_service.dart` | 1406 | 1169 | `flat_wizard_service/{flat_wizard_models,exposure_events,exposure_event_keys}.dart` |
| `predictive_af_service.dart` | 1373 | 574 | `predictive_af_service/{predictive_af_models,settings_controller,regression,focus_model_store}.dart` |
| `constellation/constellation_service.dart` | 1354 | 1085 | `constellation_service/{constellation_types,internals,defaults}.dart` |
| `scheduler/scheduler_engine.dart` | 1316 | 423 | `scheduler_engine/{evaluation,scoring}.dart` |
| `centering_service.dart` | 1310 | 374 | `centering_service/{centering_models,centering_loop,slew_settle,centering_geometry}.dart` |
| `backup_service.dart` | 1271 | 681 | `backup_service/{backup_models,backup_value_codecs,table_registry,restore_validation}.dart` |
| `sequence_time_estimator.dart` | 1195 | 452 | `sequence_time_estimator/{timing_models,node_durations,window_solver}.dart` |
| `profile_service.dart` | 1192 | 770 | `profile_service/{profile_service_types,profile_backends}.dart` |
| `science/science_processing_service.dart` | 1174 | 393 | `science_processing_service/{frame_lanes,writeback}.dart` |
| `constellation/constellation_client.dart` | 1174 | 934 | `constellation_client/{transport,io_cleanup}.dart` |
| `coimaging/coimaging_session_service.dart` | 1144 | 791 | `coimaging_session_service/{coimaging_types,baton_scheduler,internals}.dart` |
| `post_session_integration_service.dart` | 1136 | 382 | `post_session_integration_service/{integration_models,integration_stages,integration_helpers,path_helpers}.dart` |
| `imaging_records_repository.dart` | 1129 | 617 | `imaging_records_repository/{solved_frame_hooks,wire_json,remote_polling}.dart` |
| `stack_and_share_service.dart` | 1121 | 600 | `stack_and_share_service/{stack_results,rejection_reasons,stack_frame_io,stack_run_helpers}.dart` |
| `mosaic_project_service.dart` | 1094 | 546 | `mosaic_project_service/{mosaic_models,panel_integration,stitching,path_helpers}.dart` |
| `sky_atlas/sky_atlas_service.dart` | 1076 | 867 | `sky_atlas_service/{atlas_models,internals}.dart` |
| `sequence_diff_service.dart` | 1066 | 169 | `sequence_diff_service/{node_field_diff,node_describe}.dart` |
| `science/default_science_backend.dart` | 1060 | 1060 | **not split** (see below) |
| `night_analysis_service.dart` | 1037 | 404 | `night_analysis_service/{detectors,night_data,moon_ephemeris,statistics}.dart` |
| `quick_start_service.dart` | 1028 | 418 | `quick_start_service/{quick_start_models,quick_start_providers}.dart` |

`run()` in `stack_and_share_service.dart` was deliberately left whole, as the map
instructs. `_capture` in `imaging_service.dart` and `_processFrame` in
`science_processing_service.dart` were moved **verbatim** rather than decomposed — the
map's decomposition of those two into staged sub-methods is a logic refactor, out of
scope for a mechanical split.

### Not split

* **`science/default_science_backend.dart` (1060).** Every member of the class is an
  `@override` of `ScienceBackend`. An extension cannot carry an interface implementation,
  and a mixin extraction would need `mixin M on DefaultScienceBackend` while the class
  declares `with M` — circular. The map's "all `part`" plan for this file does not
  compile. Splitting it needs the class restructured, which is not mechanical.

### Split, but still over 1000

* **`flat_wizard_service.dart` → 1169.** The residue is public API:
  `resolveCaptureConfig` (153, a `static` called as `FlatWizardService.resolveCaptureConfig`
  from `flat_wizard_provider.dart` and a test — the map flags this constraint too),
  `exposeAndAwait` (221), `calibrateFilter` (204), `calibrateFilterWithRateTracking` (201),
  `calibrateMultipleFilters`, `generateFlatSequence`, `generateCompleteSequence`,
  `quickCalibrate`, `captureTestFrame`.
* **`constellation/constellation_service.dart` → 1085.** Residue is again public:
  `contributeTarget` (201), `contributeRawSubs` (122), `pullTarget` (120),
  `followTheNight` (103), `sweepSwarmBlobs` (101).

Both would come down with a forwarder pattern (public stub in the class delegating to a
private extension method), but that invents new symbols rather than moving code, so it
was left for an explicit decision.

## Verification

* `dart analyze lib` in `packages/skotiq_core` — **No issues found**.
* `flutter test` (whole package, JSON reporter): **667 suites / 7217 tests, all success**,
  `"success": true`. No test file was edited — not even an import line; `part` files
  share the parent's library, so no import anywhere in the repo changed.
* `dart format --output=none --set-exit-if-changed` over exactly the touched files — clean.
* Audited every `extension` created: all are `_`-prefixed and contain only `_`-prefixed
  members, so nothing left the class's exported surface.
