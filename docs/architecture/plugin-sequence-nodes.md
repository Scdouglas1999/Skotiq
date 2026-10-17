# Plugin Sequence Nodes

Status: v2 — Rust executor dispatch live. Plugin nodes
now run inside the same execution graph as native instructions
(checkpointing, recovery, parallel branches all apply).

This document explains how the Skotiq plugin system exposes
**sequence nodes** — user-authored automation steps that show up in the
sequence editor's palette and run as part of an imaging sequence.

It covers:

1. The plugin contract for authors (`SequencePlugin` + `PluginSequenceNode`).
2. How the `PluginHost` wires the registry.
3. The execution path — what calls into a plugin node, and what guarantees
   the host provides.
4. The three reference plugins shipped under
   `packages/skotiq_plugins/lib/examples/`.
5. Known limitations and the planned v2 (native executor dispatch).

## 1. Author contract

A plugin that adds sequence nodes extends `SequencePlugin`
(`packages/skotiq_plugins/lib/src/plugin_api.dart`):

```dart
class MyPlugin extends SequencePlugin {
  @override
  String get id => 'com.example.myplugin';
  @override
  String get name => 'My Plugin';
  @override
  String get version => '1.0.0';
  @override
  String get description => 'Adds my custom sequence node';
  @override
  String get author => 'Me';

  @override
  Future<void> onLoad(PluginContext context) async {
    // Cache the context if you need it from a configuration UI.
    context.logger.info('My plugin loaded');
  }

  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'mine.dosomething',
      name: 'Do Something',
      category: 'Automation',
      description: 'Does something interesting',
      createNode: (params) {
        final foo = params['foo'] as String? ?? 'default';
        return MyDoSomethingNode(foo: foo);
      },
    ),
  ];
}

class MyDoSomethingNode implements PluginSequenceNode {
  final String foo;
  MyDoSomethingNode({required this.foo});

  @override
  String? validate() {
    if (foo.isEmpty) return 'foo is required';
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async {
    context.logger.info('Doing something with foo=$foo');
    // ... real work here ...
    return true; // false reports failure to the sequencer
  }
}
```

Key contract points:

* `SequenceNodeDefinition.id` must be stable for the plugin's lifetime —
  it appears in saved sequences. Renaming it breaks user data.
* `createNode` returns `null` when `params` cannot produce a valid node;
  the executor surfaces this as a structured failure rather than crashing.
* `validate` is called before `execute`. It returns a user-facing string
  on failure, `null` on success. Return failures here rather than throwing
  from `execute` so the dashboard can show a clean explanation.
* `execute` returning `false` is a normal "this step failed" — the
  sequencer treats it the same as any other node failure.
* `execute` throwing is caught by `PluginNodeExecutor` and surfaced as a
  failure with the exception message. Plugins MAY rely on this safety
  net but SHOULD return `false` from anticipated error paths instead.

## 2. Host wiring

`PluginHost` (`packages/skotiq_plugins/lib/src/plugin_host.dart`)
maintains a `PluginNodeRegistry`. Lifecycle wiring:

| Host call                         | Registry effect                              |
|-----------------------------------|----------------------------------------------|
| `registerPlugin(p, enabled:true)` | publishes every `p.nodeDefinitions` entry    |
| `registerPlugin(p, enabled:false)`| no registry change (re-enable publishes)     |
| `setPluginEnabled(id, false)`     | removes every entry owned by `id`            |
| `setPluginEnabled(id, true)`      | republishes every entry owned by `id`        |
| `unregisterPlugin(id)`            | removes every entry owned by `id`            |
| `host.dispose()`                  | disposes the registry                        |

The registry is a `PluginNodeRegistry` instance held on the host; it
exposes a `Stream<List<PluginNodeRegistration>>` (the `changes` stream)
so the sequence editor's palette can render a live list as bundled plugins are
enabled or disabled.

Riverpod providers:

* `pluginHostProvider` — the host (one per app).
* `pluginNodeRegistryProvider` — the host's registry.
* `pluginNodeRegistrationsStreamProvider` — initial snapshot + change stream.

## 3. Execution path (v2)

Plugin nodes now run inside the **Rust** executor's behaviour-tree the
same way every native instruction does. The Rust side reaches a
`NodeType::PluginNode`, fires a request event into Dart, blocks on a
oneshot, and resumes Success / Failure once Dart replies with the
plugin's verdict.

