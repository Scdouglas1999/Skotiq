// Registry of plugin-provided sequence node definitions.
//
// `PluginNodeRegistry` is the bridge between the `SequencePlugin` interface
// (where plugin authors declare nodes) and the sequence editor / executor
// (which needs to know what nodes are available and how to instantiate them).
//
// The registry is populated by [PluginHost] when a plugin implementing
// [SequencePlugin] is registered, and emptied when it is unregistered.
// Downstream consumers (sequence editor palette, sequence executor dispatch,
// validation) watch [registrations] for changes.
//
// Wiring contract:
// * Keys are stable: `"<plugin_id>::<node_type_id>"`. Two different plugins
//   may use the same `node_type_id` because the plugin id disambiguates.
// * Lookup is O(1) via [findDefinition].
// * The registry is plugin-host-scoped (one per [PluginHost] instance) so
//   tests can spin up an isolated host without polluting global state.
import 'dart:async';

import 'plugin_api.dart';

/// A registered plugin sequence node definition, paired with the plugin that
/// owns it.
class PluginNodeRegistration {
  /// Id of the plugin that owns this node definition (`plugin.id`).
  final String pluginId;

  /// Human-readable plugin name, surfaced in tooltips / palette categories.
  final String pluginName;

  /// The definition the plugin author authored.
  final SequenceNodeDefinition definition;

  /// Composite registry key: `"<pluginId>::<definition.id>"`.
  String get key => composeKey(pluginId, definition.id);

  const PluginNodeRegistration({
    required this.pluginId,
    required this.pluginName,
    required this.definition,
  });

  /// Compose a stable lookup key from a plugin id + node-type id.
  static String composeKey(String pluginId, String nodeTypeId) =>
      '$pluginId::$nodeTypeId';

  /// Split a composite key back into (`pluginId`, `nodeTypeId`).
  /// Returns `null` for malformed input — callers MUST handle this case
  /// rather than silently fall back to `"unknown::unknown"`.
  static ({String pluginId, String nodeTypeId})? parseKey(String key) {
    final idx = key.indexOf('::');
    if (idx <= 0 || idx >= key.length - 2) return null;
    final pluginId = key.substring(0, idx);
    final nodeTypeId = key.substring(idx + 2);
    if (pluginId.isEmpty || nodeTypeId.isEmpty) return null;
    return (pluginId: pluginId, nodeTypeId: nodeTypeId);
  }
}

/// Result of attempting to execute a plugin sequence node.
///
/// Carries enough information to surface to the sequence executor (which
/// only sees pass/fail) and to the run dashboard / log (which surfaces the
/// optional message).
class PluginNodeExecutionResult {
  /// True if the plugin reported success.
  final bool success;

  /// Optional structured message — e.g. a Pushover delivery id, a Discord
  /// message id, a Home Assistant state confirmation. May be `null`.
  final String? message;

  const PluginNodeExecutionResult({required this.success, this.message});

  /// Convenience: build a success result with no payload.
  const PluginNodeExecutionResult.ok([this.message]) : success = true;

  /// Convenience: build a failure result with the supplied diagnostic.
  const PluginNodeExecutionResult.failed(this.message) : success = false;
}

/// Live registry of every plugin-contributed sequence node, with a broadcast
/// stream that fires whenever the table changes.
///
/// Populated by [PluginHost] — do NOT add registrations directly from plugin
/// code; declare them via `SequencePlugin.nodeDefinitions` and let the host
/// scan + register them.
class PluginNodeRegistry {
  /// Internal table — composite key -> registration.
  final Map<String, PluginNodeRegistration> _registrations = {};

  final StreamController<List<PluginNodeRegistration>> _changes =
      StreamController<List<PluginNodeRegistration>>.broadcast();

  bool _disposed = false;

  /// All current registrations, ordered by registration time. Consumers
  /// that need a stable display order should sort by category + name
  /// themselves.
  List<PluginNodeRegistration> get registrations =>
      List.unmodifiable(_registrations.values);

  /// Stream emitting a fresh snapshot of [registrations] whenever a plugin
  /// adds, removes, or re-registers a node definition.
  Stream<List<PluginNodeRegistration>> get changes => _changes.stream;

  /// Register every definition exposed by [plugin]. Existing registrations
  /// for the same composite key are replaced (re-enabling a plugin after a
  /// reload is a normal flow).
  void registerSequencePlugin(SequencePlugin plugin) {
    if (_disposed) {
      throw PluginException(
        'Cannot register definitions on a disposed PluginNodeRegistry',
      );
    }
    if (plugin.nodeDefinitions.isEmpty) return;

    var changed = false;
    for (final definition in plugin.nodeDefinitions) {
      final reg = PluginNodeRegistration(
        pluginId: plugin.id,
        pluginName: plugin.name,
        definition: definition,
      );
      _registrations[reg.key] = reg;
      changed = true;
    }
    if (changed) _emitChange();
  }

  /// Drop every registration that belongs to [pluginId]. Called by the host
  /// on `unregisterPlugin` and on `setPluginEnabled(false)`.
  void unregisterPlugin(String pluginId) {
    final removed = _registrations.keys
        .where((k) => k.startsWith('$pluginId::'))
        .toList(growable: false);
    if (removed.isEmpty) return;
    for (final key in removed) {
      _registrations.remove(key);
    }
    _emitChange();
  }

  /// Look up a registration by composite key.
  PluginNodeRegistration? findByKey(String key) => _registrations[key];

  /// Look up a registration by plugin id + node type id.
  PluginNodeRegistration? findDefinition(String pluginId, String nodeTypeId) =>
      _registrations[PluginNodeRegistration.composeKey(pluginId, nodeTypeId)];

  /// Instantiate the plugin node for the given (plugin id, node type id)
  /// pair with [params]. Returns `null` if the registration is missing or
  /// if the plugin's `createNode` factory returns `null`.
  ///
  /// Plugin authors MAY return `null` from `createNode` to indicate that
  /// the supplied parameters are unusable; in that case the executor will
  /// treat the node as a failure.
  PluginSequenceNode? createNode(
    String pluginId,
    String nodeTypeId,
    Map<String, dynamic> params,
  ) {
    final reg = findDefinition(pluginId, nodeTypeId);
    if (reg == null) return null;
    return reg.definition.createNode(params);
  }

  /// Drop every registration. Used by tests + by `PluginHost.dispose`.
  void dispose() {
    _disposed = true;
    _registrations.clear();
    _changes.close();
  }

  void _emitChange() {
    if (_disposed || _changes.isClosed) return;
    _changes.add(List.unmodifiable(_registrations.values));
  }
}
