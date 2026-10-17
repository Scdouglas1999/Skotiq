# Plugin Best Practices

Guidelines for building reliable, well-behaved Skotiq plugins.

## Lifecycle Management

### Always Store and Clear the Context

Store the `PluginContext` in `onLoad` and null it out in `onUnload`. Use nullable access (`_context?.`) to guard against calls after unload.

```dart
class MyPlugin extends SkotiqPlugin {
  PluginContext? _context;

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  void doWork() {
    // Safe: won't throw if plugin is already unloaded
    _context?.logger.info('Doing work');
  }
}
```

### Cancel All Subscriptions

Every `listen()` call on the event bus creates a `StreamSubscription`. Track them and cancel in `onUnload`:

```dart
final List<StreamSubscription> _subscriptions = [];

@override
Future<void> onLoad(PluginContext context) async {
  _subscriptions.add(
    context.eventBus.on('imaging.captured').listen(_onCapture),
  );
}

@override
Future<void> onUnload() async {
  for (final sub in _subscriptions) {
    await sub.cancel();
  }
  _subscriptions.clear();
}
```

Failing to cancel subscriptions causes memory leaks and can lead to errors when the event bus delivers events to a disposed plugin.

### Distinguish Enable/Disable from Load/Unload

- **`onLoad`/`onUnload`**: Allocate and release resources (SDK init, file handles, subscriptions)
- **`onEnable`/`onDisable`**: Start and stop activity (begin polling, resume processing)

A plugin can be disabled and re-enabled many times during a single session. Do not allocate resources in `onEnable` or release them in `onDisable`.

```dart
@override
Future<void> onEnable() async {
  // Start polling (but the timer was created in onLoad)
  _timer?.cancel();
  _timer = Timer.periodic(Duration(seconds: 30), _poll);
}

@override
Future<void> onDisable() async {
  // Stop polling (but don't dispose the timer object)
  _timer?.cancel();
  _timer = null;
}
```

## Error Handling

### Let Errors Propagate

Do not silently swallow exceptions. The plugin host catches errors from lifecycle methods and records them in the plugin's error state. Silent failures hide bugs.

```dart
// Bad: swallows the error
@override
Future<void> onLoad(PluginContext context) async {
  try {
    await _initSdk();
  } catch (e) {
    // Plugin appears loaded but SDK is broken
  }
}

// Good: let it propagate
@override
Future<void> onLoad(PluginContext context) async {
  _context = context;
  await _initSdk(); // Throws if SDK init fails
}
```

### Log Errors with Context

When catching errors in event handlers or background work, include the exception and stack trace:

```dart
try {
  await processImage(data);
} catch (e, st) {
  _context?.logger.error('Failed to process image', e, st);
  // Re-throw if this is a critical failure, or continue if recoverable
}
```

### Validate Early

For sequence nodes, implement `validate()` to catch configuration errors before execution:

```dart
@override
String? validate() {
  if (exposure <= 0) {
    return 'Exposure must be positive';
  }
  if (filterName.isEmpty) {
    return 'Filter name is required';
  }
  return null;  // null means valid
}
```

## Plugin Identity

### Use Reverse Domain Notation for IDs

Plugin IDs must be globally unique. Use reverse domain notation to prevent collisions:

```dart
// Good
String get id => 'com.mycompany.dewheater';
String get id => 'org.openastro.platesolve';

// Bad: likely to collide
String get id => 'dewheater';
String get id => 'my-plugin';
```

### Follow Semantic Versioning

Use `MAJOR.MINOR.PATCH` versioning:
- **MAJOR**: Breaking changes to the plugin's behavior or configuration
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes

### Set minAppVersion When Using New APIs

If your plugin depends on features added in a specific Skotiq version, declare the minimum:

```dart
@override
String? get minAppVersion => '2.5.0';
```

## Event Best Practices

### Namespace Plugin Events

Prefix all custom events with `plugin.<pluginId>.` to avoid naming collisions:

```dart
context.eventBus.emit('plugin.com.example.weather.reading', {
  'temperature': temp,
  'humidity': humidity,
});
```

### Keep Event Payloads Serializable

Use only strings, numbers, booleans, lists, and maps in event data. This ensures compatibility if the event bus is extended to support cross-process or network communication:

```dart
// Good: serializable types
context.eventBus.emit('measurement', {
  'value': 42.5,
  'unit': 'celsius',
  'tags': ['outdoor', 'sensor-1'],
});

// Bad: non-serializable types
context.eventBus.emit('measurement', {
  'sensor': mySensorObject,  // Not serializable
  'callback': myFunction,     // Not serializable
});
```

### Handle Events Quickly

