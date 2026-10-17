# Wave C3 — batch `core-providers-models`

Scope: `packages/skotiq_core/lib/src/{providers,models,repositories,database}/**`, files >1000
lines per the Wave A maps (`map/core-providers.md`, `map/core-models.md`). There is no
`lib/src/repositories/` directory; the two repository classes live under `lib/src/services/`
(out of this batch's literal path scope — see SKIPPED).

All splits are behaviour-preserving. Every split was verified with a content diff against
`git show HEAD:<file>` (blank lines and the new `part` / `part of` / `extension` lines excluded);
seven of the ten came back byte-identical, and the three with intentional accommodations are
itemised below.

## SPLIT (10 files)

| file | before | after | new part files |
|---|---:|---:|---|
| `providers/profiles_provider.dart` | 1245 | 26 | `profiles/{equipment_profile_model,equipment_profiles_notifier,profile_derived_providers}.dart` |
| `providers/transient_alert_provider.dart` | 1189 | 26 | `transient_alerts/{transient_alert_settings,transient_alert_feed,transient_alert_parsing,transient_alert_states,transient_queue_flights}.dart` |
| `providers/scheduler_provider.dart` | 1235 | 232 | `scheduler/{scheduler_engine_providers,scheduler_candidate_loader,scheduler_config,scheduler_readiness,scheduler_remote_and_goals}.dart` |
| `providers/polar_alignment_provider.dart` | 1453 | 910 | `polar_alignment/{polar_wire_decoding,polar_config_notifier,polar_ui_state,polar_history,polar_controller}.dart` |
| `providers/weather_safety_provider.dart` | 1724 | 678 | `weather_safety/{weather_safety_models,weather_safety_sources,weather_safety_remote,weather_safety_enforcement,weather_safety_executor_push}.dart` |
| `providers/flat_wizard_provider.dart` | 1539 | 100 | `flat_wizard/{flat_output_paths,flat_camera_config,flat_wizard_settings_ops,flat_wizard_run}.dart` |
| `providers/remote_sync_handler.dart` | 1513 | 175 | `remote_sync/{equipment_mirror,imaging_mirror,guiding_mirror,sequencer_mirror,host_mutation,device_mapping,reader_access,session_hydration}.dart` |
| `providers/settings_sections/app_settings_state.dart` | 1096 | 659 | `settings_sections/app_settings_state_copy_with.dart` |
| `models/imaging/integration_settings.dart` | 1346 | 864 | `integration_settings/integration_enums.dart` |
| `models/imaging/stack_and_share_models.dart` | 1033 | 20 | `stack_and_share/{stack_and_share_config,stack_and_share_progress,stack_and_share_result,share_card_spec,astrobin_export_metadata}.dart` |

Mechanism: Dart `part` / `part of` throughout, matching the `settings_provider.dart` +
`settings_sections/` idiom and the `sequence_executor/` operations-file idiom. No consumer import
anywhere in the repo changed (one test `show` clause excepted, below).

## ACCOMMODATIONS (the only non-verbatim edits)

1. **`state` is `@protected` on `StateNotifier`.** Moving notifier methods into a same-library
   extension raises `invalid_use_of_protected_member` /
   `invalid_use_of_visible_for_testing_member`. The three new extension part files under
   `weather_safety/` and the two under `flat_wizard/` carry
   `// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member`
   — the same header the existing split at
   `skotiq_app/lib/screens/equipment/dialogs/profile_editor_dialog/*.dart` already uses.
2. **Static members of the extended type must be qualified inside an extension.** Six call sites
   were qualified with the owning class name, nothing else changed:
   `WeatherSafetyNotifier.{_cloudMotionPushInterval,_adaptiveConditionsPushInterval,_cloudCoverTtl,
   _cloudCoverErrorRetryTtl,_parkBeforeDawnLeadTime}` and `FlatWizardNotifier._globalSettingsKey`.
   All seven occurrences were checked to be code positions, never inside a string interpolation.
3. **Two `static` helpers became library-private top-level functions** (a `static` cannot be
   reached unqualified from an extension): `WeatherSafetyNotifier._readingFromWire` and
   `._isLiveReading`. Both are pure and their unqualified call sites resolve unchanged.
   Same treatment for `FlatWizardNotifier.{_sanitizeComponent,_two,_fmtDate,_fmtStamp}`
   (instance methods that never touched `state`), now top-level in `flat_wizard/flat_output_paths.dart`
   — exactly as the map ordered.
4. **Two extensions had to be public** — `FlatWizardSettingsOps`, `FlatWizardRun` — because they
   carry public API (`setMode`, `runCapture`, …) that the app calls. A library-private extension
   would have hidden those methods from every consumer. Recorded as a visibility widening:
   two new public extension names on the barrel.
5. **One test import line changed.** `AppSettingsState.copyWith` is now an extension member, so
   `test/providers/smart_night_settings_persistence_test.dart:22` had to add
   `AppSettingsStateCopyWith` to its `show` clause. No test body changed. Note the general hazard:
   any *future* `import 'settings_provider.dart' show AppSettingsState;` will not see `copyWith`.
   Checked at time of writing — the other eight `show`-clause importers of that library do not use
   `copyWith`, and every out-of-package consumer goes through the barrel, which re-exports the
   extension.

## PARTIAL

- `weather_safety_provider.dart` lands at **678**, `polar_alignment_provider.dart` at **910** —
  both under the 1000-line bar, but neither is fully decomposed to the map's plan.
  `polar_alignment_provider.dart` deliberately keeps `PolarAlignmentStateNotifier` whole (the
  map's `polar_event_handling` / `polar_run_commands` extensions were built, produced 274
  protected-member warnings, and were reverted in favour of leaving the class intact — the file
  was already under threshold without them).

## SKIPPED (measured, not split)

| file | lines | why |
|---|---:|---|
| `providers/sequence/sequence_executor.dart` | 2286 | `providers/sequence/**` is mapped by `map/core-sequence.md`, a different C3 batch |
| `providers/sequence/sequence_executor/event_operations.dart` | 1501 | same |
| `providers/sequence/sequence_executor/runtime_config_operations.dart` | 1157 | same |
| `providers/sequence/sequence_executor/serialization_operations.dart` | 1073 | same |
| `database/database/schema_helpers.dart` | 1091 | no split plan in any Wave A map; `core-models.md:525` records `lib/src/database/**` as "assumed owned by the core-database" mapper, which produced no report |
| `database/daos/science_dao.dart` | 1019 | same |
| `services/sequence_repository.dart` | 1131 | planned in `map/core-models.md` §1.3 but lives in `lib/src/services/`, outside this batch's path scope and inside the concurrently-running core-services batch |
| `services/imaging_records_repository.dart` | 1089 | same (`map/core-models.md` §1.4) |
| `database/database.g.dart`, all `*.freezed.dart` | — | generated |

## VERIFICATION

- `dart analyze` clean on every touched library.
- `dart analyze` on `packages/skotiq_app`, `apps/desktop`, `apps/mobile`, `packages/skotiq_ui`:
  no error attributable to this batch.
- `flutter test` in `packages/skotiq_core`: 5790 tests. All green except failures owned by
  other in-flight batches (below). `test/backend/{ffi_backend_tracked_stars,network_backend_seq,
  network_backend_tailnet}_test.dart` failed only in the whole-suite run and pass in isolation
  (concurrent-agent file churn during the run).
- `dart format` run on touched files only.

## BREAKAGE FOUND IN A SIBLING BATCH (not mine, not fixed)

1. **`services/backup_service/table_registry.dart:143` — test-proven bug.** The core-services
   split qualified a static inside a *string interpolation*:
   `'ORDER BY rowid LIMIT $BackupService._dumpPageSize OFFSET $offset'` interpolates only
   `BackupService`, so the SQL literally reads `LIMIT BackupService._dumpPageSize`.
   `test/services/backup_directory_setting_test.dart` fails with
   `SqliteException(1): no such column: BackupService._dumpPageSize`. Fix: `${BackupService._dumpPageSize}`.
2. **`services/sky_atlas/sky_atlas_service/*.dart`** — split into *private* extensions, so the
   public methods (`ensureRegion`, `watchRegions`, `getRegion`, `tilesForRegion`,
   `watchRegionTimeline`, `sweepCache`, `deleteExportedDelta`, `mergeSwarmDelta`, …) are invisible
   outside the library: 11 `undefined_method` errors in `providers/sky_atlas_provider.dart`,
   `services/auto_save_service.dart`, `services/constellation/constellation_service.dart`.
   Fix: make those extensions public (same trap this batch hit with `FlatWizardSettingsOps`).
3. **`skotiq_app/lib/screens/sequencer/widgets/quick_start_wizard_dialog/_wizard_helpers.dart:199`**
   — `super` used inside an extension (`super_in_extension`); a `dispose` override cannot move to
   an extension.
