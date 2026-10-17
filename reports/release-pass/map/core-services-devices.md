# Map — skotiq_core device / imaging services

Subsystem: `packages/skotiq_core/lib/src/services/` — `device_service*`, `imaging_service*`,
`centering_service.dart`, `plate_solve_service.dart`, `flat_wizard_service.dart`,
`predictive_af_service.dart`, guiding-adjacent services (`phd2_*.dart`,
`device_service/guiding_sequencer_controls.dart`).

Read-only mapping pass. No source file was modified.

Method: one orienting `graphify query` / `graphify explain ImagingService`, then full reads of
every file over 500 lines in the subsystem plus targeted greps across `packages/` + `apps/` +
`native/` to settle caller questions. Every claim below cites file:line. Where a claim is a
hypothesis rather than a proof, it says so.

---

## 1. Oversized files

Verified with `wc -l`. Nothing in these paths is generated (no `.g.dart` / `.freezed.dart` /
`frb_generated` in the subsystem). All six are hand-written.

| File | Lines |
|---|---|
| `services/imaging_service.dart` | 1581 |
| `services/device_service/connections.dart` | 1481 |
| `services/flat_wizard_service.dart` | 1414 |
| `services/predictive_af_service.dart` | 1396 |
| `services/plate_solve_service.dart` | 1389 |
| `services/centering_service.dart` | 1310 |

Just under the bar, listed for context because the split plans below move work into them:
`device_service/event_handling.dart` 967, `device_service.dart` 611, `switch_channel_service.dart`
672, `device_service/autofocus_controls.dart` 703, `device_service/focuser_rotator_controls.dart`
702, `device_service/control_helpers.dart` 566, `device_reconnect_coordinator.dart` 813,
`focus_model_service.dart` 906.

---

### 1.1 `services/imaging_service.dart` — 1581 lines

**Why it is big.** It is four things in one library: (a) the capture state machine, (b) the
filename/naming-pattern engine, (c) three Riverpod providers plus `ExposureProgressNotifier`, and
(d) a free function. The library already has three `part` files
(`imaging_service/file_paths.dart` 159, `imaging_service/persistence.dart` 287,
`imaging_service/quality_processing.dart` 28) but the main file kept the largest pieces.

The single dominant problem is `ImagingService._capture` at **lines 154–917 — one 763-line
method** with 5 levels of nesting, its own inner `try/finally`, and 14 separate
`if (!_hasBackendAuthority(backend)) return null;` bail-outs.

**Split plan** (all pieces stay in the same library via `part`, so privates and
`_hasBackendAuthority` keep working — this is what makes the move behaviour-preserving):

*New file `services/imaging_service/naming.dart`* (`part of '../imaging_service.dart';`)
- Move verbatim from `imaging_service.dart`: `_patternVariables` (1198–1217),
  `_buildPatternSubstitutions` (1224–1269), `_patternVarRegex` (1280),
  `_unsafePathComponentChars` (1282–1284), `_sanitizePathComponent` (1290–1298),
  `expandNamingPattern` (1311–1352), `buildImageFilePath` (1362–1423),
  `buildTimestampSubstitutions` (1431–1473).
- The three `static` + `@visibleForTesting` members must stay **static members of
  `ImagingService`**, not top-level functions — `imaging_service_test.dart` and
  `native/skotiq_native/imaging/src/naming.rs` parity tests call them as
  `ImagingService.expandNamingPattern(...)`. So this file declares
  `extension _ImagingServiceNaming on ImagingService` for the instance method
  `_buildPatternSubstitutions`, and the statics move into a new
  `abstract final class ImagingNaming { ... }` **only if** the call sites are updated;
  the zero-risk version is to leave the three statics on `ImagingService` and move only
  `_buildPatternSubstitutions` + the two `RegExp`s + `_sanitizePathComponent`. Prefer the
  zero-risk version. (~180 lines out.)

*New file `services/imaging_service/providers.dart`* (plain `.dart`, not a `part`)
- Move: `imagingServiceProvider` (1477–1484), `currentImageProvider` (1487),
  `currentImageIsCalibratedProvider` (1500–1511), `previewDisplayHistogramProvider`
  (1515–1524), `histogram256FromRawU16` (1527–1533), `exposureProgressProvider` (1536–1539),
  `ExposureProgressNotifier` (1542–1581).
- Re-export from `imaging_service.dart` so `package:skotiq_core` barrel consumers
  (`live_preview_area.dart:132`, `preview_overlays.dart:21`, mobile `camera_tab.dart:566`) are
  untouched. (~105 lines out.)

*New file `services/imaging_service/capture_pipeline.dart`* (`part of`)
- Move `_capture` (154–917) here and decompose it, in this order, keeping each extracted step
  returning early exactly as today:
  1. `_admitCapture({settings, persistFrame})` → the guards at 162–214 (busy check, connected
     check, `_withLiveFilter`, frame-number resolution, notifier lookup).
  2. `_applyReadoutMode(backend, deviceId, settings)` → 232–258.
  3. `_runExposure(...)` → 260–419: arm shared state, subscribe, start, race the completer,
     handle timeout/abort. Returns a small `_ExposureOutcome` record
     `({bool ok, bool timedOut, DateTime startedAt})`.
  4. `_downloadAndPublish(...)` → 421–549: `cameraGetLastImage`, timestamp parse,
     `observationStartedAt` derivation, staleness check, `capturedImageDataFromResult`,
     preview publish.
  5. `_persistFrame(...)` → 551–747: path selection (keeper vs scratch vs temp), `_saveFitsFile`,
     `_saveToDatabase`, `stampProducingNode`, error notifications.
  6. `_postProcessFrame(...)` → 749–863: auto-calibration, science processing, session image.
- `_capture` becomes a ~60-line orchestrator. Nothing else changes.

*Keep in `imaging_service.dart`*: the class declaration + fields (46–95), `captureImage` (104–125),
`captureUtilityFrame` (136–145), `startLoopCapture` (1017–1091), `cancelExposure` (1094–1118),
`_releaseSharedExposureState` (1125–1140), `retire` (1145–1162), `_hasBackendAuthority` (1164),
`_abortActiveExposure` (1167–1180), `_withLiveFilter` (940–955), `_resolveReadoutModeIndex`
(971–991), `_readoutModeCount` (1000–1008), `_scratchKey` (937). Result: ~450 lines.

*Also fold in*: `imaging_service/quality_processing.dart` is a 28-line `part` holding one
delegating method (`_calculateQualityScore`, 12–27) that forwards to `computeFrameQualityScore`.
Move that method into `persistence.dart` next to its only caller (`persistence.dart:165`) and
delete the part file and its `part` directive (`imaging_service.dart:43`).

---

### 1.2 `services/device_service/connections.dart` — 1481 lines

