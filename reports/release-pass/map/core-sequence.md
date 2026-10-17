# Release-pass map — `skotiq_core` sequence execution

**Subsystem:** core-sequence
**Paths mapped:** `packages/skotiq_core/lib/src/providers/sequence/` (whole directory; deep focus on `sequence_executor.dart` + the `sequence_executor/` part files)
**Mode:** read-only. No source file was modified.
**Date:** 2026-08-11

Orientation was taken with `graphify query` before any grep/read, per the repo rule.

---

## 0. Shape of the subsystem

`sequence_executor.dart` is a **single Dart library** made of one main file plus five `part` files:

```
sequence_executor.dart                          2288   (library head + class SequenceExecutor)
  part sequence_executor/serialization_operations.dart      1090
  part sequence_executor/runtime_config_operations.dart     1106
  part sequence_executor/event_operations.dart              1436
  part sequence_executor/session_diagnostics_operations.dart 494
  part sequence_executor/checkpoint_watchdog_operations.dart 120
     (not a part) sequence_executor/frame_attribution.dart   168
```

Total library ≈ 6.4k lines for one class. All hand-written — no `.g.dart`, no `.freezed.dart`, no `frb_generated`, no `GENERATED CODE` / `DO NOT EDIT` banner in any of them (verified by grep).

**This makes the split unusually cheap and unusually safe.** The part files are all `part of '../sequence_executor.dart'` and expose their members as *private extensions on `SequenceExecutor`*. Moving a method from one part file to another (or to a brand-new part file of the same library) changes nothing observable: privacy is library-scoped, so private fields stay reachable, and no import, no test, and no call site anywhere outside the library can tell the difference. **Every split plan below is a pure text move plus a `part` directive.** The only members that cannot move out of `sequence_executor.dart` are the `SequenceExecutor` *fields* and its constructor.

Evidence of a previous mechanical split that was never finished: three of the five part files end with an **orphan doc comment attached to nothing**, immediately before the closing brace of the extension —

* `checkpoint_watchdog_operations.dart:115-119` — "Cancel all owned timers and subscriptions. / Wired into the owning Provider's `ref.onDispose`…" (documents `dispose()`, which lives in `sequence_executor.dart:2270`)
* `event_operations.dart:1428-1435` — "Capture the optical-train baseline + register the active sequence…" (documents `_captureSessionStartHooks`, which lives in `session_diagnostics_operations.dart:4`)
* `runtime_config_operations.dart:1105` — "Handle events from the backend (native or remote)" (documents `_handleSequencerEvent`, which lives in `event_operations.dart:4`)
* `serialization_operations.dart:1074-1089` — "Validate the sequence about to run using the FULL validator stack…" (documents `validateSequenceForStart`, which lives in `sequence_executor.dart:487`)

These are dangling docs left behind when the methods they described were moved. They compile (a doc comment before `}` is legal) but they lie about the file they sit in. Delete all four as part of any split.

---

## 1. OVERSIZED FILES

Four files over the 1000-line Dart threshold. Counts verified with `wc -l`.

---

### 1.1 `packages/skotiq_core/lib/src/providers/sequence/sequence_executor.dart` — **2288 lines** (risk: **high**)

**Why it is big.** It is the whole run lifecycle in one class: start admission + transactional acquisition, the one-per-run finalization transaction (`_RunFinalization` + `_driveFinalization` + native-stop confirmation), the transport command surface (pause/resume/stop/skip/skipToTarget/reset), and the entire checkpoint/resume path — plus ~40 instance fields and 40 imports. The finalization state machine alone is ~600 lines of extremely dense, heavily-commented invariant code that several prior audits have already had to fix in place. Every change to any one of those five concerns has to be made inside a file where a mis-scoped edit can touch the other four.

**What must stay.** The `class SequenceExecutor` field block, constructor, and `_logger`. Nothing else is pinned.

**Split plan (5 files, all parts of the same library — behaviour-preserving by construction).**