This means plugin nodes participate in the same execution machinery as
TakeExposure / Slew / Autofocus / etc.:

* **Checkpoint resume** — a sequence killed mid-plugin-node resumes at
  the right place because the node is part of the same persisted
  `SessionCheckpoint`.
* **Recovery loop** — a plugin node that fails inside a `Recovery`
  container retries on the same cadence as a failed exposure.
* **Parallel branches** — multiple `PluginNode` instructions inside a
  `NodeType::Parallel` dispatch concurrently; each carries its own
  oneshot.
* **Cancellation / Stop** — `ExecutorCommand::Stop` cancels the
  awaiting oneshot; the Dart side's verdict reply (when it eventually
  arrives) is logged at warn and dropped.

### Wire-level flow

```text
Rust executor reaches NodeType::PluginNode { plugin_id, node_type_id,
                                              config_json, ... }
   │
   ▼
PluginNodeInstruction::execute (sequencer/src/node/instructions/plugin_node.rs)
   ├── Insert tokio::oneshot::Sender into context.plugin_node_pending
   │   keyed by node_id
   ├── Emit synthetic "started" ProgressDetail::PluginNode tick
   └── Publish ExecutorEvent::PluginNodeRequested { node_id, plugin_id,
                                                    node_type_id,
                                                    config_json,
                                                    display_name,
                                                    timeout_secs }
   │
   ▼  Rust→Dart event stream (broadcast channel → bridge → FRB)
   │
SequenceExecutor._handleSequencerEvent (skotiq_core)
   │   sees 'PluginNodeRequested'
   ▼
SequenceExecutor._dispatchPluginNode
   ├── Read pluginNodeDispatcherProvider (skotiq_core)
   │   (overridden in app entry to back-to PluginNodeExecutor)
   ▼
PluginNodeExecutor.run (skotiq_plugins)
   ├── registry.findDefinition()        → SequenceNodeDefinition
   ├── host.contextFor(pluginId)        → PluginContext
   ├── definition.createNode(params)    → PluginSequenceNode
   ├── node.validate()                  → null | "reason"
   ├── node.execute(context).timeout()  → true | false | throw | timeout
   └── returns PluginNodeExecutionResult
   │
   ▼  Dart→Rust command (typed FRB API)
   │
backend.sequencerPluginNodeFinished(node_id, success, message,
                                     structured_detail_json)
   │
   ▼
api_sequencer_plugin_node_finished (bridge/src/api/sequencer.rs)
   │
   ▼
ExecutorCommand::PluginNodeFinished consumed by executor command
handler; pending oneshot resolved with PluginNodeReply
   │
   ▼
PluginNodeInstruction::execute returns NodeStatus::Success / Failure
   │
   ▼
Final ProgressDetail::PluginNode tick (carrying plugin-authored
structured_detail) emitted; executor advances to the next node
```

### Components

| Layer | File | Role |
|-------|------|------|
| Rust | `sequencer/src/lib.rs::NodeType::PluginNode` | Variant + serde shape |
| Rust | `sequencer/src/node/instructions/plugin_node.rs` | Dispatcher / oneshot |
| Rust | `sequencer/src/node/registry.rs` | `"PluginNode"` discriminant |
| Rust | `sequencer/src/executor.rs::ExecutorEvent::PluginNodeRequested` | Request event |
| Rust | `sequencer/src/executor.rs::ExecutorCommand::PluginNodeFinished` | Reply command |
| Rust | `sequencer/src/node/context.rs::plugin_node_pending` | Oneshot map |
| Rust | `sequencer/src/node/progress.rs::ProgressDetail::PluginNode` | Live progress |
| Bridge | `bridge/src/event.rs::SequencerEvent::PluginNodeRequested` | Typed FRB event |
| Bridge | `bridge/src/event.rs::SequencerEvent::PluginNodeProgress` | Typed FRB event |
| Bridge | `bridge/src/api/sequencer.rs::api_sequencer_plugin_node_finished` | Reply FRB API |
| Dart | `skotiq_core/lib/src/providers/plugin_node_dispatcher.dart` | Dispatcher abstraction + provider |
| Dart | `skotiq_core/lib/src/providers/sequence/sequence_executor.dart::_dispatchPluginNode` | Event → dispatcher → reply |
| Dart | `skotiq_plugins/lib/src/plugin_node_executor.dart` | Concrete dispatcher implementation |
| Dart | `skotiq_app/lib/services/plugin_node_dispatcher_wiring.dart` | Riverpod override that plugs `PluginNodeExecutor` into the dispatcher provider |