**Why it is big.** It holds the connect/disconnect pair for **all eleven** device types
(camera 5–123 / 217–287, mount 290–384, focuser 387–496, filter wheel 499–645, guider 648–753,
dome 756–820, weather 823–899, safety monitor 902–970, switch 1160–1235, rotator 1245–1317,
cover calibrator 1320–1371), **plus** the environmental/dome polling loop (972–1151), **plus**
the slot-handover machinery (1373–1480). Roughly 60% of the body is the same 5-step shape
repeated eleven times: validate id → resolve name → release displaced → `setConnecting` →
`connectDevice` → `setConnected`/`setDisconnected`.

**Split plan** (all new files are `part of '../device_service.dart';`, added to the `part` list at
`device_service.dart:41–49`; no visibility changes, no call-site changes):

- `device_service/connections/imaging_chain.dart` — `_connectCamera`/`_disconnectCamera`
  (5–123, 217–287), `_queryRecommendedCameraSettings` (130–134),
  `_applyRecommendedCameraSettings` (141–159), `_setCameraCooling` (162–202),
  `_warmCamera`/`_cancelWarmCamera` (209–214), `_connectMount`/`_disconnectMount` (290–384),
  `_connectFocuser`/`_disconnectFocuser` (387–496),
  `_connectFilterWheel`/`_disconnectFilterWheel` (499–645). ≈ 560 lines.
- `device_service/connections/guider_and_rotator.dart` — `_connectGuider`/`_disconnectGuider`
  (648–753), `_connectRotator`/`_disconnectRotator` (1245–1317),
  `_connectCoverCalibrator`/`_disconnectCoverCalibrator` (1320–1371). ≈ 250 lines.
- `device_service/connections/environment.dart` — `_connectDome`/`_disconnectDome` (756–820),
  `_connectWeather`/`_disconnectWeather` (823–899),
  `_connectSafetyMonitor`/`_disconnectSafetyMonitor` (902–970),
  `_ensureEnvironmentPolling` (972–985), `_stopEnvironmentPollingIfIdle` (987–1001),
  `_shouldPollEnvironmentSource` (1008–1010), `_pollEnvironmentalStatus` (1012–1092),
  `_readDomeStatusInto` (1098–1115), `_refreshDomeStatus` (1121–1131),
  `_shutterStatusFromCode` (1136–1151). ≈ 390 lines.
- `device_service/connections/switch_device.dart` — `_connectSwitch`/`_disconnectSwitch`
  (1160–1220) and the four `_refreshSwitchChannels`/`_setSwitchChannel*` forwarders (1226–1242).
  ≈ 85 lines.
- `device_service/device_slots.dart` — `_releaseDisplacedDevice` (1392–1421),
  `_slotDeviceIdFor` (1426–1451), `_disconnectForType` (1455–1479), **and** the byte-identical
  `_trackedDeviceIdFor` from `event_handling.dart:571–596` (see §2.1) collapsed into one. ≈ 110 lines.

Nothing stays in `connections.dart`; delete the file and replace its `part` directive with the
five new ones.

---

### 1.3 `services/flat_wizard_service.dart` — 1414 lines

**Why it is big.** ~160 lines of models before the class even starts, then the class carries five
unrelated responsibilities: capability resolution, the low-level exposure driver, two calibration
solvers, sequence generation, and the exposure math.

**Split plan** (`FlatWizardService` has **no** privates that cross responsibilities except
`_lastTestFrameOutcome` (711) and `_classifyExposureEvent` (446), so `part of` files are the safe
mechanism here too):

- `services/flat_wizard/flat_wizard_models.dart` (plain library, re-exported from
  `flat_wizard_service.dart`) — `FlatResult` (18–79), `FlatCancelToken` (89–108),
  `FlatFrameOutcome` (111–124), `FlatFrameCapture` (128–154), `_binningFromInts` (1395–1401)
  → promote to `binningFromInts` (only caller is `generateFlatSequence`, line 1273).
  ≈ 165 lines out. `_ExposureEventKind` (157) and `_CaptureWake` (162–174) go with the frame-capture
  part below, not here.
- `services/flat_wizard_service/frame_capture.dart` (`part of`) — `_ExposureEventKind` (157),
  `_CaptureWake` (162–174), `_terminalExposureEventTypes` (422–427), `_deviceIdKeys` (434–439),
  `_classifyExposureEvent` (446–479), `exposeAndAwait` (506–701), `captureTestFrame` (722–752).
  ≈ 260 lines out. (`_lastTestFrameOutcome` stays a field on the class — see §5.4 for why it
  should stop being a field at all.)
- `services/flat_wizard_service/calibration.dart` (`part of`) — `calculateNextExposure` (386–417),
  `calibrateFilter` (763–959), `calibrateFilterWithRateTracking` (964–1162),
  `calibrateMultipleFilters` (1167–1235), `quickCalibrate` (1358–1384). ≈ 470 lines out.
- `services/flat_wizard_service/sequence_generation.dart` (`part of`) —
  `generateFlatSequence` (1241–1290), `generateCompleteSequence` (1296–1353). ≈ 115 lines out.
- `services/flat_wizard_service/capture_config.dart` (`part of`) —
  `resolveCaptureConfig` (229–368), `_clampToRange` (372–378). Both are `static`; a `part` file
  can hold statics inside an `extension`… it cannot. **Constraint:** Dart extensions cannot
  declare static members that are callable as `FlatWizardService.resolveCaptureConfig`. Because
  `flat_wizard_provider.dart:141` and `flat_capture_config_resolution_test.dart:91` call it as
  `FlatWizardService.resolveCaptureConfig(...)`, this pair must **stay on the class body** in
  `flat_wizard_service.dart`. Do not move it. (Recorded here so an implementer does not
  rediscover it the hard way.)

Result: `flat_wizard_service.dart` keeps the class declaration, constructor + `fromSettings`
(191–214), `resolveCaptureConfig` + `_clampToRange` (229–378), the settings fields (1386–1391),
and the provider (1408–1414) — ≈ 400 lines.

---

### 1.4 `services/predictive_af_service.dart` — 1396 lines

**Why it is big.** It is a models file, a hand-rolled persistence layer, a statistics library, a
service, a remote-authority facade and a UI status model, in one file. Models occupy
**lines 38–398** (360 lines) before the service starts at 411, and a second block of
models/controller occupies **1213–1396**.

**Split plan** (all plain libraries, re-exported from `predictive_af_service.dart` so the
`skotiq_core` barrel and `apps/desktop/lib/headless_api/handlers/focus_model_handlers.dart`
are untouched):

- `services/predictive_af/predictive_af_models.dart` — `FocusTrainingSample` (38–66),
  `PredictiveAfConfig` (72–181), `FilterFocusModel` (184–290), the `PredictiveAfDecision`
  sealed hierarchy (295–351), the `DriftStatus` sealed hierarchy (356–398),
  `PredictiveAfStatus` (1352–1391). ≈ 470 lines out.
