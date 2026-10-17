# core-models implementation log

Batch: core-models. Work order: reports/release-pass/map/core-models.md
Baseline: b07d91c9d. Resumed a killed predecessor run; every item below was
re-verified against baseline code rather than taken on trust.

---

## 1. BUG — raHours double-division in the First Light scan (work order §5.0)

`services/imaging_records_repository.dart` built the difference-scan WCS with
`raHours: ra / 15.0`, but `captured_images.solved_ra` is app-canonical HOURS on
the write side and every other read side.

Extracted the WCS construction into `firstLightScanWcs(...)` (`@visibleForTesting`)
so the centre is assertable, and fixed the unit.

Test: `test/services/first_light_scan_centre_test.dart` (2 tests). The second one
reads the fold centre back off the real `SkyAtlasService` seam args rather than
recomputing it, so the two derivations are pinned to each other.

PRE-FIX PROOF — reintroduced `/ 15.0` and re-ran:
```
the First Light scan centre is the persisted solved RA in hours [E]
  Expected: within <1e-9> of <5.5773>   Actual: <0.37182>
the First Light scan centre matches the atlas fold centre for the same row [E]
  Expected: within <1e-6> of <83.6595>  Actual: <5.5773>
```
Post-fix: 2/2 pass.

## 2. RELIABILITY/PERF — non-atomic, unbatched sequence node-diff save (§5.3, §6.3)

`_updateSequence` issued one `updateNode`/`createNode`/`deleteNode` per node in a
bare loop. Metadata update + whole node diff now run inside one
`dao.transaction`, and the diff itself as one `dao.batch` (replace / insertAll /
deleteWhere). `_saveNodes` is one batch insert. Row-id preservation for surviving
nodes is unchanged (`_nodeUpdateRow` carries `existing.id` and `existing.targetId`).

Test: `test/services/sequence_repository_save_atomicity_test.dart` (3 tests).
Failure is injected at the database (a `BEFORE INSERT` trigger that ABORTs one
node) so the real save path runs.

PRE-FIX PROOF — restored the baseline `sequence_repository.dart` and re-ran:
```
a save that fails part-way leaves the persisted node set untouched [E]
  Expected: {'a': 'A', 'b': 'B', 'c': 'C'}
    Actual: {'a': 'A renamed', 'b': 'B', 'c': 'C'}
```
Post-fix: 3/3 pass.

## 3. BUG — seconds carry in CoordinateFormat (§5.1, §2.4)

`CoordinateFormat` formatted the seconds field independently of the minutes
field, so it rendered times that do not exist. Replaced the field-by-field
decomposition with `_decompose`, which quantizes the WHOLE angle at the rendered
precision and then splits, making the carry structural for every precision.
Added `SecondsPrecision.twoDecimal` (zero-padded `SS.ss`), and
`CoordinateParser.formatRaHms`/`formatDecDms` now delegate to `CoordinateFormat`
— the parser's private `_sexagesimal`/`_pad2`/`_padSeconds` are gone.

Byte contract preserved: `oneDecimal` stays unpadded (`5.0`, not `05.0`),
`integerFloored` still truncates, only `integerFloored` truncates.
`CoordinateFormat.ra` of a negative input now renders a signed magnitude
(`-00h 30m …`) instead of the baseline's nonsense `-01h 30m …`.

The predecessor had left a deliberate PRE-FIX REPRODUCTION branch live in
`_decompose` with the real fix behind `// ignore: dead_code`. I used it to
capture the failure, then deleted it.

PRE-FIX PROOF (against that reproduction branch):
```
never prints 60 seconds [E]  Expected: '05h 36m 0.0s'  Actual: '05h 35m 60.0s'
every formatted RA/Dec reads back through the strict parser [E]
  CoordinateFormat.ra(1.2, SecondsPrecision.integerRounded) = "01:11:60"
+ 2 pre-existing formatRaHms/formatDecDms tests failed through the delegation
```
Post-fix: `test/utils/coordinate_format_test.dart` 20/20 pass.

## 4. DEDUP — `_sessionFromJson` + its date coercion (§2.2, §2.3, §5.2)

One decoder: `imagingSessionFromWireJson` + `wireTimestamp`, both top-level in
`imaging_records_repository.dart`. `providers/database_provider.dart` now calls
them for sessions, sequences and targets; its `_sessionFromJson` and
`_dateTimeFromJsonValue` are deleted. The string branch routes through
`utils/utc_timestamp.dart:tryParseUtcTimestamp`, so an offset-less ISO string
reads as UTC instead of local.

Test: `test/services/imaging_session_wire_decode_test.dart` (5 tests). The UTC
assertion (`parsed.isUtc, isTrue`) fails against the baseline `DateTime.tryParse`
in any timezone, not only a non-UTC one.

## 5. PERF — batched `loadSequenceSummaries` roll-up (§6.1)

Added `SequenceRunsDao.runSummariesForSequences(ids)`: one `selectOnly` with
`groupBy(sequenceId)` returning count + max(startedAt). `loadSequenceSummaries`
does two grouped queries instead of 1 + N; the doc comment that claimed it was
already batched is corrected.

