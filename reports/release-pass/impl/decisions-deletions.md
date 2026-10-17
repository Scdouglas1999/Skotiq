# Owner decisions 5 & 6 — deletions batch

Branch: `worktree-wf_9953116a-7f8-4` (worktree of `audit/end-to-end-campaign`).
Nothing committed; all changes left in the worktree.

Source of truth: `reports/release-pass/RELEASE-PASS-2026-08-11.md` §"Owner decisions
(made 2026-08-14)" items 5 and 6, backed by the Wave A map
(`reports/release-pass/map/bridge-dart.md` §2.2, `cross-cutting.md` clusters 8 and the
dead-code table, `core-services-devices.md` §3.4, `rust-devices.md` DC5).

---

## Decision 5 — delete the Dart fallback device stack

### Files deleted (whole-file)

| File | Lines |
|---|---:|
| `packages/skotiq_bridge/lib/src/phd2_client.dart` | 970 |
| `packages/skotiq_bridge/lib/src/alpaca_client.dart` | 619 |
| `packages/skotiq_bridge/lib/src/ascom_client.dart` | 508 |
| `packages/skotiq_bridge/lib/src/utils/circuit_breaker.dart` | 294 |
| `packages/skotiq_bridge/lib/src/utils/retry.dart` | 193 |
| **subtotal (production)** | **2,584** |
| `packages/skotiq_bridge/test/alpaca_client_test.dart` | 224 |
| `packages/skotiq_bridge/test/connection_resilience_test.dart` | 326 |
| `packages/skotiq_bridge/test/phd2_event_parsing_test.dart` | 218 |
| `packages/skotiq_bridge/test/phd2_rpc_test.dart` | 153 |
| `packages/skotiq_bridge/test/fakes/fake_phd2_server.dart` | 140 |
| **subtotal (tests/fakes)** | **1,061** |

`fake_phd2_server.dart` was orphaned by the two PHD2 test deletions (zero remaining
references; it is not in `test/fakes/fakes.dart`).

### Deviation from the decision's "2,656 lines" figure — recorded honestly

The map's §2.2 table reached 2,656 by including
`packages/skotiq_bridge/lib/src/rolling_rms_calculator.dart` (72 lines).
**That file was NOT deleted**: it has a live production consumer —
`packages/skotiq_core/lib/src/providers/guiding_provider/stats_and_graph.dart:73,74`
(`RollingRmsCalculator(windowSize: 100)` for the RA/Dec guide RMS readouts). The batch
brief names only the three clients plus retry/circuit_breaker, and those total exactly
2,584. `rolling_rms_calculator_test.dart` is likewise kept.

### Files edited

* `packages/skotiq_bridge/lib/skotiq_bridge.dart` — dropped the three client
  exports.
* `packages/skotiq_bridge/lib/src/bridge_stub.dart` — dropped the three client
  imports and the now-unused `utils/safe_cast.dart` import; **rewrote the library
  docstring to state the truth**: the native library is the only device path and a
  missing bridge fails closed, with no Dart-side device implementation to fall back to.
  Renamed `_fallbackErrorMessage` → `_nativeMissingErrorMessage` and rewrote its body
  for the same reason (it claimed "This is the Dart fallback bridge").
* `bridge_stub/native_bridge_state.dart` — removed `_alpacaClients`, `_alpacaDevices`,
  `_ascomClients`, `_phd2Client` and the now-dead `_ascomNotWindowsWarned`.
* `bridge_stub/guiding_operations.dart` — every `!_nativeAvailable` tail replaced with
  `_nativeBridgeRequired('<op>')`, matching the shape the file already used for
  `builtinGuiderGetConfigRaw`. Two behaviours deliberately preserved as non-throwing
  because they are status queries, not device commands: `phd2GetStatus` still returns a
  disconnected `Phd2Status`, `builtinGuiderGetTrackedStarsJson` still returns the empty
  snapshot.
  * `isPhd2Running` is **kept and still works without the bridge**: it is a plain TCP
    reachability probe behind the onboarding "Test connection" button
    (`skotiq_app/lib/screens/onboarding/steps/guider_step.dart:95`), not a device
    operation. `checkPhd2Running` + `_resolvePhd2ConnectHost` were moved verbatim out of
    the deleted `phd2_client.dart` into this file (the localhost→127.0.0.1 normalisation
    matters: PHD2 listens on IPv4 only).
  * `phd2AutoSelectStar` was **removed** (facade forwarder too): its only body was the
    deleted Dart client, there is no native counterpart, and it had zero callers. It also
    had an inverted guard (`if (_nativeAvailable) _nativeBridgeRequired(...)`), so it was
    broken in both directions.
