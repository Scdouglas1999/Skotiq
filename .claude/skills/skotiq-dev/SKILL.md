---
name: skotiq-dev
description: Load before changing any code, test, tool or build file in the Skotiq repository (Flutter/Dart under packages/ and apps/, Rust under native/skotiq_native, tools/). Says which one file owns each kind of fact (backend roles, node kinds, device slots, settings, formatters, error text, charts, API routes, run state, vendor catalog), gives a recipe per common change (sequence node, API endpoint, setting, device vendor, screen, event, database table, host data a linked client needs), lists the invariants and the owner's product rules, and which checks prove a change.
---

# Working on Skotiq

Skotiq controls an astrophotography rig. A Flutter/Dart workspace (melos: `apps/*`, `packages/*`)
sits on a Rust workspace (`native/skotiq_native`) through flutter_rust_bridge. The desktop app is
the host that runs the rig (with a window, or headless as a daemon); phones and other desktops link
to a host over the headless API and show the same screens.

Nothing here limits what you may change. It tells you where a change belongs, so it lands next to
the code that changes with it, and how to show it works. If a rule stands in the way of a good
change, change the rule in the same commit and say why in the message.

## 1. Layers

Lower layers change less. A package uses only the packages below it.

| Package | Holds | May use |
| --- | --- | --- |
| `skotiq_astro` | astronomy, catalogs, planning math, formatters. Pure Dart. | nothing |
| `skotiq_design`, `skotiq_plugins`, `skotiq_updater`, `skotiq_remote_protocol` (wire: routes, DTOs, error body) | leaves | nothing |
| `skotiq_bridge` | Dart side of the FFI, generated | nothing |
| `skotiq_ui` | design system: tokens, components, chart kit. No providers, no backend. | astro, design |
| `skotiq_planetarium` | sky rendering | astro, design |
| `skotiq_core` | logic, Riverpod providers, backends, database, settings. No widgets. | astro, bridge, plugins, remote_protocol |
| `skotiq_app` | screens shared by desktop and phone | everything above |
| `apps/desktop`, `apps/mobile` | entry points, headless API server, host start-up | everything |

Rust: `skotiq_device` (shared vocabulary and driver traits) is the bottom; `alpaca`, `ascom`, `indi`
use only it; `native` (vendor SDKs) and `sequencer` use `device` and `imaging`; `bridge` wires them
together and is the FFI surface. Only `skotiq_core` imports `skotiq_bridge` (reviewed exceptions in
`tools/production/bridge_boundary_whitelist.json`). The full tables are `_dartPackages` and
`_rustCrates` in `tools/production/architecture_rules_audit.dart`.

## 2. Where a change goes

Paths are from the repository root. Short forms: `backend/`, `database/`, `errors/`, `models/`,
`providers/`, `services/`, `settings/` are under `packages/skotiq_core/lib/src/`; `sequencer/`,
`device/`, `bridge/`, `native/src/`, `alpaca/`, `ascom/`, `indi/` are crates under
`native/skotiq_native/`.

Each fact has one owner. Change it there and let the rest follow; do not add a second copy, a
parallel table, or a special case for one device, caller or mode.