Test: `test/services/sequence_summary_rollup_batch_test.dart` (3 tests) — pins
the batched result against the per-sequence `runSummaryForSequence` it replaced,
plus the empty-id-set case and the end-to-end summary values.

## 6. DEDUP — shared sequence enum wire codec (§2.1)

New `services/sequence_wire_codec.dart`: `enumFromWire` / `enumFromWireOr`,
`autofocusMethodFromWire`, `recoveryActionToDbWire` / `recoveryActionToFileWire`
/ `recoveryActionFromWire`, `explicitTransportsFromWire`. Both the DB codec
(`sequence_repository.dart`, ~300 lines of hand-rolled switches) and the file
codec (`sequence_file_service/sequence_decoder.dart`, ~130 lines) now bind to it.

Per the override: **encoding still emits each format's current bytes**
(`continue` on the DB side, `continueExecution` on the file side), decoding is
tolerant of both, and the unknown-token fallback stays per-format
(`continueExecution` for DB, `retry` for file) because changing what a corrupt
node does unattended is a behaviour change, not a cleanup.

**This surfaced a real bug, not just drift risk.** The DB encoder writes
`node.triggerMethod.name`, but the DB reader hand-listed only
`minutesBeforeLimit` and `hourAngleThreshold`. `MeridianTriggerMethod` also has
`onTrackingLimitHit` — so an operator who chose "flip when the mount hits its
tracking limit" got "5 minutes past meridian" back on every reload, silently.

Tests:
- `test/services/sequence_wire_codec_test.dart` (7 tests) — token-level parity.
- `test/services/sequence_repository_enum_roundtrip_test.dart` (7 tests, NEW this
  run) — exhaustive save/load round trip through the real repository for every
  value of `MeridianTriggerMethod`, `FlipFailureAction`, `RecoveryActionType`,
  `TriggerType`, `BinningMode` x `FrameType`, plus both cross-format spellings.

PRE-FIX PROOF — restored the four baseline codec files and re-ran:
```
every meridian trigger method survives a save/load [E]
  Expected: MeridianTriggerMethod.onTrackingLimitHit
    Actual: MeridianTriggerMethod.minutesPastMeridian
the file reader accepts the DB spelling of continue [E]
  Expected: RecoveryActionType.continueExecution
    Actual: RecoveryActionType.retry
```
Honest note: `the DB reader accepts the file spelling of continue` PASSED at
baseline — 'continueExecution' fell through to the DB reader's default, which
happens to be `continueExecution`. It is a guard, not a bug proof.

Post-fix: 7/7 + 7/7 pass.

## 7. DELETE (§4, §2.5)

Re-proved zero callers myself with a fresh repo-wide grep over
`packages/ apps/ native/ tools/`, excluding `.dart_tool/`, `build/`, `target/`,
`*.g.dart`, `*.freezed.dart`, `frb_generated*` — **zero hits for all of**
`PlateSolverUtils`, `AstapCatalogInfo`, `TargetVisibility`, `SessionPlan`,
`PlannedTarget`, `device_id_utils`, `plate_solver_utils`. No headless route, FRB
export, registry or string lookup reaches them; no test existed for any of them.

- Deleted `lib/src/utils/plate_solver_utils.dart` (384 lines) + both barrel
  exports (`skotiq_core.dart`, `skotiq_core_services.dart`).
- Deleted `TargetVisibility`, `SessionPlan`, `PlannedTarget` from
  `models/target/target_models.dart` (90 lines). `_TargetVisibility` in
  `skotiq_app` is an unrelated private class and is untouched.
- Deleted the 19-line re-export shim `lib/src/utils/device_id_utils.dart`; both
  barrels now export `isValidDeviceIdFormat` from `src/utils/device_id.dart`,
  the one test import is repointed, and the stale doc references in
  `services/device_exceptions.dart` and `utils/device_id.dart` are corrected.

## NOT DONE

- No file splits (work order §1.1-§1.4) — forbidden this wave.
- `imaging_records_repository` split explicitly deferred by the item list.
- §5.4 (fire-and-forget solve hook), §5.5 (poll timeout), §6.2, §6.4 — not in
  the item list.

## Verification

- `flutter analyze` on `skotiq_core`: clean for every file I touched. The 2
  remaining infos are pre-existing `deprecated_member_use` in
  `test/database/restore_clears_recovery_marker_test.dart` (not my scope).
- `dart format` run on the 23 files I touched, nothing else.
- Full package suite, first run: 5624 passed / 4 skipped / **4 failed**, all four
  in `test/providers/sequence/sequence_executor_launch_parity_test.dart` — an
  UNTRACKED file the concurrent core-services-devices agent was writing for their
  in-flight `sequence_executor.dart` rewrite. Failure was
  `SqliteException(787): FOREIGN KEY constraint failed` on
  `INSERT INTO imaging_sessions ... profile_id 7`: their fixture, no overlap with
  this batch. They landed the fix mid-run; on retry that file is 14/14.
- Full package suite, final run: **`02:39 +5629 ~4: All tests passed!`**
- Downstream consumers of what this batch changed, spot-checked green:
  `apps/desktop test/headless_api/sequencer_handlers_test.dart` (36/36, mocks
  `SequenceRepository`) and `packages/skotiq_app
  test/screens/sequencer/sequence_library_authority_test.dart` (2/2).
