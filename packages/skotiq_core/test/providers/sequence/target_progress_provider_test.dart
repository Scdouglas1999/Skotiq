import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

/// Tests for the per-target execution progress rollup.

ProviderContainer _container({
  required Sequence sequence,
  SequenceProgress progress = const SequenceProgress(),
}) {
  final container = ProviderContainer(
    overrides: [
      currentSequenceProvider.overrideWith((ref) {
        final notifier = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        notifier.state = sequence;
        return notifier;
      }),
      sequenceProgressProvider.overrideWith((ref) {
        final n = SequenceProgressNotifier();
        // ignore: invalid_use_of_protected_member
        n.state = progress;
        return n;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Build "Root → Target → Exposure(60s ×8) + Exposure(120s ×4)" so the
/// totals are 12 frames (8+4) and 8·60+4·120 = 480+480 = 960s
/// integration. Returns the target id for the assertions.
({Sequence sequence, String targetId, String firstExpoId, String secondExpoId})
_buildTwoExposureTarget() {
  final expo1 = ExposureNode(durationSecs: 60, count: 8, name: 'a');
  final expo2 = ExposureNode(durationSecs: 120, count: 4, name: 'b');
  final target = TargetHeaderNode(targetName: 'M31', raHours: 0, decDegrees: 0);
  final root = InstructionSetNode(name: 'Root');
  final tree = <String, SequenceNode>{
    expo1.id: expo1.copyWith(parentId: target.id),
    expo2.id: expo2.copyWith(parentId: target.id),
    target.id: target.copyWith(
      parentId: root.id,
      childIds: [expo1.id, expo2.id],
    ),
    root.id: root.copyWith(childIds: [target.id]),
  };
  return (
    sequence: Sequence.create(name: 'Test', nodes: tree, rootNodeId: root.id),
    targetId: target.id,
    firstExpoId: expo1.id,
    secondExpoId: expo2.id,
  );
}

void main() {
  group('targetExecutionProgressProvider', () {
    test('empty when target id not in sequence', () {
      final t = _buildTwoExposureTarget();
      final c = _container(sequence: t.sequence);
      final p = c.read(targetExecutionProgressProvider('missing-id'));
      expect(p, same(TargetExecutionProgress.empty));
    });

    test('plan totals match exposure counts before any frame completes', () {
      final t = _buildTwoExposureTarget();
      final c = _container(sequence: t.sequence);
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.totalFrames, 12);
      expect(p.completedFrames, 0);
      expect(p.totalIntegrationSecs, 960);
      expect(p.completedIntegrationSecs, 0);
      expect(p.fraction, 0.0);
    });

    test('completed exposure attributes all frames', () {
      final t = _buildTwoExposureTarget();
      final c = _container(
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {t.firstExpoId: NodeStatus.success},
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.completedFrames, 8); // expo1 done
      expect(p.completedIntegrationSecs, 480);
      // 8/12 ≈ 0.667
      expect(p.fraction, closeTo(8 / 12, 1e-9));
    });

    test('running exposure attributes partial frames from percent', () {
      final t = _buildTwoExposureTarget();
      // expo1 (count=8) at 50% -> 4 frames done.
      final c = _container(
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {t.firstExpoId: NodeStatus.running},
          nodeProgressPercent: {t.firstExpoId: 50.0},
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.completedFrames, 4);
      expect(p.completedIntegrationSecs, 4 * 60);
    });

    test('skipped/failure exposures contribute zero completed frames', () {
      final t = _buildTwoExposureTarget();
      final c = _container(
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {
            t.firstExpoId: NodeStatus.skipped,
            t.secondExpoId: NodeStatus.failure,
          },
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.completedFrames, 0);
      expect(p.completedIntegrationSecs, 0);
    });

    // A Quick-Start-Wizard sequence is `TargetHeader > Capture Loop xN >
    // Light`. The rollup used to walk that with NO loop multiplier, so the
    // live counter on the target card read "1/1 done - 100%" the moment the
    // FIRST of ten frames landed, and stayed there for the rest of the night.
    ({Sequence sequence, String targetId, String expoId}) buildLoopedTarget({
      required int repeatCount,
      LoopConditionType conditionType = LoopConditionType.count,
    }) {
      final expo = ExposureNode(durationSecs: 120, count: 1, name: 'Light');
      final loop = LoopNode(
        conditionType: conditionType,
        repeatCount: repeatCount,
        name: 'Capture Loop',
      );
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      final root = InstructionSetNode(name: 'Root');
      final tree = <String, SequenceNode>{
        expo.id: expo.copyWith(parentId: loop.id),
        loop.id: loop.copyWith(parentId: target.id, childIds: [expo.id]),
        target.id: target.copyWith(parentId: root.id, childIds: [loop.id]),
        root.id: root.copyWith(childIds: [target.id]),
      };
      return (
        sequence: Sequence.create(
          name: 'Wizard',
          nodes: tree,
          rootNodeId: root.id,
        ),
        targetId: target.id,
        expoId: expo.id,
      );
    }

    test('count loop multiplies the planned totals, matching the model', () {
      final t = buildLoopedTarget(repeatCount: 10);
      final c = _container(sequence: t.sequence);
      final p = c.read(targetExecutionProgressProvider(t.targetId));

      // Ground truth: the model itself counts 10 frames for this tree.
      expect(c.read(currentSequenceProvider)!.totalExposures, 10);
      expect(p.totalFrames, 10);
      expect(p.totalIntegrationSecs, 1200);
    });

    test('a looped target does not claim 100% after the first pass', () {
      final t = buildLoopedTarget(repeatCount: 10);
      final c = _container(
        sequence: t.sequence,
        // Pass 1 of 10 has finished: the exposure node reads success (it is
        // reset before pass 2) and the run counter stands at one frame.
        progress: SequenceProgress(
          nodeStatuses: {t.expoId: NodeStatus.success},
          completedExposures: 1,
          completedIntegrationSecs: 120,
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));

      expect(p.totalFrames, 10);
      // Every frame the run plans is under this target, so the run counter
      // attributes to it: one of ten, NOT the node status's "1/1 = 100%".
      expect(p.completedFrames, 1);
      expect(p.completedIntegrationSecs, 120);
      expect(p.fraction, closeTo(0.1, 1e-9));
      expect(p.completionUnknown, isFalse);
    });

    test('a looped target attributes later passes, not just the first', () {
      final t = buildLoopedTarget(repeatCount: 10);
      final c = _container(
        sequence: t.sequence,
        // Pass 7: the node status is identical to pass 1 — only the run
        // counter can tell the two apart.
        progress: SequenceProgress(
          nodeStatuses: {t.expoId: NodeStatus.success},
          completedExposures: 7,
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.completedFrames, 7);
      expect(p.fraction, closeTo(0.7, 1e-9));
    });

    // Guard for the inversion this attribution invites: under a
    // forever/until-time loop `totalFrames` is a ONE-PASS FLOOR (1 here), so
    // dividing the run counter by it reports "1/1 - 100%" after the first frame
    // and stays there — the exact failure the flag exists to prevent, merely
    // re-sourced from the wire.
    test(
      'an unbounded loop stays unknown even though the run counter moves',
      () {
        final t = buildLoopedTarget(
          repeatCount: 1,
          conditionType: LoopConditionType.forever,
        );
        final c = _container(
          sequence: t.sequence,
          progress: SequenceProgress(
            nodeStatuses: {t.expoId: NodeStatus.success},
            completedExposures: 7,
          ),
        );
        final p = c.read(targetExecutionProgressProvider(t.targetId));
        expect(p.completionUnknown, isTrue);
        expect(p.hasKnownCompletion, isFalse);
        expect(p.fraction, 0.0);
        // The one-pass floor is never presented as a completed count.
        expect(p.completedFrames, lessThan(p.totalFrames + 1));
      },
    );

    // The run counter is run-level, so it may only be attributed to a target
    // that owns every planned frame.
    test(
      'a looped target sharing the run with another target stays unknown',
      () {
        final t = buildLoopedTarget(repeatCount: 10);
        // Add a second target with its own exposure, so the run counter can no
        // longer be told apart between the two.
        final other = ExposureNode(durationSecs: 30, count: 5, name: 'other');
        final otherTarget = TargetHeaderNode(
          targetName: 'M42',
          raHours: 5.6,
          decDegrees: -5.4,
        );
        final rootId = t.sequence.rootNodeId!;
        final root = t.sequence.nodes[rootId]!;
        final nodes = Map<String, SequenceNode>.from(t.sequence.nodes)
          ..[other.id] = other.copyWith(parentId: otherTarget.id)
          ..[otherTarget.id] = otherTarget.copyWith(
            parentId: rootId,
            childIds: [other.id],
          )
          ..[rootId] = root.copyWith(
            childIds: [...root.childIds, otherTarget.id],
          );
        final c = _container(
          sequence: Sequence.create(
            name: 'Two targets',
            nodes: nodes,
            rootNodeId: rootId,
          ),
          progress: SequenceProgress(
            nodeStatuses: {t.expoId: NodeStatus.success},
            completedExposures: 7,
          ),
        );
        final p = c.read(targetExecutionProgressProvider(t.targetId));
        expect(p.totalFrames, 10);
        expect(p.completionUnknown, isTrue);
        expect(p.fraction, 0.0);
      },
    );

    test('a single-pass count loop keeps normal completion accounting', () {
      final t = buildLoopedTarget(repeatCount: 1);
      final c = _container(
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {t.expoId: NodeStatus.success},
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.completionUnknown, isFalse);
      expect(p.totalFrames, 1);
      expect(p.completedFrames, 1);
      expect(p.fraction, 1.0);
    });

    test('an unlooped target still reports known completion', () {
      final t = _buildTwoExposureTarget();
      final c = _container(
        sequence: t.sequence,
        progress: SequenceProgress(
          nodeStatuses: {t.firstExpoId: NodeStatus.success},
        ),
      );
      final p = c.read(targetExecutionProgressProvider(t.targetId));
      expect(p.completionUnknown, isFalse);
      expect(p.fraction, closeTo(8 / 12, 1e-9));
    });

    test('hasPlannedFrames mirrors totalFrames > 0', () {
      const empty = TargetExecutionProgress.empty;
      expect(empty.hasPlannedFrames, isFalse);
      const filled = TargetExecutionProgress(
        totalFrames: 1,
        completedFrames: 0,
        totalIntegrationSecs: 30,
        completedIntegrationSecs: 0,
      );
      expect(filled.hasPlannedFrames, isTrue);
    });
  });
}
