// A loop's length as each reader gives it for the same tree: the Builder's
// tree rollup, the plan's integration estimate, the timeline walk, the
// planned frame count and the disk projection. The pass count of a loop that
// fixes one comes from one rule (`loopPasses`).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

const _estimator = SequenceTimeEstimator();
const _camera = CameraCapabilities(
  maxWidth: 1000,
  maxHeight: 1000,
  bitDepth: 16,
);

/// A plan of [loop] holding one 5 x 60 s exposure (and [extra] children),
/// under a root.
Sequence _planOf(LoopNode loop, {List<SequenceNode> extra = const []}) {
  final exposure = ExposureNode(
    id: 'exp',
    parentId: loop.id,
    count: 5,
    durationSecs: 60,
  );
  final children = [
    exposure,
    ...extra.map((c) => c.copyWith(parentId: loop.id)),
  ];
  final root = InstructionSetNode(id: 'root', childIds: [loop.id]);
  return Sequence.create(
    id: 'seq',
    name: 'Loop',
    rootNodeId: root.id,
    nodes: {
      root.id: root,
      loop.id: loop.copyWith(
        parentId: root.id,
        childIds: [for (final c in children) c.id],
      ),
      for (final c in children) c.id: c,
    },
  );
}

class _Case {
  const _Case(
    this.name,
    this.plan, {
    required this.rollup,
    required this.integration,
    required this.unbounded,
    required this.timeline,
    required this.frames,
    required this.framesArePerPass,
  });

  final String name;
  final Sequence Function(DateTime now) plan;

  /// The loop row's rolled-up length in seconds.
  final double rollup;

  /// `estimateIntegrationSecs().estimatedSecs`.
  final double integration;
  final bool unbounded;

  /// `estimateTotalDuration` in seconds.
  final double timeline;

  /// The planned frames ([plannedCaptureUnder]), which the disk projection
  /// also counts.
  final int frames;

  /// [PlannedCapture.hasUnboundedRepeat]: [frames] is one pass, not the total.
  final bool framesArePerPass;
}

void main() {
  // One pass: 5 frames of 60 s plus the estimator's per-frame download.
  final pass =
      _estimator
          .nodeDuration(ExposureNode(count: 5, durationSecs: 60))
          .inMilliseconds /
      1000.0;

  final cases = <_Case>[
    _Case(
      'count 3',
      (_) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.count,
          repeatCount: 3,
        ),
      ),
      rollup: 3 * pass,
      integration: 900,
      unbounded: false,
      timeline: 3 * pass,
      frames: 15,
      framesArePerPass: false,
    ),
    _Case(
      'count with no repeat count',
      (_) =>
          _planOf(LoopNode(id: 'loop', conditionType: LoopConditionType.count)),
      rollup: pass,
      integration: 300,
      unbounded: false,
      timeline: pass,
      frames: 5,
      framesArePerPass: false,
    ),
    _Case(
      'count 0',
      (_) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.count,
          repeatCount: 0,
        ),
      ),
      rollup: 0,
      integration: 0,
      unbounded: false,
      timeline: pass,
      frames: 0,
      framesArePerPass: false,
    ),
    // The executor repeats an integration-time loop while its own steps'
    // integration is short of the target, so the loop takes several passes
    // and the timeline advances by all of them, as the tree row does.
    _Case(
      'integration time 1500 s over 300 s passes',
      (_) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.integrationTime,
          integrationTimeTarget: 1500,
        ),
      ),
      rollup: 5 * pass,
      integration: 1500,
      unbounded: false,
      timeline: 5 * pass,
      frames: 25,
      framesArePerPass: false,
    ),
    _Case(
      'integration time 1000 s rounds up to 4 passes',
      (_) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.integrationTime,
          integrationTimeTarget: 1000,
        ),
      ),
      rollup: 4 * pass,
      integration: 1200,
      unbounded: false,
      timeline: 4 * pass,
      frames: 20,
      framesArePerPass: false,
    ),
    _Case(
      'integration time with no target',
      (_) => _planOf(
        LoopNode(id: 'loop', conditionType: LoopConditionType.integrationTime),
      ),
      rollup: pass,
      integration: 300,
      unbounded: true,
      timeline: pass,
      frames: 5,
      framesArePerPass: true,
    ),
    _Case(
      'integration time counts only enabled exposures',
      (_) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.integrationTime,
          integrationTimeTarget: 1500,
        ),
        extra: [
          ExposureNode(id: 'off', count: 5, durationSecs: 60, isEnabled: false),
        ],
      ),
      rollup: 5 * pass,
      integration: 1500,
      unbounded: false,
      timeline: 5 * pass,
      frames: 25,
      framesArePerPass: false,
    ),
    _Case(
      'forever',
      (_) => _planOf(
        LoopNode(id: 'loop', conditionType: LoopConditionType.forever),
      ),
      rollup: pass,
      integration: 300,
      unbounded: true,
      timeline: pass,
      frames: 5,
      framesArePerPass: true,
    ),
    _Case(
      'until a time that has passed',
      (now) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.untilTime,
          repeatUntil: now.subtract(const Duration(hours: 1)),
        ),
      ),
      rollup: pass,
      integration: 300,
      unbounded: false,
      timeline: 0,
      frames: 5,
      framesArePerPass: true,
    ),
    _Case(
      'until a time two hours away',
      (now) => _planOf(
        LoopNode(
          id: 'loop',
          conditionType: LoopConditionType.untilTime,
          repeatUntil: now.add(const Duration(hours: 2)),
        ),
      ),
      rollup: 7200,
      integration: 7200 ~/ 300 * 300,
      unbounded: false,
      timeline: 7200,
      frames: 5,
      framesArePerPass: true,
    ),
  ];

  for (final c in cases) {
    test('loop length: ${c.name}', () {
      final now = DateTime.now();
      final sequence = c.plan(now);
      final rollup =
          computeNodeRollups(
            sequence,
            _estimator,
          ).durations['loop']!.inMilliseconds /
          1000.0;
      final estimate = sequence.estimateIntegrationSecs(referenceTime: now);
      final timeline =
          _estimator.estimateTotalDuration(sequence, now).inMilliseconds /
          1000.0;
      expect(rollup, closeTo(c.rollup, 2), reason: 'tree rollup');
      expect(
        estimate.estimatedSecs,
        closeTo(c.integration, 1),
        reason: 'integration estimate',
      );
      expect(estimate.isUnbounded, c.unbounded, reason: 'unbounded');
      expect(timeline, closeTo(c.timeline, 2), reason: 'timeline');
      final planned = plannedCaptureUnder(sequence, 'root');
      expect(planned.frames, c.frames, reason: 'planned frames');
      expect(
        planned.hasUnboundedRepeat,
        c.framesArePerPass,
        reason: 'frames per pass',
      );
      expect(
        DiskSpaceGuardService.projectSequenceBytes(sequence, _camera),
        c.frames * (1000 * 1000 * 2 + 65536),
        reason: 'disk projection',
      );
    });
  }
}