| Fact | Owner |
| --- | --- |
| Local host vs linked host vs no host | `packages/skotiq_core/lib/src/backend/remote_host.dart`: `backend.remoteHost` (null when the host is this process), `hasNoHost`, `runsRigHere`, `ownsDeviceBridge`; `isRemoteModeProvider`, `isRemoteClientProvider` in `providers/backend_provider.dart`. Nothing outside the backend files tests a backend's class (section 4). |
| Host data (both sides) | role interfaces in `packages/skotiq_core/lib/src/backend/roles/host_data/`, remote halves in `backend/network_backend/host_data/`, one getter each on `RemoteHost`. Recipe: section 3.8. |
| Stale async work after a host switch | `AsyncScopes` / `ref.backendScope()` in `packages/skotiq_core/lib/src/providers/async_scope.dart`; dialogs: `HostBoundDialogState` in `packages/skotiq_app/lib/utils/authority_bound_dialog.dart` |
| Sequence node types (Dart) | `NodeKind` in `packages/skotiq_core/lib/src/models/sequence/sequence_models/node_kind.dart`, one entry per type in `node_kinds.dart`: wire name, legacy names, icon, category, container flag, required devices, field table, describe, diff, captures. App icon and tint: `packages/skotiq_app/lib/screens/sequencer/widgets/node_appearance.dart`. Palette: `packages/skotiq_core/lib/src/providers/sequence/node_palette.dart`. Tree insert: `packages/skotiq_app/lib/screens/sequencer/widgets/tree_insert.dart`. |
| Sequence node types (Rust) | `NodeType` in `native/skotiq_native/sequencer/src/lib.rs` (`wire_name`, `display_name`), `instruction_for` in `sequencer/src/node/registry.rs`, node wrapper in `sequencer/src/node/instructions/`, the work in `sequencer/src/instructions/` |
| Frames a step or a plan takes | `NodeFrames` (`framesPerPass`, `capturesUntilStopped`) and `plannedCaptureUnder` in `packages/skotiq_core/lib/src/models/sequence/sequence_models/planned_capture.dart`, over `NodeKind.captures`. A Smart Exposure looping until stopped has no count, as in the native run (`sequencer/src/executor/loading.rs` `calculate_totals`). |
| Filter-name matching | `find_filter_match` in `native/skotiq_native/bridge/src/filter_matching.rs` (the wheel) and `matchingFilterIndex` in `packages/skotiq_core/lib/src/providers/sequence/filter_name_matching.dart` (the editor): one rule, both tested against `packages/skotiq_core/test/fixtures/filter_matching_cases.json`. Change both and add a case. |
| Executor wire (Dart node -> Rust config) | `packages/skotiq_core/lib/src/providers/sequence/sequence_executor/sequence_serializer.dart` |
| The sequence run as the app shows it | `RunRecord` in `packages/skotiq_core/lib/src/providers/sequence/run_record.dart`, one value written only through `RunRecordNotifier`: on the host by the event fold (`foldRunEvent` in `sequence/sequence_progress.dart`) and `SequenceExecutor`, on a linked client by the mirror (`remote_sync/sequencer_mirror.dart` and the `sequenceRun` / `runRecord` channels). `sequenceExecutionStateProvider`, `sequenceProgressProvider`, `nodeExposureTallyProvider` and the other run views are `select`s of it; add a field to the record, never a second provider. |
| A run | under `sequencer/src/`: `executor/start/run.rs` (`Run`, `Teardown`), state cell `executor/run_state.rs` (`RunCell`, `RunControl`), settings `executor/run_config.rs` (`RunConfig`, `RunConfigStore`), what node contexts share `instructions/context.rs` (`RunShared`, `InstructionContext`, `Setback`, `InstructionResult::settle`), checkpoints `executor/checkpoint_writer.rs`, triggers `triggers/standard.rs`, recovery `recovery/policy.rs`, device access `device_ops/` |
| Device types (Dart) | `DeviceType` (label, noun) in `packages/skotiq_core/lib/src/models/backend/device_types.dart`; per-type slot table `deviceSlots` in `providers/equipment/device_slots.dart`; one connect/disconnect in `services/device_service/connections/device_connections.dart`; icon and accent in `packages/skotiq_app/lib/utils/device_type_ui.dart` |
| Device vocabulary and drivers (Rust) | `native/skotiq_native/device/src/` (`DeviceKind`, `Vendor`, `DriverError`, driver traits, ASCOM member lists); vendor families `native/src/catalog.rs`; bridge handles and policy `bridge/src/device_manager/` |
| Settings | `packages/skotiq_core/lib/src/settings/app_settings_table.dart` (each setting once); kinds in `setting.dart`; read `appSettingsProvider` or `AppSettingDefs.<field>`. Settings pages: `packages/skotiq_app/lib/screens/settings/`, sections `settings_sections.dart` (`SettingsSectionId`, `openSettings`), field binding `widgets/settings_widgets/settings_field_binding.dart`. Layout class of a settings pane (split view or narrow single pane): `SettingsFormScope.narrow`, set once by `SettingsScreen`; the kit blocks in `widgets/settings_widgets/` read it, pages never take or pass it |
| Text for numbers, times, sizes, coordinates, temperatures | `packages/skotiq_astro/lib/format.dart` (`ClockFormat`, `DurationFormat`, `RelativeTime`, `ByteFormat`, `CoordinateFormat`, `AngleFormat`, `QuantityFormat`, `formatCelsius`). `ClockFormat` prints the fields it is given: call `.toLocal()` on a stored or wire time first. Binary or decimal size units is the one constant `ByteFormat.units`. |
| Error text a user sees | `userFacingError`, `failureText`, `describeError` in `packages/skotiq_core/lib/src/errors/error_text.dart`. Never show `$e` or `e.toString()`. |
| Charts | `SkotiqChart` and `ChartScale` in `packages/skotiq_ui/lib/src/charts/` |
| Widgets, tokens, look | `package:skotiq_ui/skotiq_ui.dart` (`lib/src/components`, `tokens`, `theme`); design language `docs/design/overhaul/02-design-language.md`, components `05-components.md` |
| App routes | `AppRoute` in `packages/skotiq_app/lib/router/app_routes.dart`: one enum value per path (label, icon, rail group, palette words, tour, parent, redirect). Locations with parameters are built by `AppRoutes.*`; a tab a link can name is an enum with `QueryWord` (`router/query_word.dart`). `router/app_router.dart` builds the GoRouter from the table and maps each route to its screen. Core cannot import the table, so the few route strings core models carry are checked by `packages/skotiq_app/test/router/app_routes_test.dart`. |
| API routes and their policy | one enum per area in `packages/skotiq_remote_protocol/lib/src/wire/routes/*_api.dart`, listed in `src/wire/api_routes.dart` and exported by `lib/wire.dart`; server binding `apps/desktop/lib/headless_api/route_table.dart`; handler classes `apps/desktop/lib/headless_api/handlers/` (barrel `handlers.dart`), built in `apps/desktop/lib/headless_api_server/handler_initialization.dart` |
| Wire error body and shared DTOs | `ApiErrorBody`, DTOs under `packages/skotiq_remote_protocol/lib/src/wire/` |
| Host start-up (GUI host and daemon) | steps `apps/desktop/lib/host/host_steps.dart`; always-on services by role `packages/skotiq_app/lib/startup/always_on_services.dart`; start-up prompts `packages/skotiq_app/lib/startup/startup_surface_queue.dart` |
| Events | Rust `native/skotiq_native/bridge/src/event/` (`EventPayload` in `bus.rs`); Dart `packages/skotiq_core/lib/src/models/backend/event_types.dart`; recipe 3.6 |
| What a sequencer error means for the run | decided where it happens: `ExecutorEvent::{Warning, StepProblem, RunHeld, Error}` in `sequencer/src/executor/types.rs` (`RunControl::warning/step_problem/held/error` for trigger actions), sent as `SequencerErrorKind` on `SequencerEvent::Error` (`bridge/src/event/sequencer.rs`); Dart reads it with `sequencerErrorKindOf` (`backend/sequencer_error_kind.dart`). Nothing infers it from severity or text. A run's failure is told only by `SequenceFailed`. |
| A happening the run carries on through and tells once (failed autofocus, reject streak, quality problem) | `RunNotice` in `sequencer/src/decision.rs`, set on its decision row (`ContinuedHappening` in `sequencer/src/executor/mod.rs`) and on its `ExecutorEvent::NoticedWarning`; wire `SequencerNotice` on `DecisionLogged` and `Error`; Dart `sequencerNoticeOf` (`backend/sequencer_notice.dart`). The router notifies from the row, the error bridge never toasts the warning. Summaries and sentences are display text. |
| Why the grader rejected a frame | `RejectReason` in `sequencer/src/quality/image_grading.rs`; its `Display` is the sentence. Match the variant, never the text. |
| Temperature compensation rule | a run: `FocusCompensation` in `sequencer/src/temperature_compensation.rs`; idle: its mirror `FocusCompensationRule` in `providers/equipment/focus_compensation_rule.dart`. Both run `sequencer/src/temperature_compensation_cases.json`; change the rule on both sides and add the case there. |
| Database | drift tables `packages/skotiq_core/lib/src/database/tables/`, `.drift` files in `database/schema/`, registered in `database/database.dart`; DAOs `database/daos/`; migrations `database/database/migration_v<N>.dart` |

