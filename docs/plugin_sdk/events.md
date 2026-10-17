# Plugin Events

The plugin event bus provides publish-subscribe communication between plugins and between plugins and the Skotiq application.

## Event Bus Overview

All plugins share a single event bus. Events emitted by one plugin are visible to all other plugins. The event bus is created by `PluginContextFactory` and shared across all `PluginContext` instances.

## Emitting Events

Use `eventBus.emit()` to publish an event:

```dart
// Event with no data
context.eventBus.emit('myplugin.started');

// Event with data payload
context.eventBus.emit('myplugin.measurement', {
  'temperature': 15.2,
  'humidity': 65.0,
  'timestamp': DateTime.now().toIso8601String(),
});
```

The data payload is a `Map<String, dynamic>`. Keep payloads serializable (strings, numbers, booleans, lists, maps) for maximum compatibility.

## Subscribing to Events

### Subscribe to a Specific Event

Use `eventBus.on(eventName)` to listen for events with a specific name:

```dart
final subscription = context.eventBus.on('imaging.captured').listen((data) {
  final filename = data['filename'] as String?;
  final exposureMs = data['exposureMs'] as int?;
  context.logger.info('Captured: $filename ($exposureMs ms)');
});
```

The stream returned by `on()` is a broadcast stream. Multiple listeners can subscribe to the same event name.

### Subscribe to All Events

`eventBus.onAny()` is sandboxed and disabled by default for third-party
plugins. Unless the host explicitly grants global event access, plugins should
subscribe to specific named events with `eventBus.on(eventName)`.

## Managing Subscriptions

Always cancel subscriptions in `onUnload` to prevent memory leaks:

```dart
class MyPlugin extends SkotiqPlugin {
  PluginContext? _context;
  final List<StreamSubscription> _subscriptions = [];

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;

    _subscriptions.add(
      context.eventBus.on('imaging.captured').listen((data) {
        // Handle event
      }),
    );

    _subscriptions.add(
      context.eventBus.on('guiding.settled').listen((data) {
        // Handle event
      }),
    );
  }

  @override
  Future<void> onUnload() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _context = null;
  }
}
```

## Event Naming Conventions

Use dot-separated, lowercase names following this pattern:

```
<source>.<action>
<source>.<subject>.<action>
```

Examples:
- `imaging.captured` -- An image was captured
- `guiding.settled` -- Guiding has settled to within tolerance
- `mount.slew.started` -- Mount slew began
- `mount.slew.completed` -- Mount slew finished
- `plugin.myplugin.enabled` -- Custom plugin-specific event

### Namespace your events

Prefix plugin-specific events with `plugin.<pluginId>.` to avoid collisions:

```dart
// Good: namespaced to your plugin
context.eventBus.emit('plugin.com.example.weather.alert', {
  'condition': 'high_wind',
  'speed_kph': 45.0,
});

// Bad: generic name risks collision with other plugins or the app
context.eventBus.emit('weather.alert', { ... });
```

## Application Events

The Skotiq application emits events on the plugin event bus for key state changes. Subscribe to these to react to application state:

| Event Name | Data Fields | Description |
|------------|-------------|-------------|
| `app.ready` | `{}` | Application has finished initialization |
| `imaging.captured` | `filename`, `exposureMs`, `filter` | An image was captured |
| `imaging.session.started` | `sessionId`, `target` | Imaging session began |
| `imaging.session.ended` | `sessionId`, `totalFrames` | Imaging session ended |
| `guiding.started` | `{}` | Autoguiding started |
| `guiding.settled` | `rmsArc` | Guiding RMS reached acceptable level |
| `guiding.lost` | `reason` | Guide star lost |
| `mount.slew.started` | `ra`, `dec` | Mount is slewing to coordinates |
| `mount.slew.completed` | `ra`, `dec` | Mount slew finished |
| `mount.tracking.started` | `{}` | Mount tracking enabled |
| `mount.tracking.stopped` | `reason` | Mount tracking stopped |
| `focuser.moved` | `position`, `temperature` | Focuser position changed |
| `sequence.started` | `sequenceId` | Sequence execution started |
| `sequence.completed` | `sequenceId`, `success` | Sequence execution finished |
| `sequence.paused` | `sequenceId`, `reason` | Sequence was paused |

## Timing and Threading

- Events are delivered synchronously on the main isolate
- Event handlers should return quickly to avoid blocking other listeners
- For long-running work triggered by events, use `Future` or spawn background work
- Event order within a single `emit` call is guaranteed: named stream listeners receive the event before `onAny` listeners when global subscriptions are permitted

## Error Handling in Listeners

Exceptions in event listeners do not affect other listeners or the emitting plugin. However, uncaught exceptions in stream listeners will be reported to the zone's error handler. Wrap listener bodies in try-catch for robustness:

```dart
context.eventBus.on('imaging.captured').listen((data) {
  try {
    _processCapture(data);
  } catch (e, st) {
    context.logger.error('Failed to process capture event', e, st);
  }
});
```
