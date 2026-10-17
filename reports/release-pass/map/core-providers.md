# Release-pass map — `skotiq_core` providers (excluding `sequence/`)

Scope: `packages/skotiq_core/lib/src/providers/**` minus the `sequence/` subtree.
Read-only mapping pass. No source file was modified.

Totals in scope: 121 Dart files, 55,302 lines (`find … -name '*.dart' | grep -v /sequence/ | xargs wc -l`).
No generated files exist anywhere under `providers/` — `find … -name '*.g.dart' -o -name '*.freezed.dart'`
returns nothing. Every file discussed below is hand-written.

Existing precedent that the split plans lean on: `settings_provider.dart` is already a
`part`/`part of` library with 25 section files (`settings_provider.dart:46-70`), and those
part files legally reach the notifier's private members via
`extension _AppSettingsRemoteMapping on AppSettingsNotifier`
(`settings_sections/app_settings_remote_mapping.dart:3`). Every split below uses that same
mechanism, so private fields/methods keep working and **no import in any consumer changes**.

---

## 1. OVERSIZED FILES

Threshold: >1000 lines. All counts verified with `wc -l`.

| file | lines |
|---|---|
| `weather_safety_provider.dart` | 1703 |
| `remote_sync_handler.dart` | 1665 |
| `flat_wizard_provider.dart` | 1554 |
| `polar_alignment_provider.dart` | 1432 |
| `profiles_provider.dart` | 1257 |
| `scheduler_provider.dart` | 1247 |
| `transient_alert_provider.dart` | 1136 |
| `settings_sections/app_settings_state.dart` | 1096 |

Just under the bar and part of the same clusters (listed for the implementer's awareness, not
proposed for splitting on their own): `settings_sections/app_settings_remote_mapping.dart` 950,
`notification_router_provider.dart` 945,
`settings_sections/app_settings_partial_persistence_mapping.dart` 936,
`meridian_flip_provider.dart` 922,
`settings_sections/app_settings_stored_snapshot_mapping.dart` 914,
`framing_provider.dart` 884, `tutorial_provider.dart` 872,
`session_replay_provider.dart` 867, `defect_map_provider.dart` 864,
`science_provider/session_products.dart` 857.

---

### 1.1 `weather_safety_provider.dart` — 1703 lines — risk **high**

**Why it is big.** One `StateNotifier` (`WeatherSafetyNotifier`, lines 377–1680, **1303 lines**)
owns six unrelated jobs: (a) remote/companion status polling, (b) the local multi-source safety
evaluation, (c) hardware enforcement via `SafeRigService` + the auto-resume state machine,
(d) three separate periodic pushes into the Rust executor (weather verdict, cloud motion,
adaptive conditions), (e) park-before-dawn twilight math, (f) snooze/UI plumbing. It carries
**7 timers** and 9 boolean/int latches as instance state.

**Split plan** (make it a `part` library; file keeps its name and its `export` from
`skotiq_core.dart`):

New `weather_safety_provider.dart` (target ~330 lines) keeps:
- `part` directives, all imports
- the notifier class declaration, its fields/constants (`377`–`446`), constructor (`448`–`503`)
- `_startPeriodicEvaluation`, `_scheduleSourceChangeEvaluation`, `_evaluateAllSources`,
  `_evaluateAllSourcesAsync`, `_evaluateAllSourcesWithConfiguration` (`624`–`953`)
- `snooze` / `cancelSnooze` / `forceEvaluation` / `_subscribeToAlerts` / `_shouldCloseDome` /
  `dispose` (`1542`–`1680`)
- the trailing provider declarations (`1682`–`1703`)

| new file | moves | source lines |
|---|---|---|
| `weather_safety/weather_safety_models.dart` | `NoDataResolution`, `noDataFailModeResolution`, `SafetySourceReading`, `WeatherSafetyStatus`, `WeatherSafetyActions`, `SafetyDataSource`, `WeatherSafetyState` | `31`–`144`, `255`–`371` |
| `weather_safety/weather_safety_sources.dart` | `_sourceFreshnessBudget`, `_isSourceConfigured`, `_isStaleReading`, `_evaluateHardwareWeather`, `readHardwareWeatherSource`, `readSafetyMonitorSource`, `weatherSafetySourceReadingsProvider` | `146`–`253` |
| `weather_safety/weather_safety_remote.dart` (`extension _WeatherSafetyRemote on WeatherSafetyNotifier`) | `_startRemoteStatusPolling`, `_refreshRemoteStatus`, `_readingFromWire` | `505`–`622` |
| `weather_safety/weather_safety_enforcement.dart` (`extension _WeatherSafetyEnforcement`) | `_enforceSafetyActionsAndLatch`, `_enforceSafetyActions`, `_hasAnythingToSafe`, `_announceNothingToSafe`, `_scheduleAutoResume`, `_cancelPendingAutoResume`, `_canContinueAutoResume`, `_restoreSafetyAfterInterruptedResume`, `_autoResumeAfterWeatherClear`, `_isLiveReading` | `955`–`1150`, `1419`–`1544` |
| `weather_safety/weather_safety_executor_push.dart` (`extension _WeatherSafetyExecutorPush`) | `_startCloudMotionPush`, `_startAdaptiveConditionsPush`, `_computePushedVerdict`, `_pushWeatherVerdict`, `_freshCloudCover`, `_pushCloudMotion`, `_pushAdaptiveConditions`, `_currentHfrValues`, `_conditionsScoreWeights`, `_isParkBeforeDawnDue` | `1152`–`1417` |

Constraints for the implementer:
- The `static const` timer intervals (`_evaluationInterval`, `_cloudMotionPushInterval`,
  `_adaptiveConditionsPushInterval`, `_cloudCoverTtl`, `_cloudCoverErrorRetryTtl`,
  `_autoResumeHoldoff`, `_parkBeforeDawnLeadTime`) must **stay on the class** — a `static const`
  cannot live in an extension. Only methods move.
