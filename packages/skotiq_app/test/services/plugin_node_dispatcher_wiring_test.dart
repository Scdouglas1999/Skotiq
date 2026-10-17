// End-to-end test for the plugin-node dispatcher
// wiring shipped in `skotiq_app/lib/services/plugin_node_dispatcher_wiring.dart`.
//
// The wiring layer plugs the Dart-side `PluginNodeExecutor` (defined in
// `skotiq_plugins`) into the `pluginNodeDispatcherProvider` (defined
// in `skotiq_core`). This test confirms a request that flows
// through `pluginNodeDispatcherProvider` actually:
//
//   1. Looks up the plugin in `PluginNodeRegistry`.
//   2. Resolves the plugin's `PluginContext` from `PluginHost`.
//   3. Builds the node via `SequenceNodeDefinition.createNode`.
//   4. Runs `PluginSequenceNode.validate()`.
//   5. Runs `PluginSequenceNode.execute()`.
//   6. Returns the result through the dispatcher abstraction.
//
// This is the canonical "production-finished" surface: a user drops a
// plugin into the package, the app boot wires the override, and a
// sequence containing the plugin's node runs end-to-end.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/plugin_node_dispatcher_wiring.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pluginNodeDispatcherOverride', () {
    test(
        'request resolves through registry → executor → plugin execute → result',
        () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodeDispatcherOverride(),
      ]);
      addTearDown(container.dispose);

      // Register a test plugin through the host the override uses.
      final host = container.read(pluginHostProvider);
      final plugin = _CapturingPlugin();
      await host.registerPlugin(plugin);

      // Read the dispatcher through the same provider the sequence
      // executor uses in production.
      final dispatcher = container.read(pluginNodeDispatcherProvider);

      final result = await dispatcher(
        const PluginNodeDispatchRequest(
          nodeId: 'rt-node-1',
          pluginId: 'com.example.capture',
          nodeTypeId: 'capture.echo',
          configJson: '{"message":"hello"}',
          displayName: 'Capture',
          timeoutSecs: 10,
        ),
      );

      expect(result.success, isTrue,
          reason: 'plugin reported success → verdict success');
      expect(plugin.lastNode, isNotNull,
          reason: 'plugin.createNode must have been invoked');
      expect(plugin.lastNode!.receivedMessage, equals('hello'),
          reason: 'config_json must be parsed and forwarded to createNode');
      expect(plugin.lastNode!.executed, isTrue,
          reason: 'execute() must have been called');
      expect(result.structuredDetailJson, isNotNull,
          reason: 'wiring must attach a structured detail JSON for the '
              'dashboard plugin-node panel');
      expect(result.structuredDetailJson, contains('com.example.capture'));
    });

    test('unknown plugin returns a structured failure (not a throw)', () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodeDispatcherOverride(),
      ]);
      addTearDown(container.dispose);

      final dispatcher = container.read(pluginNodeDispatcherProvider);
      final result = await dispatcher(
        const PluginNodeDispatchRequest(
          nodeId: 'rt-missing',
          pluginId: 'com.example.does-not-exist',
          nodeTypeId: 'nope.nope',
          configJson: '',
          displayName: null,
          timeoutSecs: 10,
        ),
      );

      expect(result.success, isFalse);
      expect(result.message, isNotNull);
      expect(result.message, contains('Unknown plugin node'));
    });

    test('plugin returning false maps to dispatcher success=false', () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodeDispatcherOverride(),
      ]);
      addTearDown(container.dispose);

      final host = container.read(pluginHostProvider);
      final plugin = _AlwaysFailsPlugin();
      await host.registerPlugin(plugin);

      final dispatcher = container.read(pluginNodeDispatcherProvider);
      final result = await dispatcher(
        const PluginNodeDispatchRequest(
          nodeId: 'rt-fail',
          pluginId: 'com.example.fail',
          nodeTypeId: 'fail.always',
          configJson: '',
          displayName: null,
          timeoutSecs: 10,
        ),
      );

      expect(result.success, isFalse);
      expect(result.message, contains('reported failure'));
    });

    test('malformed config fails without executing the plugin', () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodeDispatcherOverride(),
      ]);
      addTearDown(container.dispose);

      final host = container.read(pluginHostProvider);
      final plugin = _CapturingPlugin();
      await host.registerPlugin(plugin);

      final result = await container.read(pluginNodeDispatcherProvider)(
        const PluginNodeDispatchRequest(
          nodeId: 'rt-bad-json',
          pluginId: 'com.example.capture',
          nodeTypeId: 'capture.echo',
          configJson: '{not-json',
          displayName: 'Capture',
          timeoutSecs: 10,
        ),
      );

      expect(result.success, isFalse);
      expect(result.message, contains('Invalid plugin node configuration'));
      expect(plugin.lastNode, isNull,
          reason: 'Malformed input must not be replaced with default params.');
    });

    test('non-object JSON config fails without executing the plugin', () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodeDispatcherOverride(),
      ]);
      addTearDown(container.dispose);

      final host = container.read(pluginHostProvider);
      final plugin = _CapturingPlugin();
      await host.registerPlugin(plugin);

      final result = await container.read(pluginNodeDispatcherProvider)(
        const PluginNodeDispatchRequest(
          nodeId: 'rt-array-json',
          pluginId: 'com.example.capture',
          nodeTypeId: 'capture.echo',
          configJson: '[]',
          displayName: 'Capture',
          timeoutSecs: 10,
        ),
      );

      expect(result.success, isFalse);
      expect(result.message, contains('must be a JSON object'));
      expect(plugin.lastNode, isNull);
    });
  });
}

class _CapturingPlugin extends SequencePlugin {
  _CapturingPluginNode? lastNode;

  @override
  String get id => 'com.example.capture';
  @override
  String get name => 'Capturing Test Plugin';
  @override
  String get version => '0.0.1';
  @override
  String get description => 'Captures params + execute calls for tests';
  @override
  String get author => 'Test Author';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
        SequenceNodeDefinition(
          id: 'capture.echo',
          name: 'Echo',
          category: 'Test',
          description: 'Echoes the message back through the dispatcher',
          createNode: (params) {
            final node = _CapturingPluginNode(
              receivedMessage: params['message'] as String? ?? '',
            );
            lastNode = node;
            return node;
          },
        ),
      ];
}

class _CapturingPluginNode implements PluginSequenceNode {
  _CapturingPluginNode({required this.receivedMessage});

  final String receivedMessage;
  bool executed = false;

  @override
  String? validate() => null;

  @override
  Future<bool> execute(PluginContext context) async {
    executed = true;
    return true;
  }
}

class _AlwaysFailsPlugin extends SequencePlugin {
  @override
  String get id => 'com.example.fail';
  @override
  String get name => 'Always Fails Plugin';
  @override
  String get version => '0.0.1';
  @override
  String get description => 'Returns false from execute() every time';
  @override
  String get author => 'Test Author';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
        SequenceNodeDefinition(
          id: 'fail.always',
          name: 'Always Fails',
          category: 'Test',
          description: 'Returns false from execute()',
          createNode: (_) => _AlwaysFailsNode(),
        ),
      ];
}

class _AlwaysFailsNode implements PluginSequenceNode {
  @override
  String? validate() => null;
  @override
  Future<bool> execute(PluginContext context) async => false;
}