- `services/predictive_af/focus_model_regression.dart` — `_fitRegression` (1139–1196) promoted to
  a top-level pure `FocusModelRegression.fit(List<FocusTrainingSample>)`, and `_RegressionFit`
  (1213–1227). It reads nothing off `this`; making it pure lets the Rust-parity test target it
  directly instead of through a database. ≈ 90 lines out.
- `services/predictive_af/focus_model_store.dart` — every raw-SQL member:
  the two `focus_models` writes in `recordAutofocusOutcome` (650–706), `_touchLastUsed`
  (1058–1072), `_loadByKey` (1074–1092), `_rowToMap` (1094–1102), `_rawToModel` (1104–1135),
  `listModels` (903–916), `importModel`'s delete+insert (959–992), `clearSamples` (1002–1022),
  `deleteModel` (1026–1034), `setMaxSamples` (1038–1054), `_generateUuid` (1198–1210).
  Expose as `class FocusModelStore { FocusModelStore(this._db); ... }` and hold one on the
  service. This is also the file where the drift migration in §2.7 lands. ≈ 300 lines out.
- `services/predictive_af/predictive_af_settings_controller.dart` —
  `PredictiveAfSettingsSnapshot` (1242–1250), `PredictiveAfSettingsController` (1254–1337),
  `predictiveAfSettingsControllerProvider` (1339–1343),
  `lastPredictiveAfStatusProvider` (1394–1396). ≈ 110 lines out.

Result: `predictive_af_service.dart` keeps config hydration/validation (421–591),
`recordAutofocusOutcome` orchestration, `evaluateForFilter` (720–790),
`recordPredictionVsActual` (798–889), `getModel`/`exportModel`, `driftEvents`, `dispose`,
and `predictiveAfServiceProvider` — ≈ 420 lines.

---

### 1.5 `services/plate_solve_service.dart` — 1389 lines

**Why it is big — and this one is different from the rest.** The file is not big because it does
a lot; it is big because a 25-field constructor call is copy-pasted **22 times**.
`grep -c 'PlateSolveResult(' = 25` and `grep -c 'sipBpCoeffs: _kEmptyCoeffs' = 25`; three of those
25 are real (the success paths at 750, 846, 1301). A private helper that already exists —
`_failureResult(String error)` at **line 208** — is used only **3 times** (113, 172, 644).
Every other failure site writes the whole literal out.

**Split plan, in two stages. Stage 1 removes ~600 lines with no restructuring:**

1. Replace every failure literal with `_failureResult(...)`. Sites: 180–204, 397–419, 427–452,
   454–476, 478–500, 532–554, 561–583, 585–607, 654–676, 678–700, 702–724, 779–801, 803–825,
   873–895, 1089–1111, 1114–1136, 1152–1174, 1216–1238, 1243–1267, 1274–1298, 1326–1349.
   All 21 differ **only** in the `error:` string. Mechanically safe.
2. Add a sibling `_successResult({required double ra, required double dec, double pixelScale = 0,
   double rotation = 0, ...})` and use it at 750–776, 846–869, 1301–1324.

After stage 1 the file is ≈ 780 lines. **Stage 2 splits what is left:**

- `services/plate_solve/plate_solver_config.dart` — `SolverNotAvailableError` (21–27),
  `PlateSolverType` (30), `PlateSolverConfig` (33–51), `PlateSolveState` (1362–1384),
  `plateSolveStateProvider` (1387–1389), `_kEmptyCoeffs` (16). ≈ 70 lines.
- `services/plate_solve/solver_output_parsers.dart` — `_SolverProcessResult` (53–63),
  `_parseWcsFile` (728–827), `_parseWcsValue` (829–836), `_parseAstrometryOutput` (838–896),
  `_parsePlateSolve2Output` (1210–1350). Make them top-level pure functions taking a
  `String content` rather than a path (the file read moves to the caller) so they become directly
  unit-testable and the three `@visibleForTesting` seams at 80–94 can be deleted. **This is also
  where the `.wcs` correctness defect in §5.1 gets fixed.** ≈ 200 lines after stage 1.
- `services/plate_solve/local_solver_runner.dart` — `_runSolverProcess` (238–269),
  `_terminateSolverProcess` (271–282), `_solveLocally` (315–327), `_solveWithAstap` (347–502),
  `_solveWithAstrometryNet` (505–609), `_solveWithPlateSolve2` (612–726). ≈ 220 lines after
  stage 1. See §3.3 — the PlateSolve2 half of this is dead and can be deleted instead of moved.

Result: `plate_solve_service.dart` keeps the service class, exclusivity gate (108–149),
`_runSolve` (151–206), `_announceSolveResult` (287–312), `detect`/`verify`/`getConfig`/`setConfig`
(908–957), `ensureSolverAvailable` + `_validateSolverAvailability` (962–998),
`solveWithFallback` + `_solveWithFallbackInternal` (1012–1208), provider — ≈ 350 lines.

---

### 1.6 `services/centering_service.dart` — 1310 lines

**Why it is big.** 250 lines of models/exceptions up front (20–266), a 418-line method
`_centerOnTargetInternal` (580–998), a second near-copy of that method's capture+solve+offset
block in `verifyCenter` (1029–1149), plus the coordinate math and the providers.

**Split plan:**

- `services/centering/centering_models.dart` (plain library, re-exported) —
  `CenteringMountUnresponsiveException` (28–53), `CenteringSlewTimeoutException` (57–69),
  `CenteringResult` (72–114), `CenteringIteration` (117–141), `CenteringConfig` (144–187),
  `CenteringState` (190–198), `CenteringStatus` (201–266). ≈ 250 lines out.
- `services/centering/centering_geometry.dart` — `_solvedRaHours` (1228–1230),
  `_normalizedRaHours` (1234–1237), `_clampedDecDegrees` (1240–1242), `_calculateOffset`
  (1250–1280) as top-level pure functions. They touch no instance state. ≈ 60 lines out; this is
  the highest-value extraction because these four functions carry the unit contract that has
  already caused one full-night bug (the 15× RA note at 1213–1227).
- `services/centering_service/slew_settle.dart` (`part of`) — `_waitForSlewComplete`
  (1163–1211) and the three poll constants (276–290). ≈ 70 lines out.
- `services/centering_service/centering_loop.dart` (`part of`) — `_runCentering` (493–522),
  `_resolveCoImagingFramedTarget` (530–567), `_abortedResult` (569–578),
  `_centerOnTargetInternal` (580–998). Decompose `_centerOnTargetInternal` into:
  `_preflight()` (587–669: connection checks, `ensureSolverAvailable`, initial-slew settle),
  `_captureAndSolve(iteration, config, solverConfig)` (693–832 → returns a small record
  `({CapturedImageData? frame, PlateSolveResult? solve, CenteringResult? terminal})`), and
  `_applyCorrection(...)` (908–986). ≈ 470 lines out, and the extracted `_captureAndSolve` is what
  `verifyCenter` should call instead of its own copy (§2.6).