## 3. Recipes

Read the nearest existing example first and copy its shape. Every recipe ends with section 6.

### 3.1 Sequence node type
1. Rust: add the `NodeType` variant and its config struct (serde) in `sequencer/src/lib.rs`, its arm
   in `wire_name` and `display_name`, a node wrapper in `sequencer/src/node/instructions/`, the work in
   `sequencer/src/instructions/` taking `InstructionContext`, and the arm in `instruction_for`
   (`sequencer/src/node/registry.rs`). Outcomes go through `InstructionResult::settle` / `Setback`; a quality
   problem notifies and skips, it never stops the run.
2. Dart: the model class next to its siblings in `models/sequence/sequence_models/` (defaults in the
   constructor), one
   `NodeKind` entry in `node_kinds.dart` (fields, describe, diff, captures, required devices), the
   palette entry in `providers/sequence/node_palette.dart`, the icon name in `node_appearance.dart`.
3. Let the compiler find the rest: the exhaustive switches in `sequence_serializer.dart`
   (`_nodeToConfig`, executor wire), the inspector editor, the row summary and the time estimate do
   not compile until the new type has an arm. Do not add a new per-type switch; add a `NodeKind` field.
4. Goldens: add the type to `fullNodes()` and `defaultNodes()` in
   `packages/skotiq_core/test/services/node_codec_goldens/node_fixtures.dart`, write its goldens with
   `UPDATE_NODE_GOLDENS=1 flutter test test/services/node_codec_goldens`, and check that no existing
   golden file changed (`git diff --stat`).

