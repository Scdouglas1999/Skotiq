import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

class _ThrowingNode implements PluginSequenceNode {
  _ThrowingNode({this.throwOnValidate = false});
  final bool throwOnValidate;

  @override
  String? validate() {
    if (throwOnValidate) throw StateError('boom in validate');
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async => true;
}

class _FaultySequencePlugin extends SequencePlugin {
  _FaultySequencePlugin({
    required this.id,
    this.throwOnCreate = false,
    this.throwOnValidate = false,
    this.throwOnDisable = false,
  });

  @override
  final String id;
  final bool throwOnCreate;
  final bool throwOnValidate;
  final bool throwOnDisable;
  bool unloaded = false;

  @override
  String get name => 'Faulty $id';
  @override
  String get version => '1.0.0';
  @override
  String get author => 'Test';
  @override
  String get description => 'Test plugin';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {
    if (throwOnDisable) throw StateError('disable failed');
  }

  @override
  Future<void> onUnload() async {
    unloaded = true;
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'bad_node',
      name: 'Bad Node',
      description: 'Throws during create/validate',
      category: 'test',
      createNode: (_) {
        if (throwOnCreate) throw StateError('boom in createNode');
        return _ThrowingNode(throwOnValidate: throwOnValidate);
      },
    ),
  ];
}

void main() {
  group('Batch 4 plugin lifecycle and sandbox regressions', () {
    test(
      'PluginNodeExecutor catches exceptions from createNode and validate',
      () async {
        final host = PluginHost();
        await host.registerPlugin(
          _FaultySequencePlugin(id: 'p_create', throwOnCreate: true),
        );
        await host.registerPlugin(
          _FaultySequencePlugin(id: 'p_validate', throwOnValidate: true),
        );
        final executor = PluginNodeExecutor(
          host: host,
          registry: host.nodeRegistry,
        );

        final r1 = await executor.run(
          pluginId: 'p_create',
          nodeTypeId: 'bad_node',
          params: const {},
        );
        expect(r1.success, isFalse);
        expect(r1.message, contains('boom in createNode'));

        final r2 = await executor.run(
          pluginId: 'p_validate',
          nodeTypeId: 'bad_node',
          params: const {},
        );
        expect(r2.success, isFalse);
        expect(r2.message, contains('boom in validate'));
      },
    );

    test(
      'SandboxedPluginEventBus releases subscription quota on cancel',
      () async {
        final inner = StreamPluginEventBus();
        addTearDown(inner.dispose);
        final bus = SandboxedPluginEventBus(
          'p1',
          inner,
          policy: const PluginSandboxPolicy(maxNamedSubscriptions: 2),
        );

        for (var i = 0; i < 5; i++) {
          final sub = bus.on('evt').listen((_) {});
          await sub.cancel();
        }
      },
    );

    test(
      'unregisterPlugin still calls onUnload when onDisable throws, and failed disable keeps nodes registered',
      () async {
        final host = PluginHost();
        final plugin = _FaultySequencePlugin(
          id: 'p_disable',
          throwOnDisable: true,
        );
        await host.registerPlugin(plugin);

        await expectLater(
          host.setPluginEnabled('p_disable', false),
          throwsA(isA<PluginException>()),
        );
        // Because disable failed, the plugin stays enabled and its nodes stay registered.
        expect(host.isEnabled('p_disable'), isTrue);
        expect(
          host.nodeRegistry.findDefinition('p_disable', 'bad_node'),
          isNotNull,
        );

        await host.unregisterPlugin('p_disable');
        expect(plugin.unloaded, isTrue);
        expect(host.getPlugin('p_disable'), isNull);
      },
    );
  });
}
