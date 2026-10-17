// Plugin sequence-node dispatcher abstraction.
//
// The Rust executor emits `SequencerEvent::PluginNodeRequested` when it
// reaches a `NodeType::PluginNode`. The Dart `SequenceExecutor`
// (`packages/skotiq_core`) routes that event to a
// `PluginNodeDispatcher` callback, which in turn runs the plugin via
// `PluginNodeExecutor` (`packages/skotiq_plugins`) and posts the
// verdict back through the bridge via
// `api_sequencer_plugin_node_finished`.
//
// Why this abstraction lives in `skotiq_core` rather than
// `skotiq_plugins`:
//
//   * `skotiq_core` does NOT depend on `skotiq_plugins`.
//   * The Rust side needs SOME entry point to dispatch into Dart, and
//     the sequence executor (which already consumes the typed event
//     stream) is the natural place.
//   * The app layer (`skotiq_app`) overrides
//     `pluginNodeDispatcherProvider` with a real implementation that
//     calls into `PluginNodeExecutor`. The default implementation in
//     core is a fail-loud stub that NACKs every request so a
//     mis-wired environment surfaces immediately instead of hanging.
//
// This mirrors how wired the sky-brightness tracker: the
// tracker provider lives in `skotiq_core`, but the actual data
// source plugs in from a higher layer.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Request payload Dart receives when the Rust executor reaches a
/// plugin node. All fields are stable enough for the dispatcher to look
/// up the plugin definition + invoke `PluginSequenceNode.execute`.
class PluginNodeDispatchRequest {
  /// Executor-side node id. MUST be echoed back in the reply.
  final String nodeId;

  /// Stable plugin identifier (e.g. `com.example.pushover`).
  final String pluginId;

  /// Stable per-plugin node type id (e.g. `pushover.notify`).
  final String nodeTypeId;

  /// Opaque JSON payload the plugin author authored. The dispatcher
  /// parses this with `jsonDecode` and passes the resulting map to
  /// `PluginSequenceNode.execute`.
  final String configJson;

  /// Optional human-readable label. `null` => fall back to
  /// `nodeTypeId`.
  final String? displayName;

  /// Effective timeout in seconds that the Rust side is enforcing.
  /// The dispatcher SHOULD honour it (the Rust side will time out the
  /// node first if the dispatcher runs longer, but the resulting log
  /// line will mention Rust's timeout instead of the dispatcher's).
  final int timeoutSecs;

  const PluginNodeDispatchRequest({
    required this.nodeId,
    required this.pluginId,
    required this.nodeTypeId,
    required this.configJson,
    required this.displayName,
    required this.timeoutSecs,
  });
}

/// Verdict the dispatcher returns to the executor. Mirrors
/// `PluginNodeExecutionResult` in `skotiq_plugins` but lives here
/// so `skotiq_core` does not have to depend on the plugins
/// package.
class PluginNodeDispatchResult {
  /// True when the plugin reported success.
  final bool success;

  /// Optional human-readable diagnostic surfaced in logs and on the
  /// final ProgressDetail::PluginNode event.
  final String? message;

  /// Optional plugin-authored structured payload, serialised as JSON.
  /// Forwarded verbatim to Rust; invalid JSON is logged and dropped
  /// on the Rust side.
  final String? structuredDetailJson;

  const PluginNodeDispatchResult({
    required this.success,
    this.message,
    this.structuredDetailJson,
  });

  /// Convenience constructor for the "no live dispatcher / not wired"
  /// path. Surfaced loudly through the Rust executor's Error event so
  /// users never silently get a successful no-op.
  factory PluginNodeDispatchResult.unwired(String reason) =>
      PluginNodeDispatchResult(success: false, message: reason);
}

/// Function signature the app layer overrides with a real
/// implementation (see `skotiq_app/lib/plugin_node_dispatcher.dart`).
///
/// The dispatcher MUST not throw — failure paths return
/// `PluginNodeDispatchResult(success: false, …)` so the Rust executor
/// always observes a structured verdict.
typedef PluginNodeDispatcher =
    Future<PluginNodeDispatchResult> Function(
      PluginNodeDispatchRequest request,
    );

/// Best-effort in-process de-duplication for plugin node replies.
///
/// The desktop GUI can have both a `SequenceExecutor` and the embedded
/// headless API server subscribed to the native event stream. A plugin node
/// only wants one verdict posted back to Rust, so listeners claim the node id
/// before dispatch and release it after posting the verdict.
class PluginNodeDispatchCoordinator {
  final Set<String> _inFlightNodeIds = <String>{};

  bool claim(String nodeId) {
    if (nodeId.isEmpty || _inFlightNodeIds.contains(nodeId)) {
      return false;
    }
    _inFlightNodeIds.add(nodeId);
    return true;
  }

  void release(String nodeId) {
    _inFlightNodeIds.remove(nodeId);
  }
}

final pluginNodeDispatchCoordinatorProvider =
    Provider<PluginNodeDispatchCoordinator>((ref) {
      return PluginNodeDispatchCoordinator();
    });

/// Riverpod provider for the plugin-node dispatcher.
///
/// The default implementation is unwired: every plugin-node invocation
/// returns a structured failure naming the missing wiring, rather than a
/// success the host never performed. The desktop / mobile app entry points
/// override this with a real dispatcher in their `ProviderScope`.
final pluginNodeDispatcherProvider = Provider<PluginNodeDispatcher>((ref) {
  return (request) async => PluginNodeDispatchResult.unwired(
    'Plugin node dispatcher is not wired in this environment. '
    'Wire pluginNodeDispatcherProvider from the host application '
    'before running PluginNode sequence nodes. '
    '(plugin=${request.pluginId}, node_type=${request.nodeTypeId})',
  );
});
