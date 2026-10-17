/// Skotiq Plugins - Plugin host and API
///
/// This library provides the plugin system for Skotiq, allowing users
/// to extend the application with custom functionality.
///
/// ## Core Components
///
/// - [SkotiqPlugin] - Base interface all plugins must implement
/// - [PluginContext] - Provides access to app services (logging, storage, events)
/// - [PluginHost] - Manages plugin lifecycle and registration
///
/// ## Plugin Types
///
/// - [SequencePlugin] - Add custom automation sequence nodes
///
/// Sequence nodes are the extension point the host consumes: devices are the
/// Rust bridge's alone, and the UI has no host-side surface a plugin can render
/// into.
///
/// ## Example Usage
///
/// ```dart
/// class MyPlugin extends SkotiqPlugin {
///   @override
///   String get id => 'com.example.myplugin';
///
///   @override
///   String get name => 'My Plugin';
///
///   @override
///   String get version => '1.0.0';
///
///   @override
///   String get description => 'Does something cool';
///
///   @override
///   String get author => 'Me';
///
///   @override
///   Future<void> onLoad(PluginContext context) async {
///     context.logger.info('Plugin loaded!');
///   }
///
///   @override
///   Future<void> onUnload() async {
///     // Clean up resources
///   }
/// }
///
/// // Register plugin
/// await pluginHost.registerPlugin(MyPlugin());
/// ```
library;

// Core plugin API
export 'src/plugin_api.dart';

// Plugin host and lifecycle management
export 'src/plugin_host.dart';

// Plugin context implementations
export 'src/plugin_context.dart';

// Sequence-node registry + executor (the bridge between SequencePlugin
// authors and the sequence-editor / sequence-executor consumers).
export 'src/plugin_node_registry.dart';
export 'src/plugin_node_executor.dart';

// Example plugins demonstrating the API
export 'src/example_plugin.dart';

// Additional example plugins
export 'examples/weather_logger_plugin.dart';
export 'examples/custom_notification_plugin.dart';
export 'examples/sequence_delay_plugin.dart';

// Example plugins demonstrating real-world sequence-node authoring
// against external services. Each is a self-contained file under examples/.
export 'examples/pushover_notification_plugin.dart';
export 'examples/discord_webhook_plugin.dart';
export 'examples/home_assistant_plugin.dart';
