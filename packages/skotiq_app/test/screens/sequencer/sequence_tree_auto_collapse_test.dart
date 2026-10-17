// Auto-collapse wiring (spec §4): the tree listening to the run and applying
// the planner's answer to `collapsedNodeIdsProvider`.
//
// `auto_collapse_plan_test.dart` covers what the plan SAYS. This covers the
// three things only the widget can get wrong: which signals it listens to,
// whether it can tell its own expansions from the operator's, and whether the
// Follow execution toggle really stops it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_shortcuts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// root -> A -> [A loop -> a1, A loop 2 -> a2] ; root -> B -> B loop -> b1
///
/// Two loops under A on purpose: a target whose only loop has finished is
/// itself finished, so a one-loop target can never be the thing spec §4's
/// "opened by hand and has NOT run yet" clause protects. With a second loop
/// still to go, A is an unfinished container holding a finished one — which is
/// exactly the shape where the operator's hold on A has to keep the finished
/// loop on screen.
({
  Sequence sequence,
  String targetA,
  String loopA,
  String a1,
  String loopA2,
  String a2,
  String targetB,
  String b1,
}) _twoTargets() {
  final a1 = ExposureNode(name: 'A sub', durationSecs: 60, count: 1);
  final a2 = ExposureNode(name: 'A sub 2', durationSecs: 90, count: 1);
  final b1 = ExposureNode(name: 'B sub', durationSecs: 60, count: 1);
  final loopA = LoopNode(
    name: 'A loop',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final loopA2 = LoopNode(
    name: 'A loop 2',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final loopB = LoopNode(
    name: 'B loop',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final targetA = TargetHeaderNode(
    name: 'A',
    targetName: 'A',
    raHours: 5.5,
    decDegrees: -5.4,
  );
  final targetB = TargetHeaderNode(
    name: 'B',
    targetName: 'B',
    raHours: 20.1,
    decDegrees: 38.0,
  );
  final root = InstructionSetNode(name: 'Root');

  return (
    sequence: Sequence.create(
      name: 'Night',
      rootNodeId: root.id,
      nodes: {
        a1.id: a1.copyWith(parentId: loopA.id),
        a2.id: a2.copyWith(parentId: loopA2.id),
        b1.id: b1.copyWith(parentId: loopB.id),
        loopA.id: loopA.copyWith(parentId: targetA.id, childIds: [a1.id]),
        loopA2.id: loopA2.copyWith(
          parentId: targetA.id,
          orderIndex: 1,
          childIds: [a2.id],
        ),
        loopB.id: loopB.copyWith(parentId: targetB.id, childIds: [b1.id]),
        targetA.id: targetA.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [loopA.id, loopA2.id],
        ),
        targetB.id: targetB.copyWith(
          parentId: root.id,
          orderIndex: 1,
          childIds: [loopB.id],
        ),
        root.id: root.copyWith(childIds: [targetA.id, targetB.id]),
      },
    ),
    targetA: targetA.id,
    loopA: loopA.id,
    a1: a1.id,
    loopA2: loopA2.id,
    a2: a2.id,
    targetB: targetB.id,
    b1: b1.id,
  );
}

Future<HarnessHandle> _pumpTree(
  WidgetTester tester,
  Sequence sequence,
  SequenceProgressNotifier progress,
) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;

  final handle = await pumpAppScreen(
    tester,
    Builder(
      builder: (context) => SequenceTree(colors: SkotiqColors.of(context)),
    ),
    size: const Size(1200, 900),
    // Live validation debounces 500 ms; drain frames by hand instead.
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceProgressProvider.overrideWith((_) => progress),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The minute clock is a real periodic stream whose timer outlives every
      // pump in the fake-async zone.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
  );
  await tester.pump(const Duration(seconds: 1));
  return handle;
}

/// Mark A's whole branch finished, exactly as the run's NodeCompleted events
/// would.
void _finishTargetA(
  SequenceProgressNotifier progress,
  ({
    Sequence sequence,
    String targetA,
    String loopA,
    String a1,
    String loopA2,
    String a2,
    String targetB,
    String b1,
  }) t,
) {
  progress.updateNodeStatus(t.a1, NodeStatus.success);
  progress.updateNodeStatus(t.loopA, NodeStatus.success);
  progress.updateNodeStatus(t.a2, NodeStatus.success);
  progress.updateNodeStatus(t.loopA2, NodeStatus.success);
  progress.updateNodeStatus(t.targetA, NodeStatus.success);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the run leaving a finished target folds it away',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);

    progress.updateProgress(currentNodeId: t.a1);
    await tester.pump();
    expect(
      handle.container.read(collapsedNodeIdsProvider),
      isEmpty,
      reason: 'the branch the run is IN never folds',
    );

    _finishTargetA(progress, t);
    progress.updateProgress(currentNodeId: t.b1);
    // Settled, not pumped: a folding container's children now clip away over
    // `durationSmooth` (spec §9) instead of vanishing on the frame.
    await tester.pumpAndSettle();

    expect(handle.container.read(collapsedNodeIdsProvider), {t.targetA});
    expect(find.text('A sub'), findsNothing);
  });

  testWidgets('the executing branch is re-opened as the run enters it',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);

    handle.container
        .read(collapsedNodeIdsProvider.notifier)
        .collapseAll([t.targetA, t.loopA]);
    await tester.pumpAndSettle();
    expect(find.text('A sub'), findsNothing);

    progress.updateProgress(currentNodeId: t.a1);
    await tester.pumpAndSettle();

    expect(handle.container.read(collapsedNodeIdsProvider), isEmpty);
    expect(find.text('A sub'), findsOneWidget);
  });

  testWidgets('a container the operator re-opened mid-run is left alone',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);
    final collapsed = handle.container.read(collapsedNodeIdsProvider.notifier);

    progress.updateProgress(currentNodeId: t.a1);
    await tester.pump();

    // The chevron path, verbatim: close A, then open it again to watch it
    // work. A still has a loop to go, so this is the expansion spec §4
    // protects — "opened by hand and has not run yet".
    collapsed.toggle(t.targetA);
    collapsed.toggle(t.targetA);
    await tester.pump();

    // A's first loop finishes and the scheduler moves the run to B, leaving A's
    // second loop unrun — so A itself is not finished. The loop that IS
    // finished is a fold candidate, and the operator's hold on the target
    // above it is the only thing keeping it on screen.
    progress.updateNodeStatus(t.a1, NodeStatus.success);
    progress.updateNodeStatus(t.loopA, NodeStatus.success);
    progress.updateProgress(currentNodeId: t.b1);
    await tester.pump();

    expect(handle.container.read(collapsedNodeIdsProvider), isEmpty);
    expect(find.text('A sub'), findsOneWidget);
  });

  testWidgets('a finished container the operator opened is folded anyway',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);
    final collapsed = handle.container.read(collapsedNodeIdsProvider.notifier);

    progress.updateProgress(currentNodeId: t.a1);
    _finishTargetA(progress, t);
    await tester.pump();

    // Collapse the night to scan it, then Expand all to read what A shot —
    // AFTER A has finished. Spec §4 shields what the operator opened "and that
    // has not run yet"; recording a finished branch here is what let one
    // Expand all freeze the rest of the night's folding for good.
    collapsed.collapseAll([t.targetA, t.loopA, t.targetB]);
    await tester.pump();
    collapsed.expandAll();
    await tester.pump();
    expect(handle.container.read(collapsedNodeIdsProvider), isEmpty);

    progress.updateProgress(currentNodeId: t.b1);
    await tester.pumpAndSettle();

    expect(handle.container.read(collapsedNodeIdsProvider), {t.targetA});
    expect(find.text('A sub'), findsNothing);
  });

  testWidgets('the tree re-opening a branch does not count as the operator',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);

    handle.container
        .read(collapsedNodeIdsProvider.notifier)
        .collapseAll([t.targetA, t.loopA]);
    await tester.pump();

    // Auto-expanded by the run entering A...
    progress.updateProgress(currentNodeId: t.a1);
    await tester.pump();
    expect(handle.container.read(collapsedNodeIdsProvider), isEmpty);

    // ...so when the run finishes with A it may fold it again. Mistaking its
    // own expansion for the operator's would leave every branch of the night
    // open for good.
    _finishTargetA(progress, t);
    progress.updateProgress(currentNodeId: t.b1);
    await tester.pump();

    expect(handle.container.read(collapsedNodeIdsProvider), {t.targetA});
  });

  testWidgets('follow execution off stops the tree moving under the operator',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);
    handle.container.read(followExecutionProvider.notifier).state = false;

    progress.updateProgress(currentNodeId: t.a1);
    _finishTargetA(progress, t);
    progress.updateProgress(currentNodeId: t.b1);
    await tester.pump();

    expect(handle.container.read(collapsedNodeIdsProvider), isEmpty);
  });

  testWidgets('a run reset forgets what the last run was holding open',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final handle = await _pumpTree(tester, t.sequence, progress);
    final collapsed = handle.container.read(collapsedNodeIdsProvider.notifier);
    final execution =
        handle.container.read(sequenceExecutionStateProvider.notifier);

    execution.state = SequenceExecutionState.running;
    progress.updateProgress(currentNodeId: t.a1);
    await tester.pump();

    // The operator holds A open for THIS run.
    collapsed.toggle(t.targetA);
    collapsed.toggle(t.targetA);
    await tester.pump();

    // Stop. Back at idle the statuses are cleared and nothing in the sequence
    // has run, so a hold recorded against the last run describes nothing.
    execution.state = SequenceExecutionState.idle;
    await tester.pump();

    // A second night reaches the same point, and this time nothing shields
    // the loop it has finished with.
    progress.updateNodeStatus(t.a1, NodeStatus.success);
    progress.updateNodeStatus(t.loopA, NodeStatus.success);
    progress.updateProgress(currentNodeId: t.b1);
    await tester.pump();

    expect(handle.container.read(collapsedNodeIdsProvider), contains(t.loopA));
  });

  testWidgets('opening a different sequence forgets the last one\'s holds',
      (tester) async {
    final t = _twoTargets();
    final progress = SequenceProgressNotifier();
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = t.sequence;

    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceTree(colors: SkotiqColors.of(context)),
      ),
      size: const Size(1200, 900),
      settle: false,
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        sequenceProgressProvider.overrideWith((_) => progress),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
    );
    await tester.pump(const Duration(seconds: 1));
    final collapsed = handle.container.read(collapsedNodeIdsProvider.notifier);

    progress.updateProgress(currentNodeId: t.a1);
    await tester.pump();
    collapsed.toggle(t.targetA);
    collapsed.toggle(t.targetA);
    await tester.pump();

    // The operator opens a DIFFERENT sequence that happens to reuse these node
    // ids — the shape a "save as" or a re-import produces. The hold belonged
    // to the tree they left; carried over it would shield a container of the
    // new one that nobody ever opened.
    // ignore: invalid_use_of_protected_member
    notifier.state = Sequence.create(
      name: 'Another night',
      rootNodeId: t.sequence.rootNodeId,
      nodes: t.sequence.nodes,
    );
    await tester.pump();

    progress.updateNodeStatus(t.a1, NodeStatus.success);
    progress.updateNodeStatus(t.loopA, NodeStatus.success);
    progress.updateProgress(currentNodeId: t.b1);
    await tester.pump();

    expect(handle.container.read(collapsedNodeIdsProvider), contains(t.loopA));
    // Swapping the sequence arms a fresh live-validation debounce; drain it or
    // teardown trips the pending-timer assertion.
    await tester.pump(const Duration(seconds: 1));
  });
}
