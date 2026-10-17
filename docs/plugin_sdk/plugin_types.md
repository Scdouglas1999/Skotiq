# Plugin Types

Skotiq supports four plugin types, each extending the base `SkotiqPlugin` with specialized capabilities.

## Base Plugin (SkotiqPlugin)

The simplest plugin type. Useful for background tasks, event processing, or integrations that don't need UI, device, or sequencer extensions.

```dart
class BackgroundPlugin extends SkotiqPlugin {
  PluginContext? _context;
  StreamSubscription? _subscription;

  @override
  String get id => 'com.example.background';

  @override
  String get name => 'Background Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Processes events in the background';

  @override
  String get author => 'Example';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;

    _subscription = context.eventBus.on('imaging.captured').listen((data) {
      final filename = data['filename'] as String?;
      context.logger.info('Image captured: $filename');
    });
  }

  @override
  Future<void> onUnload() async {
    await _subscription?.cancel();
    _subscription = null;
    _context = null;
  }
}
```

## UI Plugin (UiPlugin)

Adds custom widgets to predefined extension points in the Skotiq UI. Each extension point defines where the widget appears and a builder function that creates it.

### Extension Point Locations

| Type | Location | Description |
|------|----------|-------------|
| `equipmentPanel` | Equipment tab | Adds a panel alongside built-in equipment controls |
| `imagingPanel` | Imaging tab | Adds a panel in the imaging workspace |
| `sequencerPanel` | Sequencer tab | Adds a panel in the sequence editor |
| `statusBar` | Bottom status bar | Adds a compact widget to the status bar |
| `settings` | Settings screen | Adds a configuration section |

### Implementation

```dart
import 'package:flutter/widgets.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

class MyUiPlugin extends UiPlugin {
  PluginContext? _context;

  @override
  String get id => 'com.example.ui';

  @override
  String get name => 'My UI Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Adds custom panels to the UI';

  @override
  String get author => 'Example';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  @override
  List<UiExtensionPoint> get extensionPoints => [
    UiExtensionPoint(
      type: UiExtensionPointType.equipmentPanel,
      title: 'Dew Heater Controls',
      widgetBuilder: () => const DewHeaterPanel(),
    ),
    UiExtensionPoint(
      type: UiExtensionPointType.statusBar,
      title: 'Dew Status',
      widgetBuilder: () => const DewStatusIndicator(),
    ),
  ];
}
```

### Accessing Extension Points

The Skotiq UI uses the `uiExtensionPointsProvider` to render plugin widgets:

```dart
final extensions = ref.watch(uiExtensionPointsProvider);
final equipmentPanels = extensions
    .where((e) => e.type == UiExtensionPointType.equipmentPanel)
    .toList();

for (final ext in equipmentPanels) {
  final widget = ext.widgetBuilder();
  if (widget != null) {
    // Render the widget
  }
}
```

The `widgetBuilder` returns `Widget?`. Returning `null` signals that the extension point should not be rendered (e.g., if its feature is not applicable in the current state).

## Device Plugin (DevicePlugin)

Adds support for custom hardware devices. Device plugins declare which device types they support.

### Supported Device Types

| Type | Description |
|------|-------------|
| `camera` | Imaging cameras (CCD, CMOS) |
| `mount` | Telescope mounts |
| `focuser` | Electronic focusers |
| `filterWheel` | Filter wheels |
| `rotator` | Camera rotators |
| `guider` | Autoguider interfaces |
| `weather` | Weather stations |
| `dome` | Observatory domes |

### Implementation

```dart
class MyDevicePlugin extends DevicePlugin {
  PluginContext? _context;

  @override
  String get id => 'com.example.device';

  @override
  String get name => 'Custom Camera Driver';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Adds support for XYZ cameras';

  @override
  String get author => 'Example';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info('Initializing XYZ camera SDK...');

    // Initialize vendor SDK, scan for connected hardware
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Shutting down XYZ camera SDK');

    // Disconnect from devices, release SDK resources
    _context = null;
  }

  @override
  List<DevicePluginType> get supportedDevices => [
    DevicePluginType.camera,
  ];
}
```