- The providers (1283–1310) stay in `centering_service.dart`.

Result: `centering_service.dart` keeps the class, `stop`/`retire`/`_stopOwnedHardware`
(332–366), `centerOnTarget` (371–447), `_validateRequest` (449–491), `plateAndCenter` (1002–1025),
`verifyCenter` (1029–1149), providers — ≈ 400 lines.

---

## 2. Duplication inside these paths

### 2.1 `_slotDeviceIdFor` and `_trackedDeviceIdFor` are the same function — CONFIRMED IDENTICAL
`device_service/connections.dart:1426–1451` and `device_service/event_handling.dart:571–596`.
Diffed with the names normalised: bodies are byte-identical (both are the same 11-case
`switch (type)` returning `_ref.read(<x>StateProvider).deviceId`). Two names, two doc comments,
one behaviour.
**Survivor:** `_slotDeviceIdFor`, relocated to the new `device_service/device_slots.dart`.
`_disconnectEventOwnsSlot` (event_handling.dart:614) calls it instead. Effort: small.

### 2.2 Four parallel string-keyed device-type switches
`event_handling.dart:427–488` (`_applyDeviceConnected`), `:505–566` (`_applyDeviceConnecting`),
`:661–775` (`_handleDeviceDisconnected`), `:827–876` (`_handleDeviceError`). Each enumerates the
same eleven types with the same alias pairs (`'filterwheel'`/`'filter wheel'`,
`'safetymonitor'`/`'safety monitor'`, `'switch'`/`'switch_'`, `'covercalibrator'`/
`'cover calibrator'` — `grep "case 'covercalibrator':"` returns exactly those four sites).
A fifth enum-keyed copy exists at `connections.dart:1455–1479` (`_disconnectForType`) and a sixth
at `device_service.dart:52–79` (`DeviceTypeDisplayExtension`).
**Survivor:** one `DeviceTypeRegistry` in `device_service/device_slots.dart` exposing
`DeviceType? parseWireType(String)` (the alias table, in one place) and, per type, the notifier
accessors the four switches need (`setConnecting`, `setConnected`, `setDisconnected`, `setError`,
`deviceId`). The four switches collapse to `registry.forType(type)?.setError(exception)` etc.
Effort: medium. This is the change that makes adding a 12th device type a one-line edit instead of
a six-site edit.

### 2.3 Five identical "get the connected device id" helpers
`focuser_rotator_controls.dart:13–22` (`_getCameraDeviceId`), `:30–39` (`_getFocuserDeviceId`),
`:314–323` (`_getRotatorDeviceId`), `filter_wheel_controls.dart:10–19`
(`_getFilterWheelDeviceId`), `guiding_sequencer_controls.dart:12–21` (`_getGuiderDeviceId`).
Same three-clause body against a different provider. Four are `Future<String?>` for no reason —
they contain no `await`; only `_getGuiderDeviceId` is correctly synchronous.
Same pattern again in three `_isStillConnectedToX` helpers:
`focuser_rotator_controls.dart:41–45`, `:325–329`, `filter_wheel_controls.dart:21–25`.
**Survivor:** `String? _connectedDeviceId(DeviceType)` and
`bool _isStillConnected(DeviceType, String)` on the registry from §2.2. Effort: small (mechanical),
but note the four `Future<String?>` signatures are `await`ed at ~20 call sites, so either keep the
`Future` shape at those sites or update them in the same commit.

### 2.4 Three near-identical "poll until the hardware reaches target" loops
`control_helpers.dart:241–288` (`_verifyFocuserPosition`), `control_helpers.dart:314–362`
(`_verifyFilterWheelPosition`), `focuser_rotator_controls.dart:649–701`
(`_verifyRotatorPosition`). All three: compute a deadline, loop, check
`_disposed || generation != _xVerifyGeneration` twice per tick, read status, publish
position+moving, return on tolerance, throw on stall (`!moving && !atTarget`), throw on deadline,
sleep the poll interval. Only the tolerance test and the message strings differ (1 step / exact
slot / 0.5° with 0/360 wraparound).
Three matching recovery helpers with the same shape: `control_helpers.dart:292–312`
(`_recoverFilterWheelMovingState`), `focuser_rotator_controls.dart:69–96`
(`_recoverFocuserMovingState`), `:363–390` (`_recoverRotatorMovingState`).
**Survivor:** one generic `Future<void> _verifyReachesTarget<S>({required Future<S> Function()
readStatus, required void Function(S) publish, required bool Function(S) atTarget,
required bool Function(S) isMoving, required int generation, required int Function() currentGeneration,
required Duration timeout, required Duration pollInterval, required String Function(S) stallMessage,
required String Function(S) timeoutMessage})` in a new `device_service/motion_verify.dart`.
Effort: medium. Payoff is correctness, not lines: three copies means three places a
generation-guard fix has to be repeated.

### 2.5 22 copies of the `PlateSolveResult` failure literal
`plate_solve_service.dart` — see §1.5 stage 1 for the full site list. A `_failureResult` helper
already exists at line 208 and is used 3 times.
**Survivor:** `_failureResult` / a new `_successResult`. Effort: small, mechanical, and it is the
single biggest line-count win available in this subsystem (~600 lines).

### 2.6 `verifyCenter` re-implements the capture+solve+offset block of the centering loop
`centering_service.dart:1029–1149` duplicates `_centerOnTargetInternal`'s
`captureUtilityFrame` → `solveWithFallback` → `_solvedRaHours` → `_calculateOffset` →
build `CenteringIteration` sequence from `:693–871`. The copy is already **behaviourally
divergent**: it never sets `_isRunning`/`_captureInFlight`/`_ownedImagingService`, so `stop()`
(line 332, `if (!_isRunning) return;`) is a no-op against it, and it does not check
`_abortRequested` anywhere.
**Survivor:** the `_captureAndSolve` helper extracted in §1.6; `verifyCenter` calls it and gains
abort support for free. Effort: medium. See also §3.4 — `verifyCenter` currently has no production
caller, so "delete it" is also a legitimate resolution.

### 2.7 `PredictiveAfService` hand-rolls persistence for a table that already has a drift accessor
`packages/skotiq_core/lib/src/database/tables/focus_models.dart` exists and
`database.g.dart:26218` defines `class FocusModelEntry`. The service nonetheless does every read
and write with raw SQL strings and untyped row maps: `customStatement` at 650, 679, 825, 846, 959,
964, 1007, 1030, 1044, 1062; `customSelect` at 905, 909, 1078; and hand-written row decoding in
`_rowToMap` (1094–1102) and `_rawToModel` (1104–1135). Column names appear as string literals in
ten places, so a schema migration that renames a column compiles fine and fails at runtime.
The class doc at line 12–18 even refers to `db.FocusModelEntry`, and the `db` import
(line 29) exists only for that doc reference plus the type annotation on `_db`.
**Survivor:** a `FocusModelsDao` alongside the other DAOs, consumed through the
`FocusModelStore` from §1.4. Effort: large (it is a real migration and needs the existing
`predictive_af_service_test.dart` suite to pass unchanged), but it removes the single largest
untyped-SQL surface in the subsystem.

