/// Plugin API - Interfaces that plugins must implement
library;

/// Base interface for all Skotiq plugins
///
/// Plugins extend this interface to integrate with the Skotiq application.
/// The plugin system provides access to logging, storage, and event communication.
abstract class SkotiqPlugin {
  /// Unique plugin identifier (e.g., 'com.example.myplugin')
  ///
  /// Must be unique across all plugins. Use reverse domain notation.
  String get id;

  /// Human-readable plugin name displayed in UI
  String get name;

  /// Plugin version following semantic versioning (e.g., '1.0.0')
  String get version;

  /// Brief description of plugin functionality
  String get description;

  /// Plugin author name or organization
  String get author;

  /// Minimum Skotiq version required (e.g., '2.0.0')
  ///
  /// Returns null if no minimum version required.
  String? get minAppVersion => null;

  /// Called when plugin is first loaded into memory
  ///
  /// Use this to initialize resources, register callbacks, etc.
  /// The [context] provides access to app services.
  Future<void> onLoad(PluginContext context);

  /// Called when plugin is enabled by user
  ///
  /// Plugins start in enabled state by default. This is called on app startup
  /// or when user manually enables the plugin in settings.
  Future<void> onEnable() async {}

  /// Called when plugin is disabled by user
  ///
  /// Should suspend plugin activity but not release resources.
  /// Resources should be released in [onUnload].
  Future<void> onDisable() async {}

  /// Called when plugin is being unloaded from memory
  ///
  /// Release all resources, close connections, unregister callbacks.
  /// After this call, the plugin instance will be destroyed.
  Future<void> onUnload();
}

/// Context provided to plugins for accessing application functionality
///
/// This is the main interface plugins use to interact with Skotiq.
class PluginContext {
  /// Logger for plugin diagnostic output
  final PluginLogger logger;

  /// Persistent storage for plugin data
  final PluginStorage storage;

  /// Event bus for inter-plugin and plugin-app communication
  final PluginEventBus eventBus;

  /// Creates a plugin context with the specified services
  const PluginContext({
    required this.logger,
    required this.storage,
    required this.eventBus,
  });
}

/// Logger interface for plugins
///
/// Provides structured logging with different severity levels.
/// Logs are written to the application log file and console.
abstract class PluginLogger {
  /// Log an informational message
  void info(String message);

  /// Log a debug message (only in debug builds)
  void debug(String message);

  /// Log a warning message
  void warning(String message);

  /// Log an error with optional exception and stack trace
  void error(String message, [Object? error, StackTrace? stackTrace]);
}

/// Persistent storage interface for plugins
///
/// Provides key-value storage scoped to the plugin.
/// Data persists across application restarts.
abstract class PluginStorage {
  /// Get a string value by key
  ///
  /// Returns null if key doesn't exist.
  Future<String?> getString(String key);

  /// Set a string value for a key
  Future<void> setString(String key, String value);

  /// Get an integer value by key
  ///
  /// Returns null if key doesn't exist or value is not an integer.
  Future<int?> getInt(String key);

  /// Set an integer value for a key
  Future<void> setInt(String key, int value);

  /// Get a boolean value by key
  ///
  /// Returns null if key doesn't exist or value is not a boolean.
  Future<bool?> getBool(String key);

  /// Set a boolean value for a key
  Future<void> setBool(String key, bool value);

  /// Remove a key-value pair
  Future<void> remove(String key);

  /// Get all stored key-value pairs
  Future<Map<String, dynamic>> getAll();

  /// Clear all stored data for this plugin
  Future<void> clear();
}

/// Event bus interface for plugins
///
/// Allows plugins to communicate with each other and with the application
/// using a publish-subscribe pattern.
abstract class PluginEventBus {
  /// Emit an event with optional data
  ///
  /// All subscribers to [eventName] will receive the event.
  void emit(String eventName, [Map<String, dynamic>? data]);

  /// Subscribe to events with a specific name
  ///
  /// Returns a stream that emits event data whenever the event is published.
  Stream<Map<String, dynamic>> on(String eventName);

  /// Subscribe to all events
  ///
  /// Returns a stream that emits all events with their names and data.
  Stream<PluginEvent> onAny();
}

/// Represents a plugin event
class PluginEvent {
  /// Event name
  final String name;

  /// Event data payload
  final Map<String, dynamic> data;

  /// Timestamp when event was emitted
  final DateTime timestamp;

  /// Creates a plugin event
  PluginEvent({required this.name, required this.data, DateTime? timestamp})
    : timestamp = timestamp ?? DateTime.now();
}

/// Exception thrown by plugin system
class PluginException implements Exception {
  /// Error message
  final String message;

  /// Optional underlying cause
  final Object? cause;

  /// Creates a plugin exception
  PluginException(this.message, [this.cause]);

  @override
  String toString() =>
      'PluginException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// Plugin that adds sequence instructions
abstract class SequencePlugin extends SkotiqPlugin {
  /// Get the sequence nodes this plugin provides
  List<SequenceNodeDefinition> get nodeDefinitions;
}

/// Interface for plugin-provided sequence node instances
///
/// Plugins return implementations of this interface from
/// [SequenceNodeDefinition.createNode]. The sequencer calls [execute]
/// when the node runs.
abstract class PluginSequenceNode {
  /// Execute the node's logic
  ///
  /// Returns true if the node completed successfully, false otherwise.
  /// The [params] map contains the node's configuration parameters.
  /// The [context] provides access to plugin services during execution.
  Future<bool> execute(PluginContext context);

  /// Validate the node's parameters before execution
  ///
  /// Returns null if valid, or an error message string if invalid.
  String? validate();
}

/// Sequence node definition
class SequenceNodeDefinition {
  final String id;
  final String name;
  final String category;
  final String description;
  final PluginSequenceNode? Function(Map<String, dynamic> params) createNode;

  SequenceNodeDefinition({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.createNode,
  });
}
