import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence/target_progress_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

// One frame count per step, read by the plan totals, the sequence total and
// per-target progress. The native run reports no total for a Smart Exposure
// looping until stopped (`executor/loading.rs` `calculate_totals`), so its
// per-filter counts are not frames anywhere.

Sequence _underTarget(List<SequenceNode> steps) {
  final target = TargetHeaderNode(
    id: 'target',
    targetName: 'M31',
    raHours: 0,
    decDegrees: 0,
  );
  final root = InstructionSetNode(id: 'root', name: 'Root');
  return Sequence.create(
    name: 'Test',
    rootNodeId: root.id,
    nodes: {
      for (final step in steps) step.id: step.copyWith(parentId: target.id),
      target.id: target.copyWith(
        parentId: root.id,
        childIds: [for (final step in steps) step.id],
      ),
      root.id: root.copyWith(childIds: [target.id]),
    },
  );
}

SmartExposureNode _smart({required bool loopUntilStopped}) => SmartExposureNode(
  id: 'smart',
  plans: const [
    FilterPlan(filterName: 'Ha', durationSecs: 300, count: 20),
    FilterPlan(filterName: 'OIII', durationSecs: 300, count: 10),
  ],
  loopUntilStopped: loopUntilStopped,
  integrationBudgetSecs: loopUntilStopped ? 7200 : 0,
);

TargetExecutionProgress _targetProgress(Sequence sequence) {
  final container = ProviderContainer(
    overrides: [
      currentSequenceProvider.overrideWith((ref) {
        final notifier = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        notifier.state = sequence;
        return notifier;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container.read(targetExecutionProgressProvider('target'));
}

void main() {
  test('a step says how many frames one pass takes', () {
    expect(ExposureNode(count: 8).framesPerPass, 8);
    expect(SciencePhotometryNode(count: 60).framesPerPass, 60);
    expect(_smart(loopUntilStopped: false).framesPerPass, 30);
    expect(_smart(loopUntilStopped: false).integrationSecsPerPass, 9000);
    expect(SlewNode().framesPerPass, 0);
  });

  test('a Smart Exposure looping until stopped has no frame count', () {
    final node = _smart(loopUntilStopped: true);
    expect(node.framesPerPass, 0);
    expect(node.capturesUntilStopped, isTrue);

    final sequence = _underTarget([node, ExposureNode(id: 'exp', count: 5)]);
    expect(sequence.totalExposures, 5);

    final planned = plannedCaptureUnder(sequence, 'target');
    expect(planned.frames, 5);
    expect(planned.hasOpenEndedLoop, isTrue);
    expect(planned.openEndedBudgetSecs, 7200);

    final progress = _targetProgress(sequence);
    expect(progress.totalFrames, 5);
    expect(progress.completionUnknown, isTrue);
  });

  test('the sequence total, the plan walk and target progress agree', () {
    final sequence = _underTarget([
      ExposureNode(id: 'exp', durationSecs: 60, count: 5),
      _smart(loopUntilStopped: false),
      SciencePhotometryNode(id: 'phot', exposureSecs: 10, count: 60),
    ]);

    expect(sequence.totalExposures, 95);
    expect(plannedCaptureUnder(sequence, 'target').frames, 95);
    final progress = _targetProgress(sequence);
    expect(progress.totalFrames, 95);
    expect(progress.totalIntegrationSecs, 300 + 9000 + 600);
    expect(progress.completionUnknown, isFalse);
  });

  test('without a root the total is the sum over enabled steps', () {
    final sequence = Sequence.create(
      name: 'Flat',
      nodes: {
        'a': ExposureNode(id: 'a', count: 3),
        'b': ExposureNode(id: 'b', count: 4, isEnabled: false),
        'smart': _smart(loopUntilStopped: true),
      },
    );
    expect(sequence.totalExposures, 3);
  });
}