* `bridge_stub/connection_operations.dart` — deleted `_connectAlpacaDevice` and
  `_connectAscomDevice` and the Alpaca/ASCOM client cleanup in `disconnectDevice`.
  `connectDevice` now fails closed when the bridge is absent for every family (Alpaca was
  previously the one family allowed to fall back after a native connect failure).
* `bridge_stub/discovery_operations.dart` — deleted the three `!_nativeAvailable`
  discovery sections (ASCOM registry, Alpaca UDP, PHD2 subnet scan) and the ten helpers
  that existed only for them: `_deviceTypeToAscomType`, `_alpacaTypeMatches`,
  `_discoverPhd2Instances`, `_getLocalNetworkAddresses`, `_scanSubnetForPhd2`,
  `_checkPhd2AtHost`, `_isPhd2Installed`, `_isPhd2InstalledWindows`,
  `_isPhd2InstalledMacOS`, `_isPhd2InstalledLinux`. Updated the `discoverDevices`
  docstring, which still listed the four now-nonexistent fallback sources.
* `bridge_stub/equipment_operations.dart`, `bridge_stub/sequencer_operations.dart` —
  `_fallbackErrorMessage` → `_nativeMissingErrorMessage` (3 call sites).

### Relocation forced by the deletion (not a deletion)

`phd2_client.dart` also held `Phd2State`, the enum on `phd2StateProvider` that drives the
guiding screen, the imaging guiding chip, the guide-health card and the Home Assistant
`guiding` entity — ~90 live references across `skotiq_core` and `skotiq_app`. It
is a domain value type, not part of the fallback client, so it was **moved** to its
natural home, `packages/skotiq_core/lib/src/models/phd2_models.dart` (verbatim, next
to `Phd2GuidingState`, which already documented it). Nine files dropped their
`import 'package:skotiq_bridge/skotiq_bridge.dart' show Phd2State;` line;
`home_assistant_discovery_service.dart` gained `import '../../models/phd2_models.dart';`.
`guiding_provider.dart` dropped the now-stale `Phd2GuideStats` from its `hide` list
(skotiq_core owns its own freezed `Phd2GuideStats`).

`Phd2ConnectionState`, `Phd2SettleProgress`, `Phd2Event` had zero references outside the
deleted file and went with it.

---

## Decision 6 — delete the unreachable code, all three blocks

### 6a — the six `Native*` traits and six unpopulatable bridge registries

Evidence re-checked in this tree before deleting: zero `insert(` against
`native_rotators` / `native_domes` / `native_weather` / `native_safety_monitors` /
`native_switches` / `native_cover_calibrators` anywhere in `bridge/src`; the only writes
are `remove()` on the disconnect path. Zero production implementors of the six traits.

* `native/skotiq_native/native/src/traits.rs` — **−225 lines**: deleted the traits
  `NativeRotator`, `NativeDome`, `NativeCoverCalibrator`, `NativeSwitch`, `NativeWeather`,
  `NativeSafetyMonitor`, plus the four value types that served only them and had no other
  user in the workspace: `ShutterState`, `NativeCoverState`, `NativeCalibratorState`,
  `NativeSwitchChannel`. (`bridge::device::ShutterState` is a different, live type and is
  untouched.)
* `bridge/src/device_manager/mod.rs` — deleted the six registry fields and their three
  construction sites; narrowed the `skotiq_native::traits` import.
* `bridge/src/device_manager/connection.rs` — the six per-type `remove()` arms on the
  native disconnect path collapsed into one no-op arm alongside `Guider`, with a comment
  saying why (the generic `native_devices` removal above is the whole cleanup).
* `bridge/src/dispatch/native.rs` — deleted the six liveness-probe arms (they now fall
  through to the generic `other` arm) and narrowed the traits import.
* `bridge/src/device_capabilities.rs` — deleted the six native capability branches, the
  two dead converters `native_cover_state_to_capability` /
  `native_calibrator_state_to_capability`, the three `#[cfg(test)]` fakes
  (`FakeNativeRotator`, `FakeNativeSwitch`, `FakeNativeCoverCalibrator`) and the four
  tests that drove them (`native_rotator_capabilities_use_connected_trait_object`,
  `native_switch_…`, `native_cover_…`,
  `native_cover_switch_rotator_operations_dispatch_to_trait_objects`).
