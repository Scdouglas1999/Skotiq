// A phone on its side keeps three or four plan rows in view. The add button
// floated over their right end, where the Count and ETA columns are.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/pump_app_screen.dart';

Sequence _plan() {
  final root = InstructionSetNode(name: 'Root');
  final steps = [
    for (final (i, name)
        in ['Lum', 'Red', 'Green', 'Blue', 'Ha', 'OIII', 'SII'].indexed)
      ExposureNode(name: name, durationSecs: 60.0 + 30 * i, count: 10 + i),
  ];
  return Sequence.create(
    name: 'NGC1313 Plan',
    nodes: {
      for (final s in steps) s.id: s.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [for (final s in steps) s.id]),
    },
    rootNodeId: root.id,
  );
}

void main() {
  testWidgets('on its side the add control covers no plan row', (tester) async {
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _plan();
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(844, 390),
      settle: false,
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        ledgerClockProvider.overrideWith(
          (ref) => const Stream<DateTime>.empty(),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 600));

    final add = find.byTooltip('Add a step');
    expect(add, findsOneWidget);
    final addRect = tester.getRect(add);
    final tree = find.byType(SequenceTree);
    final view = tester.getRect(tree);
    final own = find
        .descendant(of: add, matching: find.byType(Text))
        .evaluate()
        .toSet();
    for (final element
        in find.descendant(of: tree, matching: find.byType(Text)).evaluate()) {
      if (own.contains(element)) continue;
      final rect = tester.getRect(find.byWidget(element.widget));
      if (!view.overlaps(rect)) continue;
      expect(
        rect.overlaps(addRect),
        isFalse,
        reason: '"${(element.widget as Text).data}" at $rect lies under the '
            'add control at $addRect',
      );
    }

    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(NodePalette), findsOneWidget);
  });
}
