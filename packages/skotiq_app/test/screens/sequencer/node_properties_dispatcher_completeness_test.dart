// Dispatcher completeness.
//
// Asserts that EVERY palette-reachable sequence-node type renders a real
// property editor when selected in the NodePropertiesPanel — i.e. none of
// them fall through to the "No property editor for <Type>" fallback card
// (_UnknownNodeProperties). That fallback is the symptom of a node the engine
// reads but the UI cannot edit, so this test keeps a newly-added NodeType from
// shipping without an editor.
//
// The set of node types is sourced from the live `nodePaletteProvider` (the
// single source of truth for what the user can drop into a sequence), plus
// PluginInstructionNode which is only palette-reachable when a plugin is
// loaded but must still have an editor.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'every palette-reachable node type renders a real property editor',
      (tester) async {
    // Pump the panel once; we reload the sequence + reselect per node type so
    // we exercise the real dispatcher path for each.
    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 880,
        height: 2400,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(1000, 1400),
    );

    // Source the palette node factories. Each NodePaletteItem.createNode()
    // returns a fresh, runnable node of that type.
    final palette = handle.container.read(nodePaletteProvider);
    final nodes = <SequenceNode>[
      for (final category in palette)
        for (final item in category.items) item.createNode(),
      // Plugin nodes are only palette-reachable with a plugin loaded, but the
      // dispatcher must still cover them.
      PluginInstructionNode(
        name: 'Example Plugin Node',
        pluginId: 'com.example.test',
        nodeTypeId: 'example.node',
        pluginName: 'Example',
      ),
    ];

    // Sanity: the palette must actually produce nodes, otherwise the loop
    // below would vacuously pass.
    expect(nodes, isNotEmpty);

    final seenTypes = <String>{};
    for (final node in nodes) {
      // De-dup by runtimeType so we don't re-pump identical editors, but keep
      // the type name for the failure message.
      if (!seenTypes.add(node.runtimeType.toString())) continue;

      final sequence = Sequence.create(
        name: 'Dispatcher test',
        rootNodeId: node.id,
        nodes: {node.id: node},
      );
      handle.container
          .read(currentSequenceProvider.notifier)
          .loadSequence(sequence, discardUnsaved: true);
      handle.container.read(selectedNodeIdProvider.notifier).state = node.id;
      await tester.pumpAndSettle();

      // The fallback card renders the literal string
      // "No property editor for <Type>" — its presence means this node type
      // is NOT wired into the dispatcher.
      expect(
        find.textContaining('No property editor'),
        findsNothing,
        reason: '${node.runtimeType} (${node.nodeType}) fell through to the '
            '"No property editor" fallback — it must have a real editor in '
            'the NodePropertiesPanel dispatcher.',
      );
    }
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