* `bridge/src/device_manager/ops/{rotator,dome,weather,safety,switch,cover}.rs` — **38**
  `DriverType::Native` arms collapsed from a registry lookup to the exact `Err(...)` the
  lookup already produced. **The user-visible error string is byte-identical** in every
  arm (e.g. `"Native dome not connected"`, `format!("Native switch {} not found", …)`),
  so this is a pure deletion with no behaviour change. `ops/cover.rs` also lost its two
  dead converters `native_cover_state_to_bridge` / `native_calibrator_state_to_bridge`.

Rust net: **−1,745 / +164 lines** across 11 files.

### 6b — the `SKOTIQ_COMPANION_UI` mobile dashboard

| File | Lines |
|---|---:|
| `apps/mobile/lib/companion_ui_config.dart` | 14 |
| `apps/mobile/lib/screens/dashboard/mobile_dashboard_screen.dart` | 377 |
| `apps/mobile/lib/screens/dashboard/tabs/camera_tab.dart` | 1221 |
| `apps/mobile/lib/screens/dashboard/tabs/mount_tab.dart` | 1125 |
| `apps/mobile/lib/screens/dashboard/tabs/sequencer_tab.dart` | 751 |
| `apps/mobile/lib/screens/dashboard/tabs/devices_tab.dart` | 607 |
| `apps/mobile/lib/screens/dashboard/tabs/log_tab.dart` | 565 |
| `apps/mobile/lib/screens/dashboard/tabs/settings_tab.dart` | 305 |
| `apps/mobile/lib/screens/dashboard/tabs/science_tab.dart` | 269 |
| **subtotal (production)** | **5,234** |
| `apps/mobile/test/screens/dashboard/camera_tab_controls_test.dart` | 338 |
| `apps/mobile/test/widgets/log_tab_test.dart` | 244 |
| `apps/mobile/test/screens/dashboard/mount_tab_axis_order_test.dart` | 236 |
| `apps/mobile/test/screens/dashboard/sequencer_tab_controls_test.dart` | 96 |
| `apps/mobile/test/screens/dashboard/settings_tab_test.dart` | 68 |
| `apps/mobile/test/screens/dashboard/mobile_dashboard_setup_gate_test.dart` | 58 |
| `apps/mobile/test/screens/dashboard/science_tab_export_test.dart` | 44 |
| **subtotal (tests)** | **1,084** |

The map counted 4,845 production lines for `screens/dashboard/**`; the tree measures
5,220 for that directory (+14 for `companion_ui_config.dart`). The map's figure excluded
`mobile_dashboard_screen.dart` itself (377) — the seven tabs alone are 4,843.

Edits: `apps/mobile/lib/main.dart` dropped the two imports, the `useCompanionUi` branch
and its `MaterialApp`, and the stale comment; the phone/tablet path is now unconditionally
`SkotiqApp(isMobile: true)`. `packages/skotiq_app/lib/router/app_router.dart`
dropped `mobileDashboardBuilder` (18 lines) — a placeholder builder with zero references
anywhere in the repo, wired to no route — and its then-unused `flutter/material.dart`
import.

### 6c — the seven production-unreachable device-service methods + sequential connect

Each was re-verified in this tree: the only non-definition references were tests/mocks.

| Symbol | File | Lines removed |
|---|---|---:|
| `CenteringService.plateAndCenter` + `CenteringService.verifyCenter` | `skotiq_core/lib/src/services/centering_service.dart` | 151 |
| `ImagingService.resetFrameCounter` | `…/services/imaging_service.dart` | 5 |
| `DeviceService.connectProfile` + `DeviceService.connectActiveProfile` (public forwarders) | `…/services/device_service.dart` | 29 (incl. the now-unused `_connectProfileDeviceTimeout`) |
| `_connectProfile` + `_connectActiveProfile` (the sequential-with-abort path) | `…/services/device_service/profile_connections.dart` | 104 |
| `PredictiveAfService.importModel` + `PredictiveAfService.deleteModel` | `…/services/predictive_af_service.dart` | 81 |

The live connect-all path is unchanged: `_connectAllFromProfile` (parallel, per-device
progress, never aborts), reached from `equipment_screen.dart:623` and
`profile_service.dart:418`.

