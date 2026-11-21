# Skotiq 9.0.2 Comprehensive Rehabilitation Decision Log

Base branch: `rehab/9.0.2-untangle` (worktree `.worktrees/rehab-902`), combining `feat/live-stacking-902` (`75f9c169a`) and `fix902/af-hfr` (`b2eae8f53`) on top of `fix/9.0.2` (`179edf94f`) and `v9.0.1` (`d6568e87a`).

## Baseline Measurements (2026-11-20)

- Codebase scale: ~2.21M LOC across 14 Dart packages (`skotiq_*`, `apps/*`), 13 Rust crates (`native/skotiq_native/*`), `server/skotiq_hub`, and `tools/skotiq_relay`.
- `architecture_rules_audit`: pass (`backend-class: 0`, `src-import: 0`, `node-dispatch: 11`, `core-layers: 266`, `host-store: 26`).
- `bridge_boundary_audit`: pass (`11` whitelisted, `0` violations, `1` prunable whitelist entry: `science_handlers`).
- `analyzer_rollup`: **FAIL** (`0` errors, `3` production warnings: unused imports in `sub_quality_badge.dart:4` and `science_provider.dart:28-29`, `604` infos).
- `placeholder_audit`: **5 new high-risk markers** from `feat/live-stacking-902`.
- `behavioral_audit`: **19 unregistered behavioral findings** from `feat/live-stacking-902` (including silent `empty_catch` in `stacked_preview.dart:305`).
- `dependency_hygiene`, `fail_closed_check`, `headless_api_contract`, `headless_route_policy`, `version_consistency`: pass.
- `oversized_file_audit`: `56` warnings, `1` critical (`translations.dart`, 3,307 lines).

---

## Prioritized Architectural & Correctness Decisions

### Batch 0 — Baseline CI Gate Hygiene
- **Status**: Planned (next)
- **Problems**:
  - `packages/skotiq_app/lib/screens/imaging/widgets/sub_quality_badge.dart:4` and `packages/skotiq_core/lib/src/providers/science_provider.dart:28-29` fail `analyzer_rollup` zero-warning gate due to unused imports.
  - `tools/production/bridge_boundary_whitelist.json` retains a prunable `science_handlers` exception that no longer imports `skotiq_bridge`.
  - `packages/skotiq_app/lib/screens/sequencer/ledger_seconds.dart` is a 1-line empty leftover file.
- **Correction**: Remove unused imports, prune stale whitelist entry, delete empty leftover file.
- **Verification**: `analyzer_rollup`, `bridge_boundary_audit`, `architecture_rules_audit`.

### Batch 1 — Rust 9.0.2 Critical Correctness, Concurrency, Panics & Security
- **Status**: Planned
- **Problems**:
  - `sequencer/src/instructions/autofocus.rs:610-667`: failed/cancelled AF restores wheel without re-applying the original filter's focus offset even though entry shifted the focuser to the reference filter.
  - `sequencer/src/instructions/filter.rs:133-155` & `autofocus.rs:531`: exact case-sensitive filter offset/settings lookup breaks after alias resolution via `skotiq_device::match_filter_slot`.
  - `bridge/src/api/live_stacking.rs:1116-1119`: `clamp(black_point + 1e-4, 65535.0)` panics when `black_point + 1e-4 > 65535.0` on saturated/clipped F32 frames; unchecked byte-size multiplication and `from_u16` length.
  - `bridge/src/api/live_stacking.rs:678-714, 1257-1299, 1337-1348, 1535-1560`: split-lock races between `stacker` and `meta` poison Darkroom `BASE_CACHE` and allow `meta.revision` to move backwards on reset.
  - `bridge/src/api/live_stacking.rs:652-685, 1468-1522` & `imaging/src/stacking.rs:297-303`: `api_stacking_add_frame_for_filter` rejects frames whenever an explicit `filter_key` differs in spelling/alias from FITS `FILTER` (or header is absent); inconsistent `"—"` / case-sensitive slot lookups across endpoints.
  - `bridge/src/builtin_guider/metrics.rs:390-398, 446-450` and `imaging/src/background_extraction.rs:956`: `.clamp()` runtime panics on invalid `min_pulse_ms > max_pulse_ms` or small `< 30px` ROIs.
  - `indi/src/client/{mod.rs,reader.rs}`: reconnect orphans prior reader/writer tasks that clobber the new connection's `ReaderStatus::Running` and `connected` flag.
  - `updater/src/main.rs:1123, 1152, 1166, 1310, 1374-1376`: `install_dir.join(from_posix(rel))` allows absolute-path replacement and `..` traversal outside install root during verify/rollback.
  - `platesolve/src/lib.rs:160, 220, 312, 447`: `.expect("solver-pref RwLock")` panics on poison; `bridge/src/api/imaging.rs:219-223` silently falls back unknown AF method names to `VCurve`.
  - `native/src/vendor/lx200/mount_ops.rs:69-75, 156-163`: `sync_to_coordinates` ignores OnStepX `E<n>#` refusal and `is_slewing` ignores `:GU#` homing flag `h` (pinned by two `#[ignore]`d tests in `doc_fake_tests.rs`).
