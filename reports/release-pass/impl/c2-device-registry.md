# C2 — device-registry

Topic: the device-registry collapse (Wave A adjudication item 1). Baseline `b07d91c9d`
plus the C1 tree. Behaviour-preserving consolidation only.

## Scope decision, up front

The map named two different things "device registry". Only one of them was mine to do:

1. **The six unpopulatable bridge registries** (`native_rotators`, `native_domes`,
   `native_weather`, `native_safety_monitors`, `native_switches`,
   `native_cover_calibrators`) + the six unimplemented `Native*` traits.
   **OFF LIMITS** — `RELEASE-PASS-2026-08-11.md` § "Owner decisions" lists them verbatim
   ("Six unimplemented `Native*` traits + six unpopulatable bridge registries (a whole
   unreachable device backend)"). Not touched, not even the dispatch branches.

2. **`DeviceManager.devices` vs `AppState.devices`** (cross-cutting Cluster 3).
   **BLOCKED, not done** — see below. The collapse is not behaviour-preserving; it *is*
   the PHD2 cry-wolf bug fix, which adjudication item 5 routes to a failing-test-first bug
   batch, not to a refactor wave.

3. **The Dart device-type tables** — the C1 `core-services-devices` batch explicitly
   deferred the `DeviceTypeRegistry` consolidation (`impl/core-services-devices.md`,
   "Left untouched"), and its consumers span three packages, so it lands here. This is
   what was actually consolidated.

## What was consolidated

New canonical module: `packages/skotiq_core/lib/src/providers/equipment/device_type_registry.dart`
(exported from the `skotiq_core` barrel), carrying three tables:

| symbol | replaces | call sites re-pointed |
|---|---|---|
| `deviceTypeFromWireName(String)` | `remote_sync_handler._parseDeviceType` + the four eleven-case wire switches in `device_service/event_handling.dart` | 4 in remote_sync_handler, 4 in event_handling |
| `readDeviceConnectionNotifier(reader, type)` | `remote_sync_handler._readDeviceNotifier` + the per-type `_ref.read(<x>StateProvider.notifier)` legs of the same four switches | 11 in remote_sync_handler, 4 in event_handling |
| `readDeviceSlot(reader, type)` | `connections._slotDeviceIdFor`, `connection_lifecycle._connectedDeviceIdFor` / `._connectionStateFor`, `device_row_item._isDeviceConnected`, and the eight per-type id/connected helpers | 5 files |

Retired copies, with fresh repo-wide proof (`grep -rn … packages apps tools`, minus
`target/`, `build/`, `graphify-out/`):

- `remote_sync_handler._parseDeviceType`, `._readDeviceNotifier` — deleted; zero hits left
  outside a comment in the new test.
- `event_handling.dart`: `_applyDeviceConnected` (62 lines → 8), `_applyDeviceConnecting`
  (62 → 7), `_handleDeviceError`'s switch (49 → 12), `_handleDeviceDisconnected`'s switch
  (114 → 45, keeping every per-type extra).
- `connections._slotDeviceIdFor` (25 → 2).
- `connection_lifecycle._connectedDeviceIdFor` (25 → 2), `._connectionStateFor` (25 → 2).
- `device_row_item._isDeviceConnected` (46 → 4).
- `_getCameraDeviceId`, `_getFocuserDeviceId`, `_getRotatorDeviceId`,
  `_getFilterWheelDeviceId`, `_getGuiderDeviceId`, `_isStillConnectedToFocuser`,
  `_isStillConnectedToFilterWheel`, `_isStillConnectedToRotator` — bodies collapsed onto
  two canonical helpers (`_connectedDeviceIdFor`, `_isStillConnectedTo`) in
  `connections.dart`. The four `Future<String?>` signatures were KEPT: ~20 call sites
  `await` them, and changing the signature is not the topic.

Supporting edits:

- `DeviceConnectionNotifier` gained `void setError(Object error)`. All eleven notifiers
  already declared exactly that signature (verified one by one); each got the `@override`
  the `annotate_overrides` lint requires. Repo-wide there are exactly eleven implementors
  and no test double declares the members (they use `noSuchMethod`), so widening the
  interface is compile-time only.
- `readProvider` now also narrows a `WidgetRef` (`device_row_item` holds one). `Ref` and
  `ProviderContainer` behaviour is untouched; `invalidateProvider` was NOT widened and
  keeps its original message.

## The one real divergence found (and preserved)

Reading a slot through the **notifier** (`notifier.deviceId`) and through the **state
object** (`ref.read(provider).deviceId`) return the same value in production but are not
substitutable under test. Several widget suites install a fake that
`implements <X>StateNotifier` with a `noSuchMethod` body and publishes honest snapshots —
its getters throw. The first cut of this batch routed every read through the notifier and
`skotiq_app/test/screens/equipment/discovery_toast_currency_test.dart` failed with
`Class '_FakeCameraNotifier' has no instance getter 'connectionState'`.