Tests removed with them: the `verifyCenter` and `plateAndCenter` groups in
`centering_service_test.dart` (250 lines), the `ImagingService Frame Counter` group
(13 lines), the `connectProfile sequential abort` group in `device_service_p0_test.dart`
(32 lines), the `connectActiveProfile uses host active profile on NetworkBackend` test in
`equipment_remote_parity_test.dart` (126 lines).

`predictive_af_service_test.dart`: the `export/import` group's round-trip test was the
**only** coverage of `exportModel`, which stays wired
(`predictive_af_settings.dart:484`, `focus_model_handlers.dart:190`). Rather than lose it
with `importModel`, the group was rewritten to a single export-shape test asserting the
schema string, filter name, sample count and recovered slope. Net −39 lines.

`centering_service_test.mocks.dart` regenerated via `build_runner` so the mock no longer
advertises the deleted API.

---

## Verification run in this worktree

| Gate | Result |
|---|---|
| `dart analyze` — `packages/skotiq_bridge` | clean (3 pre-existing `dangling_library_doc_comments` infos in untouched test files) |
| `dart analyze` — `packages/skotiq_core` | clean (5 pre-existing infos/warnings in files this batch never touched) |
| `dart analyze` — `packages/skotiq_app` | clean (33 pre-existing infos, 0 errors/warnings) |
| `dart analyze` — `apps/mobile` | clean (2 pre-existing infos) |
| `flutter test` — `packages/skotiq_bridge` | **65/65 pass** |
| `flutter test` — `packages/skotiq_core` | **5127 pass, 4 skipped, 0 fail** |
| `flutter test` — `apps/mobile` | **216/216 pass** |
| `flutter test` — `packages/skotiq_app` | see below |
| `cargo build --workspace` | clean, zero warnings |
| `cargo clippy --workspace --all-targets` | clean, zero warnings |
| `cargo fmt --all -- --check` | clean |
| `cargo test -p skotiq_bridge --lib` | **416/416 pass** |
| `cargo test -p skotiq_native --lib --tests` | **150 + 14 pass, 11 ignored** |

No failing-test-first step was owed: every change is a deletion of unreachable code or a
verbatim relocation. The one place a behaviour *could* have moved — the 38
`DriverType::Native` op arms — deliberately keeps the identical error value and string.

---

# PORTED — re-landed on the main tree (2026-08-14)

Re-landed semantically at HEAD of `audit/end-to-end-campaign`, not by patch
apply: the campaign had restructured most target files since the batch's stale
base (`59dec49c7`). Nothing committed; all work left in the working tree
alongside the six already-merged batches.

## Files deleted — 27 files, 10,126 lines

Line counts are measured at HEAD (they differ slightly from the batch's own
table because several files drifted since the stale base).

| File | Lines |
|---|---:|
| `packages/skotiq_bridge/lib/src/phd2_client.dart` | 1000 |
| `packages/skotiq_bridge/lib/src/alpaca_client.dart` | 619 |
| `packages/skotiq_bridge/lib/src/ascom_client.dart` | 508 |
| `packages/skotiq_bridge/lib/src/utils/circuit_breaker.dart` | 294 |
| `packages/skotiq_bridge/lib/src/utils/retry.dart` | 193 |
| **subtotal (bridge production)** | **2,614** |
| `packages/skotiq_bridge/test/connection_resilience_test.dart` | 328 |
| `packages/skotiq_bridge/test/alpaca_client_test.dart` | 226 |
| `packages/skotiq_bridge/test/phd2_event_parsing_test.dart` | 220 |
| `packages/skotiq_bridge/test/fakes/fake_phd2_server.dart` | 166 |
| `packages/skotiq_bridge/test/phd2_rpc_test.dart` | 155 |
| `packages/skotiq_bridge/test/phd2_framing_test.dart` | 104 |
| **subtotal (bridge tests/fakes)** | **1,199** |
| `apps/mobile/lib/screens/dashboard/tabs/camera_tab.dart` | 1221 |
| `apps/mobile/lib/screens/dashboard/tabs/mount_tab.dart` | 1120 |
| `apps/mobile/lib/screens/dashboard/tabs/sequencer_tab.dart` | 751 |
| `apps/mobile/lib/screens/dashboard/tabs/devices_tab.dart` | 603 |
| `apps/mobile/lib/screens/dashboard/tabs/log_tab.dart` | 565 |
| `apps/mobile/lib/screens/dashboard/mobile_dashboard_screen.dart` | 381 |
| `apps/mobile/lib/screens/dashboard/tabs/settings_tab.dart` | 305 |
| `apps/mobile/lib/screens/dashboard/tabs/science_tab.dart` | 269 |
| `apps/mobile/lib/companion_ui_config.dart` | 14 |
| **subtotal (mobile production)** | **5,229** |
| `apps/mobile/test/screens/dashboard/camera_tab_controls_test.dart` | 338 |
| `apps/mobile/test/widgets/log_tab_test.dart` | 244 |
| `apps/mobile/test/screens/dashboard/mount_tab_axis_order_test.dart` | 236 |
| `apps/mobile/test/screens/dashboard/sequencer_tab_controls_test.dart` | 96 |
| `apps/mobile/test/screens/dashboard/settings_tab_test.dart` | 68 |
| `apps/mobile/test/screens/dashboard/mobile_dashboard_setup_gate_test.dart` | 58 |
| `apps/mobile/test/screens/dashboard/science_tab_export_test.dart` | 44 |
| **subtotal (mobile tests)** | **1,084** |
| **TOTAL** | **10,126** |