- `_readingFromWire` is `static` on the notifier; make it a library-private top-level function in
  `weather_safety_remote.dart` and update its two call sites (`584`, `588`).
- `weather_fail_mode_parity_test.dart` pins `noDataFailModeResolution`'s truth table against the
  Rust `safety_fail_mode_no_data_resolution`. Moving it to `weather_safety_models.dart` is fine
  (same library, same export) but **do not change the table**.

---

### 1.2 `remote_sync_handler.dart` — 1665 lines — risk **high**

**Why it is big.** It is the *entire* master→slave mirror as one flat file of ~45 library-private
top-level functions: event fan-out, per-device telemetry mirroring, host-mutation mirroring,
sequence-editor mirroring, remote frame fetch/publish, and full session hydration. There is no
class to hang the pieces on, so everything accumulated at top level.

**Split plan** — convert to a `part` library. `remote_sync_handler.dart` becomes the head
(target ~200 lines): imports, `part` directives, `applyRemoteSyncEvent` (`54`–`127`) and
`_applySystemSyncEvent` (`129`–`164`).

| new file | moves | source lines |
|---|---|---|
| `remote_sync/reader_access.dart` | `_read`, `_invalidate`, `_isCurrentRemoteBackend` | `1269`–`1305`, `1283`–`1289` |
| `remote_sync/device_mapping.dart` | `_parseDeviceType`, `_readDeviceNotifier`, `_readDeviceState`, `_isDeviceAlreadyConnected`, `_applyConnectingDevice`, `_applyConnectedDeviceFromPayload`, `_applyConnectedDevice`, `_applyDeviceConnectedFromSyncPayload`, `_applyDeviceDisconnectedFromSyncPayload`, `_clearLocalDeviceState` | `1069`–`1267`, `1349`–`1362`, `1394`–`1400` |
| `remote_sync/equipment_mirror.dart` | `_applyEquipmentEvent`, `_applyEquipmentTelemetry`, `_invalidateEquipmentSyncProviders` | `166`–`214`, `286`–`486` |
| `remote_sync/imaging_mirror.dart` | `_applyExposureMirror`, `_RemoteFrameFetchState`, `_remoteFrameFetchStates`, `_publishRemoteCurrentFrame` | `216`–`284`, `947`–`1053` |
| `remote_sync/sequencer_mirror.dart` | `_applySequencerEvent`, `_applySequencerMutationFromHost`, `_applySequenceEditorMirror`, `_hydrateOpenEditorSequence`, `_refreshSequencerStatus`, `_applySequencerStatus`, `_mapSequencerState`, `_parseSequenceId`, `_invalidateSequenceLibrary` | `518`–`617`, `749`–`933`, `935`–`945`, `1307`–`1347` |
| `remote_sync/host_mutation.dart` | `_applyHostMutation`, `_applyEquipmentMutationFromHost`, `_applyGuiderMutationFromHost`, `_applyFramingMutationFromHost`, `_applyFramingTargetChanged`, `_invalidateHostProfiles`, `_invalidateHostTargets`, `_invalidateHostCapturedImages`, `_invalidateHostSessions`, `_invalidateTargetProgress` | `619`–`747`, `906`–`933`, `1055`–`1067` |
| `remote_sync/guiding_mirror.dart` | `_applyGuidingEvent`, `_hydratePhd2GuiderState` | `488`–`516`, `1364`–`1392` |
| `remote_sync/session_hydration.dart` | `hydrateRemoteSessionState` (public — keep the name), `_hydrateDeviceTelemetry` | `1402`–`1665` |

Constraint: `hydrateRemoteSessionState` is imported by
`remote_session_sync_provider.dart:10`/`83`. Keeping it in a `part` of the same library preserves
that import untouched.

---

### 1.3 `flat_wizard_provider.dart` — 1554 lines — risk **high**

**Why it is big.** `FlatWizardNotifier.runCapture` alone is **481 lines** (`744`–`1224`) — a
triple-nested loop (filter → calibrate → frame) with validation, path prep, FITS write, history
recording and the truthful-status computation all inline. Around it sit ~35 one-line state
setters, the persistence hydrate/persist pair, and a second notifier
(`FlatCameraConfigNotifier`, `96`–`182`).

**Split plan** — `part` library, plus one behavior-preserving in-method decomposition.

| new file | moves | source lines |
|---|---|---|
| `flat_wizard/flat_camera_config.dart` | `flatCameraConfigProvider`, `FlatCameraConfigNotifier` | `82`–`182` |
| `flat_wizard/flat_output_paths.dart` | `prepareFlatOutputDirectory`, `validateRemoteFlatOutputDirectory`, and `_sanitizeComponent`/`_two`/`_fmtDate`/`_fmtStamp` **promoted from methods to library-private top-level functions** (they never touch `state`) | `41`–`75`, `1523`–`1541` |
| `flat_wizard/flat_wizard_settings_ops.dart` (`extension _FlatWizardSettingsOps on FlatWizardNotifier`) | mode setters, global-settings setters, `_hydrateGlobalSettings`, `_persistGlobalSettings`, `loadFiltersFromWheel`, `_remoteSuggestedExposure`, filter toggle/order/quick-select ops, all UI toggles, all one-line status/exposing/ADU setters, `reset` | `219`–`742`, `1543`–`1553` |
| `flat_wizard/flat_wizard_run.dart` (`extension _FlatWizardRun on FlatWizardNotifier`) | `runCapture`, `_buildFilterQueue`, `_prepareFiltersForRun`, `_setFinalStatus`, `moveFilterWheelAndWait`, `_recordFlatHistory` | `744`–`1521` |

`flat_wizard_provider.dart` then holds the provider (`24`–`27`), `_QueuedFilter` (`29`–`39`), the
`FlatWizardNotifier` class shell with its fields/constructor (`184`–`217`), and the `part`
directives (~90 lines).

