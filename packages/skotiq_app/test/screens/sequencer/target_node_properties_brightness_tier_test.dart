import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_node_properties.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

ProviderContainer _seed(Sequence seq) {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = seq;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((_) => notifier),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  TargetHeaderNode target,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: TargetGroupProperties(
              colors: SkotiqColors.dark,
              node: target,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Target properties edits adaptive brightness tier hint',
      (tester) async {
    final target = TargetHeaderNode(
      id: 'target-m31',
      name: 'M31',
      targetName: 'M31',
      raHours: 0.71,
      decDegrees: 41.27,
    );
    final root = InstructionSetNode(id: 'root', childIds: [target.id]);
    final sequence = Sequence.create(
      name: 'Brightness Tier Test',
      rootNodeId: root.id,
      nodes: {
        root.id: root,
        target.id: target.copyWith(parentId: root.id),
      },
    );
    final container = _seed(sequence);

    await _pump(tester, container, target);

    expect(find.text('Adaptive Brightness Tier'), findsOneWidget);
    expect(find.text('Auto (infer from target)'), findsOneWidget);

    await tester.tap(find.text('Auto (infer from target)'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.text('Bright (planetary nebulae, open clusters)').last);
    await tester.pumpAndSettle();

    final updated = container.read(currentSequenceProvider)!.nodes[target.id]
        as TargetHeaderNode;
    expect(updated.brightnessTierHint, BrightnessTier.bright);
  });
}