`phd2_framing_test.dart` (104 lines) is **one file beyond the batch's list**. It
was added after the stale base by `38dd72c41` and tests only `Phd2Client`'s
split-frame reassembly — it dies with the client it exercises. Recorded here
rather than silently folded in.

`rolling_rms_calculator.dart` was again NOT deleted, for the reason the batch
gave: it still has a live consumer in `guiding_provider/stats_and_graph.dart`.

## The twelve substantive re-lands

| # | Target | Outcome |
|---|---|---|
| 1 | `bridge_stub/guiding_operations.dart` | Re-landed. Every `_phd2Client` tail replaced by `_nativeBridgeRequired`. `isPhd2Running` kept as the TCP reachability probe with `_resolvePhd2ProbeHost` moved in verbatim. `phd2GetStatus` and `builtinGuiderGetTrackedStarsJson` kept non-throwing as designed. The `guider*` forwarders lost their `phd2_guider` fallback legs. |
| 2 | `ops/dome.rs` | Re-landed (11 arms collapsed). |
| 3 | `ops/switch.rs` | Re-landed (10 arms). |
| 4 | `ops/cover.rs` | Re-landed (9 arms) + the two dead converters. |
| 5 | `ops/rotator.rs` | Re-landed (6 arms). |
| 6 | `bridge_stub/connection_operations.dart` | Re-landed. `connectDevice` now fails closed for every family; `_connectAlpacaDevice` / `_connectAscomDevice` (176 lines) deleted; `disconnectDevice` collapsed to PHD2-or-native, dropping the Alpaca "may fall back to the direct Dart client" exception and the `disconnectedByAuthoritativeBackend` bookkeeping it existed for. |
| 7 | `phd2_models.dart` + `.freezed.dart` | **No overlap work was owed.** The batch's entire `.freezed.dart` diff was the ui-small batch's `arcseconds → guide-camera pixels` doc rewording, which is already on this tree (14 occurrences present). Only the `Phd2State` relocation was real, and a bare enum changes neither `.freezed.dart` nor `.g.dart`, so **no `build_runner` run was needed for this file**. Nothing was overwritten. |
| 8 | `bridge_stub.dart` | Re-landed: docstring now states Rust is the only device path, `_fallbackErrorMessage` → `_nativeMissingErrorMessage` with a truthful body, three client imports plus `utils/safe_cast.dart` dropped. `dart:convert` and `dart:typed_data` also became unused once `phd2GetStarImage`'s base64/cast body went, and were dropped. |
| 9 | `connection.rs` | Re-landed: six `remove()` arms collapsed to one no-op arm beside `Guider`. |
| 10 | `predictive_af_service_test.dart` | Re-landed to the batch's shape: the export/import round-trip group became a single `exported JSON carries the schema and every sample` test asserting schema, filter name, sample count and recovered slope. Net −14 lines. |
| 11 | `centering_service_test.mocks.dart` | Regenerated via `build_runner` in `skotiq_core`; −50 lines, zero remaining references to any deleted method. No other generated file changed. |
| 12 | `ops/weather.rs` + `ops/safety.rs` | Re-landed (1 arm each). |

## Deviations from the batch, recorded honestly

