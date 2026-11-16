// The Rust executor emits `SequencerEvent::PluginNodeRequested` when it
// reaches a `NodeType::PluginNode`. The sequence executor and the host's
// event fan-out route that event to [pluginNodeDispatcherProvider], which runs
// the plugin through `PluginNodeExecutor` and posts the verdict back through
// `api_sequencer_plugin_node_finished`.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

import '../errors/error_text.dart';

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

/// Verdict the dispatcher returns to the executor, with the structured
/// detail the Rust side forwards on the final plugin-node progress event.
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
}

/// Runs one plugin node.
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

/// Runs a plugin node through the live plugin host and node registry.
///
/// The node's config is the JSON object the Rust side forwarded; an empty
/// config is the empty object. Config that is not a JSON object fails the
/// node without running the plugin, so a plugin never runs with defaults the
/// operator did not choose.
final pluginNodeDispatcherProvider = Provider<PluginNodeDispatcher>((ref) {
  final executor = PluginNodeExecutor(
    host: ref.watch(pluginHostProvider),
    registry: ref.watch(pluginNodeRegistryProvider),
  );

  return (request) async {
    var params = const <String, dynamic>{};
    if (request.configJson.isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(request.configJson);
      } on FormatException catch (error) {
        return _invalidConfig(
          request,
          'configuration is not valid JSON: ${userFacingError(error)}',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        return _invalidConfig(request, 'configuration must be a JSON object');
      }
      params = decoded;
    }

    final result = await executor.run(
      pluginId: request.pluginId,
      nodeTypeId: request.nodeTypeId,
      params: params,
      timeout: Duration(seconds: request.timeoutSecs),
    );

    return PluginNodeDispatchResult(
      success: result.success,
      message: result.message,
      structuredDetailJson: jsonEncode({
        'plugin_id': request.pluginId,
        'node_type_id': request.nodeTypeId,
        'success': result.success,
        if (result.message != null) 'message': result.message,
      }),
    );
  };
});

PluginNodeDispatchResult _invalidConfig(
  PluginNodeDispatchRequest request,
  String reason,
) {
  final message = 'Invalid plugin node configuration: $reason';
  return PluginNodeDispatchResult(
    success: false,
    message: message,
    structuredDetailJson: jsonEncode({
      'plugin_id': request.pluginId,
      'node_type_id': request.nodeTypeId,
      'success': false,
      'message': message,
    }),
  );
}