Event handlers run synchronously on the main isolate. Do not perform long-running work directly in a listener. Instead, launch asynchronous work:

```dart
context.eventBus.on('imaging.captured').listen((data) {
  // Good: kick off async work and return
  _processInBackground(data);
});

Future<void> _processInBackground(Map<String, dynamic> data) async {
  // Long-running processing happens asynchronously
  await analyzeImage(data['filename'] as String);
}
```

## Storage Best Practices

### Use Descriptive Key Names

Use clear, descriptive key names. Consider using dot notation for grouping:

```dart
await context.storage.setString('connection.host', '192.168.1.100');
await context.storage.setInt('connection.port', 8080);
await context.storage.setBool('connection.useSsl', true);
```

### Save State Before Unload

Always persist important state in `onDisable` or `onUnload`:

```dart
@override
Future<void> onUnload() async {
  // Save state before cleanup
  await _context?.storage.setInt('processedCount', _processedCount);
  await _context?.storage.setString(
    'lastRun',
    DateTime.now().toIso8601String(),
  );

  // Then clean up resources
  await _subscription?.cancel();
  _context = null;
}
```

### Handle Missing Values Gracefully

Storage getters return `null` for missing keys. Always provide defaults:

```dart
final interval = await context.storage.getInt('interval') ?? 30;
```

## Testing

### Test with Real Plugin Host

Create a `PluginHost` instance in your tests and register your plugin:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

void main() {
  late PluginHost host;

  setUp(() {
    host = PluginHost();
  });

  tearDown(() async {
    await host.dispose();
  });

  test('plugin registers and loads', () async {
    final plugin = MyPlugin();
    await host.registerPlugin(plugin);

    expect(host.isLoaded(plugin.id), isTrue);
    expect(host.isEnabled(plugin.id), isTrue);
  });

  test('plugin handles enable/disable cycle', () async {
    final plugin = MyPlugin();
    await host.registerPlugin(plugin);

    await host.setPluginEnabled(plugin.id, false);
    expect(host.isEnabled(plugin.id), isFalse);

    await host.setPluginEnabled(plugin.id, true);
    expect(host.isEnabled(plugin.id), isTrue);
  });

  test('plugin stores and retrieves data', () async {
    final plugin = MyPlugin();
    await host.registerPlugin(plugin);

    // Exercise plugin functionality that uses storage
    await plugin.saveConfiguration(interval: 60);

    // Unload and reload to verify persistence
    await host.unregisterPlugin(plugin.id);

    final plugin2 = MyPlugin();
    await host.registerPlugin(plugin2);

    // Verify state was restored
    expect(plugin2.interval, equals(60));
  });
}
```

### Test Event Communication

```dart
test('plugin responds to events', () async {
  final plugin = MyPlugin();
  await host.registerPlugin(plugin);

  // Get the event bus from the loaded plugin's context
  final loaded = host.getPlugin(plugin.id) as MyPlugin;

  // Emit an event the plugin listens to
  loaded.context?.eventBus.emit('imaging.captured', {
    'filename': 'test.fits',
    'exposureMs': 30000,
  });

  // Verify plugin reacted appropriately
  await Future<void>.delayed(Duration.zero); // Let event propagate
  expect(loaded.capturedCount, equals(1));
});
```

### Test Sequence Nodes

```dart
test('custom node executes correctly', () async {
  final plugin = MySequencePlugin();
  await host.registerPlugin(plugin);

  final nodeDef = plugin.nodeDefinitions.first;
  final node = nodeDef.createNode({'duration': 100});

  expect(node, isNotNull);
  expect(node!.validate(), isNull); // Valid params

  final context = PluginContext(
    logger: ConsolePluginLogger('test'),
    storage: InMemoryPluginStorage(),
    eventBus: StreamPluginEventBus(),
  );
  final success = await node.execute(context);
  expect(success, isTrue);
});
```

## Performance

### Avoid Polling When Events Are Available

If an event exists for the state change you care about, subscribe to it instead of polling:

```dart
// Bad: polling every second
Timer.periodic(Duration(seconds: 1), (_) async {
  final temp = await getTemperature();
  if (temp > threshold) _alert();
});

// Good: subscribe to the event
context.eventBus.on('focuser.moved').listen((data) {
  final temp = data['temperature'] as double?;
  if (temp != null && temp > threshold) _alert();
});
```

### Minimize Storage Writes

Batch storage writes rather than writing on every small change:

```dart
// Bad: writes on every measurement
void onMeasurement(double value) {
  _measurements.add(value);
  context.storage.setString('measurements', jsonEncode(_measurements));
}

// Good: write periodically or on disable/unload
Timer.periodic(Duration(minutes: 5), (_) {
  _saveToStorage();
});
```
