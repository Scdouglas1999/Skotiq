# Release-pass map — app shells

Subsystem: `apps/desktop/` (incl. `headless_api/`, `headless_api_server/`), `apps/mobile/`,
`packages/skotiq_updater/`, `packages/skotiq_plugins/`,
`packages/skotiq_remote_protocol/`.

Read-only mapping pass. No source file was edited. All line counts verified with `wc -l`.
Generated files (`*.g.dart`, `*.freezed.dart`, `*frb_generated*`) are excluded throughout;
none of the files below are generated — every one is hand-written.

---

## 1. Oversized files

There are **no Rust sources** anywhere in this subsystem (`find … -name '*.rs'` returns 0),
so the 1500-line Rust threshold does not apply.

Eleven non-generated Dart library files exceed ~1000 lines. One test file
(`apps/desktop/test/headless_api/calibration_handlers_test.dart`, 1166) also does; test files
are noted at the end but are not a priority.

| Lines | File |
|------:|------|
| 2309 | `apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart` |
| 1339 | `apps/desktop/lib/headless_api/route_metadata.dart` |
| 1221 | `apps/mobile/lib/screens/dashboard/tabs/camera_tab.dart` |
| 1213 | `apps/mobile/lib/services/saved_servers_service.dart` |
| 1126 | `packages/skotiq_updater/lib/src/services/update_service.dart` |
| 1125 | `apps/mobile/lib/screens/dashboard/tabs/mount_tab.dart` |
| 1110 | `apps/desktop/lib/headless_api_server/http_middleware.dart` |
| 1107 | `packages/skotiq_updater/lib/src/services/update_controller.dart` |
| 1094 | `packages/skotiq_remote_protocol/lib/src/enhanced_discovery.dart` |
| 1061 | `apps/mobile/lib/services/notification_service.dart` |
| 1005 | `apps/mobile/lib/screens/servers/saved_servers_screen.dart` |

### A prerequisite the implementer must read first

`SequencerHandlers` and `HeadlessApiServer` are both consumed **across library boundaries**:
`apps/desktop/lib/headless_api/routes/sequencer_routes.dart` calls `handler.handleSequencerStart(...)`
and 53 sibling methods from a different library. **A private `extension … on SequencerHandlers`
in a `part` file cannot satisfy those calls** — Dart resolves extension members statically and a
library-private extension is invisible outside its own library.

The repo already solves this correctly in `headless_api_server.dart:44-48`: the `part` files hold
only **private** members (`_startServer`, `_authMiddleware`, …) inside private extensions, and the
main file keeps thin public forwarders (`Future<void> start() => _startServer();`,
`headless_api_server.dart:731-744`). Every split plan below follows that established pattern.
Deviating from it will not compile.

---

### 1.1 `apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart` — 2309 lines

**Why it is big.** One class carries the entire sequencer control surface: 54 routed handlers
(`routes/sequencer_routes.dart` declares 54 `HeadlessRoute` entries against it), the private
start-path pre-flight helpers, six ad-hoc JSON payload readers, and a 230-line private
wire-parsing value type. All handlers share one piece of mutable state
(`_explicitlyAssignedDeviceIds`, line 34) and one logger accessor (lines 36-43), which is why it
grew as one unit.

**Current internal fault lines** (verified by reading member declarations):

| Lines | Block |
|------:|-------|
| 1-44 | imports, class decl, `_explicitlyAssignedDeviceIds`, `_logger`/`_logInfo`/`_logWarning` |
| 45-136 | read handlers: `handleSequencerStatus`, `handleSequencerEditorSequence` |
| 137-593 | lifecycle: start/stop/pause/resume/skip/skipToNode/pluginNodeFinished/reset/load |
| 594-826 | start-path pre-flight privates (`_restoreNativeSavePath` … `_rejectInvalidWireSequence`) |
| 827-1013 | `handleSequencerLoadAndStart`, `_nativeStartRefusal`, `_wireConnectedDevicesIntoNativeExecutor` |
| 1014-1211 | config setters (simulation mode, devices, safety fail mode / interval, save path, active run id, decision logging) |
| 1212-1437 | config updaters (dither, meridian flip, location, filter offsets, carry-over, autofocus interval/config, quality check, reject folder, observer profile, sky brightness, adaptive exposure) |
| 1438-1654 | checkpoints + `handlePerformMeridianFlip` |
| 1655-1726 | recovery (try-now, abort, update config, current, history) |
| 1727-1842 | conditions (cloud motion, weather verdict, conditions score, adaptive swap) |
| 1843-1977 | secondary rig (status/start/stop) |
| 1978-2078 | six local payload readers |
| 2080-2309 | `_WireSequenceSummary` |

**Split plan** (behaviour-preserving; do the steps in order — 1 and 2 are independently landable
and remove ~330 lines with zero API change).

**Step 1 — extract the wire summary to its own library.**
New file `apps/desktop/lib/headless_api/handlers/sequencer/wire_sequence_summary.dart`.
Move lines 2080-2309 verbatim. Rename `_WireSequenceSummary` → `WireSequenceSummary`
(it now crosses a library boundary so it must be public); its static members
(`_collectUnassignableRoles`, `_typeOf`, `_configOf`, `_isEnabled`, `_asDouble`, `_asInt`,
`_framesIn`, `_countExposures`) stay private *class* members and need no rename.
Needs `import 'dart:convert';` and `package:skotiq_core/skotiq_core.dart` (for `DeviceType`).
`sequencer_handlers.dart` adds `import 'sequencer/wire_sequence_summary.dart';`.
The type is referenced only inside `sequencer_handlers.dart` (grep for `_WireSequenceSummary`
across `apps/desktop/lib` + `apps/desktop/test`: definition file only), so nothing else changes.

**Step 2 — delete the six local payload readers (lines 1978-2078).**
`_readNullableDouble`, `_readOptionalInteger`, `_readNullableBool` duplicate
`optionalDouble` / `optionalInt` / `optionalBool` in `headless_api/validation.dart:464-546`,
which this file **already imports** (line 13). Replace each call site with the shared helper.
`_readStringDoubleMap`, `_readStringBoolMap`, `_readNestedDoubleMap` have no shared equivalent —
move them into `validation.dart` as `optionalStringDoubleMap` / `optionalStringBoolMap` /
`optionalNestedDoubleMap`.

  **This step changes an HTTP status code and must be landed with tests.** See §5.1: the local
  readers throw `FormatException`, which `errorTranslationMiddleware`
  (`validation.dart:711-799`) does not special-case, so a bad type currently returns **500
  `internal_error`**. The shared helpers throw `BadRequestError` → **400**. That is the correct
  behaviour, but it is a wire-visible change; add a test asserting
  `POST /api/sequencer/sky-brightness {"mag":"bright"}` → 400.

