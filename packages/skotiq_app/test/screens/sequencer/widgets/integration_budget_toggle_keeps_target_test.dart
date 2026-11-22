// Turning a target's integration budget off must clear only the budget. The
// editor rebuilt the node by hand and left out the catalog link, so the run
// stopped recording that target's frames against its catalog row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_property_widgets.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('switching the budget off keeps every other target field',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 340,
        height: 2400,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(420, 2500),
    );
    final lights = ExposureNode(name: 'Lights', durationSecs: 60, count: 5);
    final header = TargetHeaderNode(
      targetName: 'M42',
      raHours: 5.5,
      decDegrees: -5.4,
      priority: 3,
      catalogTargetId: 4242,
      integrationBudget: const IntegrationBudget(totalSecs: 7200),
      childIds: [lights.id],
    );
    final sequence = Sequence.create(
      name: 'Budget test',
      rootNodeId: header.id,
      nodes: {
        header.id: header,
        lights.id: lights.copyWith(parentId: header.id)
      },
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = header.id;
    await tester.pump();

    final toggle = find.descendant(
      of: find
          .ancestor(
            of: find.text('Integration budget'),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(NodeToggleSwitch),
    );
    expect(toggle, findsOneWidget);
    tester.widget<NodeToggleSwitch>(toggle).onChanged(false);
    await tester.pump();

    final edited = handle.container
        .read(currentSequenceProvider)!
        .nodes[header.id] as TargetHeaderNode;
    expect(edited.integrationBudget, isNull);
    expect(edited.catalogTargetId, 4242);
    expect(edited.priority, 3);
    await tester.pump(const Duration(seconds: 1));
  });
}