Second step, inside `flat_wizard_run.dart` — split `runCapture` into three methods with the
existing local variables passed explicitly (nothing else changes):
1. `_FlatRunPlan? _validateAndPlanRun()` — everything from `760` to `882` (backend/camera/save-path
   validation, remote path validation, filter queue, run-mode snapshot, `flatCameraConfigProvider`
   resolve + `rangeKnown` check, post-resolve camera re-check, the committed `state = …` write,
   base save path + `prepareFlatOutputDirectory`). Returns a record carrying
   `cameraId, flatService, config, queue, baseSavePath, runMode, runTwilightMode, historyGain,
   createOutputLocally, db, profileId, brightnessTracker`; returns `null` when a `setErrorMessage`
   early-return already fired.
2. `Future<String?> _captureFilter(_QueuedFilter, _FlatRunPlan, FlatCancelToken)` — the loop body
   `890`–`1197`, returning the `haltError` string (or `null`) and setting `cancelled` via an out
   flag on the plan record.
3. `Future<({int saved, bool cancelled, bool halted, String? error})> _captureFrames(...)` — the
   inner frame loop `1049`–`1157`.
   Target: `runCapture` ≤ 60 lines, each helper ≤ 170.

---

### 1.4 `polar_alignment_provider.dart` — 1432 lines — risk **medium**

**Why it is big.** Five notifiers plus the history/remote layer in one file:
`PolarAlignmentStateNotifier` (`131`–`935`, **804 lines**), `PolarAlignmentConfigNotifier`
(`952`–`1097`), `PolarAlignmentUiState` + notifier (`1099`–`1245`),
`PolarAlignmentErrorHistoryNotifier` (`1256`–`1286`), the history providers +
remote fetch/poll (`1288`–`1386`), and `PolarAlignmentController` (`1400`–`1432`).

**Split plan** — one directory, `part` library. `polar_alignment_provider.dart` keeps imports,
`part` directives, the three exception classes (`20`–`56`), the state provider declaration
(`123`–`128`) and the `PolarAlignmentStateNotifier` class shell + fields/constructor
(`131`–`196`).

| new file | moves | source lines |
|---|---|---|
| `polar_alignment/polar_wire_decoding.dart` | `_wireInt`, `_wireDoubleOrNull`, `_decodeImageBytes` | `58`–`116` |
| `polar_alignment/polar_event_handling.dart` (`extension _PolarEvents on PolarAlignmentStateNotifier`) | `_bindToBackend`, `_handlePolarAlignmentEvent`, `_handleErrorUpdate`, `_handleStatusUpdate`, `_handleNativeComplete`, `_handleImageUpdate`, `_parsePhase` | `198`–`444` |
| `polar_alignment/polar_run_commands.dart` (`extension _PolarCommands`) | `startAlignment`, `startAllSkyAlignment`, `_startSerialized`, `_doStart`, `_throwIfBackendChanged`, `_resolveCameraCapabilities`, `stopAlignment`, `_doStop`, `completeAlignment`, `_doComplete`, `_saveResult`, `_saveHistoryOnce`, `reset` | `445`–`924` |
| `polar_alignment/polar_config_notifier.dart` | `polarAlignmentConfigProvider`, `polarAlignmentConfigSaveErrorProvider`, `PolarAlignmentConfigNotifier` | `937`–`1097` |
| `polar_alignment/polar_ui_state.dart` | `PolarAlignmentUiState`, `polarAlignmentUiStateProvider`, `PolarAlignmentUiStateNotifier`, `polarAlignmentErrorHistoryProvider`, `PolarAlignmentErrorHistoryNotifier` | `1099`–`1286` |
| `polar_alignment/polar_history.dart` | `polarAlignmentHistoryProvider`, `lastPolarAlignmentProvider`, `polarAlignmentHistoryStreamProvider`, `_pollRemotePolarHistory`, `_fetchRemotePolarHistory`, `_polarEntryFromRemote` | `1288`–`1386` |
| `polar_alignment/polar_controller.dart` | `polarAlignmentControllerProvider`, `PolarAlignmentController` | `1388`–`1432` |

`dispose()` (`925`–`930`) must stay on the class (it is an `@override`).

---

### 1.5 `profiles_provider.dart` — 1257 lines — risk **low**

**Why it is big.** A **635-line data model** (`EquipmentProfileModel`, `24`–`658`, with
`fromRow`, `toCompanion`, `copyWith`, `toInsertionCopy`, `getImageScale`) lives inside a provider
file, ahead of the actual providers.

**Split plan** — lowest-risk file in the set; do this one first as the pattern demonstrator.

| new file | moves | source lines |
|---|---|---|
| `profiles/equipment_profile_model.dart` | `EquipmentProfileModel` in full | `24`–`658` |
| `profiles/equipment_profiles_notifier.dart` | `EquipmentProfilesState`, `EquipmentProfilesNotifier`, `equipmentProfilesProvider` | `660`–`1145` |
| `profiles/profile_derived_providers.dart` | `activeEquipmentProfileProvider`, `equipmentProfileListProvider`, `opticalConfigProvider`, `profileFiltersProvider`, `sortedProfilesProvider` | `1147`–`1257` |

`profiles_provider.dart` keeps the imports, `final _log = Logger('ProfilesProvider')` (`22`) and
the three `part` directives (~25 lines).

**Do NOT move `EquipmentProfileModel` to `lib/src/models/`.** 107 files reference the symbol
(`grep -rl EquipmentProfileModel packages apps | wc -l` → 107) and `skotiq_core.dart:221`
exports `src/providers/profiles_provider.dart`. A `part` file keeps every one of those imports
byte-identical; a physical move to `models/` needs a barrel edit plus re-export gymnastics for
files that import `profiles_provider.dart` directly.

---

### 1.6 `scheduler_provider.dart` — 1247 lines — risk **medium**

**Why it is big.** Six unrelated concerns: the trigger stream, the executor sequence sink, the
candidate loader (a 330-line service class), config persistence, engine construction + auto-reeval,
status/decision notifiers, the 166-line readiness computation, and the remote snapshot.

