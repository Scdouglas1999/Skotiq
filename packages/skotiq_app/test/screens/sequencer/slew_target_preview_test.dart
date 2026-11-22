// The Slew/Center editor names the target the run will point at. The run
// takes the target the step sits under, at any depth, and has none for a step
// outside every target; the preview used to name the step's direct parent,
// else the sequence's first target.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final first = TargetHeaderNode(
    id: 'first',
    targetName: 'M31',
    raHours: 0.71,
    decDegrees: 41.27,
    parentId: 'root',
  );
  final second = TargetHeaderNode(
    id: 'second',
    targetName: 'M42',
    raHours: 5.59,
    decDegrees: -5.39,
    parentId: 'root',
    childIds: const ['loop'],
  );
  final loop = LoopNode(
    id: 'loop',
    parentId: 'second',
    childIds: const ['nested-slew'],
  );
  final nestedSlew = SlewNode(id: 'nested-slew', parentId: 'loop');
  final looseSlew = SlewNode(id: 'loose-slew', parentId: 'root');
  final root = InstructionSetNode(
    id: 'root',
    childIds: const ['first', 'second', 'loose-slew'],
  );
  final sequence = Sequence.create(
    name: 'Preview',
    rootNodeId: 'root',
    nodes: {
      for (final n in [root, first, second, loop, nestedSlew, looseSlew])
        n.id: n,
    },
  );

  Future<void> select(WidgetTester tester, String nodeId) async {
    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 880,
        height: 1400,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(1000, 1400),
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = nodeId;
    await tester.pumpAndSettle();
  }

  testWidgets('a slew inside a loop names the target around the loop',
      (tester) async {
    await select(tester, nestedSlew.id);
    expect(find.textContaining('Will use target: M42'), findsOneWidget);
    expect(find.textContaining('M31'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a slew outside every target names none', (tester) async {
    await select(tester, looseSlew.id);
    expect(find.textContaining('Will use target'), findsNothing);
    expect(find.textContaining('not inside a target'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
