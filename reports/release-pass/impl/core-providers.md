# core-providers implementation log

Baseline: b07d91c9d. Scope: `packages/skotiq_core/lib/src/providers/**` minus `sequence/`.
No predecessor work existed in scope (only `database_provider.dart`, which is another agent's
wire-codec dedup — untouched here).

## Item 1 — DEDUP duplicate device-type table (remote_sync_handler)

Failing test written first: `test/providers/remote_sync_device_type_test.dart` (3 tests).
Against baseline all 3 failed — the switch card stayed `connected` after both an equipment
`Disconnected` event and a `device_disconnected` sync payload, because
`_applyDeviceDisconnectedFromSyncPayload` re-implemented the type table without the `switch` case.

Fix: the 36-line inline switch collapses onto `_parseDeviceType` + `_readDeviceNotifier`.

Result: `flutter test test/providers/remote_sync_device_type_test.dart
test/providers/remote_sync_handler_test.dart` → 14 tests, all passed.

## Item 6 — merge `_clearLocalDeviceState` into `resetAllEquipmentStateNotifiers`

Failing test written first: `test/providers/equipment_state_reset_test.dart`, group
`slave reconnect hydration`. Against baseline it failed:
`Expected disconnected / Actual connected` for the switch card after
`hydrateRemoteSessionState` — the remote-sync copy reset only 9 device notifiers and never
cleared heartbeat health.

Fix: `resetAllEquipmentStateNotifiers` now takes `Object reader` (Ref *or* ProviderContainer,
so the headless container path still works) plus `includeGuider` / `clearHeartbeatHealth`
flags; `_clearLocalDeviceState` deleted and its one call site passes `includeGuider: false`.
The `Ref`/`ProviderContainer` narrowing itself was duplicated, so it moved to a new
`providers/provider_reader.dart` (`readProvider` / `invalidateProvider`); `remote_sync_handler`'s
`_read`/`_invalidate` now delegate to it, keeping their ~50 call sites unchanged.

Result: `flutter test test/providers/equipment_state_reset_test.dart
test/providers/remote_sync_device_type_test.dart test/providers/remote_sync_handler_test.dart
test/providers/remote_phd2_connect_test.dart test/providers/remote_session_sync_test.dart`
→ 25 tests, all passed.

## Item 3 — snapshot `globalSettings` at flat-run start

Failing test written first: `test/providers/flat_wizard_run_settings_snapshot_test.dart` (2 tests).
Against baseline both failed:
- frame-count: `Expected: <6> Actual: <4>` — an edit landing during filter 1 shrank filter 2's
  frame target.
- histogram target: `Expected: <50> Actual: <20.0>` — flat history recorded a target the frames
  were never shot at, so the library learns from a number that never happened.

Fix: `runCapture` takes one `runSettings = state.globalSettings` snapshot at the top of its try
(mirroring the existing `runMode`/`runTwilightMode` pattern) and every read inside the run uses
it — service construction, save path, binning, date/filter subfolders, target ADU, tolerance,
min/max exposure, frame count. `_recordFlatHistory` now takes `histogramTarget` rather than
re-reading live state.

Result: `flutter test` over all 7 `flat_wizard_*` provider test files → 36 tests, all passed.

## Item 4 — stop the idle 5-second churn

Failing tests written first: `test/providers/weather_safety_idle_churn_test.dart`.
Against baseline: `Unexpected calls: MockBackend.sequencerUpdateWeatherVerdict({unsafeOverride:
false})` on both the weather and safety-monitor cases — three identical polls produced three full
safety evaluations and three FFI verdict pushes.

**Deviation from the work order, deliberately.** It proposed making
`WeatherState.updateConditions` skip the write when values are unchanged. That would freeze
`lastUpdated`, which `readHardwareWeatherSource` (`weather_safety_provider.dart:208`) feeds to
`_isStaleReading` with a 5-minute budget — a sensor reporting steady values for five minutes would
be declared STALE and fail closed, aborting the run. The equipment card also renders the reading's
age from it. So the timestamp still advances (it is the truth about freshness) and the *listeners*
were gated instead: the two `_ref.listen` callbacks skip scheduling when the new state differs from
the old ONLY in `lastUpdated`/`lastChecked` (`previous.copyWith(lastUpdated: next.lastUpdated) ==
next`). Any other field difference still evaluates immediately, and the stale transition is
time-based, which the 5-minute periodic timer already owns.

`operator ==`/`hashCode` added to `SchedulerStartReadiness` and `SchedulerReadinessIssue` as
specified. Note this file is `lib/src/models/scheduler/scheduler_readiness.dart`, outside the
batch's scope path; the item named it explicitly, the change is purely additive, and the file was
unmodified from baseline when touched.

