# Skotiq Plugin SDK

Build plugins that extend Skotiq's astrophotography suite with custom UI panels, device drivers, and automation sequence nodes.

## Quick Start

### 1. Create a Plugin Class

Every plugin extends `SkotiqPlugin` and implements its lifecycle methods:

```dart
import 'package:skotiq_plugins/skotiq_plugins.dart';

class MyPlugin extends SkotiqPlugin {
  PluginContext? _context;

  @override
  String get id => 'com.example.myplugin';

  @override
  String get name => 'My Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'A plugin that does something useful';

  @override
  String get author => 'Your Name';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info('Plugin loaded');
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Plugin unloading');
    _context = null;
  }
}
```

### 2. Register the Plugin

Plugins are registered with the `PluginHost` at application startup:

```dart
final host = ref.read(pluginHostProvider);
await host.registerPlugin(MyPlugin());
```

Plugins start enabled by default. To register in a disabled state:

```dart
await host.registerPlugin(MyPlugin(), enabled: false);
```

### 3. Use the Plugin Context

The `PluginContext` provided to `onLoad` gives you access to three core services:

- **`context.logger`** -- Structured logging with severity levels
- **`context.storage`** -- Persistent key-value storage scoped to your plugin
- **`context.eventBus`** -- Publish-subscribe event communication

```dart
@override
Future<void> onLoad(PluginContext context) async {
  // Logging
  context.logger.info('Starting up');
  context.logger.debug('Detailed diagnostic info');
  context.logger.warning('Something unusual happened');
  context.logger.error('Something failed', exception, stackTrace);

  // Storage
  await context.storage.setString('lastRun', DateTime.now().toIso8601String());
  final lastRun = await context.storage.getString('lastRun');

  // Events
  context.eventBus.emit('myplugin.started', {'version': version});
  context.eventBus.on('app.ready').listen((data) {
    context.logger.info('App is ready: $data');
  });
}
```

## Plugin Types

Skotiq supports three specialized plugin types beyond the base `SkotiqPlugin`:

| Type | Base Class | Purpose |
|------|-----------|---------|
| **UI Plugin** | `UiPlugin` | Add panels to equipment, imaging, sequencer tabs, status bar, or settings |
| **Device Plugin** | `DevicePlugin` | Add support for custom hardware devices |
| **Sequence Plugin** | `SequencePlugin` | Add custom automation nodes to the sequencer |

See [plugin_types.md](plugin_types.md) for detailed guides on each type.

## Plugin Lifecycle

Plugins go through a defined lifecycle managed by `PluginHost`:

```
registerPlugin()
    |
    v
  onLoad(context) -- Initialize resources, subscribe to events
    |
    v
  onEnable() -- Called when plugin starts or user enables it
    |
    v
  [Plugin is active and running]
    |
    v
  onDisable() -- Called when user disables the plugin
    |
    v
  onUnload() -- Release all resources, cancel subscriptions
    |
    v
  [Plugin instance destroyed]
```

Key lifecycle rules:

- `onLoad` is called exactly once when the plugin is first registered
- `onEnable`/`onDisable` may be called multiple times as the user toggles the plugin
- `onUnload` is called exactly once when the plugin is unregistered or the app shuts down
- If `onLoad` throws, the plugin is stored in an error state (disabled) and a `PluginException` is raised
- During app shutdown, plugins are unloaded in reverse order of registration

## Plugin Identity

Every plugin requires these identity properties:

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | `String` | Yes | Unique identifier in reverse domain notation (e.g., `com.example.myplugin`) |
| `name` | `String` | Yes | Human-readable name displayed in the UI |
| `version` | `String` | Yes | Semantic version (e.g., `1.0.0`) |
| `description` | `String` | Yes | Brief description of what the plugin does |
| `author` | `String` | Yes | Author name or organization |
| `minAppVersion` | `String?` | No | Minimum Skotiq version required (defaults to `null`) |

## Further Reading

- [API Reference](api_reference.md) -- Complete API documentation
- [Plugin Types](plugin_types.md) -- Detailed guides for UI, Device, and Sequence plugins
- [Events](events.md) -- Event system documentation
- [Storage](storage.md) -- Plugin storage API
- [Best Practices](best_practices.md) -- Error handling, testing, lifecycle management