* **`phd2AutoSelectStar` was still deleted, but the reasoning had to be
  re-checked.** After the stale base, `38dd72c41` deliberately *fixed* this
  method's inverted guard and wrote a contract test for it. Re-verifying at
  HEAD: the guiding screen's Auto Select button routes through
  `lockPositionProvider.notifier.findStar()`, not this method, so it still has
  **zero production callers**. It went, with its facade forwarder and the
  contract test group that drove it.
* **`native_guard_contract_test.dart` was rewritten, not deleted.** Its
  guard-polarity scan used a 3-line lookbehind and flagged any positive
  `if (_nativeAvailable)` — which is exactly the shape this batch standardises
  on (`if (_nativeAvailable) { …; return; } _nativeBridgeRequired(…)`). It went
  red on 3-line method bodies. Replaced the heuristic with a brace-depth rule
  that asks the question the test actually means: is the throw *inside* the
  positive block? Both legal spellings now pass; a genuinely inverted guard
  still fails. Its second group ("every `_phd2Client` user has a native
  branch") was deleted — `_phd2Client` no longer exists and its explanatory
  comment had become untrue.
* **`phd2GetStarImage` (bridge stub) was deleted.** Drift had already removed
  its facade forwarder, so once `guiderGetStarImage`'s PHD2 fallback leg went
  it was unreachable and the analyzer flagged it. The batch kept it only
  because in its tree the facade still exposed it.
* **`device_capabilities/native.rs`**: the batch's 743-line `device_capabilities.rs`
  target no longer exists; its content is now `bridge/src/device_capabilities/`.
  The six native capability branches were deleted from `native.rs` and the
  fakes/tests from `tests.rs`. Those six device types now fall through to the
  existing `_ =>` arm, so the error changes from
  `hardware_error(id, "Native rotator not connected")` to
  `not_supported(id, "Native capabilities are unavailable for device type Rotator")`.
  This is the one place in the Rust change where the error *value* differs
  rather than being preserved; it is on a path that was already unconditionally
  an error. The 38 `ops/` arms keep byte-identical error strings.
* **Two stale comments** naming now-deleted classes were corrected
  (`settings_sections/phd2.dart`, `settings_sections/protocol.dart`).
* **The batch's six binary `.png` diffs** (`assets/screenshots/desktop-dashboard.png`,
  five `docs/design/goldens/*.png`) were **not ported**: they are
  Linux-regenerated golden artifacts incidental to the worktree's test runs, not
  batch intent, and this repo's goldens are Windows-captured.
* **`dart format` touched three files this port never edited**
  (`sequence_executor_launch_parity_test.dart`, `live_stacking_master_format_test.dart`,
  `stacking_panel.dart`) — they were left unformatted by other in-flight batches
  and the repo gate requires formatting.

## Verification run on the main tree

| Gate | Result |
|---|---|
| `dart analyze` — `skotiq_bridge` | **clean, 0 issues** |
| `dart analyze` — `skotiq_core` | 0 errors, 1 pre-existing warning (`scheduler_rejection_labels_test.dart`, untouched) |
| `dart analyze` — `skotiq_app` | 0 errors, 3 pre-existing warnings in untouched test files |
| `dart analyze` — `apps/mobile` | 0 errors, 0 warnings |
| `flutter test` — `skotiq_bridge` | **63/63 pass** |
| `flutter test` — `skotiq_core` | **5934 pass, 4 skipped, 0 fail** |
| `flutter test` — `apps/mobile` | **222/222 pass** |
| `flutter test` — `skotiq_app` | 3552 pass, **42 fail** — the documented pre-existing golden/layout debt, spread across 29 files. Only one (`guiding_screen_test.dart`) is a file this port touched, and it passes in isolation together with every other file this port edited; those two are cross-test ordering flakes within the known 42. |
| `cargo build -p skotiq_bridge` | **clean** |
| `cargo build --workspace` | clean (3 pre-existing ambiguous-glob-re-export warnings in untouched files) |
| `cargo clippy --workspace --all-targets` | 5 warnings, all pre-existing, none on a touched line |
| `cargo fmt --all -- --check` | **clean** |
| `cargo test -p skotiq_bridge --lib` | **556 pass, 0 fail, 4 ignored** |
| `cargo test -p skotiq_native --lib --tests` | **160 + 14 pass, 0 fail, 11 ignored** |

Rust net across 13 files: **+164 / −1,738**.

### Not ported

Nothing from the batch's intent was left unported. The only items deliberately
skipped are the six binary golden/screenshot `.png` diffs, for the reason above.