### 2.8 Two focus-model subsystems coexist by design, both alive
`predictive_af_service.dart:12–18` documents the split explicitly: `FocusModelService`
(`services/focus_model_service.dart`, 906 lines, JSON-file storage, profile-scoped) is the
"legacy in-app working set"; `PredictiveAfService` (1396 lines, SQLite, per-filter) is the
persisted cross-session model. Both have live production consumers —
`focusModelServiceProvider` is read from `temperature_and_time.dart:30`,
`focus_model_curve_card/actions.dart:130/149/181/218`,
`focus_model_profile_data_provider.dart:23`, `filter_offset_provider.dart:110/246/276/317`;
`predictiveAfServiceProvider` from `device_service/autofocus_controls.dart:562/641` and
`apps/desktop/.../focus_model_handlers.dart`. Two temperature-compensation models, two
regression implementations, two storage formats, one focuser.
**Survivor:** `PredictiveAfService` (it is the one the AF run trains and the one the headless API
exposes). `FocusModelService`'s four remaining jobs — the equipment-screen scatter plot, the status
bar's temperature readout, `exportData`, and the filter-offset derivation — should read from
`FilterFocusModel.samples` instead. Effort: large. Flagged as a decision, not a mechanical change.

### 2.9 Two independent "start exposure, await terminal event, abort on cancel/timeout" drivers
`ImagingService._capture` (`imaging_service.dart:274–419`) and
`FlatWizardService.exposeAndAwait` (`flat_wizard_service.dart:506–701`) each implement:
subscribe-before-start, a `Completer` settled by imaging events, a timeout equal to
`exposureTime + 30 s`, an abort-exactly-once path, and a bounded image download. They disagree on
substance, not just style — see §5.2: the flat-wizard one correlates the event to the device
(`_classifyExposureEvent`, 446–479, plus `_deviceIdKeys` 434–439) and the imaging one does not.
**Survivor:** the flat-wizard implementation is the better of the two. Extract it as
`ExposureDriver` (a small collaborator taking a `SkotiqBackend`), and have both services own
one. Effort: large — `ImagingService._capture` also drives progress notifiers and shared
`isExposing` state that the flat wizard does not — but §5.2 must be fixed regardless, and doing it
by adoption is cheaper than doing it twice.

### 2.10 `DeviceService`'s public surface is 195 lines of 1:1 forwarding
`device_service.dart:355–548` — 60 public methods, each a one-line delegate to the identically
named private extension method (`connectCamera` → `_connectCamera`, `parkMount` →
`_trackInFlight(_parkMount)`, …). Two smaller instances of the same shape:
`_writeFilterNamesToBackend` (device_service.dart:228–236) forwards to `_setFilterWheelNames`,
and `_friendlyNameFromId` (control_helpers.dart:234–235) forwards to `friendlyNameFromDeviceId`.
This is deliberate (the doc at 353–354 says the public surface is a mock/provider contract) and
the `_trackInFlight` wrapping at 462–518 is real behaviour, so this is **not** a
delete-on-sight item. Recorded so a splitter does not mistake it for accidental duplication. The
only actionable part: the ~30 forwarders that add nothing (`connectCamera`, `disconnectMount`, …)
could become the private methods renamed public, deleting the shim. Effort: medium, low value.

---

## 3. Dead code

Evidence for each is a repo-wide grep across `packages/` + `apps/` (which includes the headless
API handlers in `apps/desktop/lib/headless_api/`) — the non-obvious-caller surfaces the brief
warns about. Rust/FRB exports are not involved here: none of these are `#[frb]` targets.

### 3.1 `PredictiveAfService.setMaxSamples` — genuinely dead
`predictive_af_service.dart:1038–1054`. `grep -rn "setMaxSamples" packages apps` returns
**only the definition**. No test, no handler, no UI. The `max_training_samples` column is
therefore permanently whatever `recordAutofocusOutcome` defaulted it to (50, line 623).
Delete, or wire it to the "Re-train" UI next to `clearSamples`.

### 3.2 `_RegressionFit.sampleCount` — write-only field
`predictive_af_service.dart:1218` (declared), `:1225` (constructor param), `:1194` (assigned
`best.length`). `grep -rn "sampleCount" packages/skotiq_core/lib/src/services/` shows no read
of `_RegressionFit.sampleCount` anywhere — the other hits are `sky_brightness_tracker.dart:228`,
`science_processing_service*`, and `guide_rms_collector.dart:68`, all unrelated types.
Delete the field and the argument.

### 3.3 The whole PlateSolve2 solver path — unreachable in production
`PlateSolverType.plateSolve2` (`plate_solve_service.dart:30`), `_solveWithPlateSolve2`
(612–726), `_parsePlateSolve2Output` (1210–1350), the `parsePlateSolve2OutputForTest` seam
(93–94), and the `case PlateSolverType.plateSolve2:` arm at 324.
`grep -rn 'PlateSolverType\.' packages apps` gives exactly two production construction sites —
`centering_dialog.dart:943` and `slew_dropdown_button.dart:579`, **both** `PlateSolverType.astap`.
Every other `PlateSolverType.plateSolve2` reference is in
`plate_solve_service_lifecycle_test.dart:350` and generated mocks. `_solveWithFallbackInternal`
(1031–1208) can only produce `astap` or `astrometryNet` (1062–1072, 1139, 1177), and
`_validateSolverAvailability` (968–998) has no PlateSolve2 branch, so `solveWithFallback` — the
entry point every real caller uses — can never select it.
`AppSettingsState.plateSolver` still documents `'PlateSolve2'` as a legal value
(`app_settings_state.dart:74`, `app_settings.dart:238`) but nothing maps that string onto
`PlateSolverType`.
~250 lines. Either delete the enum arm + both methods, or (if PlateSolve2 support is a shipped
promise) wire `PlateSolverChoice` to it — but today the settings string is a lie.

### 3.4 Production-unreachable public API (test-only callers)
These are **not** unused symbols — they have tests — but they have no production caller, so they
are unverified surface area that a release pass should either wire up or delete. Each was checked
with `grep -rn <name> packages apps` and the only non-test, non-mock hit is the definition.

| Symbol | Definition | Only callers |
|---|---|---|
| `CenteringService.plateAndCenter` | `centering_service.dart:1002` | `centering_service_test.dart:2315` |
| `CenteringService.verifyCenter` | `centering_service.dart:1029` | `centering_service_test.dart:2147/2232/2417` |
| `ImagingService.resetFrameCounter` | `imaging_service.dart:1186` | `imaging_service_test.dart:1970` |
| `DeviceService.connectProfile` | `device_service.dart:429` | `device_service_p0_test.dart:321` |
| `DeviceService.connectActiveProfile` | `device_service.dart:456` | `equipment_remote_parity_test.dart:159` |
| `PredictiveAfService.importModel` | `predictive_af_service.dart:934` | `predictive_af_service_test.dart:356/367` |
| `PredictiveAfService.deleteModel` | `predictive_af_service.dart:1026` | `predictive_af_service_test.dart:350` |