**Split plan** — `part` library. `scheduler_provider.dart` keeps imports, `part` directives,
`schedulerTriggerStreamProvider` (`62`–`134`), `schedulerStatusProvider` /
`SchedulerStatusNotifier` / `currentSchedulerDecisionProvider` /
`CurrentSchedulerDecisionNotifier` / `schedulerPreviewDecisionProvider` (`915`–`1008`).

| new file | moves | source lines |
|---|---|---|
| `scheduler/scheduler_candidate_loader.dart` | `_LoaderTarget`, `SchedulerCandidateLoader`, `schedulerCandidateLoaderProvider` | `218`–`595` |
| `scheduler/scheduler_config.dart` | `SchedulerConfigStore`, `schedulerConfigStoreProvider`, `schedulerPersistedConfigProvider`, `schedulerConfigUserDirtyProvider`, `siteMinimumAltitudeDegProvider`, `integrationGoalsStreamProvider`, `targetConstraintsStreamProvider` | `596`–`679` |
| `scheduler/scheduler_engine_providers.dart` | `_ExecutorSequenceSink`, `schedulerEngineProvider`, `schedulerEngineReadyProvider`, `schedulerAutoReevalProvider` | `135`–`217`, `680`–`914` |
| `scheduler/scheduler_readiness.dart` | `schedulerStartReadinessProvider` | `1010`–`1175` |
| `scheduler/scheduler_remote_and_goals.dart` | `SchedulerRemoteSnapshot`, `schedulerRemoteSnapshotProvider`, `schedulerPreviewRankingProvider`, `allIntegrationGoalsProvider`, `integrationGoalProgressProvider` | `1176`–`1247` |

Callers to be aware of: `integrationGoalsStreamProvider`, `schedulerPreviewDecisionProvider` and
`targetConstraintsStreamProvider` are imported by name from `remote_sync_handler.dart:34-38`; the
`part` approach keeps that import working unchanged.

---

### 1.7 `transient_alert_provider.dart` — 1136 lines — risk **medium**

**Why it is big.** Four independent subsystems in one file: settings persistence
(`33`–`401`), the merged local+remote alert feed (`403`–`564`, one 160-line provider body),
JSON parsing helpers (`566`–`687`), alert-state persistence (`689`–`958`), and the observation
queue-flight provider (`960`–`1136`).

**Split plan** — `part` library, boundaries already clean:

| new file | moves | source lines |
|---|---|---|
| `transient_alerts/transient_alert_settings.dart` | `TransientAlertSettingsNotifier`, `transientAlertSettingsProvider` | `33`–`401` |
| `transient_alerts/transient_alert_feed.dart` | `activeTransientAlertsProvider` | `403`–`564` |
| `transient_alerts/transient_alert_parsing.dart` | `_mergeAlerts`, `_tryParseTransientAlertFromJson` and the remaining parse helpers | `566`–`687` |
| `transient_alerts/transient_alert_states.dart` | `TransientAlertStatesNotifier`, `transientAlertStatesProvider`, `unacknowledgedAlertCountProvider` | `689`–`958` |
| `transient_alerts/transient_queue_flights.dart` | `_transientQueueFlightsProvider` and its helpers | `960`–`1136` |

---

### 1.8 `settings_sections/app_settings_state.dart` — 1096 lines — risk **low**

**Why it is big.** A single value class with **151 `final` fields** (`grep -cP '^\s+final '` → 151)
and a **437-line `copyWith`** (`659`–`1096`). It is genuinely a wide config record; the width is
the product decision, not an accident.

**Split plan (surgical, behavior-preserving).** Move `copyWith` verbatim into a new part file
`settings_sections/app_settings_state_copy_with.dart` as
`extension AppSettingsStateCopyWith on AppSettingsState { … }`, added to the `part` list in
`settings_provider.dart` right after line 66. Same library ⇒ private members remain visible;
`state.copyWith(...)` at every call site resolves identically. Leaves the data class at ~658 lines
(fields + doc comments + constructor), which is the irreducible core.

Two checks the implementer owes before landing it:
1. `grep -rn "extends AppSettingsState\|implements AppSettingsState"` returns **nothing** today —
   confirm that is still true (extension methods are not virtual).
2. Confirm no call site invokes `copyWith` through a `dynamic` receiver (extension methods do not
   dispatch on `dynamic`). A repo-wide analyze after the move catches this.

Do **not** attempt to shard the 151 fields into nested sub-objects in this pass: 138 of them are
copyWith-able, 155 database keys read them in
`app_settings_stored_snapshot_mapping.dart`, 124 are listed in the remotable-key allow-set and
118 are assigned in `app_settings_remote_mapping.dart`. Restructuring the shape touches every
consumer and three round-trip tests; it is a separate, larger project (see §2.4).

---

## 2. DUPLICATION

### 2.1 Eleven copy-pasted device connect/retry notifiers — **canonical survivor: a new shared mixin**

`providers/equipment/` contains 11 state notifiers that each carry a byte-for-byte-equivalent
connect-with-retry state machine. Verified: `_connectWithRetry` appears in
`camera_state_provider.dart`, `mount_state_provider.dart`, `focuser_state_provider.dart`,
`filter_wheel_state_provider.dart`, `guider_state_provider.dart`, `rotator_state_provider.dart`,
`dome_state_provider.dart`, `weather_state_provider.dart`, `safety_monitor_state_provider.dart`,
`switch_state_provider.dart`, `cover_calibrator_state_provider.dart` — 11 files; `_isCurrentAttempt`
and the `preservedAutoReconnect` idiom in `setDisconnected` appear in the same 11.

Reference copy: `equipment/rotator_state_provider.dart:17`–`123` (~105 lines). The identical block is
`_retryAttempts`, `_connectionRevision`, `connect`, `_connectWithRetry`, `retryConnection`,
`clearError`, `disconnect`, `setConnecting`, `_setConnectingState`, `setConnected`,
`setDisconnected`, `_isCurrentConnection`, `_isCurrentAttempt`, `setAutoReconnect`, `setError`.
Only three things vary per device: the `DeviceService.connectX()` call, the
`DeviceService.disconnectX()` call, and the `XState()` constructor used by `setDisconnected`.