- **Correction**: Fix each root cause cleanly (single canonical alias-aware filter matching, unified slot lock / atomic metadata updates, checked clamps & containment path helper, connection-generation guard in INDI, poison-safe lock reads, typed AF method rejection), and add fault-detecting regression tests for every fix.
- **Verification**: `cargo test --release -p skotiq_sequencer -p skotiq_bridge -p skotiq_imaging -p skotiq_indi -p skotiq_native -p skotiq_updater -p skotiq_platesolve`, `cargo clippy --release --all-targets`.

### Batch 2 — 9.0.2 Live Stacking & Live Darkroom End-to-End Rehabilitation (`skotiq_core` + `skotiq_app`)
- **Status**: Planned
- **Problems**:
  - `LiveStackingService` & `NetworkBackend/stacking_operations.dart`: remote multi-filter methods drop `filterKey`, `renderStackPreviewRgba`/`isActive`/`frameCount` call local FFI directly on linked clients, 3 new 9.0.2 config fields and `totalIntegrationSecs` are dropped on the wire, and `_saveFitsMasterTo` bypasses its injectable seam.
  - `LiveStackingNotifier` (`live_stacking_provider.dart`): `stop()` races `startFromFile()` and `_ingestChain` leaking native stackers; failed remote `stackingStop()` cancels poll timer while staying running; `reset()` resets wrong native slot on 1 named filter; `resetFilter`/`stopFilter` race `_ingestChain`; `_startFromData` wipes existing filters; `addFrameFromData` crashes remotely; unnormalized filterKey map lookups; raw `e.toString()` in frame events; plain value types live in provider file; dead unused providers (`liveStackingIsActiveProvider`, `liveStackingIsActiveOrArmedProvider`).
  - `LiveStackingFeed` (`live_stacking_feed.dart`): `maxFramesToStack` reads UI-selected filter count instead of `totalFramesAcrossFilters`; `teardown()` skips opt-in runs.
  - `stacking_panel.dart`: Stop checks only selected filter count (destroying other filters without prompt); Save only saves one filter before releasing all and bypasses `liveStackMasterLibraryProvider.save(...)`; `_releaseStack()` runs even when `!mounted`.
  - `live_stack_darkroom_provider.dart` & `_landing.dart`: `_measureStretchDefaults` clobbers concurrent slider edits; missing `mounted && state.enabled` guards after await; stale target stretch anchors persist across sessions; `promoteLiveStackToDarkroom` uses `WidgetRef` after await without guard and never invalidates library; `_ActiveLiveStacksStrip` lacks remote-client guard.
  - `live_stack_formatters.dart`: duplicates `FilterColors` with hardcoded green/blue/cyan violating Red Night theme, and duplicates `DurationFormat`.
  - 5 raw `$error` UI leaks in live-stacking/darkroom files and silent `catch (_)` in `stacked_preview.dart:305`.
- **Correction**: Fix wire parity, serialize notifier lifecycle operations cleanly, move plain model types to `models/`, fix UI multi-filter stop/save/Darkroom promotion/Red Night colors/error text, and add comprehensive fault-detecting tests.
- **Verification**: `flutter test` on `skotiq_core` & `skotiq_app` live stacking/darkroom suites, `audit:architecture`, `audit:placeholders`, `audit:behavioral`.

