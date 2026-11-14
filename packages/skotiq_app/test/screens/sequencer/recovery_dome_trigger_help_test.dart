// The Recovery editor says when Dome Shutter Not Open watches the shutter:
// only between the plan's Open Dome and its Close Dome or Park Dome.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRecovery(WidgetTester tester, TriggerType trigger) async {
    final node = RecoveryNode().withTriggerType(trigger);
    final sequence = Sequence.create(
      name: 'Recovery test',
      rootNodeId: node.id,
      nodes: {node.id: node},
    );
    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 420,
        height: 1200,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(900, 1200),
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = node.id;
    await tester.pumpAndSettle();
  }

  testWidgets('the dome trigger explains when it watches the shutter', (
    tester,
  ) async {
    await pumpRecovery(tester, TriggerType.domeShutterNotOpen);

    expect(find.text('Dome Shutter Not Open'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == domeShutterTriggerHelp,
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('other triggers carry no dome help', (tester) async {
    await pumpRecovery(tester, TriggerType.weatherUnsafe);

    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == domeShutterTriggerHelp,
      ),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