### 3.2 API endpoint
1. One enum value in the area's `packages/skotiq_remote_protocol/lib/src/wire/routes/<area>_api.dart`
   with its policy (method, path, resource, rate tier, audit action for anything that moves hardware,
   `sessionOwner` for control). New area: new file, add it to `api_routes.dart` and `wire.dart`.
2. One line in the handler class's `routes` map (`apps/desktop/lib/headless_api/handlers/<area>_handlers.dart`)
   and the handler method. A handler builds JSON through the shared DTOs and errors through
   `ApiErrorBody`; `RouteTable` refuses to start when a route has no handler or a handler no route.
3. Client: the `NetworkBackend` method in `packages/skotiq_core/lib/src/backend/network_backend/`, reached by
   callers through a role (3.8), never by `is NetworkBackend`.
4. Check: `melos run audit:headless-api-contract`, `audit:headless-route-policy`,
   `packages/skotiq_remote_protocol/test/wire/`, `apps/desktop/test/headless_api/`.

### 3.3 Setting
1. One entry in `app_settings_table.dart`: field name, row key, default, bounds, `sync:` (who owns it
   when linked), `feeds:` if the executor reads it, `seeded:` for a fresh install.
2. Regenerate: in `packages/skotiq_core`,
   `SKOTIQ_REGENERATE=1 flutter test test/settings/app_settings_generated_test.dart`.
   A setting a linked client can change also needs its wire field in `models/settings/app_settings.dart`.
3. UI: a row on the section page under `packages/skotiq_app/lib/screens/settings/`, bound with the field
   binding (write, rollback and bound notice come with it). Then
   `dart run tools/production/settings_search_index_gen.dart`.
4. Link to it with `openSettings(context, SettingsSectionId.x)`, never a route string.
5. A run reads settings through `RunConfig`; the push table is `_settingsPushes` in
   `packages/skotiq_core/lib/src/providers/sequence/sequence_executor/runtime_config_sync.dart`.

### 3.4 Device vendor (native SDK or serial protocol)
1. Driver in `native/skotiq_native/native/src/vendor/<vendor>/` implementing the `skotiq_device`
   trait for its kind; the SDK handle owns its lock (`XSdk::lock().await?`), missing SDK is
   `DriverError::SdkNotInstalled`; cameras build on `camera_core.rs`, serial mounts on
   `vendor/serial_link.rs`.
2. One `Family` row in `native/src/catalog.rs` (id token, kind, vendor, labels, SDK probe, discover,
   open). Discovery, connect, id validation and labels all read the row. Ids already in users'
   profiles must not change (`id_tokens_are_the_ones_profiles_hold`).
3. Nothing per vendor in Dart. A new device kind is bigger: `DeviceKind` in `device/src/kind.rs`, the
   FFI `DeviceType` in `bridge/src/device.rs` (regenerate FRB), Dart `DeviceType` + a `deviceSlots`
   row + `device_type_ui.dart`.
4. Check: `cargo test --release -p skotiq_native` (incl. `native/tests/disconnected_contract.rs`),
   clippy, and the Windows type check (section 6) for anything `#[cfg(windows)]`.