### Batch 3 — Core Reliability, Concurrency, Resource Leaks & Database Integrity (`skotiq_core`)
- **Status**: Planned
- **Problems**:
  - `NetworkBackend._connect()` lacks post-await disposal checks, single-flight connect generation guard, and `.isClosed` guards; `HostPoll` leaks `StreamController`.
  - `DarkroomBuildJobs` (0 tests): stale snapshot clobber in `exclude`/`replan`/`setMinRetainedArea`, string-matched stop check missed in `startUnattended`, TOCTOU race in `startUnattended`, leaked `_idleWaiters` on dispose.
  - `CalibrationService.calibrateFile()` backs up to `.uncal` when NOT overwriting (`outputPath == null`) and skips backup on true in-place overwrite (`outputPath == lightPath`); `calibrateData()` bypasses `_hostTools`.
  - `HostCenteringRunner.cancel()` misses in-flight `startCentering`, unawaited cancel errors uncaught, missing `_retired` check after loop.
  - Sticky failed-Future caching in `FocusModelService` (+ `setReferenceFilter` no-op on fresh profile + raw path join), `PredictiveAfService`, `DarkroomBuildJobs`, `NightEndRunner`, `SecretsStore`, `LoggingService`.
  - `NativeDiscovery.devices()` invalidation race & 60s caching of empty pre-native sweeps.
  - `DarkroomTargetEdits` non-transactional `rename()`/`merge()`, unchunked `.isIn(...)`, linear RA median broken across 0h/24h; `SessionsDao.closeOrphanedSessions` non-transactional; `repairSolvedRotationFromCd` full-table scans on every DB open.
  - `RunConfigSync` startup race with `filterOffsetProvider`, missing `_disposed` checks, raw `$e`; `MountGuardNotifier` (0 tests) host-swap contamination; uncancellable `async*` `Future.delayed` in `disk_space_provider` & `secondary_rig_provider`; `SequenceExecutor`/`RunEventHandler`/`RunFrameRecorder` post-await & sticky `_flipCountedAtPierChange` bugs; post-await guards in `imaging_provider`, `autofocus_preview_feeder`, `depthlock_provider`, `device_capability_provider`; 25ms spin-wait in `weather_safety_provider.dart:938`.
- **Verification**: Targeted + full `skotiq_core` test runs, including new tests for `DarkroomBuildJobs` and `MountGuardNotifier`.

### Batch 4 — Headless API Security/Lifecycle, Hub, Relay, Updater, Plugins, Astro/Planetarium & Mobile
- **Status**: Planned
- **Problems**:
  - Headless API: `view`-scope blocked on `AuthApi.wsTicketIssue`/`cookieIssue`/`logout`; WS `?ticket=` upgrade skips revocation check and drops `grant:` (stripping admin access); `AuthCookieManager.validateCsrf()` never enforces `csrfExpiresAt`; `HeadlessAuthGrant.toSpec()` escalates empty grant to `'view'`; `BroadcastHandlers` hardcodes literal `'…'` breaking all private broadcasts (0 tests); `filesystem_handlers.dart:75` directory existence oracle; `websocket_sessions.dart` subscription/sink leak & broken `stop()`/`start()` restartability; `headlessSecurityAdvisories` misses scoped/fine-grained tokens.
  - `skotiq_hub`: unauthenticated random-Bearer rate-limit bypass + O(N) per-request sweep; blocking `writeAsBytesSync` for up to 1 GiB uploads.
  - `skotiq_relay`: `MuxFrameType.open` overwrites `byClientId` leaking orphaned `_byUplinkId` entries; no per-client stream cap; unthrottled registration capacity exhaustion; concurrent `_persist()` tmp-file race; uncancelled `StreamIterator`.
  - `skotiq_updater`: `hashFile()` loads full ZIP into RAM (OOM); `UpdateDownloader` `416` wedge + nullable `contentLength!` + unchecked `Content-Range`; `rollback()` bypasses `_applySafetyCheck()`; `LanPushReceiver` unbounded post-auth socket read.
  - `skotiq_plugins`: `registerPlugin`/`unregisterPlugin`/`setPluginEnabled` rollback/split-brain bugs; `createNode`/`validate` outside `try/catch` in `PluginNodeExecutor.run()`; `SandboxedPluginEventBus._subscriptionCount` never decrements.
  - `skotiq_astro` & `skotiq_planetarium`: Venus/Mercury ~5-mag phase-angle bug + unclamped `asin`; polar `tan` singularity in precession & duplicated ecliptic->equatorial math; unclamped `acos` `NaN` in Azimuthal Equidistant projection; static mutable caches on `SkyCanvasPainter`; uncancellable `Future.delayed` warmup timers.
  - `apps/mobile`: relay reconnect persists `127.0.0.1:<ephemeralPort>` as `lastServer`, retries dead port forever, and leaks `_activeRelayTunnel` on dispose.
  - Security design note (deferred/evaluated before wire change): LAN UDP push HMAC key derivation (`lan_push_broadcaster.dart:26-31`) uses public `serverFingerprint` — requires careful backward-compatible paired-secret design rather than silent wire break; document or coordinate before breaking deployed mobile clients.
