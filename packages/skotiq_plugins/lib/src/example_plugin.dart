import 'dart:async';

import 'plugin_api.dart';

/// Example plugin demonstrating the Skotiq plugin API
///
/// This plugin shows how to:
/// - Implement the SkotiqPlugin interface
/// - Use the PluginContext for logging, storage, and events
/// - Handle lifecycle callbacks
/// - Store and retrieve persistent data
/// - Emit and subscribe to events
class ExamplePlugin extends SkotiqPlugin {
  PluginContext? _context;
  StreamSubscription? _eventSubscription;
  int _counter = 0;

  @override
  String get id => 'com.skotiq.example';

  @override
  String get name => 'Example Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Demonstrates the plugin API with logging, storage, and events';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.0.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info('Example plugin loading...');

    // Load persistent counter value
    final savedCounter = await context.storage.getInt('counter');
    if (savedCounter != null) {
      _counter = savedCounter;
      context.logger.info('Restored counter value: $_counter');
    }

    // Subscribe to events
    _eventSubscription = context.eventBus.on('app.ready').listen((data) {
      context.logger.info('Received app.ready event: $data');
    });

    context.logger.info('Example plugin loaded successfully');
  }

  @override
  Future<void> onEnable() async {
    _context?.logger.info('Example plugin enabled');

    // Emit an event when enabled
    _context?.eventBus.emit('plugin.example.enabled', {
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<void> onDisable() async {
    _context?.logger.info('Example plugin disabled');

    // Save state before disabling
    await _context?.storage.setInt('counter', _counter);

    // Emit an event when disabled
    _context?.eventBus.emit('plugin.example.disabled', {
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Example plugin unloading...');

    // Cancel event subscription
    await _eventSubscription?.cancel();
    _eventSubscription = null;

    // Save final state
    await _context?.storage.setInt('counter', _counter);

    _context?.logger.info('Example plugin unloaded');
    _context = null;
  }

  /// Increment the internal counter and save to storage
  Future<void> incrementCounter() async {
    _counter++;
    _context?.logger.debug('Counter incremented to $_counter');

    await _context?.storage.setInt('counter', _counter);

    // Emit event about counter change
    _context?.eventBus.emit('plugin.example.counter', {'value': _counter});
  }

  /// Get the current counter value
  int get counter => _counter;

  /// Reset the counter
  Future<void> resetCounter() async {
    _counter = 0;
    _context?.logger.info('Counter reset to 0');

    await _context?.storage.setInt('counter', 0);

    _context?.eventBus.emit('plugin.example.counter', {'value': 0});
  }
}

/// Example sequence plugin showing how to add custom sequence nodes
///
/// This demonstrates the SequencePlugin interface for extending the sequencer.
class ExampleSequencePlugin extends SequencePlugin {
  PluginContext? _context;

  @override
  String get id => 'com.skotiq.example.sequence';

  @override
  String get name => 'Example Sequence Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Adds custom sequence nodes for automation';

  @override
  String get author => 'Skotiq Team';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info('Example sequence plugin loaded');
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Example sequence plugin unloaded');
    _context = null;
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'example.wait',
      name: 'Custom Wait',
      category: 'Example',
      description: 'Wait for a custom duration',
      createNode: (params) {
        final durationMs = params['durationMs'] as int? ?? 5000;
        return _ExampleWaitNode(durationMs: durationMs);
      },
    ),
    SequenceNodeDefinition(
      id: 'example.notify',
      name: 'Send Notification',
      category: 'Example',
      description: 'Send a custom notification',
      createNode: (params) {
        final message = params['message'] as String? ?? 'Notification';
        return _ExampleNotifyNode(message: message);
      },
    ),
  ];
}

/// Example wait node that pauses execution for a specified duration
class _ExampleWaitNode implements PluginSequenceNode {
  final int durationMs;

  _ExampleWaitNode({required this.durationMs});

  @override
  Future<bool> execute(PluginContext context) async {
    context.logger.info('Waiting for ${durationMs}ms...');
    await Future<void>.delayed(Duration(milliseconds: durationMs));
    context.logger.info('Wait complete');
    return true;
  }

  @override
  String? validate() {
    if (durationMs <= 0) {
      return 'Duration must be positive';
    }
    return null;
  }
}

/// Example notify node that emits a notification event
class _ExampleNotifyNode implements PluginSequenceNode {
  final String message;

  _ExampleNotifyNode({required this.message});

  @override
  Future<bool> execute(PluginContext context) async {
    context.logger.info('Sending notification: $message');
    context.eventBus.emit('plugin.notification', {
      'message': message,
      'timestamp': DateTime.now().toIso8601String(),
    });
    return true;
  }

  @override
  String? validate() {
    if (message.isEmpty) {
      return 'Message must not be empty';
    }
    return null;
  }
}
