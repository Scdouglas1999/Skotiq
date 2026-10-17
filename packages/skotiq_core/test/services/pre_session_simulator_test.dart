import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('PreSessionSimulator', () {
    const simulator = PreSessionSimulator();

    Sequence sequenceWith({
      required TargetHeaderNode target,
      List<SequenceNode> children = const [],
    }) {
      final nodes = <String, SequenceNode>{
        target.id: target.copyWith(
          childIds: children.map((child) => child.id).toList(),
        ),
        for (final child in children)
          child.id: child.copyWith(parentId: target.id),
      };

      return Sequence.create(name: 'Simulation Test', nodes: nodes);
    }

    test('builds Gantt segments from the shared sequence time estimator', () {
      final start = DateTime(2026, 5, 21, 22);
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-m31',
          name: 'M31 Target',
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        ),
        children: [
          ExposureNode(
            id: 'exp-l',
            name: 'Lum 120s',
            durationSecs: 120,
            count: 2,
            filter: 'L',
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
      );

      expect(result.start, start);
      expect(result.segments, hasLength(1));
      expect(result.segments.single.nodeId, 'exp-l');
      expect(result.segments.single.targetHeaderId, 'target-m31');
      expect(result.segments.single.targetName, 'M31');
      expect(result.segments.single.duration, const Duration(seconds: 244));
      expect(result.end, start.add(const Duration(seconds: 244)));
      expect(result.duration, const Duration(seconds: 244));
      expect(result.targetWindows, contains('target-m31'));
    });

    test('warns when the simulated run overruns the dark window', () {
      final start = DateTime(2026, 5, 21, 22);
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-m51',
          name: 'M51 Target',
          targetName: 'M51',
          raHours: 13.5,
          decDegrees: 47.2,
        ),
        children: [
          ExposureNode(
            id: 'exp-l',
            name: 'Lum 300s',
            durationSecs: 300,
            count: 10,
            filter: 'L',
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
        darkWindowEnd: start.add(const Duration(minutes: 20)),
      );

      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>()
              .having(
                (issue) => issue.severity,
                'severity',
                PreSessionSimulationSeverity.warning,
              )
              .having(
                (issue) => issue.message,
                'message',
                contains('dark window'),
              ),
        ),
      );
      expect(result.hasBlockingIssues, isFalse);
    });

    test('warns when the simulated run starts before the dark window', () {
      final start = DateTime(2026, 5, 21, 20, 30);
      final darkStart = start.add(const Duration(minutes: 45));
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-m13',
          name: 'M13 Target',
          targetName: 'M13',
          raHours: 16.7,
          decDegrees: 36.5,
        ),
        children: [
          ExposureNode(
            id: 'exp-l',
            name: 'Lum 60s',
            durationSecs: 60,
            count: 1,
            filter: 'L',
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
        darkWindowStart: darkStart,
      );

      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>()
              .having(
                (issue) => issue.severity,
                'severity',
                PreSessionSimulationSeverity.warning,
              )
              .having(
                (issue) => issue.message,
                'message',
                contains('before the dark window starts'),
              ),
        ),
      );
      expect(result.hasBlockingIssues, isFalse);
    });

    test('can produce timing-only simulation without observer location', () {
      final start = DateTime(2026, 5, 21, 22);
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-m31',
          name: 'M31 Target',
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        ),
        children: [
          ExposureNode(
            id: 'exp-l',
            name: 'Lum 60s',
            durationSecs: 60,
            count: 1,
          ),
        ],
      );

      final result = simulator.simulate(sequence, start: start);

      expect(result.segments, hasLength(1));
      expect(result.targetWindows, isEmpty);
      expect(result.issues, isEmpty);
      expect(result.duration, const Duration(seconds: 62));
    });

    test('marks never-rising targets as blocking issues', () {
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-south',
          name: 'Far South Target',
          targetName: 'Far South',
          raHours: 12,
          decDegrees: -80,
        ),
      );

      final result = simulator.simulate(
        sequence,
        start: DateTime(2026, 5, 21, 22),
        latitude: 40,
        longitude: -75,
        minAltitude: 20,
      );

      expect(result.segments, isEmpty);
      expect(result.hasBlockingIssues, isTrue);
      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>()
              .having(
                (issue) => issue.severity,
                'severity',
                PreSessionSimulationSeverity.error,
              )
              .having(
                (issue) => issue.targetHeaderId,
                'target id',
                'target-south',
              )
              .having(
                (issue) => issue.message,
                'message',
                contains('never rises'),
              ),
        ),
      );
    });

    test('honors target startAfter when placing child segments', () {
      final start = DateTime(2026, 5, 21, 22);
      final startAfter = start.add(const Duration(hours: 1));
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-delayed',
          name: 'Delayed Target',
          targetName: 'Delayed',
          raHours: 13.5,
          decDegrees: 47.2,
          startAfter: startAfter,
        ),
        children: [
          ExposureNode(
            id: 'exp-delayed',
            name: 'Delayed Lum',
            durationSecs: 120,
            count: 1,
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
      );

      expect(result.segments.single.start, startAfter);
      expect(
        result.segments.single.end,
        startAfter.add(const Duration(seconds: 122)),
      );
      expect(result.duration, const Duration(hours: 1, seconds: 122));
    });

    test('uses per-target minAltitude when simulating visibility windows', () {
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-low',
          name: 'Low Target',
          targetName: 'Low Target',
          raHours: 12,
          decDegrees: -20,
          minAltitude: 50,
        ),
      );

      final result = simulator.simulate(
        sequence,
        start: DateTime(2026, 5, 21, 22),
        latitude: 40,
        longitude: -75,
        minAltitude: 20,
      );

      expect(result.hasBlockingIssues, isTrue);
      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>()
              .having(
                (issue) => issue.severity,
                'severity',
                PreSessionSimulationSeverity.error,
              )
              .having(
                (issue) => issue.targetHeaderId,
                'target id',
                'target-low',
              )
              .having(
                (issue) => issue.message,
                'message',
                contains('never rises'),
              ),
        ),
      );
    });

    test('warns when simulated work overruns target endBefore', () {
      final start = DateTime(2026, 5, 21, 22);
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-capped',
          name: 'Capped Target',
          targetName: 'Capped',
          raHours: 13.5,
          decDegrees: 47.2,
          endBefore: start.add(const Duration(minutes: 5)),
        ),
        children: [
          ExposureNode(
            id: 'exp-too-long',
            name: 'Long Lum',
            durationSecs: 300,
            count: 2,
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
      );

      expect(result.hasBlockingIssues, isFalse);
      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>()
              .having(
                (issue) => issue.severity,
                'severity',
                PreSessionSimulationSeverity.warning,
              )
              .having(
                (issue) => issue.message,
                'message',
                contains('after target end time'),
              ),
        ),
      );
    });

    test('honors startWhen TimeAfter when placing child segments', () {
      final start = DateTime(2026, 5, 21, 22);
      final startWhen = start.add(const Duration(minutes: 45));
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-trigger-delay',
          name: 'Trigger Delayed Target',
          targetName: 'Trigger Delayed',
          raHours: 13.5,
          decDegrees: 47.2,
          startWhen: TimeAfterTrigger(startWhen.millisecondsSinceEpoch ~/ 1000),
        ),
        children: [
          ExposureNode(
            id: 'exp-trigger-delayed',
            name: 'Trigger Delayed Lum',
            durationSecs: 60,
            count: 1,
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
      );

      expect(result.segments.single.start, startWhen);
      expect(result.duration, const Duration(minutes: 45, seconds: 62));
    });

    test('uses startWhen AltitudeAbove as a target visibility floor', () {
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-trigger-low',
          name: 'Low Trigger Target',
          targetName: 'Low Trigger',
          raHours: 12,
          decDegrees: -20,
          startWhen: const AltitudeAboveTrigger(50),
        ),
      );

      final result = simulator.simulate(
        sequence,
        start: DateTime(2026, 5, 21, 22),
        latitude: 40,
        longitude: -75,
        minAltitude: 20,
      );

      expect(result.hasBlockingIssues, isTrue);
      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>()
              .having(
                (issue) => issue.severity,
                'severity',
                PreSessionSimulationSeverity.error,
              )
              .having(
                (issue) => issue.targetHeaderId,
                'target id',
                'target-trigger-low',
              ),
        ),
      );
    });

    test('warns when simulated work overruns endWhen TimeAfter', () {
      final start = DateTime(2026, 5, 21, 22);
      final stopAt = start.add(const Duration(minutes: 5));
      final sequence = sequenceWith(
        target: TargetHeaderNode(
          id: 'target-trigger-capped',
          name: 'Trigger Capped Target',
          targetName: 'Trigger Capped',
          raHours: 13.5,
          decDegrees: 47.2,
          endWhen: TimeAfterTrigger(stopAt.millisecondsSinceEpoch ~/ 1000),
        ),
        children: [
          ExposureNode(
            id: 'exp-trigger-too-long',
            name: 'Trigger Long Lum',
            durationSecs: 300,
            count: 2,
          ),
        ],
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
      );

      expect(
        result.issues,
        contains(
          isA<PreSessionSimulationIssue>().having(
            (issue) => issue.message,
            'message',
            contains('after target end time'),
          ),
        ),
      );
    });
    test('a sequence that ends in a Count loop is billed for every iteration, '
        'the same total the Builder estimate chip shows', () {
      // The Builder's estimate chip reads SequenceTimeEstimator
      // .estimateTotalDuration; Pre-Flight's "Duration"/"Ends" pair reads
      // this simulation. `estimateSequenceTiming` renders ONE pass of a
      // Count loop (each entry carries a "Showing 1 of N" note) while
      // advancing its own clock by the whole loop, so taking the last
      // rendered segment's end billed the pre-flight for a single
      // iteration and the two surfaces printed different totals for one
      // sequence.
      final start = DateTime(2026, 5, 21, 22);
      const estimator = SequenceTimeEstimator();
      final exposure = ExposureNode(
        id: 'exp-loop-body',
        name: 'Lum 120s',
        durationSecs: 120,
        count: 2,
        filter: 'L',
      );
      final loop = LoopNode(
        id: 'loop-3x',
        name: 'Loop 3x',
        conditionType: LoopConditionType.count,
        repeatCount: 3,
        childIds: const ['exp-loop-body'],
      );
      final target = TargetHeaderNode(
        id: 'target-m31',
        name: 'M31 Target',
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
        childIds: const ['loop-3x'],
      );
      final sequence = Sequence.create(
        name: 'Loop Simulation',
        nodes: {
          'target-m31': target,
          'loop-3x': loop.copyWith(parentId: 'target-m31'),
          'exp-loop-body': exposure.copyWith(parentId: 'loop-3x'),
        },
      );

      final result = simulator.simulate(
        sequence,
        start: start,
        latitude: 40,
        longitude: -75,
      );
      final builderChipTotal = estimator.estimateTotalDuration(
        sequence,
        start,
        latitude: 40,
        longitude: -75,
      );

      // One pass of the body; three of them must be billed.
      final onePass = result.segments.last.end.difference(start);
      expect(result.duration, builderChipTotal);
      expect(result.duration, onePass * 3);
      expect(result.end, start.add(builderChipTotal));
    });
  });
}