So the registry deliberately carries **two** accessors, not one: `readDeviceSlot` for
callers that ask, `readDeviceConnectionNotifier` for callers that drive. Every call site
kept the object its retired copy read. The library doc says this, and
`device_type_registry_test.dart` pins it with a notifier whose getters throw — collapsing
the two accessors fails that test.

## Left alone, and why (not consolidated)

- `DeviceService._disconnectForType` (`connections.dart`) — eleven cases dispatching to
  eleven *distinct* disconnect flows (`_disconnectCamera`, …), not a uniform accessor.
  Same shape, different content; folding it into the registry buys nothing.
- `DeviceReconnectCoordinator`'s per-type `connect(deviceId, maxRetries: 1)` switch —
  `connect` is not on `DeviceConnectionNotifier` because its signature genuinely varies
  (the guider carries a friendly name through its retry). That is the pre-existing,
  documented reason the interface is narrow; unchanged.
- `DeviceTypeDisplayExtension.displayName`, `device_heartbeat_router`'s label switch, and
  `connection_diagnostic.dart`'s label table — human-facing strings that deliberately
  disagree ("Guider" vs "guide camera", "Weather" vs "weather station"). Unifying them
  would change user-visible text.
- `NetworkBackend._tryParseCachedDeviceType` (`network_backend/device_operations.dart`) —
  a *normalising* parser (strips every non-alphanumeric, matches `DeviceType.values`)
  that accepts strictly more spellings than `deviceTypeFromWireName`. Adopting the
  canonical parser would narrow what a cached server payload can say.
- `headless_api/utils/device_type_parser.dart::parseDeviceType` — the REST vocabulary:
  enum names only, so `filterwheel` parses and `filter wheel` does not, and
  `validDeviceTypeList()` publishes exactly that set in every 400 body. Adopting the
  canonical parser would silently widen the documented API contract.
- `equipment_disconnect.dart`, `equipment_status_indicator.dart`,
  `profile_connection_status_provider.dart` — these enumerate all eleven slots to build a
  list, each entry carrying type-specific extras; and two of them `watch` rather than
  `read`, so routing them through the registry's `read` would change rebuild behaviour.

## Cluster 3 (`DeviceManager.devices` vs `AppState.devices`) — blocked

Live consumer set re-proved on the current tree:

- `AppState.devices` writes: `device_manager/connection.rs:419` (connect),
  `:1195`/`:1232`/`:1271` (disconnect/heartbeat-loss), `api/phd2.rs:310`/`:328`.
- `AppState.devices` reads: `hotplug.rs:242` (`get_all_device_states`),
  `api/phd2.rs:106`/`:112`/`:117` (`get_active_guider_id_for_ops`).
- `DeviceManager.devices` reads: `api/connection.rs:312-321` (the Dart-facing answers),
  `unified_device_ops.rs:244/305/1854/1860`, `builtin_guider.rs:1291/1297/1308`.

Collapsing them cannot be behaviour-preserving in either direction:

- Making `AppState` a read-through view over `DeviceManager` **removes** PHD2 from the
  guider lookup (`api/phd2.rs` registers only into `AppState`), which breaks guiding — a
  regression, not a refactor.
- Registering PHD2 through `DeviceManager::register_device` **changes** what
  `api_get_connected_devices()` returns and what `api_is_device_connected(Guider, …)`
  answers. That is the cry-wolf fix the map wants, and it is exactly the class adjudication
  item 5 sends to a failing-test-first bug batch.
- `hotplug.rs` reads `get_all_device_states()`, which today sees only the `Connected`
  mirror; `DeviceManager` also holds `Connecting`/`Disconnected` rows, so a swap changes
  hotplug arbitration input.

Recorded for the bug wave, not attempted here. Nothing in `bridge/src` was edited.

## Verification

| suite | result |
|---|---|
| `packages/skotiq_core` `flutter test test/services test/providers` | `+4310 ~4: All tests passed!` |
| `apps/desktop` `flutter test test/headless_api` | `+979: All tests passed!` |
| `packages/skotiq_app` `test/screens/equipment/` | `+162 -4` — 3 `captures_landscape_test.dart` goldens (21–27 % pixel diff, Linux-vs-Windows fonts) + they fail identically with the baseline `device_row_item.dart` restored from `HEAD`, so pre-existing; the 4th (`discovery_toast_currency_test`) was a REAL regression from the first cut and is now green |
| `packages/skotiq_app` `test/widgets/equipment_status_indicator_test.dart`, `test/screens/weather/weather_location_gate_test.dart` (the other notifier-fake suites) | `+3: All tests passed!` |
| new `test/providers/device_type_registry_test.dart` | `+8: All tests passed!` |
| `dart analyze` | clean on `skotiq_core/lib`, `apps/desktop/lib`, `skotiq_app/lib/screens/equipment`; the 17 `skotiq_app/lib` infos are pre-existing and in files this batch never opened |
| `dart format` | run on the 25 touched files only |

No Rust was touched, so no `cargo` run was required and no FRB regeneration arises.