**Step 3 — convert the remainder to `part` files** under
`apps/desktop/lib/headless_api/handlers/sequencer/`, each declaring
`part of '../sequencer_handlers.dart';` and holding one private extension on `SequencerHandlers`:

| New part file | Private extension | Moves (current lines) | ≈ |
|---|---|---|---|
| `sequencer_lifecycle_handlers.dart` | `_SequencerLifecycle` | 45-593, 827-918 | 640 |
| `sequencer_start_preflight.dart` | `_SequencerStartPreflight` | 594-826, 919-1013 | 330 |
| `sequencer_config_handlers.dart` | `_SequencerConfig` | 1014-1437 | 425 |
| `sequencer_checkpoint_handlers.dart` | `_SequencerCheckpoints` | 1438-1654 | 217 |
| `sequencer_recovery_handlers.dart` | `_SequencerRecovery` | 1655-1726 | 72 |
| `sequencer_conditions_handlers.dart` | `_SequencerConditions` | 1727-1842 | 116 |
| `sequencer_secondary_rig_handlers.dart` | `_SequencerSecondaryRig` | 1843-1977 | 135 |

Each moved public handler is renamed to a private name in the extension
(`handleSequencerStart` → `_handleSequencerStart`); `sequencer_handlers.dart` keeps a one-line
public forwarder per routed method
(`Future<Response> handleSequencerStart(Request r) => _handleSequencerStart(r);`).
After the move the main file retains: imports, the seven `part` directives, the class
declaration, `_explicitlyAssignedDeviceIds`, `_logger`/`_logInfo`/`_logWarning`, and ~54
forwarders → **≈250 lines**.

**Verification gate.** `routes/sequencer_routes.dart` must compile untouched, and these six test
files must pass unchanged (they construct `SequencerHandlers(container)` directly):
`sequencer_handlers_test.dart`, `sequencer_start_device_wiring_test.dart`,
`sequencer_save_path_disk_monitor_test.dart`, `sequencer_start_session_row_test.dart`,
`command_correlator_wiring_test.dart`, and `handler_initialization.dart:112`.

---

### 1.2 `apps/desktop/lib/headless_api/route_metadata.dart` — 1339 lines

**Why it is big.** Four unrelated concerns share one file because they all key off the request
path: body-size limits, OpenAPI spec generation, auth-scope/admin/high-risk path classification
(with ~600 lines of heavily-commented const path tables), and two rate limiters.

**Split plan.** Every importer uses a prefixed import
(`import '…/route_metadata.dart' as route_metadata;` — `headless_api_server.dart:40`,
`request_context.dart:24`, `auth/cors_policy.dart:1`, `auth_policy.dart:3`,
`handlers/system_handlers.dart:39`, plus one `show`-import in
`handlers/calibration_handlers.dart:47`). So **keep `route_metadata.dart` as a pure re-export
barrel** and every call site compiles byte-identically.

New directory `apps/desktop/lib/headless_api/route_metadata/`:

1. `body_limits.dart` — `oneMiB`, `defaultMaxRequestBodyBytes`,
   `imageProcessingMaxRequestBodyBytes`, `backupUploadMaxRequestBodyBytes`,
   `catalogUploadMaxRequestBodyBytes` (3-11), `methodCanHaveBody` (17-19),
   `requestBodyLimitForPath` (62-94), `validateContentLength` (212-246). ≈130 lines.
2. `route_tables.dart` — the const tables only: `_resourcePrefixKeys` (699),
   `_rateLimitedMethods` (754), `_adminOnlyPathPrefixes` (756), `_adminOnlyPaths` (773),
   `_pairingActivePaths` (809), `_controlPathPrefixes` (811), `_rateLimitedReadPaths` (871),
   `_rateLimitedPairingPaths` (884), `_highRiskControlPaths` (890), `_highRiskAuditActions` (953).
   Rename each to a library-public name (drop the leading `_`) so the matchers can import them;
   do **not** re-export them from the barrel. ≈310 lines.
3. `path_classification.dart` — `endpointRateLimitFor` (248), `highRiskAuditActionFor` (282),
   the ten `_is…Path` matchers (373-511), `isHighRiskControlPath` (512), `isPublicEndpoint` (521),
   `requiredAuthScopeNameForEndpoint` (527), `resourceKeyForEndpoint` (670), `_normalizePath` (747).
   Imports `route_tables.dart`. ≈410 lines.
4. `rate_limiting.dart` — `defaultControlRateLimitWindow` / `…MaxRequests` /
   `highRiskControlRateLimitMaxRequests` (13-15), `EndpointRateLimit` (1009),
   `RateLimitDecision` (1016), `TokenRouteClass` (1044), `defaultTokenBucketConfigs` (1069),
   `tokenRouteClassFor` (1095), `tokenRouteClassName` (1140), `TokenBucketConfig` (1155),
   `TokenBucketRateLimiter` (1177), `_TokenBucketState` (1286), `EndpointRateLimiter` (1292).
   Imports `path_classification.dart` for `endpointRateLimitFor` (used at 1303). ≈340 lines.
5. `openapi.dart` — `openApiRequestBodyFor` (21-60), `buildOpenApiSpec` (96-196),
   `openApiPath` (197), `openApiTag` (204). Imports `rate_limiting.dart` (`buildOpenApiSpec`
   calls `endpointRateLimitFor` at line 111) and `body_limits.dart`. ≈160 lines.

`route_metadata.dart` becomes five `export` lines. Verify with
`apps/desktop/test/headless_api/route_metadata_test.dart` (794 lines) unchanged.

---

### 1.3 `apps/desktop/lib/headless_api_server/http_middleware.dart` — 1110 lines

**Why it is big.** This is already a `part of '../headless_api_server.dart'`, but one member,
`_authMiddleware()` (lines **518-932, 414 lines**), is 37% of the file: it inlines the public-path
allowlist, the WS query-param/ticket flow, bearer extraction, scope checks, CSRF, and the paired-
session lookup in a single closure.

**Split plan** — two new sibling `part` files registered in `headless_api_server.dart:44-48`
(order matters only for readability; parts are order-independent):

- `headless_api_server/auth_middleware.dart` — private extension
  `_HeadlessApiServerAuthMiddleware on HeadlessApiServer`: `_authMiddleware` (518-932),
  `_authIdentityFrom` (933), `_extractBearerToken` (951), `_sessionOwnershipMiddleware` (972),
  `_touchPairedDeviceSeen` (1062). Also hoist the two closure-local consts `publicPaths`
  (523-556) and `webSocketPaths` (566) to file-level `const` sets named
  `_authPublicPaths` / `_authWebSocketPaths` — they are rebuilt on every middleware
  construction today and are pure data. ≈610 lines.
- `headless_api_server/rate_limit_middleware.dart` — `_rateLimitMiddleware` (297),
  `_denyRateLimited` (357), `_highRiskAuditMiddleware` (406), `_rateLimitClientKey` (463),
  plus `_rateLimitTrustProxyHeaders` / `_readTrustProxyFlag` (16-23). ≈220 lines.

