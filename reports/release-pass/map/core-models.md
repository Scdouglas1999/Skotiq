# Release-pass map — `skotiq_core` models / repositories / utils

Subsystem: **core-models**
Paths: `packages/skotiq_core/lib/src/models/**`, `packages/skotiq_core/lib/src/utils/**`,
the two repository classes in `lib/src/services/` (`sequence_repository.dart`,
`imaging_records_repository.dart`) and their `part` directories.

Note on layout: there is **no** `lib/src/repositories/` directory. The repository-pattern
classes live under `lib/src/services/`. Both were included per the brief.

Everything below was verified by reading the file and/or by a repo-wide grep; the exact
commands/line numbers are quoted so a verifier does not have to re-derive them.

---

## 1. OVERSIZED FILES

Threshold: >~1000 lines, non-generated. Counts from `wc -l`. `*.g.dart`, `*.freezed.dart`
and `frb_generated*` excluded.

Only **four** files in this subsystem cross the line. None of them are generated — all four
are hand-written (checked: no `part 'x.g.dart'` codegen backing for the two model files,
and both repository files are plain hand-authored Dart).

| File | Lines | Generated? |
|---|---|---|
| `packages/skotiq_core/lib/src/models/imaging/integration_settings.dart` | 1346 | no — hand-written, deliberately codegen-free (see its own doc, L491-495) |
| `packages/skotiq_core/lib/src/services/sequence_repository.dart` | 1131 | no (+ parts: `node_decoder.dart` 755, `node_encoder.dart` 294 → 2180 in the library) |
| `packages/skotiq_core/lib/src/services/imaging_records_repository.dart` | 1089 | no |
| `packages/skotiq_core/lib/src/models/imaging/stack_and_share_models.dart` | 1033 | no |

Near-threshold (report only, no split ordered): `models/troubleshooter/connection_diagnostic.dart`
886, `models/sequence/template_snippet.dart` 874, `models/hardware_presets/hardware_preset_models.dart`
790, `models/tutorial/tutorial_models_parts/screen_tours.dart` 736. These are mostly static
data tables and are fine as-is.

---

### 1.1 `models/imaging/integration_settings.dart` (1346) — HIGH value, LOW risk

**Why it is big.** One file carries three unrelated concerns: (a) 12 hand-written wire enums,
each with its own `wire` getter + `fromWire` static (L8-485, ~485 lines of pure boilerplate);
(b) a 45-field immutable value type with a 100-line `copyWith` (L500-925); (c) three separate
serializers — the native bridge shape, the persistence shape, and their inverses (L927-1224) —
plus hand-written `==`/`hashCode` over all 45 fields (L1226-1345).

**Split plan (behaviour-preserving, zero consumer churn).**
Consumers import it via the barrel (`packages/skotiq_core/lib/skotiq_core.dart:69`),
so as long as `integration_settings.dart` keeps re-exporting, nothing downstream changes.

New directory `packages/skotiq_core/lib/src/models/imaging/integration_settings/`:

1. **`integration_enums.dart`** — a *standalone library* (not a part). Move L8-485 verbatim:
   `TransformModel`, `Resampler`, `WeightFormula`, `NormalizationMode`, `CombineMode`,
   `RejectAlgorithm` (incl. `resolveAuto`), `OutputBitDepth`, `DrizzleKernel`, `PsfKind`,
   `StarReduceMethod`, `NarrowbandPalette`, `IntegrationPreset`. ≈485 lines.
   `integration_settings.dart` then gains
   `import 'integration_settings/integration_enums.dart';` **and**
   `export 'integration_settings/integration_enums.dart';` — this is what keeps the barrel
   and every `import '.../integration_settings.dart'` call-site working unchanged.
2. **`integration_settings_codec.dart`** — `part of '../integration_settings.dart';`.
   Move the *bodies* of `toBridgeSettings` (L934-1029), `toJson` (L1034-1081),
   `IntegrationSettings.fromJson` (L1086-1188), `_decodeCustomWeights` (L1193-1205),
   `toJsonString` (L1208) and `fromJsonStringOrDefault` (L1213-1224) into top-level
   library-private functions: `_toBridgeSettings(IntegrationSettings s)`, `_toJson(s)`,
   `_fromJson(Map<String,dynamic>)`, `_decodeCustomWeights`, `_fromJsonStringOrDefault`.
   In the class they become one-line delegates:
   `Map<String, dynamic> toBridgeSettings() => _toBridgeSettings(this);`,
   `factory IntegrationSettings.fromJson(Map<String, dynamic> j) => _fromJson(j);`, etc.
   (A factory constructor cannot itself live in a part-file member list, but delegating to a
   part-file top-level function is exactly equivalent and is the standard move here.) ≈300 lines.