- **Verification**: `apps/desktop`, `apps/mobile`, `skotiq_remote_protocol`, `skotiq_updater`, `skotiq_plugins`, `skotiq_astro`, `skotiq_planetarium`, `server/skotiq_hub`, `tools/skotiq_relay` test suites + `audit:headless-api-contract` & `audit:headless-route-policy`.

### Batch 5 — Flutter UI Correctness, Leaks, Error Hygiene & `hostStore` Cleanup (`skotiq_app`)
- **Status**: Planned
- **Problems**:
  - `NodeNumberInput.dispose()` discards pending debounced edits.
  - Missing `mounted` guards in `mount_guard_recovery_dialog.dart`, `mount_guard_banner.dart`, `update_manager_widget.dart`, `science_cards.dart`, `transient_report_panel.dart`.
  - 5 leaked dialog `TextEditingController`s; uncancellable `Future.delayed` timers in `update_manager_widget.dart`.
  - `hostNightHistoryProvider` (`night_history_sync.dart:189-208`) directly accesses `backend.remoteHost` (last `skotiq_app` `hostStore` baseline site) and mutates `temperatureHistoryProvider` inside a `FutureProvider` build without `backendScope`.
  - Raw `$e` error leaks in `guiding_screen_parts/actions.dart`, `science_status_banner.dart`, `build_masters/job_views.dart`, `calibration_waiting_panel.dart`, `lists_tab.dart`, `_template_card.dart`.
  - Raw SQL in `session_review_controller_parts/_helpers.dart:303` and dead `slew_controls.dart` (preserving unwired capabilities per `SKILL.md` §4).
- **Verification**: `skotiq_app` tests + `audit:architecture --sync-baseline`.

### Batch 6 — Deep Structural Untangling (`coreLayers`, `hostStore`, `NotificationRouterNotifier`, `bridge_boundary`)
- **Status**: Planned
- **Problems**:
  - 6× copy-pasted transport `AsyncNotifier` boilerplate in `notification_router_provider.dart` (~480 lines).
  - `filter_wheel_handlers.dart:67` calls raw FFI to work around a defect in `FfiBackend.filterWheelGetNames` instead of fixing `FfiBackend`; 4–5 `bridge_boundary_whitelist.json` entries exist solely to catch `SkotiqError`.
  - `coreLayers` baseline (266 sites): trivially pure services (`live_stacking_service`, `live_stacking_broadcast_service`, `photometric_catalog_service`, `photometric_transform_service`, `phd2_launcher`, `device_heartbeat_router`, `eon_deferral`, `smart_notification_service`, etc.) take `Ref` unnecessarily, and 27 providers are declared inside `services/`.
  - `hostStore` baseline (25 remaining core sites): convert shared-data services (`live_stacking`, `calibration_tools`, `transient_alerts`, `planning`/`scheduler`) onto `hostRoleProvider` roles and eliminate redundant `ref.listen(backendProvider)` §3.8.4 sites.
- **Verification**: `audit:architecture`, `audit:bridge-boundary`, full Rust + Dart test suites, independent adversarial review pass.