**Recommendation.** Add `equipment/device_connection_mixin.dart`:

```
mixin DeviceConnectionMixin<S extends DeviceStateBase> on StateNotifier<S> {
  Ref get connectionRef;
  Future<void> connectDevice(String deviceId);       // per-device DeviceService call
  Future<void> disconnectDevice();                   // per-device DeviceService call
  S freshDisconnectedState({required bool autoReconnectEnabled});
  // …the 15 shared members above, unchanged…
}
```
`DeviceStateBase` already effectively exists in `models/equipment/equipment_models.dart` (every
state has `connectionState`, `deviceId`, `deviceName`, `lastError`, `autoReconnectEnabled`,
`copyWith`, `clearError`); the mixin only needs those. Each of the 11 files drops to its
device-specific telemetry setters. **Removes ~1000 duplicated lines.** Effort: medium — the risk
is entirely in getting the generic bound right, and each file has existing tests.

### 2.2 Two device-type→notifier tables inside `remote_sync_handler.dart`, and they have diverged

`_parseDeviceType` (`remote_sync_handler.dart:1171-1202`) maps 11 device-type strings (including
`'switch'` / `'switch_'`) to `DeviceType`. `_applyDeviceDisconnectedFromSyncPayload`
(`:1081-1126`) re-implements the *same* string table inline, calling
`_readDeviceNotifier(reader, X).setDisconnected()` per case — and **omits the `switch` case
entirely** (`:1091-1125` covers camera/mount/focuser/filterwheel/guider/rotator/dome/weather/
safetymonitor/covercalibrator only). Consequence: a `Disconnected` equipment event or a
`RemoteSyncEventTypes.deviceDisconnected` sync payload for a **switch** device is silently dropped
on the slave, so the switch card keeps rendering as connected against a host that dropped it.

**Canonical survivor:** `_parseDeviceType` + `_readDeviceNotifier`. `_applyDeviceDisconnectedFromSyncPayload`
collapses to:
```
final parsed = _parseDeviceType(deviceType);
if (parsed == null) return;
_readDeviceNotifier(reader, parsed).setDisconnected();
```
That is a 45-line deletion **and** it fixes the switch gap. Effort: small.

### 2.3 `_clearLocalDeviceState` duplicates `resetAllEquipmentStateNotifiers`

`remote_sync_handler.dart:1349-1362` resets 9 device notifiers; `equipment/equipment_state_reset.dart:21-38`
(`resetAllEquipmentStateNotifiers`) resets 11 plus `deviceHeartbeatHealthProvider.clearAll()`.
The remote-sync copy omits `switch_` and (by its `includeGuider: false` default) the guider, and
never clears heartbeat health — so on a slave reconnect the switch card and the heartbeat health
map keep stale entries.

**Canonical survivor:** `resetAllEquipmentStateNotifiers`, extended to take the existing
`includeGuider` flag and a `clearHeartbeatHealth` flag. `_clearLocalDeviceState` deletes. Note the
signature difference: `resetAllEquipmentStateNotifiers` takes `Ref`, `_clearLocalDeviceState` takes
the `Object reader` (Ref *or* ProviderContainer) — the merged version must keep the
`Object reader` + `_read/_invalidate` shape so the headless `ProviderContainer` path still works.
Effort: small.

### 2.4 The `AppSettings` field list is enumerated four times

Same 150-ish settings are re-listed in four hand-maintained places, all inside my scope:
- `settings_sections/app_settings_state.dart` — 151 field declarations + 138 `copyWith` params
- `settings_sections/app_settings_stored_snapshot_mapping.dart` — 155 `allSettings['…']` reads
- `settings_sections/app_settings_remote_mapping.dart` — 118 `field: remote.x` assignments
- `settings_sections/app_settings_partial_persistence_mapping.dart` — a 124-entry
  `_remotableSettingKeys` allow-set whose own doc comment says *"keep this in lock-step with
  `_toRemoteSettings`. A key added to the wire model must be added here, or remote saves of it
  will throw."*

**This is guarded, not unguarded** — `test/providers/settings_remote_coverage_test.dart`,
`app_settings_stored_roundtrip_test.dart` and `settings_sync_test.dart` exist and pin the
relationships, which is why I am **not** proposing a mechanical merge in this pass.
The durable fix is a single field registry (one `const List<SettingSpec>` carrying
name / db-key / wire-getter / default / remotable-flag) that the four mappings are derived from,
or `build_runner` codegen. Effort: **large**; schedule it as its own project, not as part of a
release-tightening pass.

### 2.5 The `isNetworkBackend ? remotePoll : localDaoWatch` provider shape

Repeated verbatim across `database_provider.dart` (≥8 sites: `:86`, `:95`, `:104`, `:113`, `:124`,
`:133`, …), `dark_library_provider.dart:44/53/64`, `observation_log_provider.dart:32/41`,
`polar_alignment_provider.dart:1294/1312/1327`. The *polling* half is already correctly shared via
`utils/resilient_poll_stream.dart::resilientDistinctPoll`, so this is only the outer branch. A
`Stream<T> remoteOrLocal<T>(Ref, {required Stream<T> Function(NetworkBackend), required Stream<T> Function()})`
helper collapses ~15 five-line branches. Low value, low risk — bundle it with whichever file is
being split anyway. Effort: small.

---

## 3. CROSS-PACKAGE / CROSS-LAYER DUPLICATION SUSPECTS

One line each; a dedicated cross-cutting agent should chase these.

- **Slave telemetry mirror vs host event handler.** `remote_sync_handler.dart:286-473`
  (`_applyEquipmentTelemetry`) and `services/device_service/event_handling.dart` (967 lines) handle
  the *same* event-type strings (`MountPositionChanged` at `:135`, `FocuserTemperatureChanged` at
  `:261`, `RotatorMoveCompleted` at `:299`, …) and write to the *same* notifiers — one for the host
  path, one for the slave path.