3. **`integration_settings_presets.dart`** — `part of`. Move the `preset` factory switch
   (L723-763) and `smartDefaults` (L790-814) bodies into `_presetSettings(IntegrationPreset)`
   and `_smartDefaultSettings({...})`; the class keeps two thin factories. ≈110 lines.
4. **`integration_settings_equality.dart`** — `part of`. Move `operator ==` (L1227-1273),
   `hashCode` (L1276-1321), `_customWeightsEqual` (L1324-1339), `_customWeightsHash`
   (L1342-1345) into `_settingsEqual(a, b)` / `_settingsHash(s)` + the two helpers. ≈125 lines.

**Stays in `integration_settings.dart`** (≈400 lines): the library doc, the 45 field
declarations with their doc comments, the `const` constructor, `static const defaults`,
`resolvedReject`, `copyWith`, the delegating members, the `export` of the enums library and the
three `part` directives.

**Guard rail.** `packages/skotiq_core/test/models/imaging/integration_settings_test.dart`
must pass *unmodified* after the split — that is the acceptance test for "behaviour-preserving".

---

### 1.2 `models/imaging/stack_and_share_models.dart` (1033) — the cleanest split

**Why it is big.** Twelve unrelated top-level types for five different stages of one workflow,
concatenated. Verified class offsets:
`StackAndShareConfig` L21, `StackAndSharePhase` L163, `StackAndShareProgress` L190,
`StackedFrameSelection` L279, `StackSelectionSummary` L355, `StackAndShareResult` L435,
`ShareCardLayout` L602, `ShareCardFontScale` L618, `ShareStatLine` L633, `ShareCardSpec` L662,
`ShareExportFormat` L743, `AstroBinExportMetadata` L759.

**Split plan.** New directory `models/imaging/stack_and_share/`:

| New file | Moves | ≈lines |
|---|---|---|
| `stack_and_share_config.dart` | L1-162 (`StackAndShareConfig`, incl. `resolvedStackingConfig`) — the only file needing `import '../../../services/live_stacking_service.dart';` | 145 |
| `stack_and_share_progress.dart` | L163-434 (`StackAndSharePhase`, `StackAndShareProgress`, `StackedFrameSelection`, `StackSelectionSummary`) | 275 |
| `stack_and_share_result.dart` | L435-601 (`StackAndShareResult`) | 167 |
| `share_card_spec.dart` | L602-758 (`ShareCardLayout`, `ShareCardFontScale`, `ShareStatLine`, `ShareCardSpec`, `ShareExportFormat`) | 157 |
| `astrobin_export_metadata.dart` | L759-1033 (`AstroBinExportMetadata`) | 275 |

`stack_and_share_models.dart` becomes a 6-line barrel that `export`s the five, so
`skotiq_core.dart:67` (`export 'src/models/imaging/stack_and_share_models.dart';`) and every
existing import keep resolving with zero churn.
Only real care point: `StackAndShareResult` and `StackAndShareProgress` reference the phase enum —
have `stack_and_share_result.dart` import `stack_and_share_progress.dart`.

---

### 1.3 `services/sequence_repository.dart` (1131; library total 2180) — MEDIUM risk, read the guard rail

**Why it is big.** Four concerns in one class: (a) local/remote CRUD + duplicate/version
history (L66-784); (b) **18 hand-written enum↔string converters** that exist only to feed the
`node_encoder`/`node_decoder` parts (L786-1079, ~295 lines); (c) four free JSON helpers
(L1082-1114); (d) the Riverpod provider (L1117-1131).

**GUARD RAIL — do not "extension-ify" the public methods.** `SequenceRepository` is
mockito-mocked in at least 10 places
(`packages/skotiq_app/test/screens/sequencer/sequence_library_authority_test.dart:13`,
`packages/skotiq_core/test/services/residual_service_fixes_test.dart:61`,
`apps/desktop/test/headless_api/sequencer_handlers_test.dart:13`, …). Moving `listVersions` /
`restoreVersion` / `loadRunDiffContext` onto an `extension` would make those mocks silently run
the *real* body against a mock (hitting `_requireVersionsDao` → `StateError`). Keep every
public method on the class.

**Split plan (only private/free code moves — safe with the mocks):**

