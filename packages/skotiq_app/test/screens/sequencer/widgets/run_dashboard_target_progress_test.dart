// The SECOND production consumer of targetExecutionProgressProvider.
//
// The builder card (target_header_card_plan_test.dart) and this Run Dashboard
// panel read the same snapshot but render it independently, so a fix proven on
// one says nothing about the other — and this is the panel a user actually
// watches for the whole night. Both branches are asserted here: a target whose
// completion IS derivable must show a true counter, and one whose completion
// is not must show the plan instead of a fabricated ratio.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/target_header_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/pump_app_screen.dart';

/// TargetHeader → Loop(N, [conditionType]) → Exposure(1 × 120s).
({Sequence sequence, String targetId, String expoId}) _loopedTarget({
  required int repeatCount,
  LoopConditionType conditionType = LoopConditionType.count,
  String targetName = 'M31',
}) {
  final expo = ExposureNode(durationSecs: 120, count: 1, name: 'Light');
  final loop = LoopNode(
    conditionType: conditionType,
    repeatCount: repeatCount,
    name: 'Capture Loop',
  );
  final target = TargetHeaderNode(
    targetName: targetName,
    raHours: 0.712,
    decDegrees: 41.27,
  );
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    expo.id: expo.copyWith(parentId: loop.id),
    loop.id: loop.copyWith(parentId: target.id, childIds: [expo.id]),
    target.id: target.copyWith(parentId: root.id, childIds: [loop.id]),
    root.id: root.copyWith(childIds: [target.id]),
  };
  return (
    sequence: Sequence.create(name: 'Run', nodes: nodes, rootNodeId: root.id),
    targetId: target.id,
    expoId: expo.id,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required Sequence sequence,
  required SequenceProgress progress,
}) async {
  final seqNotifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  seqNotifier.state = sequence;

  await pumpAppScreen(
    tester,
    const Scaffold(body: RunDashboardTargetHeader()),
    size: const Size(1200, 900),
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => seqNotifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.running),
      sequenceProgressProvider.overrideWith((ref) {
        final n = SequenceProgressNotifier();
        // ignore: invalid_use_of_protected_member
        n.state = progress;
        return n;
      }),
    ],
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mid-run the dashboard counts real loop passes, never a false 100%',
    (tester) async {
      final t = _loopedTarget(repeatCount: 10);

      // Pass 1 of 10: the loop has already reset the exposure node, so its
      // `success` status describes that pass alone. Only the run-level frame
      // counter separates pass 1 from pass 10.
      await _pumpPanel(
        tester,
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {t.expoId: NodeStatus.success},
          completedExposures: 1,
          completedIntegrationSecs: 120,
        ),
      );

      // Exact strings: 'contains 1/1' would also match the correct '1/10'.
      expect(find.text('1/1 frames'), findsNothing);
      expect(find.text('100%'), findsNothing);
      expect(find.text('1/10 frames'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      expect(find.text('2m / 20m'), findsOneWidget);
    },
  );

  testWidgets(
    'an unbounded loop shows the plan, not a ratio over a one-pass floor',
    (tester) async {
      final t = _loopedTarget(
        repeatCount: 1,
        conditionType: LoopConditionType.forever,
      );

      // Seven frames are done but the plan under a forever loop is a ONE-PASS
      // FLOOR of 1, so there is no honest denominator to divide by.
      await _pumpPanel(
        tester,
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {t.expoId: NodeStatus.success},
          completedExposures: 7,
        ),
      );

      expect(find.text('7/1 frames'), findsNothing);
      expect(find.text('1/1 frames'), findsNothing);
      expect(find.text('100%'), findsNothing);
      expect(find.text('1 frames planned • 2m'), findsOneWidget);
    },
  );
}
