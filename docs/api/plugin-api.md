# Plugin API Reference

The Plugin API allows extending Skotiq with custom functionality through plugins.

## Base Plugin Interface

### SkotiqPlugin

Base interface for all plugins.

```dart
abstract class SkotiqPlugin {
  /// Unique plugin identifier
  String get id;
  
  /// Human-readable plugin name
  String get name;
  
  /// Plugin version
  String get version;
  
  /// Plugin description
  String get description;
  
  /// Plugin author
  String get author;
  
  /// Called when plugin is first loaded into memory
  Future<void> onLoad(PluginContext context);

  /// Called when plugin is enabled
  Future<void> onEnable();

  /// Called when plugin is disabled
  Future<void> onDisable();

  /// Called when plugin is unloaded
  Future<void> onUnload();
}
```

**Example:**
```dart
class MyPlugin extends SkotiqPlugin {
  @override
  String get id => 'com.example.myplugin';
  
  @override
  String get name => 'My Plugin';
  
  @override
  String get version => '1.0.0';
  
  @override
  String get description => 'A custom plugin';
  
  @override
  String get author => 'John Doe';
  
  @override
  Future<void> onLoad(PluginContext context) async {
    // Initialize plugin
  }
  
  @override
  Future<void> onUnload() async {
    // Cleanup
  }
}
```

## UI Plugins

### UiPlugin

Plugin that adds UI panels.

```dart
abstract class UiPlugin extends SkotiqPlugin {
  /// Get the UI extension points this plugin provides
  List<UiExtensionPoint> get extensionPoints;
}
```

### UiExtensionPoint

UI extension point definition.

```dart
class UiExtensionPoint {
  final UiExtensionPointType type;
  final String title;
  final dynamic Function() widgetBuilder;
}
```

### UiExtensionPointType

Available UI extension point types.

```dart
enum UiExtensionPointType {
  equipmentPanel,  // Panel in equipment tab
  imagingPanel,    // Panel in imaging tab
  sequencerPanel,  // Panel in sequencer tab
  statusBar,       // Status bar widget
  settings,         // Settings section
}
```

**Example:**
```dart
class MyUiPlugin extends UiPlugin {
  @override
  List<UiExtensionPoint> get extensionPoints => [
    UiExtensionPoint(
      type: UiExtensionPointType.equipmentPanel,
      title: 'My Custom Panel',
      widgetBuilder: () => MyCustomWidget(),
    ),
  ];
  
  // ... other required methods
}
```

## Device Plugins

### DevicePlugin

Plugin that adds device support.

```dart
abstract class DevicePlugin extends SkotiqPlugin {
  /// Get the device types this plugin supports
  List<DevicePluginType> get supportedDevices;
}
```

### DevicePluginType

Device types that can be extended.

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

**Example:**
```dart
class MyDevicePlugin extends DevicePlugin {
  @override
  List<DevicePluginType> get supportedDevices => [
    DevicePluginType.camera,
  ];
  
  // ... other required methods
}
```

## Sequence Plugins

### SequencePlugin

Plugin that adds sequence instructions.

```dart
abstract class SequencePlugin extends SkotiqPlugin {
  /// Get the sequence nodes this plugin provides
  List<SequenceNodeDefinition> get nodeDefinitions;
}
```

### SequenceNodeDefinition

Sequence node definition.

```dart
class SequenceNodeDefinition {
  final String id;
  final String name;
  final String category;
  final String description;
  final dynamic Function(Map<String, dynamic>) createNode;
}
```

**Example:**
```dart
class MySequencePlugin extends SequencePlugin {
  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'my-custom-node',
      name: 'Custom Node',
      category: 'Custom',
      description: 'A custom sequence node',
      createNode: (config) => MyCustomNode(config),
    ),
  ];
  
  // ... other required methods
}
```

## Plugin Host

Plugins are managed by the `PluginHost` class.

```dart
class PluginHost {
  Future<void> registerPlugin(SkotiqPlugin plugin, {bool enabled = true});
  Future<void> unregisterPlugin(String pluginId);
  List<SkotiqPlugin> getLoadedPlugins();
  SkotiqPlugin? getPlugin(String pluginId);
}
```

## Plugin Lifecycle

1. **Registration** - `registerPlugin()` creates plugin context and calls `onLoad()`
2. **Enablement** - `onEnable()` runs when the plugin starts enabled or is enabled later
3. **Disablement** - `onDisable()` runs when the plugin is disabled
4. **Unregistration** - `unregisterPlugin()` calls `onUnload()` and removes the plugin

## Best Practices

1. **Unique IDs** - Use reverse domain notation (e.g., `com.example.myplugin`)
2. **Versioning** - Follow semantic versioning
3. **Error Handling** - Handle errors gracefully in `onLoad()` and `onUnload()`
4. **Resource Cleanup** - Always clean up resources in `onUnload()`
5. **Thread Safety** - Ensure thread-safe operations

## Example: Complete Plugin

```dart
class WeatherMonitorPlugin extends UiPlugin {
  @override
  String get id => 'com.example.weathermonitor';
  
  @override
  String get name => 'Weather Monitor';
  
  @override
  String get version => '1.0.0';
  
  @override
  String get description => 'Monitors weather conditions';
  
  @override
  String get author => 'Jane Doe';
  
  @override
  List<UiExtensionPoint> get extensionPoints => [
    UiExtensionPoint(
      type: UiExtensionPointType.statusBar,
      title: 'Weather',
      widgetBuilder: () => WeatherStatusWidget(),
    ),
  ];
  
  @override
  Future<void> onLoad(PluginContext context) async {
    // Start weather monitoring
  }
  
  @override
  Future<void> onUnload() async {
    // Stop weather monitoring
  }
}
```