1. **`sequence_repository/db_enum_codec.dart`** (`part of '../sequence_repository.dart';`).
   Move L786-1079 — `_binningToString`, `_stringToBinning`, `_stringToFrameType`,
   `_autofocusMethodToString`, `_stringToAutofocusMethod`, `_twilightToString`,
   `_stringToTwilight`, `_notificationLevelToString`, `_stringToNotificationLevel`,
   `_parseExplicitTransports`, `_loopConditionToString`, `_stringToLoopCondition`,
   `_conditionalTypeToString`, `_stringToConditionalType`, `_recoveryActionToString`,
   `_stringToRecoveryAction`, `_stringToMeridianTriggerMethod`, `_stringToFlipFailureAction`,
   `_stringToTriggerType`, `_parseDitherPattern` — **as top-level library-private functions**.
   They are currently instance methods purely by accident (none reads `this`), and their only
   callers are the two `part` files, which are in the same library. Also move
   `_categoryWireString` (L349-356) here; keep `_getNodeCategory` on the class (L342-343) as a
   one-liner. ≈300 lines out.
2. **`sequence_repository/wire_value_types.dart`** (a plain library, not a part).
   Move `SequenceRunDiffContext` (L34-44) and `SequenceVersionSummary` (L51-63) out, and add
   `export 'sequence_repository/wire_value_types.dart';` next to the existing
   `export 'sequence_summary.dart';` at L24. ≈45 lines out.
3. **`sequence_repository/horizon_json.dart`** (`part of`). Move
   `_parseBrightnessTierPreferences` (L1082-1087), `_schedulerHorizonToJson` (L1091-1098),
   `_schedulerHorizonFromJson` (L1102-1114) and the `horizon_profile.dart` import. ≈40 lines out.

Result: `sequence_repository.dart` ≈740 lines holding only the class + provider.

---

### 1.4 `services/imaging_records_repository.dart` (1089) — HIGHEST value split

**Why it is big.** It is a CRUD repository (L45-690) with an entire *post-solve side-effect
pipeline* bolted onto the bottom of the file: sky-atlas fold, First Light difference scan,
co-imaging auto-contribute, transient push routing (L747-1081). That buried pipeline is
where the RA-unit defect in §4/§5 lives — nobody reads to line 967 of a repository file.

**Split plan.** New directory `services/imaging_records/`:

1. **`imaging_records/remote_row_codec.dart`** (plain library, `@internal`).
   Move `_sequenceRunFromRemote` (L513-524), `_sessionFromJson` (L526-552),
   `_dateTimeFromJson` (L554-562), `_companionToCreateJson` (L564-617),
   `_thumbnailListsEqual` (L692-721), `_producingThumbnailFromApiJson` (L723-745).
   Drop the leading `_` (they become `sequenceRunFromRemote` etc.) and import it back.
   ≈200 lines out. **Do this one first** — it is the file the §2.2 de-duplication lands in.
2. **`imaging_records/solved_frame_hooks.dart`** (plain library).
   Move `applyAtlasFoldDedup` (L760-779, already `@visibleForTesting`),
   `_driveCoImagingAutoContribute` (L897-939), `_runFirstLightScan` (L945-1014),
   `_kTransientPushConfidence` (L1019), `_pushTransientDiscoveries` (L1027-1058),
   `_candidateFromRow` (L1064-1081), **and** hoist the 84-line closure body currently inlined
   at `onSolvedFrameFold:` (L798-881) into a named
   `Future<void> foldSolvedFrame({required Ref ref, required ImagesDao imagesDao, required int capturedImageId})`.
   The provider then reads `onSolvedFrameFold: (id) => foldSolvedFrame(ref: ref, imagesDao: imagesDao, capturedImageId: id)`.
   ≈340 lines out. Preserve the load-bearing ordering comment at L827-835 verbatim (scan
   **before** fold) — it documents a real self-subtraction bug.
