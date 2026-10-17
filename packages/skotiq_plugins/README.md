# Skotiq Plugins

The plugin system for Skotiq, allowing developers to extend the application with custom functionality.

## Overview

Skotiq's plugin architecture provides a flexible way to add new features without modifying core code. Plugins can:

- Add custom UI panels and widgets
- Support additional hardware devices
- Extend the sequencer with custom automation nodes
- Implement background services and integrations
- Communicate via events and shared storage

## Architecture

### Core Components

- **SkotiqPlugin** - Base interface all plugins implement
- **PluginContext** - Provides access to logging, storage, and events
- **PluginHost** - Manages plugin lifecycle and registration
- **PluginLoader** (via PluginHost) - Handles enable/disable state

### Plugin Types

1. **Base Plugin** (`SkotiqPlugin`)
   - Core functionality plugins
   - Access to logging, storage, and events
   - Lifecycle hooks: `onLoad`, `onEnable`, `onDisable`, `onUnload`

2. **Sequence Plugin** (`SequencePlugin extends SkotiqPlugin`)
   - Custom sequence nodes for automation
   - Extend the behavior tree with new actions
   - Custom logic and triggers

## Creating a Plugin

### Basic Plugin Example

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
  String get description => 'Does something amazing';

  @override
  String get author => 'Your Name';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info('Plugin loaded!');

    // Subscribe to events
    context.eventBus.on('capture.complete').listen((data) {
      context.logger.info('Capture completed: $data');
    });
  }

  @override
  Future<void> onEnable() async {
    _context?.logger.info('Plugin enabled');
  }

  @override
  Future<void> onDisable() async {
    _context?.logger.info('Plugin disabled');
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Plugin unloaded');
    _context = null;
  }
}
```

### Using Plugin Services

#### Logging

```dart
context.logger.debug('Debug message');
context.logger.info('Info message');
context.logger.warning('Warning message');
context.logger.error('Error message', exception, stackTrace);
```

#### Storage

```dart
// Store values
await context.storage.setString('key', 'value');
await context.storage.setInt('counter', 42);
await context.storage.setBool('enabled', true);

// Retrieve values
final value = await context.storage.getString('key');
final counter = await context.storage.getInt('counter');
final enabled = await context.storage.getBool('enabled');

// Remove or clear
await context.storage.remove('key');
await context.storage.clear();
```

#### Events

```dart
// Emit events
context.eventBus.emit('plugin.myevent', {
  'data': 'value',
  'timestamp': DateTime.now().toIso8601String(),
});

// Subscribe to events
final subscription = context.eventBus.on('app.ready').listen((data) {
  print('App ready: $data');
});

// Cancel subscription
await subscription.cancel();
```

## Plugin Lifecycle

```
Registration:
  registerPlugin() -> onLoad() -> onEnable() -> [enabled state]

Enable/Disable:
  setPluginEnabled(true) -> onEnable()
  setPluginEnabled(false) -> onDisable()

Unregistration:
  unregisterPlugin() -> onDisable() -> onUnload() -> [destroyed]
```

## Best Practices

1. **Unique IDs**: Use reverse domain notation (e.g., `com.yourcompany.pluginname`)

2. **Semantic Versioning**: Follow semver (MAJOR.MINOR.PATCH)

3. **Resource Cleanup**: Always clean up in `onUnload()`:
   - Cancel subscriptions
   - Close connections
   - Release memory

4. **Error Handling**: Use try-catch and log errors:
   ```dart
   try {
     // Plugin code
   } catch (e, stack) {
     context.logger.error('Operation failed', e, stack);
   }
   ```

5. **State Management**: Use `onDisable()` to pause, not destroy:
   ```dart
   @override
   Future<void> onDisable() async {
     // Pause timers, save state
     // Don't release resources
   }
   ```

6. **Async Operations**: Always use async/await properly:
   ```dart
   @override
   Future<void> onLoad(PluginContext context) async {
     await someAsyncOperation();
     // Don't return until initialization is complete
   }
   ```

7. **Global event access is sandboxed**: `eventBus.onAny()` is blocked by
   default. Prefer `eventBus.on('<specific.event>')` subscriptions unless the
   host explicitly grants broader access.

## Testing

Test plugins in isolation:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

void main() {
  group('MyPlugin', () {
    late PluginHost host;
    late MyPlugin plugin;

    setUp(() {
      host = PluginHost();
      plugin = MyPlugin();
    });

    tearDown(() async {
      await host.dispose();
    });

    test('loads successfully', () async {
      await host.registerPlugin(plugin);
      expect(host.isLoaded(plugin.id), isTrue);
      expect(host.isEnabled(plugin.id), isTrue);
    });

    test('can be disabled', () async {
      await host.registerPlugin(plugin);
      await host.setPluginEnabled(plugin.id, false);
      expect(host.isEnabled(plugin.id), isFalse);
    });
  });
}
```

## Example Plugins

See `lib/src/example_plugin.dart` for basic examples and `lib/examples/` for more complete implementations:

### Basic Examples (`lib/src/example_plugin.dart`)
- **ExamplePlugin** - Basic plugin with storage and events
- **ExampleSequencePlugin** - Custom sequence nodes

### Working Examples (`lib/examples/`)
- **WeatherLoggerPlugin** - Logs weather data to persistent storage, demonstrates events + storage
- **CustomNotificationPlugin** - Sends notifications based on configurable event conditions
- **SequenceDelayPlugin** - Intelligent delay sequence nodes (conditional, cooldown, twilight)

## Full Documentation

See `docs/plugin_sdk/` for comprehensive SDK documentation:

- [Getting Started](../../docs/plugin_sdk/README.md)
- [API Reference](../../docs/plugin_sdk/api_reference.md)
- [Plugin Types](../../docs/plugin_sdk/plugin_types.md)
- [Events](../../docs/plugin_sdk/events.md)
- [Storage](../../docs/plugin_sdk/storage.md)
- [Best Practices](../../docs/plugin_sdk/best_practices.md)

## Plugin Discovery

Currently, plugins are registered programmatically at app startup. Future versions may support:

- Dynamic loading from plugin directories
- Hot reload during development
- Plugin marketplace/repository

## API Stability

The plugin API is currently in **beta**. Breaking changes may occur before 2.0.0 release:

- ✅ Stable: Core interfaces (SkotiqPlugin, PluginContext)
- ⚠️ Beta: UI extensions (may change)
- ⚠️ Beta: Device plugin interface (may change)
- ⚠️ Beta: Sequence plugin interface (may change)

## Contributing

To contribute plugin examples or improvements:

1. Follow the Dart style guide
2. Add comprehensive documentation
3. Include tests for new features
4. Update examples as needed

## License

Part of Skotiq - see LICENSE file in repository root.
