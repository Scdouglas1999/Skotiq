// Multi-select must count what it highlights.
//
// A tree row paints as selected when it is EITHER the primary selection or in
// the multi-select set (node_tree_view.dart: `isSelected || isMultiSelected`),
// but the batch bar counts only the multi-select set. Clicking one row and
// then Ctrl+clicking two more therefore drew three identical cyan borders
// while the bar said "2 selected" — and Delete, Enable, Disable and Copy all
// silently skipped the first row.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/batch_operations_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// Root with three sibling delay nodes named A / B / C.
Sequence _threeSiblings() {
  final a = DelayNode(name: 'A', seconds: 1);
  final b = DelayNode(name: 'B', seconds: 2);
  final c = DelayNode(name: 'C', seconds: 3);
  final root = InstructionSetNode(name: 'Root');
  return Sequence.create(
    name: 'T',
    rootNodeId: root.id,
    nodes: {
      a.id: a.copyWith(parentId: root.id, orderIndex: 0),
      b.id: b.copyWith(parentId: root.id, orderIndex: 1),
      c.id: c.copyWith(parentId: root.id, orderIndex: 2),
      root.id: root.copyWith(childIds: [a.id, b.id, c.id]),
    },
  );
}

Future<HarnessHandle> _pumpTree(WidgetTester tester, Sequence sequence) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;

  return pumpAppScreen(
    tester,
    Builder(
      builder: (context) => Column(
        children: [
          BatchOperationsToolbar(colors: SkotiqColors.of(context)),
          Expanded(
            child: SequenceTree(colors: SkotiqColors.of(context)),
          ),
        ],
      ),
    ),
    size: const Size(1200, 900),
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The ledger ETA clock is a real periodic stream; in the fake-async
      // zone its timer outlives every pump and fails teardown.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the first Ctrl+click folds the already-selected row into the set, so the '
    'count matches the highlight',
    (tester) async {
      final sequence = _threeSiblings();
      final handle = await _pumpTree(tester, sequence);

      // Plain click selects A as the primary selection (already painted
      // selected).
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(handle.container.read(selectedNodeIdProvider), isNotNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.text('C'));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      final selected = handle.container.read(multiSelectedNodeIdsProvider);
      expect(
        selected.length,
        3,
        reason: 'three rows are highlighted, so three must be selected',
      );
      expect(
        selected.contains(handle.container.read(selectedNodeIdProvider)),
        isTrue,
        reason: 'the primary row must be part of every batch operation',
      );
      expect(find.text('3 selected'), findsOneWidget);
    },
  );

  testWidgets(
    'Ctrl+clicking with no prior selection still starts at one',
    (tester) async {
      final handle = await _pumpTree(tester, _threeSiblings());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(handle.container.read(multiSelectedNodeIdsProvider).length, 1);
      expect(find.text('1 selected'), findsOneWidget);
    },
  );
}