3. **Stays** in `imaging_records_repository.dart` (≈550 lines): the class, the two providers
   (`imagingRecordsRepositoryProvider` L787, `sessionDbImagesProvider` L1084), the polling
   statics L619-689 (they are the repository's own remote-mode plumbing).

---

## 2. DUPLICATION

### 2.1 Two complete sequence-node serializers (DB-format vs file-format) — LARGE

- DB side: `services/sequence_repository/node_encoder.dart` (294) +
  `node_decoder.dart` (755) + the 18 converters in `sequence_repository.dart:786-1079`.
- File side: `services/sequence_file_service/sequence_encoder.dart` (361) +
  `sequence_decoder.dart` (842), with its own 12 parsers at `sequence_decoder.dart:711-842`.

Evidence they are the same job: the DB decoder has **83** `case '…'` labels and the file
decoder **49**, over the same `SequenceNode` subtypes; `sequence_decoder.dart:773` and
`sequence_repository.dart:896` are byte-identical `_parseExplicitTransports` implementations,
and `sequence_repository.dart:894-895` says so in a comment ("See
`SequenceFileService._parseExplicitTransports` for the equivalent file-side parser").

**They have already drifted, in the fail-silent direction:**
- `sequence_repository.dart:988-1015` encodes `RecoveryActionType.continueExecution` as the
  token `'continue'`; `sequence_encoder.dart:96` encodes the same field as
  `node.recoveryAction.name` → `'continueExecution'`. Two wire vocabularies for one field.
- On an unknown/absent token the DB decoder falls back to
  `RecoveryActionType.continueExecution` (`sequence_repository.dart:1040`) while the file
  decoder falls back to `RecoveryActionType.retry` (`sequence_decoder.dart:796`). Same input,
  opposite recovery behaviour.
  (Each path is currently self-consistent — the DB decoder only ever sees DB-written blobs —
  so this is drift risk, not a proven live bug. But it is exactly the shape that becomes one.)

**Canonical survivor:** the **file-format** codec (`sequence_file_service/`). It is the
format used by version snapshots, remote `saveFullSequence`/`getFullSequence`
(`sequence_repository.dart:161,169`) and import/export, i.e. it already crosses every boundary.
**Merge plan:** (a) extract the 12+18 enum codecs into one shared
`services/sequence_wire_codec.dart` with a single canonical token per value and a tolerant
reader that accepts both historical spellings (the DB decoder already demonstrates the
multi-spelling pattern — `case 'calibrator_off': case 'calibratorOff': case 'CalibratorOff':`);
(b) have `node_encoder`/`node_decoder` call it; (c) as a second, larger step, make the DB
`sequence_nodes.properties` column store the file-format map so `node_encoder`/`node_decoder`
collapse into thin adapters over `sequence_encoder`/`sequence_decoder`. Step (a) alone removes
~300 duplicated lines and closes the divergent-default hazard.
Effort: medium for (a), large for (c).

### 2.2 `_sessionFromJson` + its date coercion exist twice, verbatim — SMALL, do it now

- `services/imaging_records_repository.dart:526-562` (`_sessionFromJson`, `_dateTimeFromJson`)
- `providers/database_provider.dart:458-484` (`_sessionFromJson`) and `:490-499`
  (`_dateTimeFromJsonValue`)

Both decode the same `/api/sessions` wire row into `db.ImagingSession`, field for field, with
the same `int → epoch ms | String → tryParse | else → epoch 0` fallback, and both are fed by
`backend.getAllSessions()` (`imaging_records_repository.dart:98`,
`database_provider.dart:412`). Two copies of one wire contract.
**Canonical survivor:** `ImagingRecordsRepository` (it is the declared host-authoritative
access layer, per its own doc at L40-44). `_fetchRemoteSessions` in `database_provider.dart`
should call `ImagingRecordsRepository.getAllSessions()` instead of re-decoding; if the provider
cannot take that dependency, both must import the shared decoder from the new
`services/imaging_records/remote_row_codec.dart` in §1.4.1. Effort: small.

### 2.3 Three "JSON value → DateTime" coercions, one of which is the correct one — SMALL

- `utils/utc_timestamp.dart:17-45` — the **canonical** one. Its doc (L1-10) states the whole
  problem: `DateTime.parse` reads an offset-less ISO string as *local* time, silently shifting
  the instant by the host's UTC offset.
- `services/imaging_records_repository.dart:559` — `DateTime.tryParse(value)`. No UTC guard.
- `services/sequence_file_service/sequence_decoder.dart:711-720` (`_parseDate`) —
  `DateTime.parse(value)`. No UTC guard.
- `providers/database_provider.dart:495` — third copy of the same unguarded coercion.

**Canonical survivor:** `tryParseUtcTimestamp` from `utils/utc_timestamp.dart`. Every
`String →DateTime` on a wire boundary should route through it. See §5.2 for the reliability
consequence. Effort: small.

### 2.4 Two sexagesimal formatters, only one with the carry fix — SMALL, but fix the bug

- `utils/coordinate_format.dart` — `CoordinateFormat.ra/dec` (the declared "single place" for
  formatting, per its doc L1-13).
- `utils/coordinate_parser.dart:150-194` — `CoordinateParser._sexagesimal` + `formatRaHms` /
  `formatDecDms`, i.e. *formatting living in the parser*.

`CoordinateParser._sexagesimal` carries a documented fix (L150-158) for the
"05:35:60.00 is not a time" class of bug. `CoordinateFormat` does **not** have it — see §5.1,
where it is reproduced.
**Canonical survivor:** `CoordinateFormat`. Port `_sexagesimal`'s quantize-then-decompose into
it, add a `SecondsPrecision.twoDecimal` (the only shape `CoordinateFormat` currently cannot
produce), then make `CoordinateParser.formatRaHms/formatDecDms` one-line delegates
(`CoordinateFormat.ra(h, style: paddedColons, seconds: twoDecimal)`) or delete them after
migrating call sites. Effort: small.

### 2.5 `utils/device_id_utils.dart` is a 19-line re-export shim — TRIVIAL

`utils/device_id_utils.dart` (19 lines) is nothing but
`export 'device_id.dart' show isValidDeviceIdFormat, kKnownDeviceIdPrefixes, kKnownDeviceIdSingletons;`.
Its only non-barrel importer in the whole repo is
`packages/skotiq_core/test/services/device_service_connect_all_test.dart:29`.
**Merge:** point `skotiq_core.dart:339` and `skotiq_core_services.dart:17` at
`src/utils/device_id.dart show isValidDeviceIdFormat`, repoint that one test import, delete the
shim, and fix the two stale doc references (`services/device_exceptions.dart:52`,
`utils/device_id.dart:30,231`). Effort: small.

---

## 3. SUSPECTED CROSS-PACKAGE DUPLICATION (for the cross-cutting agent)

- **Three semantic-version types.** `models/backend/remote_api_compatibility.dart:100`
  (`SemanticVersion`), `packages/skotiq_remote_protocol/lib/src/server_compatibility.dart`
  (`ServerSemanticVersion`), `packages/skotiq_plugins/lib/src/plugin_host.dart:497`
  (`_SemanticVersion`). Core's is already a pure adapter (`_toCore`, L38-39).
- **`models/imaging/integration_settings.dart:934-1029` hand-mirrors the Rust
  `IntegrationSettingsArgs` / `DrizzleConfigArgs` / `PsfArgs` / `ReduceStarsConfigArgs` /
  `BackgroundConfigArgs` / `CombineChannelsArgs` serde structs** in
  `native/skotiq_native/bridge/src/api/finishing_*.rs`. Two hand-maintained copies of one
  JSON contract, kept in sync only by comments.
- **`utils/device_id.dart` explicitly mirrors `native/skotiq_native/bridge/src/device_id.rs`**
  — stated in its own doc at L14-15. Dart and Rust parsers for the same id grammar.
- **`utils/coordinate_format.dart` / `coordinate_parser.dart` vs per-screen RA/Dec formatters.**
  `coordinate_format.dart:4-7` says ~20 screens each carried a private `_formatRa`/`_formatDec`;
  worth re-checking whether all of them actually migrated, plus the web dashboard's own copy.
- **`models/import/canonical_sequence_node.dart` vs `models/sequence/sequence_models/**`** —
  two node representations for the same domain (importer canonical form vs runtime model).
- **`utils/json_validation.dart`** (`decodeJsonObjectString`, `jsonInt`, `jsonDouble`,
  `jsonString`, `jsonDateTime`) vs the payload coercion helpers in
  `apps/desktop/lib/headless_api/handlers/*` (`requireDouble`, `optionalDouble`,
  `optionalString` — see `session_handlers.dart:451-468`).
- **`models/calibration/remote_calibration_models.dart`** wire DTOs vs the equivalent shapes in
  `skotiq_remote_protocol` / the headless calibration handlers.
- **`utils/skotiq_data_directory.dart`** vs the Rust-side data-directory resolution and the
  `SKOTIQ_DATABASE_DIR` handling in the desktop app.

---

## 4. DEAD CODE

Every entry below was checked with a repo-wide grep across `packages/`, `apps/`, `tools/`
(and `native/` for the symbol scan), excluding `*.g.dart` / `*.freezed.dart`. Headless routes,
FRB exports and registry lookups were considered — none of these are reached that way.

| Symbol | Location | Evidence |
|---|---|---|
| `PlateSolverUtils` + `AstapCatalogInfo` (the whole file, 384 lines) | `utils/plate_solver_utils.dart` | `grep -rn '\bPlateSolverUtils\b'` over packages+apps+tools → **3 hits, all inside the file itself** (L26 declaration, L256/L376 log `name:` strings). Each public static is likewise definition-only: `findAstapExecutable` 1 hit (L33), `detectAstapCatalog` 1 (L98), `getAstapNotFoundMessage` 1 (L266), `findAstrometryNetExecutable` 1 (L298). `AstapCatalogInfo` 5 hits, all in-file. The file is exported from both barrels (`skotiq_core.dart:665`, `skotiq_core_services.dart:248`) — that export is the only thing keeping it "public", and it is a monorepo-internal package. |
| `TargetVisibility` | `models/target/target_models.dart:197` | 2 hits total (declaration L197 + ctor L208). No `TargetVisibility(` construction anywhere. (`_TargetVisibility` in `skotiq_app/lib/screens/sequencer/widgets/target_queue_panel.dart:139` is an unrelated private class.) |
| `SessionPlan` | `models/target/target_models.dart:238` | 2 hits total (L238, L245). Nothing constructs or references it. |
| `PlannedTarget` | `models/target/target_models.dart:258` | 3 hits, all in-file (L242 field of the dead `SessionPlan`, L258, L266). The live planner type is `SmartNightPlannedTarget` in `services/smart_night_models/planned_target_results.dart:29` — a different class. |
| `ScienceDiagnostics` | `models/science/science_models/session_context.dart:93` | 2 hits total (L93, L99). Never constructed, never a field/parameter type. |
| `SemanticVersion.tryParse` | `models/backend/remote_api_compatibility.dart:107` | The *class* is alive (`RemoteApiCompatibility.clientApiVersion` is used from `backend/network_backend/http_transport.dart:21`, `connection_lifecycle.dart:93,268`, `remote_log_operations.dart:161`). But `tryParse` has zero callers — the only `tryParse` hits are `ServerSemanticVersion.tryParse` (`skotiq_remote_protocol`) and `_SemanticVersion.tryParse` (`skotiq_plugins`). All parsing was delegated to `skotiq_remote_protocol` (see the adapter comment at L5-12); `tryParse` and the `<`/`>`/`compareTo` comparison surface were left behind. |
| `ImageFileFormatSettingsX.settingsValue` | `models/imaging/imaging_models/file_format_and_capture_state.dart:42` | `grep -rn 'settingsValue'` → the declaration plus two unrelated `_settingsValueEquals` hits in `apps/desktop/lib/headless_api/handlers/profile_handlers.dart:621,630`. No caller. |
| `utils/device_id_utils.dart` (as a file) | 19 lines | Pure re-export shim; see §2.5. Not dead *code* but dead *indirection*. |

**Explicitly NOT claimed dead** (checked and rejected, or unprovable by grep — recorded so the
next pass does not re-chase them):
- `ProfileFilterConfig` / `ProfileFilterResult` (`models/equipment_profile_validation.dart:64,73`)
  — alive via `ProfileValidator.parseFilterRows`, called from
  `skotiq_app/.../profile_data_operations.dart:395` and `profile_details.dart:214`.
- `DriverTypeDescription` (`models/equipment/unified_device.dart:278`) — alive; `.shortLabel`
  and `.description` are used across the equipment/onboarding screens.
- The `*Extension on <enum>` cluster (`BinningModeExtension`, `PolarAlignPhaseExtension`,
  `PolarAlignmentModeExtension`, `FlipStepExtension`, `FlipFailureActionExtension`,
  `Phd2GuidingStateExtension`, `SourceFormatExtension`) exposes only generic member names
  (`label`, `description`, `displayName`, `isActive`) that grep cannot resolve — 200-700
  same-named hits each, almost all unrelated. **Some of these are probably dead weight, but
  proving it needs a type-aware pass** (analyzer `unused_element` on a temporarily-privatised
  copy, or an LSP find-references per member). Recommend one LSP sweep over this cluster rather
  than more grepping. Note the one counter-example found:
  `MeridianTriggerMethodExtension.supportsStandaloneMonitoring` /
  `.standaloneMonitoringLimitation` **are** live
  (`providers/meridian_flip_provider.dart:227,230`).
- The freezed `JsonConverter` classes (`Uint8ListConverter`, `NullableUint8ListConverter`,
  `TargetWarningConverter`, …) — they are referenced as `@Converter()` annotations inside their
  own declaring file, which a cross-file grep cannot see. Not dead.

---

## 5. RELIABILITY RISKS

### 5.0 The First Light difference scan divides the RA by 15 a second time — P1, CONFIRMED

`services/imaging_records_repository.dart:966-968`:

```dart
final wcs = SolvedWcs(
  raHours: ra / 15.0,      // ra == image.solvedRa
```

`image.solvedRa` is **already in hours**. Three independent confirmations:

1. Write site — `services/science/science_processing_service/private_helpers.dart:521`
   persists `solvedRa: solved.raHours`.
2. Read site — `providers/database_provider.dart:200` maps the column straight across as
   `solvedRaHours: row.solvedRa`.
3. Sibling read site — `services/sky_atlas/sky_atlas_service.dart:212` builds its WCS with
   `raHours: image.solvedRa!`, no conversion.

And the *other* helper in this very file gets it right:
`services/imaging_records_repository.dart:909` converts to degrees with `raDeg: ra * 15.0`
inside `_driveCoImagingAutoContribute`. So the two functions sitting 60 lines apart, reading
the same field, disagree about its unit.

**Consequence.** Every First Light scan builds a `SolvedWcs` centred at 1/15 of the true RA.
The frame is then differenced against the wrong sky tile, so the transient search either finds
nothing or reports garbage — and it fails silently, because the whole chain is wrapped in the
fire-and-forget swallow described in §5.4. A frame at RA 20h is scanned as if it were at
RA 1h20m. This is the same defect shape already recorded for the planetarium (RA stored in
degrees in an hours field).

**Fix:** `raHours: ra` at L967. Then add a regression test that asserts the `SolvedWcs` centre
for a known `captured_images` row matches the `SkyAtlasService` fold centre for the same row —
the two must agree by construction, which is what would have caught this.

**Caveat for the verifier:** this is a code-read finding. Per the repo rule, reproduce it in the
running app (solve a frame with a known RA and log the `SolvedWcs` the scan builds) before
landing the one-character fix.

### 5.1 `CoordinateFormat` can render impossible coordinates — CONFIRMED by execution

`utils/coordinate_format.dart:93-102` formats the seconds field independently of the minutes
field: `SecondsPrecision.oneDecimal` does `rawSeconds.toStringAsFixed(1)` and
`integerRounded` does `_pad2(rawSeconds.round())`. Neither carries into minutes.

Reproduced by running the exact code path:

```
input 5h35m59.97s  → CoordinateFormat.ra(...)            → "05h 35m 60.0s"
input 5h59m59.70s  → CoordinateFormat.ra(..., integerRounded) → "05h 59m 60s"
input 23h59m59.99s → CoordinateFormat.ra(...)            → "23h 59m 60.0s"
```

`CoordinateParser._sexagesimal` (`utils/coordinate_parser.dart:150-167`) documents this exact
failure and fixes it by quantizing the whole angle first. `CoordinateFormat` never got the fix.
Reachable in production from, among others,
`services/imaging_records_repository.dart:1045` (the transient-discovery push text) and the ~20
screens the class's own doc says were migrated onto it.
**Fix:** port the quantize-then-decompose from `coordinate_parser.dart:159-167` into
`CoordinateFormat`, and add a `SecondsPrecision.twoDecimal` so `CoordinateParser` can delegate
(§2.4). The byte-for-byte output contract in the doc (L9-13) means the fix must be paired with a
golden test for each style.

### 5.2 Remote session times are parsed without the UTC guard — timezone shift across a remote link

`services/imaging_records_repository.dart:554-562` (`_dateTimeFromJson`) does
`DateTime.tryParse(value)` on the `startTime`/`endTime` fields of a `/api/sessions` row, and
`providers/database_provider.dart:490-499` has the identical copy. `utils/utc_timestamp.dart:1-10`
exists precisely because `DateTime.parse`/`tryParse` interprets an offset-less ISO-8601 string as
**local** time. A phone in a different timezone than the appliance therefore renders every
session start/end shifted by the offset delta, with no error.
The `int` branch (epoch ms) is safe, so whether this fires depends on which serializer the host
used for a given row — the codebase emits both shapes
(`apps/desktop/lib/headless_api/handlers/analytics_handlers.dart:602` writes epoch ms;
`sequencer_handlers.dart:56` writes `toIso8601String()`), which is itself the hazard.
**Fix:** route both copies through `tryParseUtcTimestamp` and make the host emit one shape.

### 5.3 A multi-node sequence save is not atomic and not batched

`services/sequence_repository.dart:262-308` (`_updateSequence`) and `:311-330` (`_saveNodes`)
issue one `await dao.updateNode(...)` / `createNode(...)` / `deleteNode(...)` **per node, in a
loop, with no enclosing transaction**. `SequencesDao.createNode/updateNode/deleteNode`
(`database/daos/sequences_dao.dart:343,348,353`) are single statements — the DAO *has*
`transaction()` (L239, L271) and `batch()` (L366) elsewhere, so the primitive exists and is
simply not used here.
Consequence: an exception or an app kill part-way through saving a 200-node sequence leaves the
library row updated but the node set half-migrated — some nodes updated, some inserted, some of
the to-delete set still present. There is no recovery path; the next load rebuilds a corrupted
tree from whatever survived.
**Fix:** wrap the whole diff-apply in one `dao.transaction(() async { … })`, and use
`dao.batch()` for the insert/delete arms.

### 5.4 The solve-persist side-effect chain is fire-and-forget with a total swallow

`services/imaging_records_repository.dart:401-409` fires `onSolvedFrameFold(id)` with
`unawaited(...)` + `.catchError((Object _) {})`. That hook (L798-881) is no longer a small
"fold into atlas" step — it now runs the **First Light difference scan**, the **co-imaging
auto-contribute**, and the **transient push routing**, all inside one `try { } catch` that only
logs a warning (L875-880).
Two consequences: (a) there is no join point, so a headless shutdown between the solve write and
the fold completion drops the scan silently (see the existing `HeadlessShutdown` coordinator —
this chain is not one of its awaited steps); (b) a systematically broken First Light path is
invisible to the caller — the solve reports success either way. This matches the "cry-wolf"
defect class already recorded for this repo.
**Recommendation:** keep it non-blocking, but return/expose the `Future` so the headless
shutdown path and the tests can join it, and escalate a repeated hook failure to the notification
router instead of only `logger.warning`.

### 5.5 `resilientDistinctPoll` has no per-fetch timeout

`utils/resilient_poll_stream.dart:36-56`: `poll()` sets `polling = true`, then `await fetch()`.
If `fetch()` never completes (a hung socket with no transport-level timeout), `polling` stays
`true` forever, `scheduleNext()` in the `finally` never runs, and the stream simply stops
emitting — no error, no retry, no log. The consumer
(`imaging_records_repository.dart:619-689` → `sessionDbImagesProvider`) shows a frozen frame
list that looks like "no new frames" rather than "connection lost".
Impact depends on whether every `NetworkBackend` call already carries an HTTP timeout — worth
confirming, but a `fetch().timeout(interval * 3)` here is cheap and makes the stall self-healing.
Marked medium, not high, for that reason.

---

## 6. PERF RISKS

### 6.1 `loadSequenceSummaries` is N+1, and its own doc says it is not — MEDIUM

`services/sequence_repository.dart:452-509`. The doc (L454-456) claims "a single grouped DAO
query plus a **batched** run-history roll-up, so the library list renders without hydrating any
node tree". The code at L486-508 does one grouped query (`getSequenceSummaryRows()`) and then,
inside a collection-`for`, `await runsDao.runSummaryForSequence(row.id)` **per row** —
`database/daos/sequence_runs_dao.dart:192-202` is a single-sequence `selectOnly … where(id ==)`.
So a 40-sequence library costs 41 serialized round trips on the sequencer library screen.
**Fix:** add `SequenceRunsDao.runSummariesForSequences(List<int> ids)` — one `selectOnly` with
`groupBy(sequenceRuns.sequenceId)` returning `count` + `max(startedAt)` — and fold the result in.
Then correct the doc comment.

### 6.2 `loadAllSequences` hydrates every node tree — MEDIUM (partially mitigated)

`services/sequence_repository.dart:409-428` calls `loadSequence(id)` per row, and each
`loadSequence` (L359-406) issues two more queries (`getSequenceById` + `getNodesForSequence`)
and rebuilds the full node map. `SequenceSummary`/`loadSequenceSummaries` exists precisely to
avoid this and the library screen uses it
(`providers/sequence/sequence_catalog_sync.dart:91`), but `loadAllSequences` is still on the
backup path (`services/backup_service.dart:775`) and `sequence_catalog_sync.dart:79`.
**Fix:** confirm `sequence_catalog_sync.dart:79`'s caller genuinely needs full trees; if not,
move it to summaries. Otherwise batch the node fetch (one `getNodesForSequences(ids)` query
grouped in memory) instead of 1+2N queries.

### 6.3 Per-node DB round trips on save — MEDIUM

Same code as §5.3 (`sequence_repository.dart:262-330`). Independent of the atomicity problem, a
200-node sequence save is 200+ awaited statements; `dao.batch()` (already used at
`sequences_dao.dart:366`) collapses that to one.

### 6.4 `IntegrationSettings.fromJsonStringOrDefault` re-decodes JSON on every call — LOW

`models/imaging/integration_settings.dart:1213-1224` does a `jsonDecode` + a 100-field
reconstruction each time it is called, and it is the read path for the
`integrated_masters.settings_json` column and the app-settings default key. It is cheap per call
and is not (as far as I could see) called from a `build()`; flagged as LOW and only worth
addressing if a caller is found inside a widget build or a per-frame loop. Not evidenced as hot —
do not "fix" this without a profile.

---

## 7. WHAT I DID NOT COVER

- `lib/src/database/**` (daos, tables, schema_helpers) — assumed owned by the core-database
  mapper; I only read `sequences_dao.dart` / `sequence_runs_dao.dart` / `captured_images.dart`
  as evidence for the repository findings above.
- `lib/src/providers/**` and `lib/src/services/**` beyond the two repository files — owned by
  the other core mappers. `providers/database_provider.dart` appears above only because it holds
  the second copy of a repository decoder (§2.2, §5.2).
- The `*Extension on enum` dead-weight cluster (§4) needs a type-aware tool, not this pass.
