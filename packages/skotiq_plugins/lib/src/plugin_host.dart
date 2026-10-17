import 'dart:developer' as developer;
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'plugin_api.dart';
import 'plugin_context.dart';
import 'plugin_node_registry.dart';

/// Represents a loaded plugin with its state
class LoadedPlugin {
  /// The plugin instance
  final SkotiqPlugin plugin;

  /// Plugin context providing access to app services
  final PluginContext context;

  /// Whether the plugin is currently enabled
  final bool enabled;

  /// Timestamp when plugin was loaded
  final DateTime loadedAt;

  /// Error that occurred during plugin operation, if any
  final String? error;

  /// True only when initial registration failed and a fresh registration may
  /// replace this entry. Enable/disable failures and compatibility blocks must
  /// not make a provider refresh tear down an otherwise loaded plugin.
  final bool registrationFailed;

  /// True when the plugin's minimum Skotiq version is newer than this
  /// host. Such an entry remains visible but cannot be enabled or retried by a
  /// provider refresh; only running a compatible app version can unblock it.
  final bool compatibilityBlocked;

  /// Creates a loaded plugin entry
  LoadedPlugin({
    required this.plugin,
    required this.context,
    required this.enabled,
    DateTime? loadedAt,
    this.error,
    this.registrationFailed = false,
    this.compatibilityBlocked = false,
  }) : loadedAt = loadedAt ?? DateTime.now();

  /// Create a copy with updated fields
  LoadedPlugin copyWith({
    bool? enabled,
    String? error,
    bool clearError = false,
    bool? registrationFailed,
    bool? compatibilityBlocked,
  }) {
    assert(!clearError || error == null);
    return LoadedPlugin(
      plugin: plugin,
      context: context,
      enabled: enabled ?? this.enabled,
      loadedAt: loadedAt,
      error: clearError ? null : (error ?? this.error),
      registrationFailed: registrationFailed ?? this.registrationFailed,
      compatibilityBlocked: compatibilityBlocked ?? this.compatibilityBlocked,
    );
  }
}

/// Plugin information for UI display
class PluginInfo {
  /// Unique plugin identifier
  final String id;

  /// Human-readable name
  final String name;

  /// Version string
  final String version;

  /// Plugin description
  final String description;

  /// Plugin author
  final String author;

  /// Whether plugin is enabled
  final bool enabled;

  /// When plugin was loaded
  final DateTime loadedAt;

  /// Error message if plugin failed
  final String? error;

  /// Whether the current host version permits enabling this plugin.
  final bool canEnable;

  /// Creates plugin info
  const PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.enabled,
    required this.loadedAt,
    this.error,
    this.canEnable = true,
  });
}

/// Plugin host - manages loading and lifecycle of plugins
///
/// This is the central registry for all plugins. It handles:
/// - Plugin registration and unregistration
/// - Enable/disable state management
/// - Plugin lifecycle callbacks (load, enable, disable, unload)
/// - Error handling and recovery
class PluginHost {
  final Map<String, LoadedPlugin> _plugins = {};
  final PluginContextFactory _contextFactory;
  final Duration _lifecycleTimeout;

  /// Running application version (e.g. `6.0.0`), or null when the host was
  /// created without one. When set, [registerPlugin] enforces each plugin's
  /// [SkotiqPlugin.minAppVersion]; when null, enforcement is skipped so the
  /// package and its tests work standalone.
  final String? _appVersion;

  /// Registry of plugin-contributed sequence node definitions. Populated
  /// automatically when a [SequencePlugin] is registered + enabled; emptied
  /// when the plugin is unregistered or disabled.
  ///
  /// Consumers (sequence editor palette, sequence executor dispatch) read
  /// from this registry — there is intentionally NO separate "register
  /// node" API for plugin authors. Authoring a node = exposing it from
  /// `SequencePlugin.nodeDefinitions`.
  final PluginNodeRegistry nodeRegistry;

  PluginHost({
    PluginContextFactory? contextFactory,
    Duration lifecycleTimeout = const Duration(seconds: 5),
    PluginNodeRegistry? nodeRegistry,
    String? appVersion,
  }) : _contextFactory = contextFactory ?? PluginContextFactory(),
       _lifecycleTimeout = lifecycleTimeout,
       _appVersion = appVersion,
       nodeRegistry = nodeRegistry ?? PluginNodeRegistry();