| New file | What moves in (current lines) | ≈ lines |
|---|---|---|
| `sequence_executor.dart` (kept) | imports + `part` directives; ETA constants `kEtaWindowSize` / `kEtaEmaAlpha` / `kCoolerSetpointBandDegC` (86-105); `sequenceExecutorProvider` (129-143); `class SequenceExecutor` field block + ctor (230-396) — **plus `_runCatalogTargetIds` (684) moved up into the field block**; `_ensureBackendAuthority` (389); every `@visibleForTesting` accessor (398-480, 628-631, 2256-2260); `dispose()` (2270-2287) | ≈ 400 |
| `sequence_executor/finalization_operations.dart` (new part) | `kNativeStopConfirmationTimeout` + `kNativeStopConfirmationPollInterval` (107-127); `class _RunFinalization` (145-228); `_resetFinalizationForNewRun` (862-873); `_rollbackStart` (875-936); `_releaseAutomatedEditorOwnership` (938-967); `_onTerminalEvent` (969-1057); `_swallowSpawnedFinalizationError` (1059-1065); `_nativeTerminalStates` (1067-1085) → **re-declare as a top-level `const _kNativeTerminalStates` in this part** (a `static const` cannot move into an extension without also moving the class); `_awaitNativeStopConfirmation` (1087-1177); `_launchDrive` (1179-1190); `_driveFinalization` (1192-1383); `_releaseRunResources` (1385-1430); `_publishTerminalResult` (1432-1453); `_setExecutionState` (1672-1679) | ≈ 640 |
| `sequence_executor/start_operations.dart` (new part) | `validateSequenceForStart` (482-492); `validateSequence` (494-499) — *or delete it, see §3.1*; `start()` (501-596); `_startSessionRow` (598-626) + `startSessionRowForTest` (628-631); `_ensureSequencePersisted` (633-680); `_bindCatalogTargets` (686-727); `_runTargetIdFor` (729-735); `_acquireAndStartRun` (737-850); `_isStartAdmissible` (852-858) | ≈ 380 |
| `sequence_executor/transport_operations.dart` (new part) | `_awaitStateChange` (1455-1496); `pause` (1498-1533); `resume` (1535-1570); `_persistLiveRunStatus` (1572-1589); `stop` (1591-1670); `skip` (1681-1685); `skipToNode` (1687-1695); `skipToTarget` (1697-1783); `_owningTargetHeaderId` (1785-1802); `reset` (1804-1866) | ≈ 410 |
| `sequence_executor/checkpoint_watchdog_operations.dart` (existing, grows 120 → ~520) | `initializeCheckpoints` / `hasCheckpoint` / `getCheckpointInfo` (1871-1891); `resumeFromCheckpoint` (1893-1922); `_recoverResumedSequence` (1924-2001); `_resumeFromCheckpointInner` (2003-2219); `attachHostListenersForNativeRun` (2221-2254); `discardCheckpoint` (2262-2267). Also delete the orphan doc at 115-119. | ≈ 520 |