### 3.5 Screen
1. Directory `packages/skotiq_app/lib/screens/<feature>/` (desktop-only entry code in `apps/desktop/lib/`).
   Route: one `AppRoute` value in `router/app_routes.dart` and its arm in `_screen` in
   `router/app_router.dart` (the switch does not compile without it). Link to it with
   `AppRoute.x.path` or an `AppRoutes.x(...)` builder, never a path or query written as a string.
2. Build from `skotiq_ui` components and tokens; charts with `SkotiqChart`; text through
   `skotiq_astro` formatters and `userFacingError`. Every state: loading, empty, error, linked to a
   host, no host, phone width (420 px), red night theme.
3. Data from providers in `skotiq_core`. Linked mode works by the provider picking the role's side; a
   screen that needs files only the rig has asks `isRemoteClientProvider`.
4. Launch and drive it (section 6). A screen is not done until you have used it.

### 3.6 Event
1. Rust: the variant in the right enum under `native/skotiq_native/bridge/src/event/`, emitted where
   the fact happens; regenerate FRB.
2. Dart today has three places, keep them in step: `packages/skotiq_core/lib/src/backend/ffi_backend/event_mapping.dart`
   (bridge event -> `SkotiqEvent`), the host forwards it to clients (fan-out only in
   `apps/desktop/lib/headless_api_server/server_lifecycle.dart` `_subscribeToBackendEvents`), and the
   client rebuilds it in `backend/bridge_event_mapper.dart` (add the type to
   `_faithfulCoreEventTypes`, or a linked client sees a placeholder).
3. Consumers watch `skotiqEventsProvider` (`providers/event_provider.dart`). Prefer an event to a
   poll; a poll of host data goes through `HostPoll`.

### 3.7 Database table or query
1. Table as a drift class in `database/tables/` or in a `.drift` file in `database/schema/`; register
   it in `database.dart`. The drift definition is the only schema.
2. Bump `schemaVersion` in `database.dart`, add `migration_v<N>.dart` (part of `database.dart`) and
   its call in `migration_strategy.dart`. New tables are created by the closing `_createMissing` pass;
   a column added to an old table needs a guarded `ALTER TABLE` step.
3. Queries are typed drift queries in a DAO (`@DriftAccessor`). Raw SQL only with a measured or stated
   reason next to it.
4. Check: `test/database/schema/one_schema_source_test.dart`, a migration test, the DAO pin tests in
   `test/database/daos/pins/`, `melos run audit:migration-regression`. A schema bump on the rig needs a
   database backup before deploy.

### 3.8 Host data a linked client needs
Copy a converted role: `backend/roles/host_data/observing_lists_store.dart` (local side
`ObservingListsDao`), `observation_log.dart`, `calibration_library.dart`, and their `Remote*` halves in
`backend/network_backend/host_data/`.
1. Both sides have the same shape: an interface in `backend/roles/host_data/<role>.dart`; the local
   DAO or service `implements` it; `Remote<Role>` in `backend/network_backend/host_data/` calls the
   client methods (watched reads through `HostPoll`); a `late final` field on `RemoteHost`; a provider
   `ref.watch(backendProvider).remoteHost?.<role> ?? ref.watch(<localProvider>)`.
2. Only the host has it: `Host<X>` interface listing the `NetworkBackend` methods, which
   `NetworkBackend` implements, and a getter on `RemoteHost`; callers use `backend.remoteHost?.x`.
3. The host side is an API endpoint (3.2). Do not add members to `SkotiqBackend`; a non-future member
   of a role needs an override in `disconnected_backend.dart`
   (`test/backend/disconnected_backend_contract_test.dart`).
4. Async work started for one host is dropped when the host changes: take a scope
   (`AsyncScopes.begin()`, `ref.backendScope()`) and check `isStale` after each await. Listen to the
   role provider, not to `backendProvider`.
5. Drive it twice: local, and as a linked client of a headless host; switch hosts with the screen open.

## 4. Invariants

- Dependency direction as in section 1; no `package:<other>/src/` imports (import the package's
  library, export the name there if needed).
- Inside `skotiq_core`, `backend/`, `database/`, `models/` and `services/` do not import
  `providers/` or the core barrel. A plain value (data class, enum, result type, pure function of
  values) lives in `models/` or the domain folder that owns it, never in a provider file. A service
  that needs a Riverpod `Ref` has a `coreLayers` entry in
  `tools/production/architecture_rules_baseline.json` saying what it reads.
