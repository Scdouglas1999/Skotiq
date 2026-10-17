// Widget tests for the plan summary line on [TargetHeaderCard].
//
// The card is the thing a user reads to decide whether tonight's plan is
// right, so its "N planned exposures · Xm" line has to agree with the
// toolbar's frame counter (Sequence.totalExposures) and with the stored
// estimate. Walking the target's subtree with NO loop multiplier makes every
// Quick-Start-Wizard sequence — a `Capture Loop ×N` wrapping one exposure node —
// report a tenth of its real plan.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_header_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Build the wizard-shaped tree: TargetHeader → Loop(count N) → Exposure.
/// Returns the container so the test can also read the model's own count.
ProviderContainer _seedLoopedTarget({
  required TargetHeaderNode target,
  required LoopNode loop,
  required ExposureNode exposure,
}) {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  final editor = container.read(currentSequenceProvider.notifier);
  editor.createSequence(name: 'plan test');
  editor.addNode(target);
  editor.addNode(loop, parentId: target.id);
  editor.addNode(exposure, parentId: loop.id);
  return container;
}

Future<void> _pumpCard(
  WidgetTester tester,
  ProviderContainer container,
  TargetHeaderNode target, {
  NodeStatus? nodeStatus,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: TargetHeaderCard(
              node: target,
              colors: SkotiqColors.dark,
              nodeStatus: nodeStatus,
              // Mobile layout hides the altitude chart, keeping the pump to
              // the plan line this test is about.
              isMobile: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'count loop multiplies the target plan (matches the toolbar frame count)',
    (tester) async {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      final loop = LoopNode(
        conditionType: LoopConditionType.count,
        repeatCount: 10,
      );
      final exposure = ExposureNode(count: 1, durationSecs: 120);

      final container = _seedLoopedTarget(
        target: target,
        loop: loop,
        exposure: exposure,
      );
      addTearDown(container.dispose);

      // Ground truth: the model counts 10 frames for this tree.
      expect(container.read(currentSequenceProvider)!.totalExposures, 10);

      await _pumpCard(tester, container, target);

      expect(find.text('10 planned exposures • 20m'), findsOneWidget);
      expect(find.text('1 planned exposures • 2m'), findsNothing);
    },
  );

  testWidgets('nested count loops compound the multiplier', (tester) async {
    final target =
        TargetHeaderNode(targetName: 'M42', raHours: 5.59, decDegrees: -5.39);
    final outer = LoopNode(
      conditionType: LoopConditionType.count,
      repeatCount: 3,
    );
    final inner = LoopNode(
      conditionType: LoopConditionType.count,
      repeatCount: 4,
    );
    final exposure = ExposureNode(count: 2, durationSecs: 60);

    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    final editor = container.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'nested');
    editor.addNode(target);
    editor.addNode(outer, parentId: target.id);
    editor.addNode(inner, parentId: outer.id);
    editor.addNode(exposure, parentId: inner.id);

    expect(container.read(currentSequenceProvider)!.totalExposures, 24);

    await _pumpCard(tester, container, target);

    // 3 × 4 × 2 = 24 frames × 60s = 24m.
    expect(find.text('24 planned exposures • 24m'), findsOneWidget);
  });

  testWidgets(
    'a non-count loop is reported as a per-pass floor, not as the plan',
    (tester) async {
      final target = TargetHeaderNode(
        targetName: 'NGC 7000',
        raHours: 20.98,
        decDegrees: 44.53,
      );
      final loop = LoopNode(conditionType: LoopConditionType.forever);
      final exposure = ExposureNode(count: 4, durationSecs: 60);

      final container = _seedLoopedTarget(
        target: target,
        loop: loop,
        exposure: exposure,
      );
      addTearDown(container.dispose);

      await _pumpCard(tester, container, target);

      expect(
        find.text(
          '4 planned exposures • 4m per pass • '
          'loop repeats until its stop condition',
        ),
        findsOneWidget,
      );
    },
  );

  // The idle plan line was fixed first; the LIVE counter on the same card
  // still divided the current pass's frame count by an unmultiplied plan, so
  // the card flipped to "1/1 done - 100%" the moment the first of ten frames
  // landed and stayed there all night. Running is the state the user watches.
  testWidgets(
    'mid-run a looped target counts real passes, never a false 100%',
    (tester) async {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      final loop = LoopNode(
        conditionType: LoopConditionType.count,
        repeatCount: 10,
      );
      final exposure = ExposureNode(count: 1, durationSecs: 120);

      final container = _seedLoopedTarget(
        target: target,
        loop: loop,
        exposure: exposure,
      );
      addTearDown(container.dispose);

      // The run is live and pass 1 of 10 has finished: the loop has already
      // reset the exposure node, so its `success` status describes that pass
      // alone. Only the run-level frame counter distinguishes pass 1 from 10.
      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      // ignore: invalid_use_of_protected_member
      container.read(sequenceProgressProvider.notifier).state =
          SequenceProgress(
        nodeStatuses: {exposure.id: NodeStatus.success},
        completedExposures: 1,
        completedIntegrationSecs: 120,
      );

      await _pumpCard(
        tester,
        container,
        target,
        nodeStatus: NodeStatus.running,
      );

      expect(find.text('1/1 done'), findsNothing);
      expect(find.text('100%'), findsNothing);
      expect(find.text('1/10 done'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      expect(find.text('2m / 20m'), findsOneWidget);
    },
  );

  // Under a forever loop the plan is a ONE-PASS FLOOR, so there is no honest
  // denominator: the card must fall back to the plan line rather than divide
  // the run counter by the floor and pin itself at 100%.
  testWidgets(
    'mid-run an unbounded loop shows its plan, not a ratio over a floor',
    (tester) async {
      final target = TargetHeaderNode(
        targetName: 'NGC 7000',
        raHours: 20.98,
        decDegrees: 44.53,
      );
      final loop = LoopNode(conditionType: LoopConditionType.forever);
      final exposure = ExposureNode(count: 1, durationSecs: 120);

      final container = _seedLoopedTarget(
        target: target,
        loop: loop,
        exposure: exposure,
      );
      addTearDown(container.dispose);

      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      // ignore: invalid_use_of_protected_member
      container.read(sequenceProgressProvider.notifier).state =
          SequenceProgress(
        nodeStatuses: {exposure.id: NodeStatus.success},
        completedExposures: 7,
      );

      await _pumpCard(
        tester,
        container,
        target,
        nodeStatus: NodeStatus.running,
      );

      expect(find.text('1/1 done'), findsNothing);
      expect(find.text('7/1 done'), findsNothing);
      expect(find.text('100%'), findsNothing);
      expect(
        find.text(
          '1 planned exposures • 2m per pass • '
          'loop repeats until its stop condition',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a disabled exposure node is left out of the plan',
      (tester) async {
    final target =
        TargetHeaderNode(targetName: 'M13', raHours: 16.69, decDegrees: 36.46);
    final loop = LoopNode(
      conditionType: LoopConditionType.count,
      repeatCount: 5,
    );
    final exposure = ExposureNode(
      count: 2,
      durationSecs: 60,
      isEnabled: false,
    );

    final container = _seedLoopedTarget(
      target: target,
      loop: loop,
      exposure: exposure,
    );
    addTearDown(container.dispose);

    await _pumpCard(tester, container, target);

    expect(find.text('No exposure nodes under this target'), findsOneWidget);
  });
}
