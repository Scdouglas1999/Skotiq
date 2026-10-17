# Plugin SDK API Reference

Complete API reference for the Skotiq Plugin SDK. All types are exported from `package:skotiq_plugins/skotiq_plugins.dart`.

## Core Interfaces

### SkotiqPlugin

Base class for all plugins. Every plugin must extend this class.

```dart
abstract class SkotiqPlugin {
  String get id;
  String get name;
  String get version;
  String get description;
  String get author;
  String? get minAppVersion;

  Future<void> onLoad(PluginContext context);
  Future<void> onEnable();
  Future<void> onDisable();
  Future<void> onUnload();
}
```

#### Properties

| Property | Type | Description |
|----------|------|-------------|
| `id` | `String` | Unique plugin identifier in reverse domain notation |
| `name` | `String` | Human-readable display name |
| `version` | `String` | Semantic version string |
| `description` | `String` | Brief description of functionality |
| `author` | `String` | Author name or organization |
| `minAppVersion` | `String?` | Minimum Skotiq version required. Returns `null` by default |

#### Methods

##### `onLoad(PluginContext context) -> Future<void>`

Called once when the plugin is first loaded into memory. Use this to:
- Store the `context` reference for later use
- Initialize resources and SDK connections
- Subscribe to events
- Restore persisted state from storage

The `context` is the primary interface to Skotiq services. Store it as an instance variable.

Throwing from `onLoad` puts the plugin in an error state (disabled) and raises a `PluginException` to the caller.

##### `onEnable() -> Future<void>`

Called when the plugin is enabled. This happens:
- Immediately after `onLoad` if the plugin is registered with `enabled: true` (default)
- When the user manually enables a previously disabled plugin

Default implementation is a no-op.

##### `onDisable() -> Future<void>`

Called when the plugin is disabled by the user. The plugin should:
- Suspend active operations
- Save any in-progress state to storage
- Stop producing events

Resources should NOT be released here -- that is reserved for `onUnload`.

Default implementation is a no-op.

##### `onUnload() -> Future<void>`

Called once when the plugin is being removed from memory. The plugin must:
- Cancel all stream subscriptions
- Close connections and release resources
- Save final state to storage
- Null out the stored `PluginContext` reference

After this call, the plugin instance will be garbage collected.

---

### PluginContext

Provided to plugins via `onLoad`. Contains all services a plugin needs to interact with Skotiq.

```dart
class PluginContext {
  final PluginLogger logger;
  final PluginStorage storage;
  final PluginEventBus eventBus;

  const PluginContext({
    required this.logger,
    required this.storage,
    required this.eventBus,
  });
}
```

| Field | Type | Description |
|-------|------|-------------|
| `logger` | `PluginLogger` | Structured logging scoped to the plugin |
| `storage` | `PluginStorage` | Persistent key-value storage scoped to the plugin |
| `eventBus` | `PluginEventBus` | Publish-subscribe event communication |

---

### PluginLogger

Logging interface with four severity levels. Logs are written to the application log file and developer console.

```dart
abstract class PluginLogger {
  void info(String message);
  void debug(String message);
  void warning(String message);
  void error(String message, [Object? error, StackTrace? stackTrace]);
}
```

| Method | Level | Description |
|--------|-------|-------------|
| `info` | 800 | General informational messages |
| `debug` | 500 | Detailed diagnostic output (debug builds only) |
| `warning` | 900 | Unusual conditions that are not errors |
| `error` | 1000 | Errors with optional exception and stack trace |

All log messages are prefixed with `Plugin.<pluginId>` in the output.

---

### PluginStorage

Persistent key-value storage scoped to the plugin. Data persists across application restarts.

```dart
abstract class PluginStorage {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<int?> getInt(String key);
  Future<void> setInt(String key, int value);
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
  Future<void> remove(String key);
  Future<Map<String, dynamic>> getAll();
  Future<void> clear();
}
```

| Method | Description |
|--------|-------------|
| `getString(key)` | Get a string value, returns `null` if key doesn't exist |
| `setString(key, value)` | Store a string value |
| `getInt(key)` | Get an integer value, returns `null` if key doesn't exist or value is not an int |
| `setInt(key, value)` | Store an integer value |
| `getBool(key)` | Get a boolean value, returns `null` if key doesn't exist |
| `setBool(key, value)` | Store a boolean value |
| `remove(key)` | Delete a key-value pair |
| `getAll()` | Get all stored key-value pairs as a map |
| `clear()` | Remove all stored data for this plugin |

Storage keys are scoped per-plugin. Two plugins can use the same key name without conflict.

---

### PluginEventBus

Publish-subscribe event system for inter-plugin and plugin-app communication.

```dart
abstract class PluginEventBus {
  void emit(String eventName, [Map<String, dynamic>? data]);
  Stream<Map<String, dynamic>> on(String eventName);
  Stream<PluginEvent> onAny();
}
```

| Method | Description |
|--------|-------------|
| `emit(eventName, data?)` | Publish an event with optional data payload |
| `on(eventName)` | Subscribe to events with a specific name. Returns a broadcast stream |
| `onAny()` | Subscribe to all events. Returns a stream of `PluginEvent` objects |

The event bus is shared across all plugins. Events emitted by one plugin are visible to all others.

---

### PluginEvent

Represents a single event on the event bus.