- No `is`/`as NetworkBackend|FfiBackend|DisconnectedBackend` outside the backend files.
- Per-type facts live on the tables (`NodeKind`, `NodeType`, `deviceSlots`, `Family`, the settings
  table, the route enums). A switch per type elsewhere is allowed only where the compiler's
  exhaustiveness is the point.
- Errors are typed and handled where they can be; what reaches a user goes through `userFacingError`.
  No `catch (_) {}`, no silent `?? 0` / `?? ''` fallbacks that hide a missing value.
- Never invent hardware data or substitute a simulator for a missing device
  (`docs/no-fake-hardware-policy.md`).
- Generated files (`*.g.dart`, `*.freezed.dart`, `frb_generated.*`, `packages/skotiq_bridge/lib/src/`)
  are regenerated, never edited. FRB: `./scripts/dev.sh` (sets the CPATH codegen needs).
- Do not run `dart format` on `packages/skotiq_app` files: that package declares SDK 3.0 and is in
  the older format style, so a format pass rewrites the whole file. Match the style by hand. Other
  packages are in the current style and can be formatted.
- Unreferenced code may be a built feature that was never wired in: judge before deleting, and keep a
  distinct user capability.
- Writing: American English everywhere. Plain prose in comments, UI text, commits and notes: no
  bolded lead on every bullet, no slogans, no engineering jargon in user text. Comments say what the
  code cannot (a reason, a unit, an outside constraint), never history. Commit messages state what is
  now true in one sentence. No AI attribution in commits, tags, PRs or release notes.

## 5. Owner product rules

- A failed autofocus, a lost guide star or a quality problem notifies; it never stops, pauses or parks
  a run. Retries are configurable (default 3).
- Asteroid / moving-object detection is off by default and only notifies.
- Heavy background builders (sky atlas and similar) are opt-in, off by default, and say what they cost.
- The mount guard stops only a move toward the horizon or a limit; it never fights a move made with
  the hand controller or another program.
- Never remove a convenience to be "honest"; show its accuracy instead. Product and default changes
  are the owner's call: ask, do not decide.

## 6. Verify

Run what covers what you touched and keep it green. Note any failure that also fails on the base
commit instead of hiding it.

| Area | Checks |
| --- | --- |
| Any Dart | `dart analyze <changed paths>` (no new issues); `flutter test --concurrency=4` in each changed package (`dart test` in `skotiq_astro`) |
| Any Rust | in `native/skotiq_native`: `cargo test --release -p <crate>`, `cargo clippy --release -p <crate> --all-targets`; for code Windows uses: `cargo check --release --target x86_64-pc-windows-gnu --workspace --all-targets` |
| Structure | `melos run audit:architecture` (the first four rules in section 4: dependency direction and `src/` imports, core layers below providers, backend class tests, per-node-type dispatch; it says where a change goes when it fails) and `audit:bridge-boundary` |
| Moved or renamed code | `melos run audit:behavioral:sync` and `audit:placeholders:sync`, then the plain gates `audit:behavioral`, `audit:placeholders`, `audit:fail-closed` |
| Nodes | node codec goldens (3.1) and `cargo test --release -p skotiq_sequencer` |
| Settings | `test/settings/` in `skotiq_core` (generated table, base compatibility) |
| API | `audit:headless-api-contract`, `audit:headless-route-policy`, `skotiq_remote_protocol` tests |
| Database | 3.7 |
| Drivers | `alpaca/tests/wire_transcript.rs`, `ascom/tests/com_members.rs`, `native/tests/` |
| Anything a user sees | launch the built app and use it (below) |

UI is never judged from code, tests or the analyzer. Build the app (`dart scripts/build.dart
desktop linux`, or `./scripts/dev.sh` when the FFI changed), then drive it with
`tools/ui_audit/drive_linux.py` (read its header): a private Xvfb display, never the desktop's `:0`;
`GALLIUM_DRIVER=softpipe`; a scratch `SKOTIQ_DATABASE_DIR`;
simulator devices only with Alpaca, INDI and network discovery off, and never connect or move a device
that is not a simulator. Open the screen, do the workflow end to end as a user would, look at the
screenshots (layout, states, phone width, red night), drive linked mode when the feature works there,
and stop every instance you started by its PID. Rig behavior is proved on the rig, not on simulators.