`http_middleware.dart` retains request tracking, CORS (`_corsMiddleware`, `_buildCorsHeaders`,
`_resolveAllowedOrigin`), the two body-limit middlewares, `_readRequestBodyWithinLimit`, and the
API-version middleware → **≈290 lines**.

Note `_authMiddleware` at 610 lines is still large after the move; a second pass should extract
the WS ticket/query-token branch (lines 601-660ish) into a private helper
`_authorizeWebSocketUpgrade(Request)` returning `Request?`. Do that as a follow-up, not in the
same commit as the file move, so the diff stays reviewable.

---

### 1.4 `apps/mobile/lib/screens/dashboard/tabs/camera_tab.dart` — 1221 lines

**Why it is big.** One file holds the tab shell plus 12 private widgets, three of which
(`_ExposureControls`, `_CoolingCard`, `_FilterCard`) each carry their own copy of the same
"operation generation" concurrency guard (§2.3).

**Split plan** — new directory `apps/mobile/lib/screens/dashboard/tabs/camera/`; these are plain
private widgets used only inside this file, so they move as ordinary libraries with the leading
underscore dropped (they become package-private to the mobile app, which is fine; nothing outside
`apps/mobile` imports them):

| New file | Moves (current lines) | ≈ |
|---|---|---|
| `camera_live_view_card.dart` | `_LiveViewStreamCard` + state (93-255) | 163 |
| `camera_thumbnail_card.dart` | `_ThumbnailCard`, `_ImagePainterWidget` + state, `_RawImagePainter`, `_FullscreenImage` (256-490) | 235 |
| `camera_exposure_controls.dart` | `_ExposureControls` + state (491-731) | 241 |
| `camera_cooling_card.dart` | `_CoolingCard` + state (732-949) | 218 |
| `camera_filter_card.dart` | `_FilterCard` + state, `_FilterChip` (950-1166) | 217 |
| `camera_tab_atoms.dart` | `_Pill`, `_Metric` (1167-1221) | 55 |
| `device_operation_guard.dart` | new — see §2.3 | ~45 |

`camera_tab.dart` keeps only `CameraTab` (20-92) + imports → **≈100 lines**.

Land §2.3 (the shared `DeviceOperationGuard` mixin) in the same series, otherwise three copies of
the guard get scattered across three new files and become harder to reconcile later.

---

### 1.5 `apps/mobile/lib/screens/dashboard/tabs/mount_tab.dart` — 1125 lines

**Why it is big.** Tab shell plus nine presentation widgets, several of which (`_Dpad` /
`_DpadButton` / `_StopButton`, and `_SlewToTarget` with its catalog search) are self-contained
sub-features.

**Split plan** — new directory `apps/mobile/lib/screens/dashboard/tabs/mount/`:

| New file | Moves | ≈ |
|---|---|---|
| `mount_position_card.dart` | `_PositionCard`, `_MetricCell`, `_StatusBadge` (284-420) | 137 |
| `mount_slew_rate_selector.dart` | `_SlewRateSelector`, `_RateChip` (421-513) | 93 |
| `mount_dpad.dart` | `_Dpad`, `_DpadButton` + state, `_StopButton` (514-759) | 246 |
| `mount_controls_row.dart` | `_ControlsRow` + state (760-845) | 86 |
| `mount_slew_to_target.dart` | `_SlewToTarget` + state, `_HitTile` (846-1125) | 280 |

`mount_tab.dart` keeps `MountTab` + `_MountTabState` (23-283: `_startMove`, `_stopMove`,
`_stopAll`, `_queueAxisCommand`, `_showMessage`, `dispose`, `build`) → **≈290 lines**.
The `_Dpad` widgets take `onStart`/`onStop` callbacks today, so the move is a pure relocation.

---

### 1.6 `apps/mobile/lib/services/saved_servers_service.dart` — 1213 lines

**Why it is big.** Three concerns in one file: a 390-line `SavedServer` value type with
hand-written JSON + `==`/`hashCode`, a storage-key holder, and the service.

**Split plan** — new directory `apps/mobile/lib/services/saved_servers/`:

- `saved_server.dart` — `SavedServer` (57-445), including `isTailscaleEndpoint` (199),
  `toJsonNonSecret` (268), `fromJsonNonSecret` (296), `operator ==` (401), `hashCode` (419),
  `toString` (436). ≈390 lines.
- `saved_servers_storage_keys.dart` — `SavedServersStorageKeys` (447-479). ≈35 lines.
- `saved_servers_migration.dart` — `_migrateLegacyIfNeeded` (1096-1213) as a top-level
  `Future<void> migrateLegacySavedServers(SharedPreferences prefs, …)`; it is called once from
  `loadAll` and has no other coupling to instance state. ≈120 lines.

`saved_servers_service.dart` keeps `SavedServersService` (480-1095) and re-exports
`saved_server.dart` + `saved_servers_storage_keys.dart` so the ~20 existing importers of
`services/saved_servers_service.dart` compile unchanged → **≈620 lines**.

Do **not** restructure the `_serializeMutation` / `_mutationTail` queue (1011-1017) while moving
files: it is correct as written (errors are captured into the per-call `Completer`, so the tail
future never rejects and the queue cannot poison), and it is the only thing keeping concurrent
mutations ordered.

---

### 1.7 `packages/skotiq_updater/lib/src/services/update_service.dart` — 1126 lines

**Why it is big.** The staging/apply/rollback state machine, the manifest HTTP client, the
directory-layout resolvers, the anti-freeze/skip-version persistence, and six result/exception
types all live in one class + file.

**Split plan** — the class holds `_httpClient`, `_verifier`, `_antiFreezeStore`, `_channel`,
`_currentVersion` etc. so the pieces that touch those must stay; the pieces that do not can leave
outright:

1. `packages/skotiq_updater/lib/src/models/update_results.dart` — move the pure value types:
   `UpdateNotice` (38), `UpdateCheckResult` (1067), `StagedUpdate` (1084),
   `PendingInstallState` (1098), `PendingInstallStatus` (1100), `UpdateException` (1119).
   ≈120 lines. `update_service.dart` re-exports them so
   `packages/skotiq_updater/lib/skotiq_updater.dart` consumers are unaffected.
2. `src/services/update_paths.dart` — new top-level functions taking the
   `applicationSupportDirectoryProvider` the service already injects:
   `_getStagingDirectory` (446), `_getInstallDirectory` (851), `_getBackupDirectory` (858),
   `_getUpdatesRootDirectory` (867), `_getPendingInstallFile` (876), `_getSkippedVersionFile` (881).
   ≈90 lines.