- **Device-type string table, 5 more copies.** `services/device_service/event_handling.dart:443`,
  `:521`, `:704`, `:837` each re-implement the `case 'filterwheel':` mapping that
  `remote_sync_handler.dart:1171` owns.
- **Path-component sanitizer, two divergent versions.**
  `flat_wizard_provider.dart:1526` (`_sanitizeComponent`, returns `'unnamed'` when empty, no
  `.`/`..` guard) vs `services/imaging_service.dart:1290` (`_sanitizePathComponent`, returns `'_'`,
  explicitly rejects `.` and `..`).
- **JSON wire coercion helpers.** `polar_alignment_provider.dart:59` `_wireInt` / `:68`
  `_wireDoubleOrNull` vs `apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart:2248`
  `_asDouble` — same "JSON collapses whole numbers to int" problem, solved twice.
- **Sequencer-state string parser.** `remote_sync_handler.dart:1327` `_mapSequencerState` vs
  `apps/mobile/lib/services/voice_control_service.dart:197` (`case 'stopping':`) — both map host
  state strings to app state.
- **Weather threshold evaluation across the language boundary.**
  `services/weather/weather_threshold_evaluator.dart` (Dart) vs the Rust
  `safety_fail_mode_no_data_resolution` in `native/skotiq_native/sequencer/src/lib.rs`; kept in
  sync only by a hand-written parity test pair (documented at
  `weather_safety_provider.dart:31-56`).
- **`AppSettings` shape, fifth and sixth copies.** The four in §2.4 plus the wire model in
  `models/settings/app_settings.dart` and the headless settings handler in
  `apps/desktop/lib/headless_api/handlers/`.

---

## 4. DEAD CODE

Method used: for every top-level `final …Provider` and every top-level class in scope, count
*total* whole-word occurrences across `packages/ apps/ tools/ lib/ server/` (`.dart` only).
A total of **1** means the definition is the only occurrence anywhere in the repo, tests included.
Riverpod providers cannot be looked up by string, and none of these appear in
`apps/desktop/lib/headless_api/`, so there is no reflection/route escape hatch.

### 4.1 Providers with zero references (27)

All confirmed `TOTAL=1`. Those inside my scope's own files:

| symbol | file |
|---|---|
| `isWeatherSafeProvider` | `weather_safety_provider.dart:1690` |
| `schedulerPreviewRankingProvider` | `scheduler_provider.dart:1222` |
| `themeSettingsProvider` | `settings_provider.dart:328` |
| `currentAlertLevelProvider` | `weather_providers.dart` |
| `weatherSettingsStreamProvider` | `weather_providers.dart` |
| `meridianFlipEventStreamProvider` | `meridian_flip_provider.dart` |
| `darkFrameEntriesProvider`, `biasFrameEntriesProvider`, `darkTempToleranceProvider` | `dark_library_provider.dart` |
| `filterOffsetForFilterProvider`, `availableFiltersProvider` | `filter_offset_provider.dart` |
| `sessionServiceStatusProvider`, `isSessionActiveProvider` | `session_provider.dart` |
| `shouldShowFirstNightProvider`, `tutorialKeyRegistry` | `tutorial_provider.dart` |
| `hasExplicitBackendSelectionProvider` | `device_backend_selection_provider.dart` |
| `llmAssistantConfiguredProvider` | `conversational_builder_provider.dart` |
| `isRecoveringProvider` | `recovery_provider.dart` |
| `annotationOpacityProvider` | `annotation_settings_provider.dart` |
| `lastEventProvider` | `event_provider.dart` |
| `filteredObservationLogsProvider` | `observation_log_provider.dart` |
| `transformForFilterProvider` | `photometric_transform_provider.dart` |
| `pushNotificationStreamProvider` | `push_notification_provider.dart` |
| `remoteFocusProfileDataProvider` | `focus_model_profile_data_provider.dart` |
| `liveStackingFrameCountProvider` | `live_stacking_provider.dart` |
| `activeFilterCountProvider` | `suggestion_filter_provider.dart` |
| `currentScienceFrameProductsProvider` | `science_provider/session_products.dart` |

Caveat for the implementer: `tutorialKeyRegistry` returns a `TutorialKeyRegistry()` — the class
itself is referenced elsewhere, only this provider wrapper is orphaned. Same shape for
`themeSettingsProvider` (its `ThemeSettingsNotifier` is live).

### 4.2 Methods with zero callers (11)

Confirmed `TOTAL=1` whole-word occurrences repo-wide:

| symbol | location |
|---|---|
| `WeatherSafetyNotifier.evaluateNow` | `weather_safety_provider.dart:1657` — **also removes the unbounded busy-wait, see §5.1** |
| `PolarAlignmentConfigNotifier.applyQuickStart` | `polar_alignment_provider.dart:1084` |
| `PolarAlignmentConfigNotifier.applyHighPrecision` | `polar_alignment_provider.dart:1087` |
| `PolarAlignmentController.startWithConfig` | `polar_alignment_provider.dart:1412` |
| `FlatWizardNotifier.reorderFilters` | `flat_wizard_provider.dart:489` |
| `FlatWizardNotifier.clearCancelRequest` | `flat_wizard_provider.dart:607` |
| `FlatWizardNotifier.toggleExposureTimeline` | `flat_wizard_provider.dart:559` |
| `FlatWizardNotifier.toggleSkyBrightness` | `flat_wizard_provider.dart:563` |
| `FlatWizardNotifier.toggleHistogramOverlay` | `flat_wizard_provider.dart:571` |
| `EquipmentProfilesNotifier.exportAllProfiles` | `profiles_provider.dart:1126` (the service it wraps, `ProfileService.exportAllProfilesToJson` at `services/profile_service.dart:518`, IS used by `exportAllProfilesToFile:547`) |
| `EquipmentProfileModel.getImageScale` | `profiles_provider.dart:590` |
| `TransientAlertStatesNotifier.markObserved` | `transient_alert_provider.dart:833` — checked `.dart`/`.rs`/`.js`/`.html` across `packages apps native`; only the definition |

