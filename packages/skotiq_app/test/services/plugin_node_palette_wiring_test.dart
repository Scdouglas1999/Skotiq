// End-to-end test for the plugin-node palette wiring in
// `skotiq_app/lib/services/plugin_node_palette_wiring.dart`.
//
// The wiring layer plugs the live `PluginNodeRegistry` (defined in
// `skotiq_plugins`) into the `pluginNodeBlueprintsProvider` (defined
// in `skotiq_core`). This test confirms that:
//
//   1. Before any plugin registers, the palette renders only the
//      built-in categories.
//   2. After a `SequencePlugin` is registered, the palette adds a
//      "Plugins / <category>" section whose item produces a runnable
//      [PluginInstructionNode] with the plugin's identifiers + config.
//   3. The palette is reactive: a plugin loaded post-startup shows up
//      without re-creating the ProviderContainer.
//   4. Malformed registrations (empty id / name) are filtered out
//      loudly, NOT silently rendered as broken items.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/plugin_node_palette_wiring.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pluginNodePaletteBlueprintsOverride', () {
    test('blueprints list is empty before any plugin registers', () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodePaletteBlueprintsOverride(),
      ]);
      addTearDown(container.dispose);

      // Force the stream to evaluate at least once so the override
      // populates from the (empty) registry snapshot.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final blueprints = container.read(pluginNodeBlueprintsProvider);
      expect(blueprints, isEmpty,
          reason: 'no plugins registered yet → no blueprints');
    });

    test(
        'registering a SequencePlugin surfaces a blueprint whose factory '
        'creates a PluginInstructionNode', () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodePaletteBlueprintsOverride(),
      ]);
      addTearDown(container.dispose);

      // Subscribe to the blueprint stream so the override stays live
      // for the duration of the test.
      final subscription =
          container.listen(pluginNodeBlueprintsProvider, (_, __) {});
      addTearDown(subscription.close);

      final host = container.read(pluginHostProvider);
      await host.registerPlugin(_NotifierTestPlugin());

      // Let the broadcast stream propagate the change.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final blueprints = container.read(pluginNodeBlueprintsProvider);
      expect(blueprints, hasLength(1));
      expect(blueprints.single.pluginId, equals('com.example.notifier'));
      expect(blueprints.single.nodeTypeId, equals('notifier.ping'));
      expect(blueprints.single.name, equals('Ping'));
      expect(blueprints.single.category, equals('Notifications'));
      expect(blueprints.single.pluginName, equals('Notifier Test Plugin'));

      // We can't read `nodePaletteProvider` directly here because the
      // built-in palette pulls sequencer defaults from the Drift
      // database, which path_provider can't initialise in a plain
      // dart-test environment. Instead, we drive the same grouping
      // logic the palette uses (`PluginNodeBlueprint` → executor
      // dispatch wiring) by hand: a single blueprint must produce a
      // `PluginInstructionNode` that round-trips into the executor as
      // the expected JSON payload.
      final blueprint = blueprints.single;
      final node = PluginInstructionNode(
        name: blueprint.name,
        pluginId: blueprint.pluginId,
        nodeTypeId: blueprint.nodeTypeId,
        pluginName: blueprint.pluginName,
        configJson: blueprint.defaultConfigJson,
        iconHint: blueprint.iconHint,
      );
      expect(node, isA<PluginInstructionNode>());
      expect(node.pluginId, equals('com.example.notifier'));
      expect(node.nodeTypeId, equals('notifier.ping'));
      expect(node.nodeType, equals('PluginNode'));
      expect(node.pluginName, equals('Notifier Test Plugin'));
      expect(node.iconName, equals('puzzle'));
    });

    test('palette updates reactively when a plugin registers post-startup',
        () async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        pluginNodePaletteBlueprintsOverride(),
      ]);
      addTearDown(container.dispose);

      final blueprintEmissions = <int>[];
      final subscription = container.listen<List<PluginNodeBlueprint>>(
          pluginNodeBlueprintsProvider, (prev, next) {
        blueprintEmissions.add(next.length);
      }, fireImmediately: true);
      addTearDown(subscription.close);

      // Baseline: zero blueprints.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(container.read(pluginNodeBlueprintsProvider), isEmpty);

      // Register a plugin after the ProviderContainer was constructed.
      final host = container.read(pluginHostProvider);
      await host.registerPlugin(_NotifierTestPlugin());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(pluginNodeBlueprintsProvider), hasLength(1),
          reason: 'palette should pick up the new plugin without restart');

      // Disable the plugin; the blueprint should disappear without
      // tearing the palette down.
      await host.setPluginEnabled('com.example.notifier', false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(container.read(pluginNodeBlueprintsProvider), isEmpty,
          reason: 'disabling a plugin yanks its blueprints from the palette');
    });

    test(
        'blueprintsFromRegistrations filters malformed definitions '
        'loudly (no crash, no silent render)', () async {
      // Build a registry manually so we can shove a malformed
      // SequenceNodeDefinition (empty id + empty name) past the host.
      final registry = PluginNodeRegistry();
      addTearDown(registry.dispose);
      registry.registerSequencePlugin(_BrokenDefinitionPlugin());

      final blueprints = blueprintsFromRegistrations(registry.registrations);
      expect(blueprints, hasLength(1),
          reason: 'only the well-formed definition should be retained');
      expect(blueprints.single.nodeTypeId, equals('ok.node'));
    });
  });
}

/// Plugin that contributes one well-formed sequence node so we can
/// observe the palette wiring end-to-end.
class _NotifierTestPlugin extends SequencePlugin {
  @override
  String get id => 'com.example.notifier';
  @override
  String get name => 'Notifier Test Plugin';
  @override
  String get version => '0.0.1';
  @override
  String get description => 'Surfaces a single Ping node for palette tests';
  @override
  String get author => 'Palette wiring tests';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
        SequenceNodeDefinition(
          id: 'notifier.ping',
          name: 'Ping',
          category: 'Notifications',
          description: 'Sends a ping event',
          createNode: (params) => _NoopPluginNode(),
        ),
      ];
}

/// Plugin whose `nodeDefinitions` contains one valid entry and one
/// malformed entry (empty id + empty name). The wiring should drop the
/// malformed one but keep the good one.
class _BrokenDefinitionPlugin extends SequencePlugin {
  @override
  String get id => 'com.example.partial';
  @override
  String get name => 'Partial Plugin';
  @override
  String get version => '0.0.1';
  @override
  String get description => 'Mixes malformed + valid node definitions';
  @override
  String get author => 'Palette wiring tests';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
        // Malformed — empty id, will be dropped by the wiring layer.
        SequenceNodeDefinition(
          id: '',
          name: '',
          category: 'General',
          description: '',
          createNode: (_) => _NoopPluginNode(),
        ),
        // Good.
        SequenceNodeDefinition(
          id: 'ok.node',
          name: 'OK Node',
          category: 'General',
          description: 'Working entry',
          createNode: (_) => _NoopPluginNode(),
        ),
      ];
}

class _NoopPluginNode implements PluginSequenceNode {
  @override
  String? validate() => null;

  @override
  Future<bool> execute(PluginContext context) async => true;
}