### Querying Device Plugins

```dart
final host = ref.read(pluginHostProvider);
final devicePlugins = host.getPlugins<DevicePlugin>();

for (final plugin in devicePlugins) {
  if (plugin.supportedDevices.contains(DevicePluginType.camera)) {
    // This plugin provides camera support
  }
}
```

## Sequence Plugin (SequencePlugin)

Adds custom automation nodes to the Skotiq sequencer. These nodes appear in the sequence editor alongside built-in nodes like Expose, Slew, and Autofocus.

### Node Definition

Each sequence node has:
- An `id` for serialization and identification
- A `name` and `description` for display
- A `category` for grouping in the node palette
- A `createNode` factory that builds a `PluginSequenceNode` from parameter values

### PluginSequenceNode Interface

The `PluginSequenceNode` interface defines two methods:

- **`execute(context)`**: Runs the node's logic. Returns `true` on success, `false` on failure. The `PluginContext` is passed in to provide logging and event access during execution.
- **`validate()`**: Validates the node's parameters before execution. Returns `null` if parameters are valid, or an error message string describing what is wrong.

### Implementation

```dart
class MySequencePlugin extends SequencePlugin {
  PluginContext? _context;

  @override
  String get id => 'com.example.sequence';

  @override
  String get name => 'Smart Delay Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Adds intelligent delay nodes';

  @override
  String get author => 'Example';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'smartdelay.altitude',
      name: 'Wait for Altitude',
      category: 'Smart Delays',
      description: 'Waits until a target reaches a minimum altitude',
      createNode: (params) {
        final minAlt = params['minAltitude'] as double? ?? 30.0;
        final targetRa = params['targetRa'] as double? ?? 0.0;
        final targetDec = params['targetDec'] as double? ?? 0.0;
        return AltitudeWaitNode(
          minAltitude: minAlt,
          targetRa: targetRa,
          targetDec: targetDec,
        );
      },
    ),
  ];
}

class AltitudeWaitNode implements PluginSequenceNode {
  final double minAltitude;
  final double targetRa;
  final double targetDec;

  AltitudeWaitNode({
    required this.minAltitude,
    required this.targetRa,
    required this.targetDec,
  });

  @override
  Future<bool> execute(PluginContext context) async {
    context.logger.info(
      'Waiting for target at RA=$targetRa, Dec=$targetDec '
      'to reach altitude >= $minAltitude degrees',
    );

    // Poll altitude until condition is met
    while (true) {
      // In a real implementation, compute current altitude from
      // observer location, target coordinates, and current time
      final currentAlt = _computeAltitude();
      if (currentAlt >= minAltitude) {
        context.logger.info('Target altitude $currentAlt >= $minAltitude, proceeding');
        return true;
      }
      context.logger.debug('Current altitude: $currentAlt, waiting...');
      await Future<void>.delayed(const Duration(seconds: 30));
    }
  }

  @override
  String? validate() {
    if (minAltitude < 0 || minAltitude > 90) {
      return 'Minimum altitude must be between 0 and 90 degrees';
    }
    if (targetRa < 0 || targetRa >= 360) {
      return 'Target RA must be between 0 and 360 degrees';
    }
    if (targetDec < -90 || targetDec > 90) {
      return 'Target Dec must be between -90 and 90 degrees';
    }
    return null;
  }

  double _computeAltitude() {
    // Placeholder for real astronomical altitude calculation
    return 0.0;
  }
}
```

### Querying Sequence Nodes

```dart
final host = ref.read(pluginHostProvider);
final sequencePlugins = host.getPlugins<SequencePlugin>();

final allNodes = sequencePlugins
    .expand((p) => p.nodeDefinitions)
    .toList();

// Group by category
final categories = <String, List<SequenceNodeDefinition>>{};
for (final node in allNodes) {
  categories.putIfAbsent(node.category, () => []).add(node);
}
```