3. `src/services/update_apply.dart` — `part of 'update_service.dart'` holding a private
   extension `_UpdateApply on UpdateService`: `applyUpdate` (533-750, 218 lines),
   `hasRestorePoint` (751), `rollbackToPrevious` (769-850). Keep public forwarders in the main
   file. ≈300 lines.
4. `src/services/update_staging_guards.dart` — same `part` pattern, extension `_UpdateGuards`:
   `verifyPendingInstall` (174), `_assertManifestNotRolledBack` (935),
   `_readStagedManifest` (957), `_assertVerifiedMarkerMatches` (973),
   `_writeExpectedHashes` (996), `readSkippedVersion` (889), `writeSkippedVersion` (909).
   ≈180 lines.

`update_service.dart` retains construction, `configure`, `cancelDownload`, `checkForUpdates`,
`_fetchManifest`, `_assertSecureUpdateUrl`, `_assertManifestCompatibility`, `downloadAndStage`,
`getStagedUpdate`, `clearStagedUpdate`, `_flushDeveloperLog`, `dispose`, and the forwarders →
**≈420 lines**. Land the timeout fix (§5.2) at the same time; it touches lines 245 and 319 only.

---

### 1.8 `packages/skotiq_updater/lib/src/services/update_controller.dart` — 1107 lines

**Why it is big.** Eight event classes and four DTOs (lines 32-386, 355 lines) sit ahead of the
controller (387-1107).

**Split plan** (trivially safe — these are leaf types):

- `packages/skotiq_updater/lib/src/models/update_lifecycle.dart` —
  `UpdateLifecycleState` (32), `UpdateLifecycleStateX` (66), `UpdateControllerStatus` (72),
  `StagedUpdateInfo` (115), `UpdateCheckOutcome` (150). ≈170 lines.
- `packages/skotiq_updater/lib/src/models/update_events.dart` — `UpdateAvailableEvent` (199)
  through `UpdateFailedEvent` (358) and their `UpdateEvent` base. ≈190 lines.

`update_controller.dart` keeps `UpdateController` (387-1107) and re-exports both new files →
**≈730 lines**, which is acceptable for a single state machine. If a second pass is wanted, move
`bootstrap` (444-535) + `_readTimestamp` (1088) + `_writeTimestamp` (1100) into a
`part` file `update_controller_bootstrap.dart` (≈130 lines).

---

### 1.9 `packages/skotiq_remote_protocol/lib/src/enhanced_discovery.dart` — 1094 lines

**Why it is big.** The QR pairing payload type with its 226-line strict parser
(`QrConnectionData.parseStrict`, 197-423) is bolted onto the discovery service.

**Split plan**:

- `packages/skotiq_remote_protocol/lib/src/qr_connection_data.dart` —
  `QrRejectionReason` (91), `QrValidationException` (107), `QrConnectionData` (122-423)
  including `toJson` (174), `toQrString` (192), `parseStrict` (197). ≈335 lines.
- `packages/skotiq_remote_protocol/lib/src/discovery/discovery_prefs.dart` —
  `_DiscoveryPrefs` (22-90), made public as `DiscoveryPrefs`. ≈70 lines.

`enhanced_discovery.dart` keeps `ServerProbeOutcome` (424) and
`EnhancedSkotiqDiscovery` (438-1094) and adds
`export 'qr_connection_data.dart';` so the package barrel
(`skotiq_remote_protocol.dart:17`, which exports this file) keeps the same public surface →
**≈690 lines**. `discoverViaMdns` (836-975) is the remaining hot spot; it is a single closure
with an inline TXT-record parser — extract `DiscoveredServer? _serverFromResolvedService(...)`
(the block at 862-925) as a follow-up.

---

### 1.10 `apps/mobile/lib/services/notification_service.dart` — 1061 lines

**Why it is big.** 18 `notify*` methods, each repeating a full inline `NotificationDetails(
android: AndroidNotificationDetails(...), iOS: DarwinNotificationDetails(...))` literal.
`grep -c 'NotificationDetails('` → **54 occurrences** across five distinct channels
(`skotiq_sequence`, `skotiq_warnings`, `skotiq_info`, `skotiq_push`,
`skotiq_critical`, declared once each at lines 262/271/280/289/300 and then re-declared at 18
call sites: 456, 489, 522, 550, 591, 636, 666, 695, 724, 752, 783, 812, 873, 910, 938, 966, 1007,
1035).

**Split plan — deduplicate first, then split.** After the dedup the file is already under the
threshold, so the split is optional:

1. New `apps/mobile/lib/services/notification_service/channels.dart`
   (`part of '../notification_service.dart';` — the directory already holds one part,
   `contracts.dart`, wired at `notification_service.dart:8`). Move the five channel definitions
   and add one `const NotificationDetails` per channel plus
   `NotificationDetails _detailsFor(_NsChannel channel)`. Rewrite each `notify*` body as
   `await _notifications.show(id, title, body, _detailsFor(_NsChannel.critical), payload: '…');`
   — collapses ~600 lines to ~150.
2. New `notification_service/notification_routing.dart` (part) — `setNavigator` (323),
   `handleLaunchNotification` (338), `_onNotificationTapped` (363), `_routeForPayload` (399).
   ≈125 lines.
3. New `notification_service/notification_permissions.dart` (part) —
   `_requestAndroidNotificationPermission` (176), `refreshAndroidNotificationsAuthorization` (222),
   `refreshCriticalAlertsAuthorization` (246). ≈85 lines.

`notification_service.dart` ends ≈300 lines. **The 18 `notify*` methods are `@override`s of
`MobileNotificationSink`** (`notification_service/contracts.dart:21+`) so they must stay on the
class itself, not move into an extension.

---

### 1.11 `apps/mobile/lib/screens/servers/saved_servers_screen.dart` — 1005 lines

**Why it is big.** Screen + five presentation widgets + a local `StateNotifier`.

**Split plan** — new directory `apps/mobile/lib/screens/servers/widgets/`:

- `saved_server_row.dart` — `_SavedServerRow` (812-947, incl. `_secondaryLine` and the static
  `_formatRelative`) and `_ReachBadge` (948-1005). ≈195 lines.
- `saved_servers_empty_state.dart` — `_EmptyState` (776-811). ≈36 lines.
- `edit_text_dialog.dart` — `_EditTextDialog` + state (693-775). ≈83 lines.
- `reachability_notifier.dart` — `_ReachabilityNotifier` (51-77) and its provider. ≈30 lines.

`saved_servers_screen.dart` keeps `SavedServersScreen` + `_SavedServersScreenState` (78-692) →
**≈660 lines**. A second pass can move the six action methods
(`_activateServer` 227, `_activateRelayServer` 364, `_handleAddServer` 399, `_showRowMenu` 428,
`_editTailscaleHost` 534, `_renameServer` 563, `_editNotes` 586, `_confirmAndRemove` 610,
`_persistServerChange` 646) into a `part` file `saved_servers_actions.dart`.