The three `FlatWizardNotifier` toggles being dead implies their backing
`FlatWizardState` fields (`showExposureTimeline` / `showSkyBrightness` / `showHistogramOverlay`)
are write-only — the model lives outside my scope; flag it to the models mapper.

### 4.3 Production-dead but test-live (do NOT delete blind)

`WeatherSafetyNotifier.forceEvaluation` (`weather_safety_provider.dart:1647`) has **zero**
production callers and 8 test call sites
(`weather_safety_monitoring_disclosure_test.dart:117`, `weather_safety_verdict_push_test.dart:186/212/244/270`,
`weather_auto_resume_authority_test.dart:159/173/180`). It is a test seam, not dead code; leave it,
or mark it `@visibleForTesting`.

---

## 5. PERF RISKS

### 5.1 The 5-minute weather evaluation actually runs every 5 seconds, and rebuilds the scheduler readiness tree each time — **medium**

Chain, all evidenced:
1. `services/device_service.dart:144` — `environmentPollInterval = Duration(seconds: 5)`, driving
   `services/device_service/connections.dart:981` `Timer.periodic(...)`.
2. Each tick calls `weatherStateProvider.notifier.updateConditions(...)`
   (`connections.dart:1038`), and `equipment/weather_state_provider.dart:125-152` **always** writes
   `lastUpdated: DateTime.now()` — so the state object changes every 5 s even when every sensor
   value is identical. `equipment/safety_monitor_state_provider.dart:128` does the same with
   `lastChecked: DateTime.now()`.
3. `weather_safety_provider.dart:478-483` — `_ref.listen<WeatherState>` and
   `_ref.listen<SafetyMonitorState>` fire, calling `_scheduleSourceChangeEvaluation()`
   (250 ms debounce, `:641-648`).
4. `_evaluateAllSourcesAsync` (`:655`) awaits two providers, runs the full evaluation, and at
   `:859-877` writes a new state with `lastEvaluation: DateTime.now()`, then at `:910-922` issues
   `backend.sequencerUpdateWeatherVerdict(...)` — an FFI/HTTP round-trip.
5. `WeatherSafetyState` has **no `operator ==`** (`grep 'operator ==' weather_safety_provider.dart`
   → nothing), and `lastEvaluation` changes anyway, so every watcher rebuilds. There are 8
   `ref.watch(weatherSafetyProvider)` sites; 7 are live (the 8th is the dead
   `isWeatherSafeProvider`, §4.1), and one of the 7 is `scheduler_provider.dart:1072` inside
   `schedulerStartReadinessProvider`.
6. `SchedulerStartReadiness` also has **no `operator ==`** (`models/scheduler/scheduler_readiness.dart:62-125`),
   so its own watchers (`screens/planner/widgets/scheduler_tab_content/decision_panel.dart:39`)
   rebuild on every one of those ticks too.

Net: with a weather device *or* safety monitor connected, a full safety evaluation + one executor
round-trip + a readiness-panel rebuild happen every ~5 s all night, on a path documented and
constant-named for a 5-minute cadence (`_evaluationInterval = Duration(minutes: 5)`, `:414`).

Cheapest fixes, in order: (a) make `WeatherState.updateConditions` skip the write when every value
is unchanged (or exclude `lastUpdated` from what listeners key on); (b) add `operator ==`/`hashCode`
to `SchedulerStartReadiness` and `SchedulerReadinessIssue`; (c) have
`_scheduleSourceChangeEvaluation` compare the *safety-relevant* fields before scheduling.

### 5.2 Remote companion re-hydration is ~20 network round-trips every 30 s — **medium**

`remote_session_sync_provider.dart:73` — `Timer.periodic(const Duration(seconds: 30))` calls
`hydrateRemoteSessionState`. One pass (`remote_sync_handler.dart:1412-1513`) issues
`sequencerGetStatus` (`:1417`), `getConnectedDevices` (`:1421`), five parallel device-status GETs
(`:1584-1590`), `cameraGetLastImage` (`:1444` → `:995`), `getOpenEditorSequence` (`:872`) and the
PHD2 status poll (`:1372`) — then invalidates a dozen-plus further providers that are themselves
network-backed in `NetworkBackend` mode (`:1462`, `:1468`, `:1477`, `:1479-1480`, `:1487`,
`:1494-1496`, `:1503`, `:1511-1512`). On a phone this is a continuous ~20-request burst twice a
minute. Suggested: split hydration into a "cheap 30 s" set (status + devices) and an "expensive
on-reconnect/on-mutation-only" set; the mutation events at `:619-663` already cover most of the
expensive half.

### 5.3 Adaptive-conditions push copies the whole session image list every 30 s — **low**

`weather_safety_provider.dart:1387-1392` — `_currentHfrValues()` reads `sessionImagesProvider` and
allocates a full `List<double?>` of every image in the session, called from `_pushAdaptiveConditions`
on the `_adaptiveConditionsPushInterval = Duration(seconds: 30)` timer (`:425`, `:1177-1190`). O(n)
in frames captured tonight, growing all night, when the consumer only wants recent HFR. Low impact
(hundreds of elements), but it is free to bound with `.take(n)`.

### 5.4 `sortedProfilesProvider` copies + sorts on each recompute — **low**

`profiles_provider.dart:1248-1257` — `List.from(profiles)` then `sort`. It is a plain `Provider`
so it only recomputes when `equipmentProfileListProvider` changes, and profile counts are small.
Listed only so a verifier does not re-find it; not worth acting on.

---

## 6. RELIABILITY RISKS

### 6.1 Unbounded busy-wait in `WeatherSafetyNotifier.evaluateNow`

`weather_safety_provider.dart:1663-1665`:
```
while (mounted && (_evaluationInFlight || _evaluationPending)) {
  await Future<void>.delayed(const Duration(milliseconds: 5));
}
```
No iteration cap and no deadline. `_evaluationInFlight` is cleared in a `finally` (`:682`), so the
realistic hang requires `weatherSettingsDataProvider.future` / `appSettingsProvider.future`
(`:663-666`) never completing — possible on a `NetworkBackend` whose settings fetch stalls. It also
spins 200 times/second while waiting. **This method has zero callers (§4.2)** — deleting it is the
correct fix; if it is kept, bound it with a deadline.