  /// Get all loaded plugins
  List<SkotiqPlugin> get plugins =>
      _plugins.values.map((p) => p.plugin).toList();

  /// Get plugin information for UI display
  List<PluginInfo> get pluginInfo {
    return _plugins.values.map((loaded) {
      final plugin = loaded.plugin;
      return PluginInfo(
        id: plugin.id,
        name: plugin.name,
        version: plugin.version,
        description: plugin.description,
        author: plugin.author,
        enabled: loaded.enabled,
        loadedAt: loaded.loadedAt,
        error: loaded.error,
        canEnable: !loaded.compatibilityBlocked,
      );
    }).toList();
  }

  /// Get plugins of a specific type
  List<T> getPlugins<T extends SkotiqPlugin>() {
    return _plugins.values
        .where((p) => p.enabled && p.plugin is T)
        .map((p) => p.plugin as T)
        .toList();
  }

  /// Get a plugin by ID
  SkotiqPlugin? getPlugin(String pluginId) {
    return _plugins[pluginId]?.plugin;
  }

  /// Return the live [PluginContext] associated with [pluginId], or `null`
  /// if no such plugin is registered. Plugin nodes use this to access the
  /// same logger / storage / event bus their owning plugin sees during
  /// lifecycle callbacks.
  PluginContext? contextFor(String pluginId) {
    return _plugins[pluginId]?.context;
  }

  /// Check if a plugin is loaded
  bool isLoaded(String pluginId) {
    return _plugins.containsKey(pluginId);
  }

  /// Check if a plugin is enabled
  bool isEnabled(String pluginId) {
    return _plugins[pluginId]?.enabled ?? false;
  }

  /// The recorded error for [pluginId], or null when the plugin is healthy or
  /// not loaded. The registration pipeline uses this to decide whether a
  /// previously-failed plugin should be torn down and re-attempted (so the
  /// Settings "Retry" actually recovers it) instead of being skipped forever.
  String? pluginError(String pluginId) => _plugins[pluginId]?.error;

  /// Whether [pluginId] is a retained failed initial registration that the
  /// registration pipeline should tear down and recreate on Retry.
  bool registrationFailed(String pluginId) =>
      _plugins[pluginId]?.registrationFailed ?? false;

  /// Register a plugin
  ///
  /// Loads the plugin and calls its [onLoad] lifecycle method.
  /// The plugin starts in enabled state by default.
  ///
  /// Throws [PluginException] if:
  /// - Plugin ID is unsafe (path-traversal / invalid characters)
  /// - Plugin ID already registered
  /// - Plugin loading fails
  ///
  /// A plugin whose [SkotiqPlugin.minAppVersion] is newer than the host's
  /// app version (when one was supplied) is NOT an error: it is registered
  /// loaded-but-disabled with a descriptive [LoadedPlugin.error] and this
  /// method returns normally, so the UI can surface "requires vX" without its
  /// lifecycle ever running against an incompatible build.
  Future<void> registerPlugin(
    SkotiqPlugin plugin, {
    bool enabled = true,
  }) async {
    // Reject unsafe ids before anything touches disk: the id becomes a storage
    // filename, so a `../`-style id must never reach [FilePluginStorage].
    assertSafePluginId(plugin.id);

    if (_plugins.containsKey(plugin.id)) {
      throw PluginException('Plugin ${plugin.id} is already registered');
    }

    final context = _contextFactory.createContext(plugin.id);

    // Enforce the declared minimum app version before running any lifecycle
    // callback — an incompatible plugin may call APIs this build lacks. Only
    // active when the host knows the running version.
    final appVersion = _appVersion;
    final minRequired = plugin.minAppVersion;
    if (appVersion != null &&
        minRequired != null &&
        !_appVersionSatisfies(appVersion, minRequired)) {
      _plugins[plugin.id] = LoadedPlugin(
        plugin: plugin,
        context: context,
        enabled: false,
        error:
            'Requires Skotiq $minRequired or newer (running $appVersion).',
        compatibilityBlocked: true,
      );
      context.logger.warning(
        'Plugin ${plugin.id} requires app version $minRequired but the app is '
        '$appVersion; registered as disabled.',
      );
      return;
    }

    try {
      // Call onLoad lifecycle method
      await _runLifecycle(
        plugin,
        context,
        'onLoad',
        () => plugin.onLoad(context),
      );

      // Store loaded plugin
      _plugins[plugin.id] = LoadedPlugin(
        plugin: plugin,
        context: context,
        enabled: enabled,
      );

      // Call onEnable if starting enabled
      if (enabled) {
        await _runLifecycle(plugin, context, 'onEnable', plugin.onEnable);
        // Wire sequence-plugin nodes into the registry as soon as the
        // plugin is enabled. SequenceNodeDefinition.createNode is the
        // contract — we DON'T pre-instantiate nodes, just expose the
        // factories so the sequence executor can build instances later.
        if (plugin is SequencePlugin) {
          nodeRegistry.registerSequencePlugin(plugin);
        }
      }

      context.logger.info('Plugin registered successfully');
    } catch (e, stackTrace) {
      context.logger.error('Failed to register plugin', e, stackTrace);

      // Store plugin with error state
      _plugins[plugin.id] = LoadedPlugin(
        plugin: plugin,
        context: context,
        enabled: false,
        error: e.toString(),
        registrationFailed: true,
      );

      throw PluginException('Failed to register plugin ${plugin.id}', e);
    }
  }