The `connectProfile` / `connectActiveProfile` entry means the whole sequential-with-abort profile
connect path — `profile_connections.dart:11–106`, 96 lines — is production-dead; the live path is
`connectAllFromProfile` (`equipment_screen.dart:623`, `profile_service.dart:418`), which is
parallel and never aborts. Two different connect-all semantics ship, one of them unused.
`importModel` being test-only is notable because `exportModel` **is** wired
(`predictive_af_settings.dart:484`, `focus_model_handlers.dart:190`) — the app can export a focus
model it can never import.

### 3.5 Possibly-stale analyzer suppressions
`imaging_service.dart:1` (`// ignore_for_file: unused_element`),
`imaging_service/quality_processing.dart:1` (same),
`plate_solve_service.dart:1` (`// ignore_for_file: unused_local_variable`).
I could not identify any element these actually suppress (`_calculateQualityScore` is called from
`persistence.dart:165`; the `logging` locals in `plate_solve_service.dart` at 909, 928, 1038 are
all used). Flagged as *suspected* stale, not proven — an implementer should delete them and see
what the analyzer says. Low effort, and a stale file-wide `unused_element` ignore actively hides
future dead code in a 1581-line library.

---

## 4. Performance risks

### 4.1 Full-frame histogram on the UI isolate, once per captured frame — MEDIUM
`imaging_service.dart:1515–1524` (`previewDisplayHistogramProvider`) →
`histogram256FromRawU16` (1527–1533), a plain `for` over `raw.length`.
`raw` is `CapturedImageData.rawU16`, and `hasRawReady`
(`imaging_models/file_format_and_capture_state.dart:119–122`) requires
`rawU16!.length == width * height` — i.e. the entire sensor. On a 62 MP sensor that is a 62-million
iteration loop with a bounds-checked `Uint16List` read and a `List<int>` increment per pixel,
executed synchronously in a Riverpod `Provider` body on the UI isolate.
Honest scope: the provider only recomputes when `currentImageProvider` changes, so this is once per
frame, not once per repaint. But once per frame during a live-view loop with a 5 s sub is a visible
hitch every 5 s on the same isolate that draws the preview. Consumer:
`live_preview_area.dart:132`.
Fix direction: compute the histogram alongside the raw load (off-isolate, where the raw already
arrives) and carry it on `CapturedImageData`, or downsample (every 8th pixel is
statistically indistinguishable for a 256-bin display histogram).

### 4.2 Up-to-100,000 sequential `stat` calls before every keeper exposure — MEDIUM
`imaging_service/file_paths.dart:86–135` (`_nextKeeperFrameNumber`), loop at 123–125:
`while (candidate < ceiling && await File(renderFor(candidate)).exists()) candidate++;`
with `ceiling = fallback + _keeperProbeLimit` and `_keeperProbeLimit = 100000`
(`imaging_service.dart:90`). Each iteration also runs `renderFor` → `buildImageFilePath`
(`imaging_service.dart:1362–1423`), which re-runs `expandNamingPattern`'s regex validation, a
per-segment safety scan, `path.normalize`, `path.absolute` and `path.isWithin`.
Called from `_capture` at line 204 on **every** keeper capture, before the exposure starts.
Cost is O(frames already in the target folder) per capture, so a night is O(n²) round trips. At
300 frames that is ~45,000 stats over the night — tolerable on local SSD, meaningfully slower on a
network share or an SD card, which is exactly where an appliance writes.
Fix direction: `Directory.list()` the target folder once and take the max matching index, or cache
the high-water mark per rendered folder+date and re-probe only on a miss.

### 4.3 `_ensureUniqueFilePath` recomputes path components inside its loop — LOW
`imaging_service/file_paths.dart:141–150`: `path.dirname/basenameWithoutExtension/extension` are
all called on the loop-invariant `desiredPath` on every iteration. Hoist. Trivial; listed only
because it is in the same hot path as 4.2.

### 4.4 Environmental poll can serialise three 4 s timeouts inside a 5 s tick — MEDIUM
`device_service/connections.dart:1012–1092`. The tick reads weather (1030–1032, `.timeout(4s)`),
then safety (1061–1063, `.timeout(4s)`), then dome (1081, `.timeout(4s)`) **sequentially**, under a
single `_environmentPollInFlight` flag (1013, 1022, 1090). A rig with all three connected and all
three slow burns up to 12 s per tick, so every third `Timer.periodic` tick
(`environmentPollInterval = 5 s`, device_service.dart:144) is dropped by the in-flight guard and
the "Last checked" age the card renders is up to 3× staler than the configured interval.
Fix direction: `Future.wait` the three reads (they target three different drivers), or give each
source its own in-flight flag.

### 4.5 `evaluateForFilter` costs two DB round trips plus a JSON decode per AF gate — LOW
`predictive_af_service.dart:725–734`: `getModel` → `_loadByKey` (a `SELECT *`) → `_rowToMap`
(1094–1102) which `jsonDecode`s `training_samples_json` (up to 50 samples) and rebuilds every
`FocusTrainingSample`; then `_touchLastUsed` (1058–1072) issues a second `UPDATE`.
`recordAutofocusOutcome` does the same decode again at 613 and once more at 709
(`getModel` "to get the canonical row"). Three decodes and four statements per autofocus run.
Impact is low in absolute terms (an AF run costs minutes) but this is the same code the sequencer's
per-filter gate calls, and it is the sort of thing that gets called in a loop later.

### 4.6 `_recentDeviceErrorToasts` cleanup only runs above 128 entries — LOW
`device_service/event_handling.dart:11` declares a library-level `Map<String, DateTime>`;
`:890–896` inserts unconditionally and only prunes when `length > 128`, and then only removes
entries older than the 60 s window. A device emitting many *distinct* messages inside one window
grows the map past 128 without shedding anything. Bounded in practice; noted for completeness. See
§5.7 for the more serious problem with this map.

---

## 5. Reliability risks

### 5.1 The Dart `.wcs` parser cannot read a real ASTAP `.wcs` — HIGH, and the native side already knows
`plate_solve_service.dart:728–747`:
```dart
final content = await File(wcsPath).readAsString();
final lines = content.split('\n');
for (final line in lines) {
  if (line.startsWith('CRVAL1')) { ... }
```
The authoritative statement of the format lives in this repo, in the native implementation that was
already fixed: `native/skotiq_native/imaging/src/platesolve.rs:933–944`, doc comment on
`fits_header_cards`:

> A `.wcs` file is a raw FITS header: fixed-width cards packed end to end **with no line
> terminators at all**. Iterating it with `str::lines()` therefore yields the whole header as one
> enormous "line", so only the very first card (`SIMPLE`) is ever inspected and every keyword after
> it — `CRVAL1`, the CD matrix, `NAXIS1/2` — is invisible. ASTAP would solve, the parse would then
> report the solution as missing `CRVAL1`, and the caller counted a successful solve as a failed
> one: `Plate Solve & Center` failed every attempt and took the run down with it.

`split('\n')` is Dart's `str::lines()`. The Dart copy has the exact defect the Rust copy documents
having had. The reason the test suite is green is that the fixture is newline-delimited:
`plate_solve_service_test.dart:35–40` writes `'CRVAL1  = ...\nCRVAL2  = ...\n'`, which is the one
input shape the broken parser handles.
Reachability: `_parseWcsFile` is reached from `_solveWithAstap` (line 424), which is reached from
`_solveLocally` (321), which `_runSolve` calls at line 175 whenever `backend.plateSolve` throws on
a non-`NetworkBackend` backend. So this is the local-fallback path — the one that runs precisely
when the native solver has already failed.
Fix: port `fits_header_cards`' newline-first-then-80-char-split logic (it deliberately still honours
newlines, so the existing fixture keeps passing), and add a fixture with no terminators.

### 5.2 `ImagingService`'s exposure listener accepts **any** camera's completion event — HIGH
`imaging_service.dart:284–323`. The listener filters on
`event.category == EventCategory.imaging` and `event.eventType` only. It never looks at
`event.data['deviceId']` / `['device_id']` / `['cameraId']` / `['camera_id']`, even though the
capture has `deviceId` in scope (line 219) and the *sibling service in this same subsystem* does
exactly that check: `flat_wizard_service.dart:434–439` (`_deviceIdKeys`) and `:456–464`, with the
rationale written out at 429–433 ("When a key IS present it MUST match the camera we drove, so a
second camera's completion on a shared stream can never satisfy our wait").
Consequence on a dual-camera rig (main + guide camera, or two imaging cameras — a configuration
`_releaseDisplacedDevice` at connections.dart:1392 exists specifically to manage): the guide
camera's `ExposureComplete` completes the main camera's `exposureCompleter` early, `_capture`
proceeds to `cameraGetLastImage` mid-exposure and either downloads a stale frame or fails, and the
stale-frame guard at 495–510 only fires on the *timeout* branch, not this one.
Fix: lift `_classifyExposureEvent`'s device-correlation guard into the imaging listener (or adopt
§2.9's shared `ExposureDriver`).

### 5.3 `PredictiveAfService`'s `config` setter drops its errors on the floor — MEDIUM
`predictive_af_service.dart:440–448`:
```dart
set config(PredictiveAfConfig value) {
  final dao = _settingsDao;
  if (dao == null) { _validateConfig(value); _config = value; return; }
  unawaited(updateConfig(value));
}
```
With a `SettingsDao` present (the production case — `predictiveAfServiceProvider:1231–1234` always
supplies one), the setter is fire-and-forget. `updateConfig` (450–460) calls `_validateConfig`
(which throws `ArgumentError` for out-of-range thresholds, 464–514) and awaits a DB write; both
failure modes escape as an **unhandled async error in the zone**, while the caller's assignment
statement returned normally. So `service.config = badConfig` reports success and leaves `_config`
unchanged. The two branches also disagree: without a DAO the setter validates synchronously and
throws; with one it does not.
Note `_configWriteTail = operation.then<void>((_) {}, onError: (_, __) {})` at 458 swallows the tail
but `operation` itself — the one handed to `unawaited` — still carries the error.
Fix: make the setter `@Deprecated`/private and force callers onto `await updateConfig(...)`, or at
minimum validate synchronously in the setter before dispatching.

### 5.4 `FlatWizardService._lastTestFrameOutcome` is a shared out-parameter on an app-wide singleton — MEDIUM
`flat_wizard_service.dart:711` declares the field; `captureTestFrame` writes it at 750; both
solvers read-and-clear it at 833–834 and 1024–1025. It exists only to widen
`captureTestFrame`'s `double?` return without changing the signature (rationale at 703–710).
`flatWizardServiceProvider` (1408–1414) is a plain `Provider` — one instance per container — and it
has two independent drivers: the GUI wizard
(`providers/flat_wizard_provider.dart:950` → `calibrateFilterWithRateTracking`) and the headless
API (`apps/desktop/lib/headless_api/handlers/flat_wizard_handlers.dart:81` →
`calibrateMultipleFilters`, `:246` → `quickCalibrate`). Nothing serialises them. If both run, the
`await captureTestFrame(...)` in one solver can be followed by the *other* solver's write to
`_lastTestFrameOutcome`, and the first solver then reads a foreign frame's outcome — deciding
"timed out, halt the run" or "cancelled" on the basis of a different filter's exposure.
Fix: return a `({double? adu, FlatFrameCapture outcome})` record from `captureTestFrame` and delete
the field. The test-double seam survives — a subclass just returns a record.

### 5.5 `verifyCenter` cannot be stopped — MEDIUM
`centering_service.dart:1029–1149` never sets `_isRunning` (299), `_captureInFlight` (301),
`_ownedImagingService` (304) or checks `_abortRequested` (298). `stop()` (332–345) opens with
`if (!_isRunning) return;`, so pressing Abort during a `verifyCenter` exposure does nothing at all:
no `cancelExposure`, no `abortMountSlew`, and the caller waits out the full exposure and solve.
Mitigating: §3.4 shows `verifyCenter` has no production caller today. Either wire the lifecycle
flags in when it gets one, or delete it (§2.6).

### 5.6 Local solver timeout abandons its stdout/stderr readers — LOW
`plate_solve_service.dart:249–262`. `stdoutFuture`/`stderrFuture` are created at 249–254, but on
the `TimeoutException` branch (259–262) the method kills the process and throws without awaiting
them. They carry `.catchError((Object _) => '')` so nothing becomes an unhandled error, but the two
decode streams are left attached to a killed process's pipes. Cheap fix: await both (with a short
timeout) inside the catch before rethrowing.

### 5.7 A library-level mutable map is shared by every `DeviceService` instance and never cleared — MEDIUM
`device_service/event_handling.dart:11`:
`final Map<String, DateTime> _recentDeviceErrorToasts = <String, DateTime>{};` — top-level, not a
field. `DeviceService.dispose()` (device_service.dart:318–327) does not touch it, and
`prepareForBackendSwap` (284–298) does not either. Consequences:
(a) after a backend swap the new `DeviceService` inherits the old host's 60 s suppression window,
so the first error from the newly connected host can be silently swallowed if its
`(deviceId, message)` key collides;
(b) in tests it is process-global state that leaks between cases, which makes any test asserting
"an error toast was shown" order-dependent.
Fix: make it an instance field on `DeviceService` and clear it in `dispose()`.