### Timeouts

The default plugin-node timeout is 10 minutes
(`DEFAULT_PLUGIN_NODE_TIMEOUT_SECS = 600`). Plugin nodes can override
via `NodeType::PluginNode.timeout_secs`. When the timeout fires:

* Rust marks the node `NodeStatus::Failure`.
* Rust emits `ExecutorEvent::Error` with the timed-out plugin id.
* The pending oneshot is removed; a late reply from Dart logs at warn
  and is dropped.

`Some(0)` and `None` both fall back to the default — a zero-second
timeout is treated as a configuration bug rather than a fire-now
request.

### Why oneshots, not a broadcast

Two plugin-node invocations can run sequentially with the same plugin
and the same node_type_id but different `node_id`s — we need 1:1
request/response routing keyed on the executor-side node id.
`tokio::sync::oneshot` is the cheapest correct primitive; broadcast
channels would require every node instance to filter out replies
intended for someone else, and would still race on closed senders
after timeout.

`PluginNodeExecutor` never throws — every error path becomes a
`PluginNodeExecutionResult(success: false, message: ...)`. Plugin
exceptions are logged through the plugin's own context logger, then
surfaced as the result message. The same contract applies to the
`PluginNodeDispatcher` typedef: implementations MUST not throw; the
wrapper in `SequenceExecutor._dispatchPluginNode` catches anything
that escapes and turns it into a failure verdict.

### What the plugin sees

The `PluginContext` passed to `execute` is the same context the host
passed to `onLoad`:

* `context.logger` — writes to the application log (and, in debug
  builds, the console via `dart:developer`).
* `context.storage` — file-backed key/value storage at
  `<appDataDir>/skotiq_plugins/storage/<pluginId>.json`. Survives
  restarts.
* `context.eventBus` — sandboxed pub/sub. Plugins MAY emit events with
  any name. `onAny()` is blocked by default to prevent cross-plugin
  snooping; sandbox limits enforced by `SandboxedPluginEventBus`.

### What the plugin does NOT see

* The Rust executor's `ExecutionContext` (devices, save path, target).
  Plugins author **side-effects** — notifications, switches, file
  writes — not telescope motion or exposure decisions.
* Other plugins' storage.
* The global event bus (only its own scoped events plus what gets
  re-emitted through `eventBus` by app code).

## 4. Reference plugins

Three example plugins ship under
`packages/skotiq_plugins/lib/examples/` and are exported from the
package's barrel file (`skotiq_plugins.dart`). Each is < 300 lines
and demonstrates a different authoring pattern.

### 4.1 `pushover_notification_plugin.dart`

* Node: `Pushover Notification` (`pushover.notify`).
* Demonstrates: per-plugin credential storage + per-node title/message.
* Storage keys: `pushover.apiToken`, `pushover.userKey`.
* External: POST `https://api.pushover.net/1/messages.json`.

Different from the built-in Pushover transport: this
plugin is **per-node**, so a user can have it fire only on specific
sequence steps without enabling Pushover as a global transport.

### 4.2 `discord_webhook_plugin.dart`

* Node: `Discord Webhook` (`discord.webhook`).
* Demonstrates: per-node credential (URL is the secret), content +
  embed rendering.
* No persistent storage required.
* External: POST to the configured webhook URL.

Validates the URL is HTTPS and points at `discord.com` /
`discordapp.com` so a misconfigured node cannot be coerced into POSTing
to an attacker-controlled host.

### 4.3 `home_assistant_plugin.dart`

* Node: `Toggle Home Assistant Entity` (`home_assistant.toggle`).
* Demonstrates: per-plugin connection config + per-node entity/service +
  optional post-call state confirmation.
* Storage keys: `home_assistant.baseUrl`, `home_assistant.token`.
* External: POST `<baseUrl>/api/services/<domain>/<service>` then
  optionally GET `<baseUrl>/api/states/<entityId>`.

The canonical "automate my observatory" plugin: turn on dew heaters at
session start, close the dome shutter on a weather-trigger abort, fire a
scene to dim room lights to red.