### Oversized test file (low priority)

`apps/desktop/test/headless_api/calibration_handlers_test.dart` — 1166 lines. Split by
`group()` into `calibration_dark_library_test.dart` / `calibration_flat_test.dart` /
`calibration_defect_map_test.dart` mirroring the three handler files under
`lib/headless_api/handlers/calibration_handlers/`.

---

## 2. Duplication

### 2.1 The endpoint catalog is a hand-maintained mirror of the route table — **HIGH value**

`apps/desktop/lib/headless_api/handlers/system_endpoint_catalog.dart:18` returns a
`const` list of **598** `'<METHOD> <path>'` strings. The runtime routing table is
`List<HeadlessRoute>` built by the 54 `routes/*_routes.dart` files — **610** `HeadlessRoute(...)`
constructions, each already carrying `HttpMethod method` and `String path`
(`routes/headless_route.dart:48-63`), and the file's own doc comment says
"[HeadlessRoute] is the single source of truth for the routing table at runtime".

The two are kept in sync by a CI script (`tools/production/headless_api_contract_audit.dart`),
which is the tell: a guard exists precisely because the data is stated twice.

**Canonical survivor:** the `HeadlessRoute` lists.
**Merge:** replace `availableHeadlessEndpoints()` with a derivation over the same `allRoutes`
list `server_lifecycle.dart:18+` builds — `'${route.method.name.toUpperCase()} ${route.path}'` —
hoisting the `allRoutes` construction into a pure `List<HeadlessRoute> buildAllRoutes(...)`
function so both `registerRoutes` and the catalog consume it. The WebSocket pseudo-entries
(`'WS /ws/live-view'`, `'WS /api/ws'`, `'WS /events'`) and the `'SSE …'` entries have no
`HeadlessRoute` and stay as a small hand-written supplement list. The CI audit script then only
needs to check that supplement.
**Effort: medium.** Guard: `apps/desktop/test/headless_api/route_metadata_test.dart` plus the
existing contract-audit script must both stay green, and `GET /api/info`'s `endpoints` array must
be byte-identical before/after (order is currently hand-curated — preserve it by ordering the
derivation the same way `allRoutes` is concatenated).

### 2.2 Sequencer payload readers duplicate `validation.dart` — **and diverge in status code**

`sequencer_handlers.dart:1978-2000` defines `_readNullableDouble`, `_readOptionalInteger`,
`_readNullableBool`. `headless_api/validation.dart:464-546` already defines `optionalInt`,
`optionalDouble`, `optionalBool` doing the same job, and `sequencer_handlers.dart` **already
imports that file** (line 13).

The copies are not equivalent: `_readNullableDouble` (1982) and `_readNullableBool` (1999) throw
`FormatException`, which `errorTranslationMiddleware` (`validation.dart:711-799`) has no clause
for, so it falls into the terminal `catch (e)` at line 772 and returns **500 `internal_error`**.
`optionalDouble`/`optionalBool` throw `BadRequestError` → **400**.

**Canonical survivor:** `validation.dart`. Delete the three readers; move
`_readStringDoubleMap` / `_readStringBoolMap` / `_readNestedDoubleMap` (2002-2078) into
`validation.dart` as `optionalStringDoubleMap` / `optionalStringBoolMap` /
`optionalNestedDoubleMap`. **Effort: small**, but it is a wire-visible status-code change —
see §5.1.

### 2.3 Three copies of the "operation generation" guard in `camera_tab.dart`

`_ExposureControlsState` (523-601), `_CoolingCardState` (748-848) and `_FilterCardState` (960-…)
each declare `int _operationGeneration = 0;`, `ProviderSubscription<SkotiqBackend>?
_backendSubscription`, the identical `initState` `ref.listenManual(backendProvider, …)` block,
the identical `didUpdateWidget` device-id check, the identical `dispose`, an identical
`_retireOperation()`, and a near-identical `_isCurrent(backend, deviceId, generation)`
(compare 592-600 with 839-847 — same five clauses, only the busy-flag name differs:
`_starting` vs `_busy`).

**Canonical survivor:** a new
`apps/mobile/lib/screens/dashboard/tabs/camera/device_operation_guard.dart` exposing
`mixin DeviceOperationGuard<T extends StatefulWidget> on ConsumerState<T>` with
`int operationGeneration`, `beginOperation()`, `retireOperation()`,
`bool isCurrent(SkotiqBackend, String?, int)`, `attachBackendListener()`, and an abstract
`String? get guardedDeviceId` / `void onRetire()` hook for the per-widget busy flag.
`_CoolingCardState` additionally nulls `_resumeCoolingTarget` on retire (759, 770) — that is what
`onRetire()` is for. **Effort: small.** Land with §1.4.

### 2.4 Two copies of the JPEG frame response builder

`handlers/device_handlers/camera_handlers.dart:521-551`
(`GET /api/camera/last-image/jpeg`) and `handlers/run_watch_handlers.dart:554-600`
(`GET /api/run-watch/frame-thumbnail`) both call
`encodeCapturedImageDisplayBufferToJpeg`, then build a `contentResponse` with the same
`cache-control: no-store, no-cache, must-revalidate` plus the same `x-frame-timestamp` /
`x-frame-exposure-secs` / `x-frame-hfr` / `x-frame-star-count` header set. Only the
`x-image-*` dimension headers differ (present in `camera_handlers`, absent in `run_watch`).

**Canonical survivor:** a shared
`Response capturedImageJpegResponse(CapturedImageResult image, DisplayBufferJpegEncodeResult
encoded, {bool includeImageDimensionHeaders = true})` in
`apps/desktop/lib/headless_api/display_buffer_jpeg.dart` (which already owns
`DisplayBufferJpegEncodeResult` and `capturedImageTimestampUtc`). **Effort: small.**

### 2.5 Notification detail literals

18 duplicated `NotificationDetails` literals over 5 channels — see §1.10 step 1.
**Canonical survivor:** one `const NotificationDetails` per channel in
`notification_service/channels.dart`. **Effort: small.**

### Explicitly checked and NOT duplication (do not re-file these)

- `EnhancedSkotiqDiscovery.discoverViaUdp` (`enhanced_discovery.dart:985-991`) **delegates**
  to `SkotiqDiscovery.discoverServers` — it is a thin wrapper, not a reimplementation.
- The LAN push wire format has exactly one codec: `encodePushFrame` / `decodePushFrame` in
  `packages/skotiq_remote_protocol/lib/src/push/lan_push_broadcaster.dart:257,332`; the
  mobile receiver calls `decodePushFrame` at
  `apps/mobile/lib/services/lan_push_notification_receiver.dart:229`. Shared, correct.
- `packages/skotiq_updater/.../lan_push_receiver.dart` (OTA, TCP:45680) and
  `apps/mobile/.../lan_push_notification_receiver.dart` (alerts, UDP:45681) are deliberately
  different protocols; the mobile file's header (lines 10-14) says so.