  /// Unregister a plugin
  ///
  /// Disables the plugin if enabled, then unloads it by calling [onUnload].
  Future<void> unregisterPlugin(String pluginId) async {
    final loaded = _plugins[pluginId];
    if (loaded == null) return;

    // Drop sequence-node registrations BEFORE running onDisable so any
    // in-flight palette / executor lookups see a consistent state during
    // teardown. A late-firing executor that grabs a registration just
    // before unregister will still find the node in the host's plugin
    // map (the registration is purely a "is this node available right
    // now?" cache).
    nodeRegistry.unregisterPlugin(pluginId);

    try {
      // Disable if enabled
      if (loaded.enabled) {
        await _runLifecycle(
          loaded.plugin,
          loaded.context,
          'onDisable',
          loaded.plugin.onDisable,
        );
      }

      // Unload plugin
      await _runLifecycle(
        loaded.plugin,
        loaded.context,
        'onUnload',
        loaded.plugin.onUnload,
      );

      loaded.context.logger.info('Plugin unregistered successfully');
    } catch (e, stackTrace) {
      loaded.context.logger.error('Error unregistering plugin', e, stackTrace);
      // Continue with removal even if unload fails
    } finally {
      _plugins.remove(pluginId);
    }
  }

  /// Set plugin enabled state
  ///
  /// Calls [onEnable] when enabling or [onDisable] when disabling.
  ///
  /// Returns true when the state changes, false when it already matched.
  Future<bool> setPluginEnabled(String pluginId, bool enabled) async {
    final loaded = _plugins[pluginId];
    if (loaded == null) {
      throw PluginException('Plugin $pluginId not found');
    }
    if (enabled && loaded.compatibilityBlocked) {
      throw PluginException(
        loaded.error ??
            'Plugin $pluginId is incompatible with this app version',
      );
    }

    // No change needed
    if (loaded.enabled == enabled) {
      return false;
    }

    try {
      if (enabled) {
        await _runLifecycle(
          loaded.plugin,
          loaded.context,
          'onEnable',
          loaded.plugin.onEnable,
        );
        // Re-publish sequence nodes when a previously-disabled plugin
        // is re-enabled. We do this AFTER onEnable returns so the
        // plugin's own context is in the enabled state by the time
        // the executor could resolve and run one of its nodes.
        if (loaded.plugin is SequencePlugin) {
          nodeRegistry.registerSequencePlugin(loaded.plugin as SequencePlugin);
        }
        loaded.context.logger.info('Plugin enabled');
      } else {
        // Yank registrations BEFORE onDisable so a late palette refresh
        // doesn't show ghost entries for a plugin that's halfway through
        // releasing resources.
        nodeRegistry.unregisterPlugin(pluginId);
        await _runLifecycle(
          loaded.plugin,
          loaded.context,
          'onDisable',
          loaded.plugin.onDisable,
        );
        loaded.context.logger.info('Plugin disabled');
      }

      // Update state
      _plugins[pluginId] = loaded.copyWith(
        enabled: enabled,
        clearError: true,
        registrationFailed: false,
        compatibilityBlocked: false,
      );
      return true;
    } catch (e, stackTrace) {
      loaded.context.logger.error(
        'Failed to ${enabled ? 'enable' : 'disable'} plugin',
        e,
        stackTrace,
      );

      // Update with error state
      _plugins[pluginId] = loaded.copyWith(error: e.toString());

      throw PluginException(
        'Failed to ${enabled ? 'enable' : 'disable'} plugin $pluginId',
        e,
      );
    }
  }