### 6.2 Flat-wizard run reads live settings mid-run, defeating its own snapshot invariant

`flat_wizard_provider.dart:814-823` deliberately snapshots `state.mode` / `state.twilightMode`
because *"The tab bar stays intentionally tappable mid-run so the operator can browse, which flips
`state.mode` live."* The same live-read hazard is left open for the rest of the settings — none of
`updateGlobalSettings` (`:231`), `setHistogramTarget` (`:237`), `setTolerance` (`:247`),
`setFrameCount` (`:257`), `setSavePath` (`:267`) has the `_running` guard that
`loadFiltersFromWheel` (`:366`) and `reset` (`:1547`) do, while `runCapture` reads
`state.globalSettings` **inside** the per-filter loop:
- `:935` `state.globalSettings.histogramTarget` (target ADU for the *next* filter)
- `:1032` `state.globalSettings.createFilterSubfolders` (output layout changes mid-run)
- `:1044` `state.globalSettings.frameCount` (per-filter frame target, and the `savedCount < frameCount`
  comparison at `:1165` that decides `partial` vs `complete`)
- `:1484` `state.globalSettings.histogramTarget` written into the **flat-history record**, so a
  mid-run edit misrecords the calibration the library learns from.

Fix: extend the existing run snapshot at `:822` to cover `globalSettings` and read the snapshot
throughout the loop (mirrors the `runMode`/`runTwilightMode` pattern already there).

### 6.3 `_readDeviceNotifier` / `_readDeviceState` return `dynamic`

`remote_sync_handler.dart:1204` and `:1232` are declared `dynamic _readDeviceNotifier(...)` /
`dynamic _readDeviceState(...)`, and their results are used all over the mirror
(`:681`, `:698`, `:1093`-`1123`, `:1264-1266`, `:1350-1361`, `:1368`, `:1395-1399`). Every method
name on those notifiers is unchecked at compile time; a rename in any of the 11 equipment notifiers
becomes a runtime `NoSuchMethodError` on the slave's event pump instead of an analyzer error.
`_isDeviceAlreadyConnected` (`:1259-1267`) reads `.connectionState` and `.deviceId` off `dynamic`
for the same reason. Fix alongside §2.1: give the 11 notifiers a shared base/mixin type and return
that instead of `dynamic`.

### 6.4 Same `dynamic` hole in the flat-history write

`flat_wizard_provider.dart:1456-1467` — `_recordFlatHistory({required dynamic backend, required dynamic db, …})`
then calls `db.flatHistoryDao.recordCalibration(...)` (`:1491`) unchecked. The whole body is wrapped
in `catch (e, st)` (`:1501`) which downgrades a *typo* to a user-facing "the flat library did not
record this calibration" warning rather than a build failure. Type the parameters
(`SkotiqBackend` / `AppDatabase`).

### 6.5 `_hasAnythingToSafe` swallows every error into "enforce anyway"

`weather_safety_provider.dart:1075-1079` — `try { return await …isArmed(); } catch (_) { return true; }`.
The fail-safe direction is correct (assume something is running), but it also means a persistently
broken `secondaryRigControllerProvider` makes the "nothing to safe" disclosure
(`_announceNothingToSafe`, `:1084`) unreachable forever, and `_enforceSafetyActions` will keep
invoking `SafeRigService.safeTheRig` against a rig with nothing connected — the exact false-CRITICAL
pattern the surrounding comment (`:1001-1011`) was written to stop. Log the caught error at least
once per episode.

### 6.6 Backend-swap during flat capture is unguarded

`flat_wizard_provider.dart:760` reads `backendProvider` **once** at run start and holds that
`backend` for the whole run (`saveFitsFromLastCapture` at `:1128`, `recordFlat` at `:1480`).
`PolarAlignmentStateNotifier` treats exactly this situation as a hard error
(`PolarAlignmentBackendChangedException`, `polar_alignment_provider.dart:49`, enforced at
`:212-233` and `:615`), and `WeatherSafetyNotifier` re-checks authority mid-flight
(`_backendNotifier.isCurrentBackend`, `weather_safety_provider.dart:1419-1423`). The flat wizard has
neither: swapping local↔network mid-run would keep writing FITS through the retired backend. Adopt
the polar-alignment generation guard.

---

## 7. WHAT I WOULD DO FIRST

1. `remote_sync_handler.dart:1081-1126` — collapse the duplicate device-type table onto
   `_parseDeviceType`; fixes the dropped switch-disconnect on slaves. ~45 lines, small.
2. Delete the 27 zero-reference providers (§4.1) and the 11 zero-caller methods (§4.2), including
   `evaluateNow` and its busy-wait (§6.1).
3. Snapshot `globalSettings` at flat-run start (§6.2) — a truthfulness bug in the flat library.
4. Split `profiles_provider.dart` (§1.5) as the pattern demonstrator, then
   `weather_safety_provider.dart` (§1.1) and `remote_sync_handler.dart` (§1.2).
5. Add `operator ==`/`hashCode` to `SchedulerStartReadiness`/`SchedulerReadinessIssue` and stop
   `WeatherState.updateConditions` writing an unchanged state (§5.1).
6. Extract `DeviceConnectionMixin` for the 11 equipment notifiers (§2.1) — ~1000 lines removed and
   it is the prerequisite for killing the `dynamic` returns in §6.3.
7. Merge `_clearLocalDeviceState` into `resetAllEquipmentStateNotifiers` (§2.3).
8. Split the remaining oversized files (§1.3, §1.4, §1.6, §1.7) and lift `copyWith` out of
   `app_settings_state.dart` (§1.8).

Explicitly **not** recommended in this pass: restructuring the `AppSettings` field list (§2.4) —
it is test-guarded and needs its own project.