- `event_forwarding.dart:108-132` encodes each event **once** and reuses the string across
  sockets. Correct.

### Suspected CROSS-PACKAGE duplication (for the cross-cutting agent)

- `tools/update_pusher/push_update.dart:153` defines its own `discoverTargets()` and a local
  `UpdateTarget`; `packages/skotiq_remote_protocol/lib/src/discovery.dart:512-632` already
  ships `DiscoveredUpdateTarget` + `UpdatePushDiscovery.discoverTargets` for the same UDP
  responder protocol.
- The mDNS TXT-record key names (`version`, `name`, `signaling_port`, `scheme`, `fingerprint`,
  `pairingSupported`) are written as bare string literals on the advertise side
  (`packages/skotiq_remote_protocol/lib/src/discovery/mdns_registration.dart:103`) and again
  on the parse side (`enhanced_discovery.dart:886-912`). One shared const key set is owed.
- `apps/desktop/lib/headless_api/validation.dart` carries a full JSON-payload validation kit
  (`requireString`/`optionalInt`/`requireQueryDouble`/…, 382-690). `skotiq_core` and the
  Rust bridge boundary very likely have their own coercion layer for the same wire values.
- `describeBackendError` + `_httpStatusForBackendError` + `_backendErrorCode`
  (`validation.dart:48-210`) map `bridge_error.SkotiqError` to user text and HTTP status.
  The desktop GUI (`packages/skotiq_app`) almost certainly renders the same error union to
  user text somewhere else.
- `apps/mobile/lib/services/notification_service.dart` defines the alert taxonomy
  (severity → channel → title/body) client-side; the desktop narrator/push broadcaster
  (`push/lan_push_broadcaster.dart` `PushNotificationFrame.severityCode`) defines a parallel one
  server-side.
- `apps/mobile/lib/services/saved_servers_service.dart` `SavedServer` (57-445) vs the desktop's
  paired-device / profile row types in
  `packages/skotiq_remote_protocol/lib/src/database/paired_devices_table.dart`.

---

## 3. Dead code

### 3.1 `SecureDiscovery` — 620 lines, zero callers, and the docs point users at it

`packages/skotiq_remote_protocol/lib/src/discovery/secure_discovery.dart` — the whole file:
`DiscoveryMode` (10), `SecureDiscoveredServer` (22), `SecureDiscovery` (74).

Evidence: `grep -rn 'SecureDiscovery|DiscoveryMode\b' --include='*.dart'` across the entire repo
(excluding `build/` and `.dart_tool/`, excluding the defining file) returns **nothing** —
no app, no package, no test, no tool. The only reference is the barrel export at
`packages/skotiq_remote_protocol/lib/skotiq_remote_protocol.dart:30`.

The package's own `SECURITY.md:66` already records it: *"`SecureDiscovery` … **Not wired** into
desktop startup. The class exists for pairing-mode broadcasts but is not started by
`HeadlessApiServer` or the GUI bootstrap. Do not document it as an active control plane."*
Meanwhile `packages/skotiq_remote_protocol/QUICK_START.md:25,56,234,292` presents it as the
recommended discovery API. Deleting the file must also strip those QUICK_START sections.

### 3.2 `ChannelEncryption` — 205 lines, only its own test uses it

`packages/skotiq_remote_protocol/lib/src/crypto/channel_encryption.dart` (`ChannelEncryption`,
`encrypt`, `encryptJson`, `decryptJson`, `fromToken`).
Evidence: `grep -rn 'ChannelEncryption|encryptJson' --include='*.dart'` repo-wide, excluding the
defining file, hits only `packages/skotiq_remote_protocol/test/channel_encryption_test.dart`.
Exported at `skotiq_remote_protocol.dart:27`. Live transport is TLS + bearer tokens
(`headless_api/tls_provisioner.dart`, `auth/token_resolver.dart`), so this second, unused
encryption layer is a maintenance and audit liability. Delete the file, its test, and the export.

### 3.3 `SequenceDelayPlugin` (440) + `CustomNotificationPlugin` (294) — never constructed

`packages/skotiq_plugins/lib/examples/sequence_delay_plugin.dart` (`SequenceDelayPlugin` :24,
`ConditionalDelayNode` :122, `CooldownWaitNode` :201, `TwilightWaitNode` :309) and
`packages/skotiq_plugins/lib/examples/custom_notification_plugin.dart` (`NotificationRule` :8,
`CustomNotificationPlugin` :123).