**Preconditions for the mover.** (a) Move `final Map<String, int> _runCatalogTargetIds` from line 684 up into the field block *before* moving `_bindCatalogTargets` out — a field declared mid-class cannot live in an extension. (b) `_nativeTerminalStates` must become a top-level private const, not an extension static, so `_awaitNativeStopConfirmation` keeps referring to it unqualified. (c) Nothing else changes; do **not** add imports (parts share the library's imports) and do **not** change any member's privacy.

**Do this split *after* §2.1 and §2.2** (the start/resume duplication) — de-duplicating first means ~150 fewer lines get moved twice.

---

### 1.2 `.../sequence_executor/event_operations.dart` — **1436 lines** (risk: **high**)

**Why it is big.** It is four unrelated responsibilities stapled to one 448-line `switch`: (1) the native-event dispatch itself, (2) `captured_images` row construction (`_registerSequenceFrame`, 293 lines with ~50 lines of comment), (3) the live-run-stats mutation + persistence + `finishRun` transaction, and (4) the entire live-stacking auto-feed. Live stacking has nothing to do with event *decoding*; it just happens to be triggered by one case of the switch.

**Split plan (5 files, all parts).**

| New file | What moves in (current lines) | ≈ lines |
|---|---|---|
| `event_operations.dart` (kept) | `_handleSequencerEvent` (4-451); `_decodeStructuredProgressJson` (459-469); `_handleMeridianFlipOutcome` (1004-1087); `_nodeRanAutofocus` (911-926). Delete the orphan doc at 1428-1435. | ≈ 560 |
| `sequence_executor/frame_registration_operations.dart` (new part) | `_registerSequenceFrame` (613-909); `_resolveActiveFilter` (928-945); `_resolveActiveTargetName` (947-970) | ≈ 340 |
| `sequence_executor/run_stats_operations.dart` (new part) | `_recordRunFrame` (972-990); `_recordRunError` (992-994); `_recordTerminalRunError` (996-1002); `_incrementRunStat` (1089-1120); `_persistLiveRunStats` (1122-1140); `_finalizeRun` (1142-1180); `_drainPendingStatWrites` (1182-1194). **Also pull in `_surfaceRunWarning` + `_surfaceFilterLookupWarning` from `serialization_operations.dart:249-271`** — they are run-stat mutators that only live in the serializer because that is where their first caller was. | ≈ 240 |
| `sequence_executor/live_stacking_operations.dart` (new part) | the whole `2026-06-04 live-stacking auto-feed` block, 1196-1422: `_findActiveLiveStackingNode`, `_liveStackingConfigFor`, `_maybeFeedLiveStacking`, `_resolveLiveStackExposureSecs`, `_feedLiveStackingFrame`, `_teardownLiveStacking` | ≈ 230 |
| `sequence_executor/plugin_replay_operations.dart` (new part) | `_persistReplayDecision` (471-510); `_dispatchPluginNode` (512-611) | ≈ 145 |

---

### 1.3 `.../sequence_executor/runtime_config_operations.dart` — **1106 lines** (risk: **medium-high**)

**Why it is big.** Three separate phases live here: the native launch sequence (`_startNativeExecution`), an eleven-`try`-block one-shot config seed (`_seedRuntimeConfigFromSettings`, 407 lines), and the mid-run settings-watcher fan-out (`_startSettingsWatchers`, 341 lines) that re-implements a large part of the seed. See §2.3 for the duplication that should be removed *before* the split.

**Split plan (4 files, all parts).**

| New file | What moves in (current lines) | ≈ lines |
|---|---|---|
| `runtime_config_operations.dart` (kept) | `_startNativeExecution` (4-174); `_effectiveSafetyFailMode` (176-198); `_pushEffectiveSafetyFailMode` (200-212). Delete the orphan doc at 1105. | ≈ 215 |
| `sequence_executor/runtime_config_seed.dart` (new part) | `_seedRuntimeConfigFromSettings` (214-629) | ≈ 415 (≈ 360 after §2.3) |
| `sequence_executor/integration_carry_over.dart` (new part) | `_seedIntegrationCarryOverFromHandoff` (631-760) | ≈ 130 |
| `sequence_executor/settings_watchers.dart` (new part) | `_startSettingsWatchers` (762-966); `_pushObserverProfile` (968-1036); `_stopSettingsWatchers` (1038-1049); `_startSkyBrightnessPoll` (1051-1103) | ≈ 345 (≈ 290 after §2.3) |

While in here, fix the 5 mojibake sequences (`mag/arcsecÂ²` should be `mag/arcsec²`) at `runtime_config_operations.dart:579, 1052, 1076, 1088` and `session_diagnostics_operations.dart:375`. Line 1088 is an **operator-visible log line**, not just a comment.

---

### 1.4 `.../sequence_executor/serialization_operations.dart` — **1090 lines** (risk: **medium**)

**Why it is big.** It is the Dart→Rust wire codec (`_nodeToConfig`, a 452-line exhaustive switch over the sealed `SequenceNode` hierarchy — legitimately long and *should stay one switch*), plus ~185 lines of enum→PascalCase string mappers, plus the meridian-flip config builder, plus three things that are not serialization at all: the filter-index lookup, the run-warning surface, and the ETA/EMA smoother.

**Split plan (5 files, all parts).**

| New file | What moves in (current lines) | ≈ lines |
|---|---|---|
| `serialization_operations.dart` (kept) | `_sequenceToJson` (4-135); `_autofocusRuntimeConfig` (137-194); `_autofocusBinningToString` (196-201); `_lookupFilterIndex` (203-247). Delete the orphan doc at 1074-1089. | ≈ 250 |
| `sequence_executor/node_serialization.dart` (new part) | `_nodeToConfig` (334-791) — moved **whole and unmodified**; the exhaustive switch is the compiler's guard that a new node type cannot be silently dropped on the wire | ≈ 460 |
| `sequence_executor/meridian_flip_serialization.dart` (new part) | `buildGlobalMeridianFlipConfigJson` (793-824); `_buildMeridianFlipConfig` (826-887); `_meridianTriggerMethodToString` (889-902); `_flipFailureActionToString` (904-911) | ≈ 120 |
| `sequence_executor/wire_enums.dart` (new part) | `_frameTypeToWire` (913-923); `_binningToString` (925-936); `_autofocusMethodToString` (938-947); `_twilightToString` (949-958); `_notificationLevelToString` (960-971); `_safetyFailModeToBackendString` (973-977); `_loopConditionToString` (979-996); `_conditionalTypeToString` (998-1017); `_recoveryActionToRust` (1019-1037); `_recoveryActionToString` (1039-1072) | ≈ 160 |
| `sequence_executor/eta_smoothing.dart` (new part) | `_recordFrameDurationSample` (273-297); `_resetEtaState` (299-305); `_computeSmoothedEta` (307-332) | ≈ 60 |
| → `run_stats_operations.dart` (from §1.2) | `_surfaceFilterLookupWarning` + `_surfaceRunWarning` (249-271) | (25) |

---

## 2. DUPLICATION (inside these paths)

### 2.1 Run acquisition is written twice: `start()` vs `resumeFromCheckpoint()` — **effort: medium** ⭐ top priority

`_acquireAndStartRun` (`sequence_executor.dart:741-850`) and the acquisition half of `_resumeFromCheckpointInner` (`sequence_executor.dart:2104-2218`) perform the *same ordered sequence of resource acquisitions*, copy-pasted:

| Step | start | resume |
|---|---|---|
| running-state flip (progress notifier + state provider) | 765-767 | 2107-2109 |
| `_bindCatalogTargets` | 769 | 2137 |
| `sessionNotifier.startSession(...)` | 616-624 (via `_startSessionRow`) | 2140-2144 |
| `sequenceRunsDao.startRun(...)` + `currentRunIdProvider` | 777-784 | 2145-2152 |
| `liveSequenceStatsProvider = SequenceRunStats()` | 785 | 2153 |
| `_runFinalized = false; _liveStackingArmedForRun = false; _liveStackingFeedChain = null` | 786-790 | 2154-2156 |
| `sequencerSetActiveSequenceRunId(runId)` in try/warn | 800-807 | 2157-2165 |
| `_startTime = now; _isPaused = false; _resetEtaState()` | 819-821 | 2167-2174 |
| **the 1-second progress timer, byte-identical 14-line closure** | 827-840 | 2176-2189 |
| `_startCheckpointTimer(); _startDiskSpaceWatchdog()` | 842-843 | 2191-2192 |
| native event subscription | via `_startNativeExecution` 161-165 | 2194-2199 |
| `_startSettingsWatchers(backend)` | via `_startNativeExecution` 167 | 2201 |
| `_nativeLaunchAttempted = true; sequencerStart()` | via `_startNativeExecution` 172-173 | 2208-2209 |

The resume path also omits `_ensureSequencePersisted` ordering nuances and `progressNotifier.reset()/setTotals()` (deliberately — but nothing states so). This is exactly the shape that produced the "resume ran without a session id / without a target binding" defects the surrounding comments describe: someone fixed `start` and had to remember to fix `resume` separately.

**Canonical survivor:** `_acquireAndStartRun`. Extract two private helpers used by both:

* `Future<int> _openRunRecords({required String sequenceName, int? sequenceDatabaseId, String? snapshotJson, double? targetRa, double? targetDec, int? totalExposures})` — session row + `startRun` + `currentRunIdProvider` + fresh `SequenceRunStats` + the three per-run flag resets + `sequencerSetActiveSequenceRunId`. Returns the run id.
* `void _startPerRunTimers()` — `_startTime`/`_isPaused`/`_resetEtaState`/the 1 s progress timer/`_startCheckpointTimer`/`_startDiskSpaceWatchdog`.

Then `_resumeFromCheckpointInner` calls both, plus `attachHostListenersForNativeRun()` (which already is the canonical "install the native subscription" method — see §2.4). Net: ~90 lines deleted, and the resume path can no longer drift from the start path.

**Regression guard for the implementer:** `packages/skotiq_core/test/providers/sequence/sequence_executor_run_lifecycle_test.dart` and `.../sequence_executor_lifecycle_test.dart` pin the ordering; run them before and after.

---

### 2.2 Launch-settings push to native is written twice — **effort: small**

`_startNativeExecution` (`runtime_config_operations.dart:10-116`) and `_resumeFromCheckpointInner` (`sequence_executor.dart:2022-2081`) both push the same launch-authoritative config in the same order, with deliberately different edge behaviour that is documented on the resume side only:

| Push | start | resume | intentional difference |
|---|---|---|---|
| `setLocation` guarded by `lat != 0 \|\| lon != 0` | 20-38 | 2026-2034 | none |
| `sequencerSetSimulationMode(effectiveSimulationMode(...))` | 40-42 | 2035-2037 | none |
| `_pushEffectiveSafetyFailMode` | 44 | 2042 | none (this was already unified once — see the doc at `runtime_config_operations.dart:188-192`) |
| `sequencerSetSavePath` | 46-56 | 2046-2049 | **yes**: start pushes `null` when empty, resume skips (must not clobber the snapshot path) |
| 5× device-id resolution + `sequencerSetDevices` | 58-91 | 2055-2079 | **yes**: resume only pushes when the camera is connected |
| `seedDefectMapRuntimeForSequence(_ref)` | 116 | 2080 | none |
| `_seedRuntimeConfigFromSettings(backend)` | 136 | 2081 | none |

**Canonical survivor:** a new `Future<void> _pushLaunchConfig(SkotiqBackend backend, AppSettingsState settings, {required bool isResume})` in `runtime_config_operations.dart`, with the two real differences expressed as `if (!isResume)` / `if (!isResume || cameraConnected)` and the existing comments carried over verbatim. Both callers then have one line. ~55 lines deleted, and the class of bug the resume path already suffered ("resume pushed the raw configured safety mode and aborted instantly") becomes structurally impossible.

---

### 2.3 Observer-profile derivation is written twice, verbatim — **effort: small** ⭐ cheapest real win

`runtime_config_operations.dart:490-545` (inside `_seedRuntimeConfigFromSettings`) and `runtime_config_operations.dart:978-1029` (inside `_pushObserverProfile`) are the **same 55 lines**: camera-name split on first space, focal-length `telescopeFocalLength ?? focalLength` fallback, aperture `telescopeAperture ?? aperture` fallback (with the *same* 8-line explanatory comment duplicated at 518-523 and 1002-1007), and the same `sequencerUpdateObserverProfile(...)` call with the same seven arguments and the same null-guards.

The aperture-fallback comment records that this exact bug (missing `APTDIA` in FITS) had to be fixed once. It was fixed in two places. The next such fix will be applied to one.

**Canonical survivor:** `_pushObserverProfile(backend)`. Have `_seedRuntimeConfigFromSettings`'s observer block become `try { await _pushObserverProfile(backend); } catch (e, st) { firstError ??= e; … }` — which requires making `_pushObserverProfile` `Future<void>` and `await`ing the backend call inside it (**which also fixes the unawaited-future defect in §5.2** — do these together).

---

### 2.4 Three copies of "subscribe to the native event stream" — **effort: small**

Identical 5-line block at:

* `runtime_config_operations.dart:161-165` (inside `_startNativeExecution`)
* `sequence_executor.dart:2194-2199` (inside `_resumeFromCheckpointInner`)
* `sequence_executor.dart:2248-2253` (`attachHostListenersForNativeRun`)

Two of the three do `await _nativeEventSubscription?.cancel()` first; `_startNativeExecution` does **not** — it overwrites the field, so if `_startNativeExecution` is ever reached with a live subscription (a stopFailed/cleanupFailed run that deliberately retains its subscription, then a later admissible start) the old one leaks and every event is handled twice.

**Canonical survivor:** `attachHostListenersForNativeRun()` — it already carries the doc explaining why the subscription exists and is already the headless entry point (`apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart:789`). Have both other sites call it. This also fixes the missing-cancel asymmetry for free.

---

### 2.5 Two independent writers interpret the same native events into the same providers — **effort: large**

`SequenceExecutor._handleSequencerEvent` (`event_operations.dart:4-451`) and `applySequencerEventToSequenceProviders` (`sequence_progress.dart:264-446`) both decode the *same* `SkotiqEvent` stream into the *same* `sequenceProgressProvider` / `sequenceExecutionStateProvider`. On a desktop host with a Dart-owned run, **both are live simultaneously** (DeviceService subscribes at app start; the executor subscribes at run start).

The codebase already carries three separate defences against their divergence, each added after a real bug:

* `_localExecutorOwnsRun` (`sequence_progress.dart:216`) — a runtime ownership check gating six lifecycle cases;
* `recordCompletedFrameIntegration(eventKey:)` (`sequence_progress.dart:178-187`) — an event-identity de-dup added because both writers did a read-modify-write and every frame's integration time was counted twice (comment at 161-172 cites the live-rig measurement: 9.0 s reported as 18.0 s);
* absolute-frame-index assignment in both writers (`event_operations.dart:151`, `sequence_progress.dart:407-410`) so the frame *count* is idempotent.

They still disagree today: `NodeCompleted` maps `null` status to `NodeStatus.failure` in the executor (`event_operations.dart:50-56`) but to "leave alone" in the pump (`sequence_progress.dart:235-249`); `ExposureStarted`/`ExposureCompleted` drive `cameraStateProvider.setExposing` only in the pump.

**Canonical survivor:** the *decoding* should be one pure function. Recommended shape: extract a `SequencerEventDecoder` (a pure `SkotiqEvent -> SequenceProgressDelta` mapper, no provider reads) used by both, leaving the executor with only the side-effects a Dart-owned run adds (frame registration, run stats, live stacking, finalization) and the pump with only the writes it makes when no executor owns the run. This is the largest single item in this report and should be scheduled as its own work order, not folded into a split.

---

### 2.6 `_resolveLiveStackExposureSecs` recomputes what `_registerSequenceFrame` already computed — **effort: small**

On a `FrameAccepted` event the switch calls `_registerSequenceFrame` (which builds a `FrameAttribution` at `event_operations.dart:706-712`) and then `_maybeFeedLiveStacking` → `_resolveLiveStackExposureSecs` (`event_operations.dart:1273-1287`), which calls `resolveFrameAttribution` **again on the same node and sequence**, purely to read `exposureSecs`. Resolve once in the `FrameAccepted` case and pass the value down.

---

### 2.7 `_surfaceFilterLookupWarning` is a pure alias — **effort: trivial**

`serialization_operations.dart:252-253` is `void _surfaceFilterLookupWarning(String m) => _surfaceRunWarning(m);` with three call sites (220, 229, 241) all inside `_lookupFilterIndex`. Inline it and delete the wrapper.

---

## 3. DEAD CODE

### 3.1 `SequenceExecutor.validateSequence` — no callers, and its own doc comment is false

`packages/skotiq_core/lib/src/providers/sequence/sequence_executor.dart:494-499`

```dart
/// Backwards-compatible structural-only validator. Kept because external
/// callers (UI badges, tests) still depend on the sync semantics. …
List<validation.ValidationIssue> validateSequence(Sequence sequence) =>
    validation.validateSequence(sequence);
```

**Evidence:** `grep -rn "\.validateSequence(" --include="*.dart" packages apps server` returns exactly one hit — line 499, the delegation inside the method itself. Every real consumer calls the *top-level* `validateSequence` from `sequence_validation.dart:475` directly: `sequence_file_service.dart:56`, `conversational_builder_service.dart:322`, `sequence_importer.dart:78`, and the tests at `sequence_validation_rules_test.dart:727`. The stated reason for keeping it ("external callers… still depend on") is not true of any caller in the repo.

**Caveat for the verifier:** `SequenceExecutor` is exported from the `skotiq_core` barrel, so this is technically public API of an internal monorepo package. There is no plugin/reflection path to it (no `dart:mirrors`, no registry lookup by name in this repo).

### 3.2 `SequenceRunStats.recordDither()` — zero callers, and `ditherCount` is rendered in four places

`packages/skotiq_core/lib/src/providers/sequence_stats_provider.dart:163` (the *symbol* is just outside these paths; the *missing caller* is inside them).

**Evidence:** `grep -rn "recordDither" --include="*.dart" packages apps server` returns only the definition. Meanwhile `ditherCount` is read and displayed by `cockpit_session_vitals.dart:162`, `post_session_stats_dialog.dart:177`, `session_report_dialog/target_conditions.dart:25`, and is serialized into `sequence_runs.stats_json` (documented at `database/tables/sequence_runs.dart:49`) and `models/session_report.dart:211`.

So the Session Report's "Dithers" figure is a **hard zero for every run**. This is the identical shape as the `recordAutofocus()` bug the code itself documents at `event_operations.dart:59-77` ("had ZERO production call sites… the run still persisted `autofocusRuns:0`") — which was fixed for autofocus and not for dither.

The wiring exists to fix it: the native side emits `GuidingEvent::DitherCompleted` (`native/skotiq_native/bridge/src/event.rs:389`) and a `Dither` node produces a `NodeCompleted` with `node_type == "Dither"` (`native/skotiq_native/sequencer/src/node/registry.rs:188`). `_handleSequencerEvent` handles neither.

### 3.3 Four orphan doc comments

Listed in §0. `checkpoint_watchdog_operations.dart:115-119`, `event_operations.dart:1428-1435`, `runtime_config_operations.dart:1105`, `serialization_operations.dart:1074-1089`. Each documents a method that lives in a different file.

**Not dead (checked and cleared):** every `@visibleForTesting` hook (`sequenceToJsonForTest`, `captureSessionStartHooksForTest`, `captureSessionEndHooksForTest`, `handleSequencerEventForTest`, `startSessionRowForTest`, `seedIntegrationCarryOverFromHandoffForTest`, `liveStackingFeedSettledForTest`, `terminalCleanupSettledForTest`, `isListeningToNativeEventsForTest`) has live test callers; `attachHostListenersForNativeRun` is called from the headless route (`sequencer_handlers.dart:789`); `skipToTarget` from `playback_footer.dart:49`; `skipToNode` from `sequence_tree_context_menu.dart:383`; `initializeCheckpoints` from both `headless_services_bootstrap.dart:104` and `mobile_reconnect_ops.dart:569`; `buildGlobalMeridianFlipConfigJson` from `runtime_config_operations.dart:314`. `RecoveryActionType.retry` in `_recoveryActionToString` is unreachable-by-design and correctly documented as an exhaustiveness arm.

---

## 4. PERF RISKS

### 4.1 Every sequenced frame triggers **two** full last-image fetches over the bridge — impact: **high**

`event_operations.dart:13-23` and `event_operations.dart:174`.

`_handleSequencerEvent` calls `_fetchAndDisplaySequenceImage` twice per frame, from two different events that native emits for the *same* exposure:

* the **imaging** `ExposureComplete` (line 21) — `if (event.category == EventCategory.imaging && event.eventType == 'ExposureComplete')`
* the **sequencer** `ExposureCompleted` (line 174), inside the `'ExposureCompleted'` case

Both are emitted for a sequenced exposure. Traced end to end:
`expose.rs:221 execute_exposure_with_renderer` → `instructions.rs:2249+` → `ctx.device_ops.camera_start_exposure_with_frame_type` → `unified_device_ops.rs:537` → `unified_device_ops.rs:547 camera_start_exposure_configured` → **`unified_device_ops.rs:930-933` publishes `ImagingEvent::ExposureComplete { success: true }`**. `UnifiedDeviceOps` is the sequencer's `DeviceOps` impl (`unified_device_ops.rs:273 impl DeviceOps for UnifiedDeviceOps`). The sequencer separately synthesises `SequencerEvent::ExposureCompleted` from its per-frame progress callback (`expose.rs:233-235`). Dart maps them to distinct `(category, eventType)` pairs at `ffi_backend/event_mapping.dart:881-883` and `:481-483`.

`_fetchAndDisplaySequenceImage` (`session_diagnostics_operations.dart:446-493`) does a full `backend.cameraGetLastImage(cameraDeviceId)` and republishes the preview. Doing it twice per frame doubles the bridge transfer and the preview decode/publish for every light of the night.

**Second-order correctness problem in the same code:** the imaging `ExposureComplete` payload is `{'success': bool}` only (`event_mapping.dart:883`), so `event.data['duration_secs']` is always absent and line 20 falls through to the literal **`?? 2.0`**. `_fetchAndDisplaySequenceImage` then stamps `ExposureSettings(exposureTime: 2.0, gain: 0, offset: 0, binningX: 1, binningY: 1, frameType: FrameType.light)` (`session_diagnostics_operations.dart:471-479`) onto the published preview. Whichever of the two fetches lands last wins, so the Imaging tab can show a 300 s sub labelled "2 s, gain 0, bin 1".

**Recommendation:** drop the imaging-`ExposureComplete` branch entirely for sequencer-owned runs (the sequencer `ExposureCompleted` carries the real duration), or gate it on "no run is owned". Either way stop fabricating gain/offset/binning — use the `FrameCapture.fromEventData` values the `FrameAccepted` path already reads (`event_operations.dart:647`).

### 4.2 `enclosingTargetHeader` rebuilds the whole parent map 3–4× per accepted frame — impact: **low-medium**

`sequence_executor/frame_attribution.dart:152-158` builds a fresh `Map<String,String> parentByChild` over **every node and every childId in the sequence** on each call. Per accepted frame it is called from:

1. `_recordRunFrame` → `_resolveActiveTargetName` → `enclosingTargetHeader` (`event_operations.dart:963`)
2. `_registerSequenceFrame` → `resolveFrameAttribution` → `enclosingTargetHeader` (`frame_attribution.dart:129`, entered at `event_operations.dart:708`)
3. `_registerSequenceFrame` → `_runTargetIdFor` → `enclosingTargetHeader` (`sequence_executor.dart:732`)
4. (when live stacking is enabled) `_resolveLiveStackExposureSecs` → `resolveFrameAttribution` → `enclosingTargetHeader` (`event_operations.dart:1277`)

Honest sizing: for a typical 50-200 node sequence this is microseconds and does not matter. It becomes visible only for large generated mosaics (thousands of nodes), and it runs on the UI isolate inside the event handler. Cheap fix: memoise the parent map per `Sequence` identity, or resolve the header once per frame and thread it through (see §2.6, which removes call 4 anyway).

### 4.3 Per-event map copies in the progress notifier — impact: **low**

`sequence_progress.dart:94-134`: `updateNodeProgress` copies **two** maps and `updateNodeStructuredProgress` copies two maps on every call. Both are invoked from the `InstructionProgress` / `InstructionProgressStructured` cases (`event_operations.dart:293`, `:322`), which the native autofocus/centring instructions emit at high rate during a sweep. O(touched-nodes) allocation per progress tick. Only worth addressing if a profile shows it; noted for completeness.

**Not claimed:** I did not find evidence of a provider rebuild storm, a non-builder long list, sync IO on the UI isolate, or an unbounded cache inside these paths. `_frameDurations` is explicitly bounded to `kEtaWindowSize` (`serialization_operations.dart:285-288`); `_pendingStatWrites` and `_inFlightFrameRegistrations` are drained. Who watches `sequenceProgressProvider` high in the widget tree is a `skotiq_app` question — flagged as a cross-package suspect below.

---

## 5. RELIABILITY RISKS

### 5.1 Nine fire-and-forget backend calls in the mid-run settings watchers — no `await`, no `catchError`

`runtime_config_operations.dart:785, 811, 826, 849, 866, 915, 927, 947` (inside the three `_ref.listen` callbacks in `_startSettingsWatchers`) and `:1017` (inside `_pushObserverProfile`).

Every one of these is an `async` backend call invoked from a **synchronous** callback with the result discarded:

```dart
backend.sequencerUpdateDitherConfig(...);            // :785
backend.sequencerUpdateLocation(...);                // :811
_pushEffectiveSafetyFailMode(backend, ...);          // :826  (async fn, not awaited)
backend.sequencerUpdateDefaultQualityCheck(...);     // :849
backend.sequencerUpdateRejectFolderPath(...);        // :866
backend.sequencerUpdateDefaultAdaptiveExposure(...); // :915
backend.sequencerClearDefaultAdaptiveExposure();     // :927
backend.sequencerUpdateFilterOffsets(...);           // :947
backend.sequencerUpdateObserverProfile(...);         // :1017
```

Two consequences. (a) A rejected future has no handler and surfaces as an **unhandled async error** in the zone. (b) The operator is told nothing: they change dither settings mid-run, the push fails, and the run keeps dithering on the old config with no log line. Note `:1017` sits inside a `try { … } catch (e) { _logger.error('Failed to propagate observer_profile mid-run…') }` (`:974`, `:1030-1035`) — that catch **cannot fire**, because the call is not awaited. The handler is decorative.

Contrast with the seed path, which awaits every equivalent call and aggregates `firstError` (`:223-224, 269-276, …, 623-628`). Fix: make each watcher body `async` (or wrap in `unawaited(x.catchError(...))`) and log the failure the same way the seed does.

### 5.2 The 10-second sky-brightness poll can throw out of its own guard

`runtime_config_operations.dart:1086`, inside the `try` at `:1073`.

```dart
backend.sequencerUpdateSkyBrightness(mag: mag);   // async, not awaited
```

The surrounding `try/catch` (`:1073`, `:1093-1101`) is synchronous, so a rejected future escapes it — every 10 seconds, for the whole run, against a backend that may have gone away. The comment at `:1057-1062` documents a *previous* incarnation of exactly this failure ("the error handler ITSELF threw… surfacing as an unhandled async error every 10 seconds. A catch that can throw is not a guard"), fixed by hoisting the logger read; the un-awaited push was left behind.

### 5.3 A failing incremental `updateStats` becomes an unhandled async error

`event_operations.dart:1135-1139`:

```dart
final Future<void> write = _ref.read(sequenceRunsDaoProvider).updateStats(runId, stats.toJson());
_pendingStatWrites.add(write);
unawaited(write.whenComplete(() => _pendingStatWrites.remove(write)));
```

`whenComplete` forwards the error to its derived future, and `unawaited` attaches no handler, so a DB write failure mid-run is an unhandled zone error. `_drainPendingStatWrites` (`:1187-1194`) does apply `catchError`, but only to writes still pending when finalization drains — a write that fails earlier is unprotected. Fix: `unawaited(write.catchError((Object e) { … }).whenComplete(…))`, or drop the error at the `whenComplete` site.

### 5.4 Rejected frames are recorded as accepted in the run stats — the "Rejected" figure is structurally always 0

`event_operations.dart:129-138` (`case 'ExposureCompleted'`):

```dart
_recordRunFrame(exposureSecs: durationSecs, filter: event.data['filter'] as String?, accepted: true);
```

That is the **only** call site of `_recordRunFrame` (`grep -rn "_recordRunFrame"` → definition at `:972` and this one call), and it is the **only** production caller of `SequenceRunStats.recordFrame` (`grep -rn "recordFrame"` across `packages apps server`, excluding tests → `sequence_stats_provider.dart:140` definition and `event_operations.dart:981`). `accepted` is hardcoded `true`. The `FrameRejected` case (`event_operations.dart:407-417`) calls only `_registerSequenceFrame` and never touches run stats.

`recordFrame` is the sole writer of `framesRejected` and `FilterStats.rejected` (`sequence_stats_provider.dart:146-157`). Those fields are rendered as a "Rejected" figure by at least five surfaces reading `liveSequenceStatsProvider` / `stats_json`: `cockpit_session_vitals.dart:143` (`ref.watch(liveSequenceStatsProvider)` at `:25`), `cockpit_morning_report.dart:66,117`, `standby/last_night_recap_card.dart:113-117`, `post_session_stats_dialog.dart:146-154`, `session_report_dialog/target_conditions.dart:211`, and `sequencer_screen.dart:308`.

So on a night where the grader rejected frames — and wrote `captured_images` rows with `runtime_grade='reject'` to prove it — the Session Report says "0 rejected". Same defect family as the `recordAutofocus` bug documented in this very file at `:59-77`. Recommended fix: record the frame from `FrameAccepted`/`FrameRejected` (which know the verdict and carry the exposure metadata) rather than from `ExposureCompleted`, or add a `_recordRunFrame(accepted: false)` on `FrameRejected` and drop the `ExposureCompleted` call.

### 5.5 `_isPaused` is only maintained by the Dart `pause()`/`resume()` API

`sequence_executor.dart:235, 820, 1528, 1565, 2168` and the timer guards at `:828` and `:2177`; `checkpoint_watchdog_operations.dart:102`.

`_isPaused = true` appears at exactly one place: inside `SequenceExecutor.pause()` (`:1528`). The `Paused` native event handler (`event_operations.dart:355-359`) updates both providers but does not touch `_isPaused`. So a pause that does not originate from `SequenceExecutor.pause()` leaves the flag false and the 1-second progress timer keeps advancing `elapsedSecs` and recomputing the ETA for the whole pause.

That path is real, not hypothetical: the headless route calls the backend directly — `apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart:374` is `await backend.sequencerPause();`, not `executor.pause()`. A run started in the GUI and paused from the web dashboard or the phone on the same host lands exactly here.

### 5.6 `dispose()` releases a *subset* of what `_releaseRunResources` releases

`sequence_executor.dart:2270-2287` cancels `_progressTimer`, `_checkpointTimer`, `_nativeEventSubscription`, `_skyBrightnessPollTimer` and calls `_stopDiskSpaceWatchdog()` — but not `_stopSettingsWatchers()`, and it does not reset `_lastPushedSkyMag`. `_releaseRunResources` (`:1390-1430`) does the settings watchers plus live-stacking teardown. Riverpod closes `ref.listen` subscriptions when the owning provider is disposed, so I am **not** claiming a leak — but the two teardown paths having different member lists is exactly how the `_skyBrightnessPollTimer` leak this file's own comment describes (`:2278-2285`) happened. Make `dispose()` call `_releaseRunResources` (with a no-op `secondary`) rather than maintaining a second list.

### 5.7 `_startNativeExecution` overwrites a possibly-live event subscription

Covered in §2.4. `runtime_config_operations.dart:161` assigns `_nativeEventSubscription` without cancelling the previous one, unlike the other two subscribe sites. A start admitted after a run that ended in `stopFailed`/`cleanupFailed` (which deliberately retains its subscription — `sequence_executor.dart:1282-1293`) would double-handle every event.

---

## 6. SUSPECTED CROSS-PACKAGE DUPLICATION (for the cross-cutting agent)

* `_nodeToConfig` (`serialization_operations.dart:339-791`) is a Dart→Rust wire codec that must mirror `native/skotiq_native/sequencer/src/node/registry.rs` and the per-instruction serde structs; a parallel node→wire mapper may exist in `packages/skotiq_core/lib/src/services/sequence_file_service.dart` (`sequenceToMap` / `parseFromMap`, used at `sequence_executor.dart:775` and `:1978`).
* The enum→PascalCase string tables (`_binningToString`, `_twilightToString`, `_loopConditionToString`, `_conditionalTypeToString`, `_recoveryActionToString`, `_meridianTriggerMethodToString`, `_flipFailureActionToString`, `serialization_operations.dart:889-1072`) smell like they also exist on the model side (`models/sequence/sequence_models.dart` `storageKey` / `wireValue` accessors are already used for some enums at `:536`, `:779-780`).
* `applySequencerEventToSequenceProviders` (`sequence_progress.dart:264`) vs `SequenceExecutor._handleSequencerEvent` — see §2.5; the third decoder of the same stream may be in `apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart` and/or the run-watch snapshot builder.
* `_pushObserverProfile`'s camera-make/model split and focal-length/aperture fallbacks probably duplicate FITS-header assembly logic in `skotiq_core/lib/src/services/` and/or `native/skotiq_native/imaging/src/fits.rs`.
* `_lookupFilterIndex` (`serialization_operations.dart:216-247`) resolves a filter name→wheel index from the active profile; the same resolution almost certainly exists in the filter-wheel provider and in `DeviceService`.
* `_effectiveSafetyFailMode` (`runtime_config_operations.dart:193-198`) pairs with a Dart-side weather verdict in `weather_safety_provider`; confirm there is exactly one definition of "weather safety is off ⇒ fail open".
* `enclosingTargetHeader` (`frame_attribution.dart:152`) deliberately re-derives parent links by inverting `childIds` because `Sequence.parentOf` is unreliable for generated sequences — `Sequence.parentOf` itself is used at `sequence_executor.dart:1798`. Two different notions of "parent" in one subsystem is worth a cross-package look at `sequence_models.dart`.
* Who watches `sequenceProgressProvider` (updated ~1 Hz plus per-event) high in the `skotiq_app` widget tree — outside these paths, but this subsystem is the producer.

---

## 7. Suggested order of work

1. §5.4 rejected-frame stats (user-visible falsehood, ~10 lines)
2. §5.1 + §5.2 + §5.3 unawaited backend/DB futures (~30 lines, removes a class of unhandled async errors)
3. §4.1 double image fetch + fabricated preview metadata
4. §2.3 observer-profile duplication (do together with §5.1 — the fix is the same edit)
5. §2.4 single subscribe site (also fixes §5.7)
6. §2.1 + §2.2 start/resume acquisition + launch-config duplication
7. §1.1–§1.4 the four file splits (after 6, so ~150 lines are not moved twice)
8. §3.1 + §3.2 + §3.3 dead code and orphan docs
9. §2.5 the two-decoder problem — its own work order