Result: `weather_safety_idle_churn_test.dart` 5/5 passed (including 'a real weather change still
re-pushes the verdict', which guards against over-suppressing). Weather + scheduler regression set
(11 files) → 43 tests, all passed.

## Item 2 — dead code

Every symbol re-proved fresh: whole-word count across `packages apps tools` for `*.dart`, plus a
second sweep over `*.rs/*.js/*.html/*.json/*.yaml/*.md` for string-based lookups.

**27 providers: all confirmed TOTAL=1** (definition is the only occurrence repo-wide, tests
included) and zero non-Dart references. All deleted. Follow-on dead code removed with them:
`_decodeTransformFitData` (only caller was `transformForFilterProvider`) and five now-unused
imports.

**10 of the 11 methods confirmed TOTAL=1** and deleted: `applyQuickStart`, `applyHighPrecision`,
`startWithConfig`, `reorderFilters`, `clearCancelRequest`, `toggleExposureTimeline`,
`toggleSkyBrightness`, `toggleHistogramOverlay`, `exportAllProfiles`, `getImageScale`,
`markObserved`.

`forceEvaluation` kept as instructed (test seam, 16 occurrences).

Newly orphaned by these deletions and NOT removed (outside the enumerated item, flagged for a
follow-up): the `TutorialKeyRegistry` class in `tutorial_provider.dart` — its only reference was
the deleted `tutorialKeyRegistry` provider.

Result: `flutter analyze lib test` on skotiq_core → clean (the 2 remaining infos are
pre-existing `deprecated_member_use` in `test/database/restore_clears_recovery_marker_test.dart`).
Full `flutter test` on skotiq_core → **5655 passed, 4 skipped, 0 failed**.
`flutter analyze lib` on skotiq_app and apps/desktop → no errors or warnings.

### FALSE POSITIVE: `WeatherSafetyNotifier.evaluateNow`

The item said to delete it. Fresh re-proof found a live caller:
`apps/desktop/lib/headless_api/handlers/weather_handlers.dart:330` awaits it so
`PUT /api/weather/settings` cannot answer "updated" while `safety/status` still reports the
previous verdict — exactly the headless-route escape hatch the DELETE rule warns about. Not
deleted.

Its unbounded busy-wait (§6.1) is real and now matters more, so it was BOUNDED instead. Failing
test first: `test/providers/weather_evaluate_now_deadline_test.dart` with a settings stream that
never emits — against baseline the test hung and was killed by the 20 s harness timeout
(`TimeoutException after 0:00:20`). Fixed with a deadline (`_evaluateNowTimeout = 10 s`, injectable
per call) and a 25 ms poll instead of a 5 ms spin. Test passes in <1 s.

## Item 5 — device connection type / mixin

**Done: the shared TYPE, which is what kills the `dynamic` hole (§6.3).** New
`equipment/device_connection_notifier.dart` declares `DeviceConnectionNotifier`
(`connectionState`, `deviceId`, `setConnecting`, `setConnected`, `setDisconnected`). All 11
equipment notifiers now `implements` it (plus two one-line getters each). `_readDeviceNotifier`
returns `DeviceConnectionNotifier` instead of `dynamic`; `_readDeviceState` is **deleted** —
`_isDeviceAlreadyConnected` reads the notifier, and the one filter-wheel state read now uses the
typed `filterWheelStateProvider` directly. `remote_sync_handler.dart` has no `dynamic` left.

**Not done: hoisting the ~1000 duplicated lines of the connect/retry machine.** A mechanical
normalized-hash diff of the `connect` + `_connectWithRetry` block across all 11 shows 8 identical
and **3 genuinely divergent**:
- `filter_wheel` deliberately does NOT call `setConnected()` in `_connectWithRetry`
  (`DeviceService.connectFilterWheel` owns that, plus filter-name sync);
- `guider.connect` carries a `deviceName` through the retry (pinned by
  `guider_connect_keeps_friendly_name_test.dart`);
- `mount` stops/starts position polling inside `setConnecting`/`setConnected`/`setDisconnected`
  and its `disconnect` restarts polling on a throw.
Further divergence outside that block: `camera.disconnect` guards on
`deviceId == null && deviceName == null`; `focuser.setConnected` takes four extra named params;
`switch`/`weather` `_setConnectingState` pass `clearError: true` while `camera`/`rotator`
deliberately preserve `lastError` across Connecting.
A single mixin would need per-device hooks for the connect call, the disconnect call, the
disconnect guard, the fresh-state constructor, connecting/connected side effects, the
clearError-on-connecting policy, `deviceName` threading, plus `copyWith` hooks for two error
writes — which is most of the duplicated volume back as hook surface, on eleven safety-relevant
connect paths, with no way to prove behavior preservation beyond the existing tests. Recorded as
not-done rather than landed on a guess.

Result: `flutter analyze lib` on skotiq_core → No issues found. Full `flutter test` →
5655 passed, 4 skipped, 0 failed.