Evidence: `kUserFacingExamplePlugins`
(`packages/skotiq_plugins/lib/src/plugin_registration.dart:81-103`) registers exactly four —
Discord, Pushover, Home Assistant, WeatherLogger — and `plugin_registration.dart:28-31` imports
only those four example files. `grep -rn 'SequenceDelayPlugin|CustomNotificationPlugin'` across
`apps` + `packages` hits only the defining files' own doc comments; `grep -rn
'ConditionalDelayNode|CooldownWaitNode|TwilightWaitNode|NotificationRule'` outside
`lib/examples/` returns nothing, including `packages/skotiq_plugins/test/
plugin_sequence_nodes_test.dart` (797 lines), whose header (lines 9-10) names only Pushover,
Discord and Home Assistant.

Both are still exported (`skotiq_plugins.dart:72-73`). Either register them in
`kUserFacingExamplePlugins` (they look like intended product features — a conditional delay and a
rules-based notifier) or delete them. **This is a product decision, not a mechanical one.**

### 3.4 `UiPlugin` / `DevicePlugin` are declared extension points with no host consumer

`packages/skotiq_plugins/lib/src/plugin_api.dart:190` (`UiPlugin`), `:214`
(`UiExtensionPoint`), `:227` (`DevicePlugin`).

Evidence: the only way a host reaches typed plugins is
`PluginHost.getPlugins<T>()` (`plugin_host.dart:171`). `grep -rn 'getPlugins<|getPlugins('`
across `apps` + `packages`, excluding `skotiq_plugins/test` and `plugin_host.dart`, returns
**nothing** — no production caller anywhere. `UiPlugin` / `DevicePlugin` are referenced only by
`src/example_plugin.dart:123,177` and `test/plugin_system_test.dart`.

By contrast `SequencePlugin` **is** wired: `skotiq_app` reaches it through
`registerSequencePlugin` (see `packages/skotiq_app/test/services/
plugin_node_palette_wiring_test.dart:141`).

So a third-party `UiPlugin`'s panels would never render and a `DevicePlugin`'s devices would
never appear — the README (`packages/skotiq_plugins/README.md`, "Plugin Types") advertises
both. Either wire them or mark them experimental in the README and the doc comments. Do **not**
silently delete: they are the published API surface of a plugin package.

### 3.5 `UpdatePushDiscovery.discoverTargets` + `DiscoveredUpdateTarget` — client half is dead

`packages/skotiq_remote_protocol/lib/src/discovery.dart:512-532`
(`DiscoveredUpdateTarget`) and `:541-632` (`UpdatePushDiscovery.discoverTargets`).
Evidence: `grep -rn 'discoverTargets'` repo-wide finds only the definition and
`tools/update_pusher/push_update.dart`, which defines and calls its **own** local
`discoverTargets()` (`push_update.dart:153`) returning a local `UpdateTarget` type.
The sibling `UpdatePushDiscovery.startResponding` (`discovery.dart:633`) **is** live
(`apps/desktop/lib/desktop_app_bootstrap.dart:556`), so delete the two client-side members only,
or point `tools/update_pusher` at the package version (see §2 cross-package suspects).

### Checked, NOT dead (do not re-file)

- `apps/desktop/lib/frame_timing_probe.dart` — `main.dart:331`.
- `apps/desktop/lib/desktop_logging_init.dart` — `main.dart:11`, `main_headless.dart:12`.
- `ExamplePlugin` (`packages/skotiq_plugins/lib/src/example_plugin.dart:13`) — test-only, but it is the
  documented reference implementation for the README; keep.
- Every `handlers/*_handlers.dart` file has a matching `routes/*_routes.dart` registration.

---

## 4. Performance risks

### 4.1 Full-resolution JPEG encode runs synchronously on the server isolate — **HIGH**

`apps/desktop/lib/headless_api/display_buffer_jpeg.dart:34-84`
(`encodeCapturedImageDisplayBufferToJpeg`) does, on the calling isolate:

- `final rgba = Uint8List.fromList(image.displayData);` (line 44) — `displayData` is **already**
  a `Uint8List` (`packages/skotiq_core/lib/src/models/imaging/imaging_models/
  file_format_and_capture_state.dart:84`), so this is a gratuitous full copy of
  `width × height × 4` bytes. On a 26 MP sensor that is ~104 MB per request.
- `img.copyResize` (line 61) and `img.encodeJpg` (line 64) — pure-Dart, no isolate.
- `Uint8List.fromList(jpeg)` (line 78) — `package:image` ^4.1.7 `encodeJpg` already returns a
  `Uint8List`; second gratuitous copy.

Two live call sites, both in HTTP handlers with no `compute`/`Isolate.run`:
`handlers/device_handlers/camera_handlers.dart:521` (`GET /api/camera/last-image/jpeg`) and
`handlers/run_watch_handlers.dart:554` (`GET /api/run-watch/frame-thumbnail`, which
`camera_handlers.dart:556-560` documents as intended for **2-5 Hz polling** by a remote viewer).

In the desktop GUI process the headless server shares the Flutter root isolate, so a full-frame
encode blocks the UI *and* every other in-flight HTTP request for its duration.

**Fix:** drop both `Uint8List.fromList` copies; move `copyResize` + `encodeJpg` behind
`Isolate.run` (or a persistent worker isolate, since the input is a transferable typed data
buffer).

### 4.2 Live-view hub decodes + re-encodes on the server isolate at 4 Hz — **MEDIUM-HIGH**

`apps/desktop/lib/headless_api/handlers/live_view_stream_handlers.dart:433`
starts `Timer.periodic(_producerMinTick /* 250 ms, line 153 */)` driving `_producerTick` (459).
Per tick, per device: `img.decodeJpg(masterJpeg)` (line 511) then, per distinct subscriber
encode-key, `_encodeFor` → `img.copyCrop` / `img.copyResize` / `img.encodeJpg` (585-604), plus a
third `Uint8List.fromList(...)` wrapper at 603 around an already-`Uint8List` result.

The hub is well-designed otherwise (decode once per device per tick, cache encodes by
`(maxDim, region, quality)` — 532-556), so the cost is bounded, but all of it is on the isolate
that also serves HTTP and, in GUI mode, paints frames. **Fix:** same as 4.1 — move the
decode/resize/encode pipeline to a worker isolate; drop the redundant copy at 603.

### 4.3 `CameraTab` watches exposure progress at the top of the tab — **MEDIUM**

`apps/mobile/lib/screens/dashboard/tabs/camera_tab.dart:24-59`: `CameraTab.build` watches five
providers, including `exposureProgressProvider` (line 27) and `cameraStateProvider` (line 25).
Both are written from the same handler on every `ExposureProgress` backend event
(`packages/skotiq_core/lib/src/services/imaging_service.dart:292-297` calls
`cameraNotifier.setExposing(...)` and `progressNotifier.updateProgress(...)` back-to-back), so
every progress event rebuilds the whole `ListView` subtree at line 60 — `_ThumbnailCard`,
`_LiveViewStreamCard`, `_ExposureControls`, `_CoolingCard`, `_FilterCard`.

The children are guarded (`_ImagePainterWidget.didUpdateWidget` at line 378 compares
`oldWidget.image != widget.image` before re-decoding, so no image is re-decoded), which is why
this is medium and not high. **Fix:** push `ref.watch(exposureProgressProvider)` down into
`_ExposureControls` (which is the only consumer of `progress`) and pass the rest unchanged;
mark the static children `const` where possible.

### 4.4 `_ImagePainterWidget._decode` copies the whole display buffer — **MEDIUM**

`apps/mobile/lib/screens/dashboard/tabs/camera_tab.dart:395`:
`ui.decodeImageFromPixels(Uint8List.fromList(img.displayData), …)`. `displayData` is already a
`Uint8List`; `decodeImageFromPixels` accepts it directly. On the fullscreen path
(`_FullscreenImage`, line 458) this is a full-sensor RGBA buffer copied on the UI isolate on
every image change. **Fix:** pass `img.displayData` directly (one-token change).

### 4.5 `buildOpenApiSpec` rebuilds the whole 598-endpoint spec per request — **LOW**

`apps/desktop/lib/headless_api/route_metadata.dart:96-196`, called from
`handlers/system_handlers.dart:349` for `GET /api/openapi.json`. It loops every endpoint,
calls `endpointRateLimitFor` (111) and `openApiRequestBodyFor` per path, then json-encodes.
Cheap to memoise (the input is a compile-time constant list); low impact because the endpoint is
on-demand and rate-limited.

---

## 5. Reliability risks

### 5.1 Sequencer config endpoints return 500 for a bad field type

`sequencer_handlers.dart:1982` (`_readNullableDouble`) and `:1999` (`_readNullableBool`) throw
`FormatException`. `errorTranslationMiddleware` (`validation.dart:711-799`) has clauses for
`BadRequestError` (724), `HandlerFailure` (726), `bridge_error.SkotiqError` (747) — and
nothing for `FormatException`, so it lands in the terminal `catch (e)` at line 772 and returns
**500 `internal_error`**.

Reachable from at least: `POST /api/sequencer/sky-brightness` with `{"mag":"bright"}`
(handler at 1389, reader call at 1394); `POST /api/sequencer/weather-verdict` with a non-bool
`unsafeOverride` (1761/1766); `POST /api/sequencer/cloud-motion` (1727, six reader calls at
1732-1749); `POST /api/sequencer/secondary-rig/start` with a string `exposureSecs`
(1867/1878). A client that mis-types a field gets a 500 and a server-side error log instead of a
400 telling it which field is wrong. Fixed by §2.2.

### 5.2 The entire updater HTTP path has no timeout, and a hang wedges the subsystem permanently

`grep -n 'timeout|Timeout'` across `packages/skotiq_updater/lib/src/services/
update_service.dart`, `update_controller.dart`, `providers/update_provider.dart` and
`apps/desktop/lib/headless_api/update_wiring.dart` returns **zero hits**.

- `update_service.dart:245` — `await _httpClient.get(Uri.parse(versionUrl))`, no `.timeout(…)`.
- `update_service.dart:319` — same in `_fetchManifest`.
- `update_downloader.dart:71` — `await _client.send(request)`, no timeout; the chunk loop
  (`moveNextOrCancel`, 113-125) has no per-chunk stall deadline either (it is cancellable, but
  only by an operator who is watching).

`UpdateController.checkForUpdates` calls `_beginOperation('check')`
(`update_controller.dart:537`), and `_beginOperation` **throws `StateError`** if another
operation is active (`:1054-1062`). Its own comment at `:559` says *"the HTTP check itself is not
cancellable"*. So a blackholing update server (SYN-accept, never respond) leaves
`_activeOperation == 'check'` forever, the controller stuck in `UpdateLifecycleState.checking`,
and **every subsequent check/download/apply/rollback throws** — including the headless
`/api/update/*` routes, which surface it as a 500. Only a process restart recovers.

**Fix:** `.timeout(const Duration(seconds: 20))` on both `get` calls and a stall deadline on the
download stream; on timeout, `_endOperation` in a `finally` and surface a typed
`UpdateException('Update server did not respond')`.

### 5.3 `EndpointRateLimiter._requestsByKey` is unbounded

`apps/desktop/lib/headless_api/route_metadata.dart:1293` —
`final _requestsByKey = <String, List<DateTime>>{};`, keyed
`'$clientKey ${method} $path'` (line 1305). Timestamps inside a bucket are pruned (1308), but a
**key is never removed** and there is no cap. Compare its sibling ten lines above:
`TokenBucketRateLimiter` explicitly carries `maxBuckets = 8192` with LRU eviction
(`:1180, 1264-1268`) — the asymmetry looks like an oversight, not a decision.

The path component is the concrete request path, and several rate-limited prefixes are
parametric: `_controlPathPrefixes` (`:811`) includes `/api/mosaic/` and `/api/coimaging/`, so
each distinct `/api/coimaging/sessions/<sessionId>/contribute` mints a permanent entry. The
client component is `_rateLimitClientKey` (`http_middleware.dart:463`), i.e. the peer address,
which multiplies it. Slow leak over a long unattended run.
**Fix:** give it the same `maxEntries` + LRU treatment, and drop keys whose pruned list is empty.

### 5.4 No cap on concurrent WebSocket clients

`apps/desktop/lib/headless_api_server/websocket_sessions.dart:80` — `_sockets.add(socket)` with
no ceiling; `headless_api_server.dart:171-190` declares `_sockets`, `_socketViewerIds`,
`_socketAuthIdentities`, `_socketLastSeenAt` with no bound. Every broadcast iterates all sockets
(`event_forwarding.dart:77, 132, 169, 210`), so cost is linear in connections.
Mitigating: the auth middleware runs before the upgrade, and `_removeWebSocket`
(`websocket_sessions.dart:130-143`) cleans all four collections correctly — this is not a leak,
only an unbounded resource. Still worth a `maxWebSocketClients` (reject with 503 above it) on an
appliance whose token may be shared across a household.

### 5.5 `Uint8List.fromList(_buffer.sublist(0, length))` double-copies on the OTA receive path

`packages/skotiq_updater/lib/src/services/lan_push_receiver.dart:561` and `:572` —
`sublist` already allocates a copy, `Uint8List.fromList` copies it again. On the OTA package
receive path the buffers are megabyte-scale. Low impact (once per transfer), trivial fix
(`Uint8List.sublistView(_buffer, 0, length)`), listed for completeness.

### Checked and sound (do not re-file)

- `SavedServersService._serializeMutation` (`saved_servers_service.dart:1011-1017`) — errors are
  routed into the per-call `Completer`, so `_mutationTail` never rejects and the queue cannot
  poison.
- `_ImagePainterWidgetState` (`camera_tab.dart:367-421`) — generation-guarded decode with correct
  `ui.Image` disposal on stale callbacks, `didUpdateWidget` and `dispose`.
- `_removeWebSocket` (`websocket_sessions.dart:130-143`) — removes from all four maps.
- 58 explicit `unawaited(...)` call sites across the subsystem; no bare fire-and-forget pattern
  found, and no `// ignore: unawaited_futures` suppressions.
- `update_downloader.dart:103`'s `streamedResponse.contentLength!` is only reachable when the
  caller passes `expectedSize: null`; the sole production caller
  (`update_service.dart:373-379`) always passes `manifest.compressedSize`. Not reachable today.

---

## 6. Ordered priorities

1. §5.2 — add timeouts to the updater HTTP path and release `_activeOperation` on failure.
   A hung update server permanently disables the whole update subsystem until restart.
2. §4.1 — move the full-resolution JPEG encode off the server/UI isolate and drop the two
   redundant `Uint8List.fromList` copies. Two handlers, one of which is documented for 2-5 Hz
   polling.
3. §2.2 + §5.1 — delete the sequencer's local payload readers in favour of `validation.dart`;
   fixes 500→400 on mistyped sequencer config fields and removes ~100 lines.
4. §1.1 — split `sequencer_handlers.dart` (2309 → ~250 + 7 parts), starting with the two
   zero-risk extractions (wire summary, payload readers).
5. §3.1 + §3.2 — delete `SecureDiscovery` (620) and `ChannelEncryption` (205); strip the
   QUICK_START.md sections that advertise the former.
6. §1.2 — split `route_metadata.dart` behind a re-export barrel (all 8 importers use a prefixed
   import, so this is mechanically safe) and give `EndpointRateLimiter` the LRU cap from §5.3.
7. §2.1 — derive `availableHeadlessEndpoints()` from the `HeadlessRoute` table and retire the
   598-string hand-maintained mirror plus most of the CI contract-audit script.
8. §1.10 + §2.5 — collapse the 18 duplicated `NotificationDetails` literals to 5 channel
   constants (~600 lines → ~150) and split the mobile notification service.