```dart
class PluginEvent {
  final String name;
  final Map<String, dynamic> data;
  final DateTime timestamp;
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | `String` | Event name used for routing |
| `data` | `Map<String, dynamic>` | Event payload |
| `timestamp` | `DateTime` | When the event was emitted |

---

### PluginException

Exception type thrown by the plugin system.

```dart
class PluginException implements Exception {
  final String message;
  final Object? cause;
}
```

Thrown when:
- Registering a plugin with a duplicate ID
- A plugin's `onLoad` method fails
- Enabling or disabling a plugin fails

---

## Specialized Plugin Types

### UiPlugin

Extends `SkotiqPlugin` to add UI extension points.

```dart
abstract class UiPlugin extends SkotiqPlugin {
  List<UiExtensionPoint> get extensionPoints;
}
```

#### UiExtensionPoint

Defines where and what widget to inject into the Skotiq UI.

```dart
class UiExtensionPoint {
  final UiExtensionPointType type;
  final String title;
  final Widget? Function() widgetBuilder;
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | `UiExtensionPointType` | Where the widget appears in the UI |
| `title` | `String` | Title displayed for this extension point |
| `widgetBuilder` | `Widget? Function()` | Factory that creates the widget. Return `null` to skip rendering |

#### UiExtensionPointType

```dart
enum UiExtensionPointType {
  equipmentPanel,   // Panel in the equipment tab
  imagingPanel,     // Panel in the imaging tab
  sequencerPanel,   // Panel in the sequencer tab
  statusBar,        // Widget in the status bar
  settings,         // Section in the settings screen
}
```

---

### DevicePlugin

Extends `SkotiqPlugin` to declare hardware device support.

```dart
abstract class DevicePlugin extends SkotiqPlugin {
  List<DevicePluginType> get supportedDevices;
}
```

#### DevicePluginType

```dart
enum DevicePluginType {
  camera,
  mount,
  focuser,
  filterWheel,
  rotator,
  guider,
  weather,
  dome,
}
```

---

### SequencePlugin

Extends `SkotiqPlugin` to provide custom sequence automation nodes.

```dart
abstract class SequencePlugin extends SkotiqPlugin {
  List<SequenceNodeDefinition> get nodeDefinitions;
}
```

#### SequenceNodeDefinition

Defines a custom sequence node that can be inserted into automation sequences.

```dart
class SequenceNodeDefinition {
  final String id;
  final String name;
  final String category;
  final String description;
  final PluginSequenceNode? Function(Map<String, dynamic> params) createNode;
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | Unique node identifier |
| `name` | `String` | Display name for the node |
| `category` | `String` | Category for grouping in the node palette |
| `description` | `String` | Description of what the node does |
| `createNode` | `PluginSequenceNode? Function(Map<String, dynamic>)` | Factory that creates a node instance from parameters |

#### PluginSequenceNode

Interface that plugin sequence node instances must implement.

```dart
abstract class PluginSequenceNode {
  Future<bool> execute(PluginContext context);
  String? validate();
}
```

| Method | Description |
|--------|-------------|
| `execute(context)` | Run the node's logic. Returns `true` on success, `false` on failure |
| `validate()` | Validate parameters before execution. Returns `null` if valid, error message if not |

---

## Plugin Host

### PluginHost

Central registry that manages plugin lifecycle. Available via Riverpod provider.

```dart
class PluginHost {
  List<SkotiqPlugin> get plugins;
  List<PluginInfo> get pluginInfo;

  List<T> getPlugins<T extends SkotiqPlugin>();
  SkotiqPlugin? getPlugin(String pluginId);
  bool isLoaded(String pluginId);
  bool isEnabled(String pluginId);

  Future<void> registerPlugin(SkotiqPlugin plugin, {bool enabled = true});
  Future<void> unregisterPlugin(String pluginId);
  Future<bool> setPluginEnabled(String pluginId, bool enabled);
  Future<void> dispose();
}
```

| Method | Description |
|--------|-------------|
| `plugins` | All loaded plugin instances |
| `pluginInfo` | Plugin metadata for UI display |
| `getPlugins<T>()` | Get all enabled plugins of a specific type (e.g., `getPlugins<UiPlugin>()`) |
| `getPlugin(id)` | Get a plugin by its ID, or `null` if not found |
| `isLoaded(id)` | Check if a plugin is registered |
| `isEnabled(id)` | Check if a plugin is currently enabled |
| `registerPlugin(plugin)` | Register and load a plugin |
| `unregisterPlugin(id)` | Disable, unload, and remove a plugin |
| `setPluginEnabled(id, enabled)` | Toggle a plugin's enabled state. Returns `true` if state changed |
| `dispose()` | Unload all plugins and release resources |

### PluginInfo

Read-only metadata about a loaded plugin, used for UI display.

```dart
class PluginInfo {
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final bool enabled;
  final DateTime loadedAt;
  final String? error;
}
```

---

## Riverpod Providers

### pluginHostProvider

```dart
final pluginHostProvider = Provider<PluginHost>((ref) { ... });
```

Provides the singleton `PluginHost` instance. Automatically disposes when the provider is destroyed.

### uiExtensionPointsProvider

```dart
final uiExtensionPointsProvider = Provider<List<UiExtensionPoint>>((ref) { ... });
```

Provides all UI extension points from enabled `UiPlugin` instances. Watches the `pluginHostProvider` for changes.

---

## Implementations

### ConsolePluginLogger

Default `PluginLogger` implementation that writes to the Dart developer log. Log entries are prefixed with `Plugin.<pluginId>`.

### InMemoryPluginStorage

Default `PluginStorage` implementation backed by an in-memory map. Data does not persist across app restarts in this implementation.

### StreamPluginEventBus

Default `PluginEventBus` implementation using Dart `StreamController` broadcast streams. Supports both named event streams and a global event stream.

### PluginContextFactory

Creates `PluginContext` instances for plugins. Shares a single `StreamPluginEventBus` across all plugins so they can communicate via events.
