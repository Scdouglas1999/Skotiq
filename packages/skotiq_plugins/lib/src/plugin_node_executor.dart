// Executor for plugin-provided sequence nodes.
//
// Sequence-executor / bridge code calls `PluginNodeExecutor.run` with the
// composite plugin/node ids + config. The executor looks the definition up
// in `PluginNodeRegistry`, creates a fresh `PluginSequenceNode`, validates
// parameters, executes it against a wired `PluginContext`, and returns a
// structured `PluginNodeExecutionResult`.
//
// This file is intentionally executor-agnostic: it does not depend on the
// Rust bridge or on `skotiq_core` types. The Dart-side `SequenceExecutor`
// wires the inbound "this plugin node is up next" event to a call into
// `PluginNodeExecutor.run`.
import 'dart:async';

import 'plugin_host.dart';
import 'plugin_node_registry.dart';

/// Bridges the plugin-node registry, the per-plugin context (held by the
/// host), and the node execution lifecycle.
class PluginNodeExecutor {
  final PluginHost _host;
  final PluginNodeRegistry _registry;

  /// How long to wait for a plugin's `execute` future before forcibly
  /// reporting a failure. Plugins that need to run longer than the default
  /// (e.g. a long HA wait-for-state cycle) MUST shorten their own internal
  /// timeout to stay below this; otherwise the host treats them as hung
  /// and surfaces a structured failure to the sequencer.
  final Duration defaultTimeout;

  PluginNodeExecutor({
    required PluginHost host,
    required PluginNodeRegistry registry,
    this.defaultTimeout = const Duration(minutes: 10),
  }) : _host = host,
       _registry = registry;

  /// Execute the plugin node identified by [pluginId] / [nodeTypeId] with
  /// the supplied [params] map.
  ///
  /// Returns a structured result rather than throwing:
  /// * plugin lookup failures => `failed("Unknown plugin node …")`
  /// * plugin's `validate()` returning non-null => `failed(reason)`
  /// * plugin's `execute()` throwing => `failed("Plugin threw: …")`
  /// * plugin's `execute()` exceeding [timeout] (or [defaultTimeout]) =>
  ///   `failed("Plugin timed out after Xs")`
  Future<PluginNodeExecutionResult> run({
    required String pluginId,
    required String nodeTypeId,
    required Map<String, dynamic> params,
    Duration? timeout,
  }) async {
    // 1. Look up the registration.
    final registration = _registry.findDefinition(pluginId, nodeTypeId);
    if (registration == null) {
      return PluginNodeExecutionResult.failed(
        'Unknown plugin node: $pluginId / $nodeTypeId. '
        'Is the plugin loaded and enabled?',
      );
    }

    // 2. Confirm the owning plugin is currently enabled. A disabled plugin
    // SHOULD have been removed from the registry already, but a guard here
    // keeps the contract explicit (and survives races where the user
    // toggles enable between palette pick + sequence start).
    if (!_host.isEnabled(pluginId)) {
      return PluginNodeExecutionResult.failed(
        'Plugin $pluginId is not enabled; cannot execute its nodes',
      );
    }

    // 3. Resolve the plugin's context (logger / storage / event bus) from
    // the host. We need this context, not a freshly-built one, so the node
    // shares storage and event bus with the plugin's own lifecycle.
    final context = _host.contextFor(pluginId);
    if (context == null) {
      return PluginNodeExecutionResult.failed(
        'Plugin $pluginId has no live context — cannot execute its nodes',
      );
    }

    // 4. Build the plugin's node instance.
    final node = registration.definition.createNode(params);
    if (node == null) {
      return PluginNodeExecutionResult.failed(
        'Plugin $pluginId rejected the node parameters '
        '(createNode returned null). Check the node\'s configuration.',
      );
    }

    // 5. Pre-execution validation. Surfaces friendly errors before we
    // commit to a long-running execute().
    final validationError = node.validate();
    if (validationError != null) {
      return PluginNodeExecutionResult.failed(
        'Plugin node ${registration.pluginName}/${registration.definition.name} '
        'failed validation: $validationError',
      );
    }

    // 6. Execute the node. We never let plugin exceptions tear down the
    // executor — every error path becomes a structured failure result.
    final effectiveTimeout = timeout ?? defaultTimeout;
    try {
      final ok = await node.execute(context).timeout(effectiveTimeout);
      return PluginNodeExecutionResult(
        success: ok,
        message: ok
            ? '${registration.definition.name} completed'
            : '${registration.definition.name} reported failure',
      );
    } on TimeoutException catch (error) {
      context.logger.error(
        'Plugin node ${registration.definition.id} exceeded timeout '
        '${effectiveTimeout.inSeconds}s',
        error,
      );
      return PluginNodeExecutionResult.failed(
        'Plugin node ${registration.definition.name} timed out after '
        '${effectiveTimeout.inSeconds}s',
      );
    } catch (error, stackTrace) {
      context.logger.error(
        'Plugin node ${registration.definition.id} threw',
        error,
        stackTrace,
      );
      return PluginNodeExecutionResult.failed(
        'Plugin node ${registration.definition.name} threw: $error',
      );
    }
  }
}