## 5. Limitations + roadmap

### v1 (this doc)

* Plugins must be **compiled into the app** — Dart code cannot be
  loaded at runtime on desktop without an isolate-based interpreter,
  which is out of scope. The "drop a `.dart` file into ~/Plugins/"
  UX described in the strategic report is **not** achievable today;
  bundling plugins as compile-time exports of `skotiq_plugins`
  is.
* Plugin node execution happens **between** Rust sequencer steps,
  driven by the Dart-side `SequenceExecutor`. Latency is dominated by
  the plugin's own network I/O.
* The Integrations settings page enables/disables bundled plugins and
  configures the credentials used by their nodes.

### v2 — DONE

* **Rust executor dispatch** — landed. See "Execution path (v2)" above
  for the full Rust↔Dart roundtrip and the file-by-file map.
* Plugin nodes now participate in checkpoint resume, recovery loops,
  parallel branches, and cancellation the same way native instructions
  do.

### Still planned

* **Discoverable plugins directory**: when Flutter ships a
  production-grade JIT or AOT-isolate spawn API, scan
  `<appDataDir>/Plugins/` for `.dart` files and load them.
* **Runtime installation**: uploaded Dart source cannot be loaded by the AOT
  desktop/headless process. `/api/plugins/upload` therefore reports 501; a
  plugin must be included in a Skotiq build to become executable.

## 6. Self-audit

The v1 plugin-nodes wiring was verified by:

* `flutter test packages/skotiq_plugins` — 45/45 pass, including
  17 pre-existing tests and 28 new tests covering registry behavior,
  executor failure paths, and each reference plugin's HTTP shape.
* `flutter analyze packages/skotiq_plugins` — no errors or warnings
  introduced; 3 pre-existing info-level issues remain (`unnecessary_library_name`,
  `dangling_library_doc_comments` in `plugin_api.dart`,
  `unawaited_futures` in `plugin_host.dart`'s lifecycle runner).
* Grep verification:
  * `PluginNodeRegistry` instantiated in `plugin_host.dart` and exposed
    via `host.nodeRegistry` + `pluginNodeRegistryProvider`.
  * `PluginNodeExecutor` resolves registrations, instantiates plugin
    nodes via `definition.createNode`, and invokes
    `PluginSequenceNode.execute`.
  * Three example plugins (`pushover_notification_plugin.dart`,
    `discord_webhook_plugin.dart`, `home_assistant_plugin.dart`) all
    extend `SequencePlugin` and ship from the package barrel.

The v2 (Rust dispatch) layer was verified by:

* `cargo test --workspace --all-features` clean (376 sequencer tests
  pass; 5 new plugin tests including `plugin_node_e2e_completes_via_executor_round_trip`
  which exercises the full `SequenceExecutor::start` → request event
  → `plugin_node_finished` reply → Success node status flow).
* `cargo clippy --workspace --tests --all-features -- -D warnings`
  clean.
* `flutter test packages/skotiq_core/test/providers/sequence/` —
  254 pass including:
  * `sequence_executor_frame_accepted_save_path_test.dart` — proves
    the accepted-frame save_path lands as `file_path` on the
    `captured_images` row.
  * `sequence_executor_plugin_dispatch_test.dart` — proves the typed
    `PluginNodeRequested` event routes through the dispatcher provider
    and posts the verdict via `backend.sequencerPluginNodeFinished`.
* `flutter test packages/skotiq_app/test/services/plugin_node_dispatcher_wiring_test.dart`
  — proves `pluginNodeDispatcherOverride()` plugs `PluginNodeExecutor`
  into the dispatcher provider end-to-end: a registered test plugin
  receives the parsed `config_json` params, runs `execute()`, and the
  verdict flows back as a `PluginNodeDispatchResult`.
* `flutter test packages/skotiq_plugins` — still 45/45 pass.
* FRB regen produced typed bindings:
  * `apiSequencerPluginNodeFinished` (in
    `packages/skotiq_bridge/lib/src/api/sequencer.dart`)
  * `SequencerEvent.pluginNodeRequested` and
    `SequencerEvent.pluginNodeProgress` (in
    `packages/skotiq_bridge/lib/src/event.dart`)
  * `SequencerEvent.frameAccepted` now carries `savePath`.