### 5.8 `dispose()` leaves `quiesce()` awaiters hanging and does not await the subscription cancel — MEDIUM
`device_service.dart:318–327`. `dispose()` sets `_disposed`, unregisters, fires
`_eventSubscription?.cancel()` **without awaiting** (321), cancels the env timer, and disposes the
pollers. It never completes `_quiesceWaiters` (169). A caller sitting in `quiesce()` (265–280) when
the service is disposed mid-flight is only released by its own 30 s
`_quiesceTimeout` (174), which then surfaces as a `TimeoutException` rather than "the service went
away". `prepareForBackendSwap` (284–298) awaits `quiesce()` at 297, so a backend swap racing a
dispose can stall for 30 s. Also `dispose()` does not cancel `_reconnectCoordinator`'s pending work
beyond `cancelAll()` (326) and does not stop `_switchChannels`.
Fix: in `dispose()`, drain `_quiesceWaiters` (complete them, or complete them with an error), and
`unawaited(_eventSubscription?.cancel())` explicitly so the intent is legible.

### 5.9 Operational diagnostics that bypass the logging service — LOW
`centering_service.dart:1184–1188` uses `// ignore: avoid_print` + `print(...)` to report
post-slew status-poll failures, and `device_service.dart:219–220` does the same for logger-emission
failures. The centering one is the more serious: consecutive-failure escalation toward
`CenteringMountUnresponsiveException` is exactly the diagnostic an operator wants in the activity
log and the diagnostic dump, and `print` puts it in neither. The `device_service.dart` one is
deliberate (it is the fallback *for* a broken logger) and should stay.

### 5.10 Unawaited DB write in the AF prediction gate — LOW
`predictive_af_service.dart:734`: `unawaited(_touchLastUsed(equipmentProfileId, filterName));`
with the rationale "the predict path is performance-sensitive". `_touchLastUsed` (1058–1072) is a
`customStatement` against a database that may be closed by the time it lands — the service already
has a `StateError`-on-closed-DB guard in `_hydrateFromSettings` (550–556) for exactly this
shutdown-order hazard, but not here. Add the same `if (_disposed) return;` / `on StateError` guard.

---

## 6. Cross-package duplication suspects (for the cross-cutting agent)

One line each; each is a Dart implementation in these paths that appears to have a Rust or
handler-layer twin.

- **`.wcs` parsing** — `plate_solve_service.dart:728–836` vs
  `native/skotiq_native/imaging/src/platesolve.rs:977+` (`parse_wcs_file_inner` +
  `fits_header_cards`). The Rust one is correct and richer (CD matrix, SIP, NAXIS); the Dart one is
  broken (§5.1) and returns `cd11..cd22 = 0` even on success (764–775).
- **ASTAP CLI argument construction** — `plate_solve_service.dart:363–387` vs
  `platesolve.rs:596–648`. The Dart comment at 331–346 explicitly says it "mirrors" the Rust; two
  hand-synced argument lists.
- **astrometry.net output parsing** — `plate_solve_service.dart:838–896` vs whatever the native
  solver does for `solve-field`; the Dart regex handles only the `RA,Dec = (…)` line.
- **Capture filename / naming-pattern expansion** — `imaging_service.dart:1198–1473` vs
  `native/skotiq_native/imaging/src/naming.rs` (`FilenameGenerator`). Cross-referenced by
  comment at `imaging_service.dart:1190–1197` and `imaging_service/file_paths.dart:11–13`; the
  `$SEQUENCE` sentinel at 1464–1470 documents a case where they already diverged.
- **Focus-model linear regression** — `predictive_af_service._fitRegression` (1139–1196) vs
  `native/skotiq_native/sequencer/src/focus_prediction.rs` `PersistedFocusModel::refit`,
  declared identical by the header comment at lines 1–18 and 1137–1138. Same 1 °C bucketing,
  lowest-HFR-per-bucket selection, and intercept-at-mean convention duplicated in two languages.
- **Frame quality score** — `imaging_service/quality_processing.dart:12–27` →
  `frame_quality_score.dart` vs the Rust implementation in `imaging/fits.rs` (named in the comment
  at quality_processing.dart:6–7).
- **Flat convergence exposure math** — `FlatWizardService.calculateNextExposure` (386–417) vs the
  Rust flat convergence engine; a parity test already exists
  (`test/services/flat_convergence_rust_parity_test.dart:106`), which is itself the evidence that
  two implementations are being kept in sync by hand.
- **Flat-wizard orchestration** — `apps/desktop/lib/headless_api/handlers/flat_wizard_handlers.dart`
  (:81, :210, :246) re-drives `calibrateMultipleFilters`/`generateCompleteSequence`/`quickCalibrate`
  in parallel with `packages/skotiq_core/lib/src/providers/flat_wizard_provider.dart:950`;
  two orchestrators over one non-reentrant service (see §5.4).
- **Centering orchestration** — `apps/desktop/lib/headless_api/handlers/framing_handlers.dart:109/137`
  and `planetarium_handlers.dart:242/274` each build their own `CenteringConfig`/`PlateSolverConfig`
  and call `centerOnTarget`, as do `centering_dialog.dart:950` and `slew_dropdown_button.dart:586`;
  four independent config-assembly sites for one operation.
- **`focus_models` persistence** — raw SQL in `predictive_af_service.dart` vs the generated drift
  table/`FocusModelEntry` in `database.g.dart:26218` (§2.7).
- **Temperature-compensation focus modelling** — `predictive_af_service.dart` vs
  `services/focus_model_service.dart` (906 lines, JSON-file storage), both live (§2.8).

---

## 7. Suggested order of work

1. **`.wcs` parser** (§5.1) — a correctness bug on the plate-solve fallback path, with the fix
   already written in Rust next door. Smallest change with the largest night-cost avoided.
2. **PlateSolveResult literal collapse** (§2.5) — mechanical, removes ~600 of 1389 lines, and makes
   the rest of the plate-solve split trivial.
3. **Device-id correlation on the imaging exposure listener** (§5.2) — one guard, copied from a
   sibling file in the same package.
4. **Split `imaging_service.dart`'s 763-line `_capture`** (§1.1) — the largest single method in the
   subsystem and the one every capture path runs through.
5. **Split `device_service/connections.dart` + collapse the device-type switches and the twin slot
   helper** (§1.2, §2.1, §2.2) — the duplication and the file size are the same problem here.
6. **`FlatWizardService._lastTestFrameOutcome` → return value** (§5.4) and the flat-wizard file
   split (§1.3).
7. **Models-out-of-service splits for `predictive_af_service.dart` and `centering_service.dart`**
   (§1.4, §1.6), including the pure `centering_geometry` extraction that carries the RA unit
   contract.
8. **Dead-code sweep** (§3): delete `setMaxSamples`, `_RegressionFit.sampleCount`, and the
   PlateSolve2 path; take a decision on the seven production-unreachable public methods and on the
   unused sequential profile-connect path.