  /// Dispose all plugins and release resources
  ///
  /// Unregisters all plugins in reverse order of registration.
  Future<void> dispose() async {
    final pluginIds = _plugins.keys.toList().reversed;

    for (final pluginId in pluginIds) {
      try {
        await unregisterPlugin(pluginId);
      } catch (e) {
        // Log but continue disposing other plugins
        developer.log(
          'Error disposing plugin $pluginId: $e',
          name: 'PluginHost',
          level: 1000,
        );
      }
    }

    _contextFactory.dispose();
    _plugins.clear();
    nodeRegistry.dispose();
  }

  Future<void> _runLifecycle(
    SkotiqPlugin plugin,
    PluginContext context,
    String phase,
    Future<void> Function() action,
  ) async {
    final completer = Completer<void>();

    unawaited(
      runZonedGuarded(
        () async {
          try {
            await action();
            if (!completer.isCompleted) {
              completer.complete();
            }
          } catch (error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          }
        },
        (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );

    try {
      await completer.future.timeout(_lifecycleTimeout);
    } on TimeoutException catch (error) {
      context.logger.error('Plugin lifecycle timed out during $phase', error);
      throw PluginException(
        'Plugin ${plugin.id} timed out during $phase after '
        '${_lifecycleTimeout.inSeconds}s',
        error,
      );
    }
  }
}

bool _appVersionSatisfies(String running, String minimum) {
  final current = _SemanticVersion.tryParse(running);
  final required = _SemanticVersion.tryParse(minimum);
  if (current == null || required == null) return false;
  return current.compareTo(required) >= 0;
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.core, this.preRelease);

  final List<int> core;
  final List<String> preRelease;

  static _SemanticVersion? tryParse(String raw) {
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    value = value.split('+').first;
    final dash = value.indexOf('-');
    final coreText = dash < 0 ? value : value.substring(0, dash);
    final preText = dash < 0 ? '' : value.substring(dash + 1);
    final parts = coreText.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final core = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^\d+$').hasMatch(part)) return null;
      final number = int.tryParse(part);
      if (number == null) return null;
      core.add(number);
    }
    while (core.length < 3) {
      core.add(0);
    }

    final preRelease = preText.isEmpty ? <String>[] : preText.split('.');
    if (preRelease.any(
      (part) => part.isEmpty || !RegExp(r'^[0-9A-Za-z-]+$').hasMatch(part),
    )) {
      return null;
    }
    return _SemanticVersion(core, preRelease);
  }

  @override
  int compareTo(_SemanticVersion other) {
    for (var i = 0; i < 3; i++) {
      final comparison = core[i].compareTo(other.core[i]);
      if (comparison != 0) return comparison;
    }
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final common = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < common; i++) {
      final left = preRelease[i];
      final right = other.preRelease[i];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      final comparison = switch ((leftNumber, rightNumber)) {
        (final int a, final int b) => a.compareTo(b),
        (final int _, null) => -1,
        (null, final int _) => 1,
        (null, null) => left.compareTo(right),
      };
      if (comparison != 0) return comparison;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }
}

/// Plugin host provider
final pluginHostProvider = Provider<PluginHost>((ref) {
  final host = PluginHost();
  ref.onDispose(() => host.dispose());
  return host;
});

/// Plugin sequence-node registry provider. Exposed at the package level so
/// the sequence editor (palette) and the sequence executor (dispatch) can
/// resolve plugin-contributed nodes without depending on the host directly.
final pluginNodeRegistryProvider = Provider<PluginNodeRegistry>((ref) {
  final host = ref.watch(pluginHostProvider);
  return host.nodeRegistry;
});

/// Stream of registry changes. Useful for editor widgets that want to keep
/// a live "available plugin nodes" listing in sync as the user installs /
/// enables / disables plugins.
final pluginNodeRegistrationsStreamProvider =
    StreamProvider<List<PluginNodeRegistration>>((ref) {
      final registry = ref.watch(pluginNodeRegistryProvider);
      // Seed the stream with the current snapshot so a subscriber attached
      // after registration still observes the existing entries on first build.
      return Stream<List<PluginNodeRegistration>>.value(
        registry.registrations,
      ).asyncExpand((seed) async* {
        yield seed;
        yield* registry.changes;
      });
    });
