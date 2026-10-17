// Collapse-all was reported to paint a solid grey block over the rest of the
// tree. These tests pin what the widget layer must do: after Collapse all,
// every container header and every top-level sibling is still rendered, still
// hit-testable (nothing is covering them), and the hidden children are gone —
// and Expand all puts them back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

/// Root
///   TargetHeader "M42"
///     InstructionSet "Photometry"
///       Delay "Inner one"
///       Delay "Inner two"
///   Delay "Tail"
Sequence _nestedSequence() {
  final inner1 = DelayNode(name: 'Inner one', seconds: 1);
  final inner2 = DelayNode(name: 'Inner two', seconds: 2);
  final set = InstructionSetNode(name: 'Photometry');
  final target = TargetHeaderNode(
    targetName: 'M42',
    raHours: 5.59,
    decDegrees: -5.39,
  );
  final tail = DelayNode(name: 'Tail', seconds: 3);
  final root = InstructionSetNode(name: 'Root');

  return Sequence.create(
    name: 'T',
    rootNodeId: root.id,
    nodes: {
      inner1.id: inner1.copyWith(parentId: set.id, orderIndex: 0),
      inner2.id: inner2.copyWith(parentId: set.id, orderIndex: 1),
      set.id: set.copyWith(
        parentId: target.id,
        childIds: [inner1.id, inner2.id],
      ),
      target.id: target.copyWith(parentId: root.id, childIds: [set.id]),
      tail.id: tail.copyWith(parentId: root.id, orderIndex: 1),
      root.id: root.copyWith(childIds: [target.id, tail.id]),
    },
  );
}

Future<HarnessHandle> _pumpTree(WidgetTester tester) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _nestedSequence();

  return pumpAppScreen(
    tester,
    // Collapse-all moved from the tree's own header row into the canvas
    // bar's menu in wave 3 (06 §Sequencer), so the pair is pumped
    // together — which is also how the builder lays them out.
    Builder(
      builder: (context) => Column(
        children: [
          SequenceToolbar(colors: SkotiqColors.of(context)),
          Expanded(
            child: SequenceTree(colors: SkotiqColors.of(context)),
          ),
        ],
      ),
    ),
    size: const Size(1000, 900),
    // The target card animates continuously (altitude chart / status pulse),
    // so pumpAndSettle would never return.
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // Collapsed ledger rows print a rollup summary naming their children,
      // which collides with this test's "children are gone" assertion — the
      // comfortable card has no such line, so pin it.
      sequencerDensityProvider
          .overrideWith((ref) => SequencerDensity.comfortable),
    ],
  );
}

Future<HarnessHandle> _pumpAndDrain(WidgetTester tester) async {
  final handle = await _pumpTree(tester);
  await tester.pump(const Duration(milliseconds: 600));
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Collapse all hides children but keeps every header rendered and usable',
    (tester) async {
      final handle = await _pumpAndDrain(tester);

      expect(find.text('Inner one'), findsOneWidget);
      expect(find.text('Tail'), findsOneWidget);

      await tapCanvasBarAction(tester, 'Collapse all steps');

      expect(tester.takeException(), isNull);

      // Every container's children are hidden — including the target's, so
      // the nested set disappears with them.
      expect(find.text('Inner one'), findsNothing);
      expect(find.text('Inner two'), findsNothing);
      expect(find.text('Photometry'), findsNothing);
      // …but the top-level rows are still rendered, not replaced by a grey
      // ErrorWidget block.
      expect(find.text('M42'), findsWidgets);
      expect(find.text('Tail'), findsOneWidget);

      // Hit-testable: anything painted over the tree would take this tap
      // instead of the row.
      await tester.tap(find.text('Tail'));
      await tester.pump();
      final tailId = handle.container
          .read(currentSequenceProvider)!
          .nodes
          .values
          .firstWhere((n) => n.name == 'Tail')
          .id;
      expect(handle.container.read(selectedNodeIdProvider), tailId);
      await tester.pump(const Duration(milliseconds: 800));
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('Expand all restores the hidden rows', (tester) async {
    await _pumpAndDrain(tester);

    await tapCanvasBarAction(tester, 'Collapse all steps');
    expect(find.text('Inner one'), findsNothing);

    await tapCanvasBarAction(tester, 'Expand all steps');

    expect(find.text('Inner one'), findsOneWidget);
    expect(find.text('Inner two'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 800));
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
