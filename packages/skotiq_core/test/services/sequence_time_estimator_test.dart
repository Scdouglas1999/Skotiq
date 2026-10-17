import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('SequenceTimeEstimator', () {
    late SequenceTimeEstimator estimator;

    setUp(() {
      estimator = const SequenceTimeEstimator();
    });

    /// Helper to create a test sequence with nodes
    Sequence createSequence({
      String? rootNodeId,
      Map<String, SequenceNode>? nodes,
    }) {
      return Sequence.create(
        name: 'Test Sequence',
        rootNodeId: rootNodeId,
        nodes: nodes ?? {},
      );
    }

    group('estimateSequenceTiming', () {
      test('returns empty list for empty sequence', () {
        final sequence = createSequence();
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        expect(timings, isEmpty);
      });

      test(
        'returns empty list for sequence with no root and no target headers',
        () {
          final sequence = createSequence(
            nodes: {
              'exposure1': ExposureNode(
                id: 'exposure1',
                name: 'Light 300s',
                durationSecs: 300,
                count: 10,
              ),
            },
          );
          final startTime = DateTime(2024, 6, 15, 22, 0);

          final timings = estimator.estimateSequenceTiming(sequence, startTime);

          // No root node and no target headers means empty result
          expect(timings, isEmpty);
        },
      );

      test('estimates ExposureNode duration correctly', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 300s',
          durationSecs: 300,
          count: 10,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'M31 Target',
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
          childIds: const ['exposure1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'exposure1': exposureNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        // Find the exposure node timing
        final exposureTiming = timings.firstWhere(
          (t) => t.nodeType == 'TakeExposure',
        );

        // 10 exposures * 300s + 10 * 2s download overhead = 3020s
        expect(exposureTiming.duration.inSeconds, equals(3020));
      });

      test('estimates AutofocusNode duration correctly', () {
        final autofocusNode = AutofocusNode(
          id: 'af1',
          name: 'Autofocus',
          stepsOut: 7,
          exposuresPerPoint: 1,
          exposureDuration: 3.0,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'M31 Target',
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
          childIds: const ['af1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'af1': autofocusNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final afTiming = timings.firstWhere((t) => t.nodeType == 'Autofocus');

        // (7 * 2 + 1) data points * 1 exposure * 3s = 15 * 1 * 3 = 45s
        expect(afTiming.duration.inSeconds, equals(45));
      });

      test('estimates DitherNode duration correctly', () {
        final ditherNode = DitherNode(
          id: 'dither1',
          name: 'Dither',
          settleTime: 10.0,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['dither1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'dither1': ditherNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final ditherTiming = timings.firstWhere((t) => t.nodeType == 'Dither');

        // Uses settleTime when > 0
        expect(ditherTiming.duration.inSeconds, equals(10));
      });

      test(
        'estimates DitherNode with default duration when settleTime is zero',
        () {
          final ditherNode = DitherNode(
            id: 'dither1',
            name: 'Dither',
            settleTime: 0.0, // Zero settle time
          );
          final targetNode = TargetHeaderNode(
            id: 'target1',
            name: 'Test Target',
            targetName: 'Test',
            raHours: 12.0,
            decDegrees: 45.0,
            childIds: const ['dither1'],
          );

          final sequence = createSequence(
            nodes: {
              'target1': targetNode,
              'dither1': ditherNode.copyWith(parentId: 'target1'),
            },
          );
          final startTime = DateTime(2024, 6, 15, 22, 0);

          final timings = estimator.estimateSequenceTiming(sequence, startTime);

          final ditherTiming = timings.firstWhere(
            (t) => t.nodeType == 'Dither',
          );

          // Uses default of 5 seconds
          expect(ditherTiming.duration.inSeconds, equals(5));
        },
      );

      test('estimates DelayNode duration correctly', () {
        final delayNode = DelayNode(id: 'delay1', name: 'Delay', seconds: 30.0);
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['delay1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'delay1': delayNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final delayTiming = timings.firstWhere((t) => t.nodeType == 'Delay');

        expect(delayTiming.duration.inSeconds, equals(30));
      });

      test('estimates SlewNode duration correctly', () {
        final slewNode = SlewNode(id: 'slew1', name: 'Slew to Target');
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['slew1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'slew1': slewNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final slewTiming = timings.firstWhere(
          (t) => t.nodeType == 'SlewToTarget',
        );

        // Default slew duration is 30 seconds
        expect(slewTiming.duration.inSeconds, equals(30));
      });

      test('calculates cumulative timing correctly', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 5, // 5 * 60 + 5 * 2 = 310s
        );
        final delayNode = DelayNode(id: 'delay1', name: 'Delay', seconds: 30.0);
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['exposure1', 'delay1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'exposure1': exposureNode.copyWith(
              parentId: 'target1',
              orderIndex: 0,
            ),
            'delay1': delayNode.copyWith(parentId: 'target1', orderIndex: 1),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        // Find the delay node timing (it should come after exposure)
        final delayTiming = timings.firstWhere((t) => t.nodeType == 'Delay');

        // Delay should start after exposure ends
        final exposureTiming = timings.firstWhere(
          (t) => t.nodeType == 'TakeExposure',
        );
        expect(delayTiming.estimatedStart, equals(exposureTiming.estimatedEnd));
      });

      test('skips disabled nodes', () {
        final enabledExposure = ExposureNode(
          id: 'exposure1',
          name: 'Enabled Light',
          durationSecs: 60,
          count: 5,
          isEnabled: true,
        );
        final disabledExposure = ExposureNode(
          id: 'exposure2',
          name: 'Disabled Light',
          durationSecs: 120,
          count: 10,
          isEnabled: false, // Disabled
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['exposure1', 'exposure2'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'exposure1': enabledExposure.copyWith(parentId: 'target1'),
            'exposure2': disabledExposure.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        // Should only have one exposure timing (enabled one)
        final exposureTimings = timings.where(
          (t) => t.nodeType == 'TakeExposure',
        );
        expect(exposureTimings, hasLength(1));
        expect(exposureTimings.first.nodeName, equals('Enabled Light'));
      });

      test('estimates WaitTimeNode with waitUntil', () {
        final startTime = DateTime(2024, 6, 15, 22, 0);
        final waitUntil = DateTime(2024, 6, 15, 23, 30); // 1.5 hours later

        final waitNode = WaitTimeNode(
          id: 'wait1',
          name: 'Wait for Dark',
          waitUntil: waitUntil,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['wait1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'wait1': waitNode.copyWith(parentId: 'target1'),
          },
        );

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final waitTiming = timings.firstWhere(
          (t) => t.nodeType == 'WaitForTime',
        );

        // Should wait 1.5 hours = 90 minutes = 5400 seconds
        expect(waitTiming.duration.inMinutes, equals(90));
      });

      test('estimates CoolCameraNode duration', () {
        final coolNode = CoolCameraNode(
          id: 'cool1',
          name: 'Cool Camera',
          targetTemp: -10.0,
          durationMins: 15.0,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['cool1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'cool1': coolNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final coolTiming = timings.firstWhere(
          (t) => t.nodeType == 'CoolCamera',
        );

        expect(coolTiming.duration.inMinutes, equals(15));
      });

      test('estimates MeridianFlipNode duration with autoCenter', () {
        final flipNode = MeridianFlipNode(
          id: 'flip1',
          name: 'Meridian Flip',
          autoCenter: true,
          settleTime: 10.0,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['flip1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'flip1': flipNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final flipTiming = timings.firstWhere(
          (t) => t.nodeType == 'MeridianFlip',
        );

        // 120s base + 30s center + 10s settle = 160s
        expect(flipTiming.duration.inSeconds, equals(160));
      });

      test('estimates StartGuidingNode duration', () {
        final guideNode = StartGuidingNode(
          id: 'guide1',
          name: 'Start Guiding',
          settleTimeout: 45.0,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['guide1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'guide1': guideNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        final guideTiming = timings.firstWhere(
          (t) => t.nodeType == 'StartGuiding',
        );

        expect(guideTiming.duration.inSeconds, equals(45));
      });

      test('handles LoopNode with single iteration estimate', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 5,
        );
        final loopNode = LoopNode(
          id: 'loop1',
          name: 'Loop 3x',
          conditionType: LoopConditionType.count,
          repeatCount: 3,
          childIds: const ['exposure1'],
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['loop1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'loop1': loopNode.copyWith(parentId: 'target1'),
            'exposure1': exposureNode.copyWith(parentId: 'loop1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        // Loop shows single iteration in timeline but adds warning
        final exposureTiming = timings.firstWhere(
          (t) => t.nodeType == 'TakeExposure',
        );
        expect(exposureTiming.warnings, isNotNull);
        expect(
          exposureTiming.warnings!.any((w) => w.contains('1 of 3')),
          isTrue,
        );
      });

      test('Count loop multiplies body duration by the loop factor in the '
          'cumulative timeline', () {
        // Loop(count=10) over a 5x60s exposure body (= 5*60 + 5*2 = 310s).
        // The total must reflect 10 iterations (3100s), not a single pass.
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 5, // 310s per pass
        );
        final loopNode = LoopNode(
          id: 'loop1',
          name: 'Loop 10x',
          conditionType: LoopConditionType.count,
          repeatCount: 10,
          childIds: const ['exposure1'],
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['loop1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'loop1': loopNode.copyWith(parentId: 'target1'),
            'exposure1': exposureNode.copyWith(parentId: 'loop1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final total = estimator.estimateTotalDuration(sequence, startTime);

        // 10 iterations * 310s = 3100s.
        expect(total.inSeconds, equals(3100));
      });

      test('A trailing node after a Count loop starts after the full loop, '
          'not one pass', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 1, // 60 + 2 = 62s per pass
        );
        final loopNode = LoopNode(
          id: 'loop1',
          name: 'Loop 4x',
          conditionType: LoopConditionType.count,
          repeatCount: 4,
          childIds: const ['exposure1'],
        );
        final delayNode = DelayNode(id: 'delay1', name: 'Delay', seconds: 30.0);
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['loop1', 'delay1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'loop1': loopNode.copyWith(parentId: 'target1', orderIndex: 0),
            'exposure1': exposureNode.copyWith(parentId: 'loop1'),
            'delay1': delayNode.copyWith(parentId: 'target1', orderIndex: 1),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);
        final delayTiming = timings.firstWhere((t) => t.nodeType == 'Delay');

        // Loop body = 62s/pass * 4 = 248s, so the delay starts 248s after
        // the loop's start (22:00 + 248s = 22:04:08).
        expect(
          delayTiming.estimatedStart,
          equals(startTime.add(const Duration(seconds: 248))),
        );
      });

      test('Unbounded loop keeps the single-iteration estimate (no factor '
          'multiplication)', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 5, // 310s per pass
        );
        final loopNode = LoopNode(
          id: 'loop1',
          name: 'Forever',
          conditionType: LoopConditionType.forever,
          maxSafetyIterations: 100,
          childIds: const ['exposure1'],
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['loop1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'loop1': loopNode.copyWith(parentId: 'target1'),
            'exposure1': exposureNode.copyWith(parentId: 'loop1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final total = estimator.estimateTotalDuration(sequence, startTime);

        // Unbounded loops can't be statically counted, so the estimate is a
        // single pass (310s).
        expect(total.inSeconds, equals(310));
      });

      test('NotificationNode has zero duration', () {
        final notifyNode = NotificationNode(
          id: 'notify1',
          name: 'Notify',
          title: 'Test',
          message: 'Test message',
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['notify1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'notify1': notifyNode.copyWith(parentId: 'target1'),
          },
        );
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final timings = estimator.estimateSequenceTiming(sequence, startTime);

        // NotificationNode has zero duration, so it won't appear in timings
        expect(timings.where((t) => t.nodeType == 'Notification'), isEmpty);
      });
    });

    group('calculateTargetWindows', () {
      test('calculates visibility window for target', () {
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Vega',
          targetName: 'Vega',
          raHours: 18.6, // Vega RA
          decDegrees: 38.8, // Vega Dec
        );

        final sequence = createSequence(nodes: {'target1': targetNode});

        final date = DateTime(2024, 6, 15, 22, 0);
        final windows = estimator.calculateTargetWindows(
          sequence,
          date,
          latitude: 40.0,
          longitude: -75.0,
        );

        expect(windows, hasLength(1));
        expect(windows.containsKey('target1'), isTrue);

        final window = windows['target1']!;
        expect(window.targetName, equals('Vega'));
        expect(window.neverRises, isFalse);
        // Vega is circumpolar at high northern latitudes but not at 40N
        // It should have rise/transit/set times
        expect(window.transitAltitude, isNotNull);
        expect(window.transitAltitude, greaterThan(0));
      });

      test('identifies never-rising targets', () {
        // Target at Dec -80 will never rise above horizon at 40N
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Southern Target',
          targetName: 'Southern',
          raHours: 12.0,
          decDegrees: -80.0,
        );

        final sequence = createSequence(nodes: {'target1': targetNode});

        final date = DateTime(2024, 6, 15, 22, 0);
        final windows = estimator.calculateTargetWindows(
          sequence,
          date,
          latitude: 40.0,
          longitude: -75.0,
          minAltitude: 10.0,
        );

        final window = windows['target1']!;
        expect(window.neverRises, isTrue);
      });

      test('identifies circumpolar targets', () {
        // Target at Dec +85 will be circumpolar at 40N (90 - 40 = 50, 85 > 50)
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Polar Target',
          targetName: 'Polaris-like',
          raHours: 2.5,
          decDegrees: 85.0,
        );

        final sequence = createSequence(nodes: {'target1': targetNode});

        final date = DateTime(2024, 6, 15, 22, 0);
        final windows = estimator.calculateTargetWindows(
          sequence,
          date,
          latitude: 40.0,
          longitude: -75.0,
          minAltitude: 0.0,
        );

        final window = windows['target1']!;
        // Should be circumpolar or have very long visibility
        expect(window.neverRises, isFalse);
        expect(window.transitAltitude, greaterThan(40.0)); // High transit
      });

      test('skips disabled target headers', () {
        final enabledTarget = TargetHeaderNode(
          id: 'target1',
          name: 'Enabled',
          targetName: 'Enabled Target',
          raHours: 12.0,
          decDegrees: 45.0,
          isEnabled: true,
        );
        final disabledTarget = TargetHeaderNode(
          id: 'target2',
          name: 'Disabled',
          targetName: 'Disabled Target',
          raHours: 14.0,
          decDegrees: 45.0,
          isEnabled: false,
        );

        final sequence = createSequence(
          nodes: {'target1': enabledTarget, 'target2': disabledTarget},
        );

        final date = DateTime(2024, 6, 15, 22, 0);
        final windows = estimator.calculateTargetWindows(
          sequence,
          date,
          latitude: 40.0,
          longitude: -75.0,
        );

        expect(windows, hasLength(1));
        expect(windows.containsKey('target1'), isTrue);
        expect(windows.containsKey('target2'), isFalse);
      });
    });

    group('findTimingConflicts', () {
      test('detects conflict when node runs after target sets', () {
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
        );
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Long Exposure',
          durationSecs: 300,
          count: 10,
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'exposure1': exposureNode.copyWith(parentId: 'target1'),
          },
        );

        // Create timings that extend past set time
        final timings = [
          NodeTiming(
            nodeId: 'exposure1',
            nodeName: 'Long Exposure',
            nodeType: 'TakeExposure',
            estimatedStart: DateTime(2024, 6, 15, 4, 0), // 4 AM
            estimatedEnd: DateTime(2024, 6, 15, 5, 0), // 5 AM
            duration: const Duration(hours: 1),
            targetHeaderId: 'target1',
          ),
        ];

        // Create a window where target sets at 4:30 AM
        final windows = {
          'target1': TargetWindow(
            targetId: 'target1',
            targetName: 'Test',
            riseTime: DateTime(2024, 6, 14, 20, 0),
            transitTime: DateTime(2024, 6, 15, 0, 0),
            setTime: DateTime(2024, 6, 15, 4, 30), // Sets at 4:30 AM
            transitAltitude: 75.0,
          ),
        };

        final conflicts = estimator.findTimingConflicts(
          timings,
          windows,
          sequence,
        );

        expect(conflicts, isNotEmpty);
        expect(conflicts.any((c) => c.contains('after target sets')), isTrue);
      });

      test('detects conflict when node runs before target rises', () {
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
        );

        final sequence = createSequence(nodes: {'target1': targetNode});

        // Create timings that start before rise time
        final timings = [
          NodeTiming(
            nodeId: 'exposure1',
            nodeName: 'Early Exposure',
            nodeType: 'TakeExposure',
            estimatedStart: DateTime(2024, 6, 15, 19, 0), // 7 PM
            estimatedEnd: DateTime(2024, 6, 15, 19, 30), // 7:30 PM
            duration: const Duration(minutes: 30),
            targetHeaderId: 'target1',
          ),
        ];

        // Create a window where target rises at 8 PM
        final windows = {
          'target1': TargetWindow(
            targetId: 'target1',
            targetName: 'Test',
            riseTime: DateTime(2024, 6, 15, 20, 0), // Rises at 8 PM
            transitTime: DateTime(2024, 6, 16, 0, 0),
            setTime: DateTime(2024, 6, 16, 4, 0),
            transitAltitude: 75.0,
          ),
        };

        final conflicts = estimator.findTimingConflicts(
          timings,
          windows,
          sequence,
        );

        expect(conflicts, isNotEmpty);
        expect(conflicts.any((c) => c.contains('before target rises')), isTrue);
      });

      test('reports never-rising target as conflict', () {
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Southern Target',
          targetName: 'Southern',
          raHours: 12.0,
          decDegrees: -80.0,
        );

        final sequence = createSequence(nodes: {'target1': targetNode});

        final timings = [
          NodeTiming(
            nodeId: 'exposure1',
            nodeName: 'Impossible Exposure',
            nodeType: 'TakeExposure',
            estimatedStart: DateTime(2024, 6, 15, 22, 0),
            estimatedEnd: DateTime(2024, 6, 15, 23, 0),
            duration: const Duration(hours: 1),
            targetHeaderId: 'target1',
          ),
        ];

        final windows = {
          'target1': TargetWindow(
            targetId: 'target1',
            targetName: 'Southern',
            neverRises: true,
          ),
        };

        final conflicts = estimator.findTimingConflicts(
          timings,
          windows,
          sequence,
        );

        expect(conflicts, isNotEmpty);
        expect(conflicts.any((c) => c.contains('never rises')), isTrue);
      });

      test('no conflicts for circumpolar target', () {
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Polar Target',
          targetName: 'Polaris',
          raHours: 2.5,
          decDegrees: 89.0,
        );

        final sequence = createSequence(nodes: {'target1': targetNode});

        final timings = [
          NodeTiming(
            nodeId: 'exposure1',
            nodeName: 'Night Exposure',
            nodeType: 'TakeExposure',
            estimatedStart: DateTime(2024, 6, 15, 22, 0),
            estimatedEnd: DateTime(2024, 6, 15, 23, 0),
            duration: const Duration(hours: 1),
            targetHeaderId: 'target1',
          ),
        ];

        final windows = {
          'target1': TargetWindow(
            targetId: 'target1',
            targetName: 'Polaris',
            isCircumpolar: true,
            transitAltitude: 50.0,
          ),
        };

        final conflicts = estimator.findTimingConflicts(
          timings,
          windows,
          sequence,
        );

        // No conflicts for circumpolar targets
        expect(conflicts, isEmpty);
      });

      test('skips nodes without target header', () {
        final sequence = createSequence();

        final timings = [
          NodeTiming(
            nodeId: 'exposure1',
            nodeName: 'Orphan Exposure',
            nodeType: 'TakeExposure',
            estimatedStart: DateTime(2024, 6, 15, 22, 0),
            estimatedEnd: DateTime(2024, 6, 15, 23, 0),
            duration: const Duration(hours: 1),
            targetHeaderId: null, // No target header
          ),
        ];

        final windows = <String, TargetWindow>{};

        final conflicts = estimator.findTimingConflicts(
          timings,
          windows,
          sequence,
        );

        // Should not produce conflicts for nodes without target headers
        expect(conflicts, isEmpty);
      });
    });

    group('analyzeSequence', () {
      test('performs full analysis combining all functions', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 300s',
          durationSecs: 300,
          count: 10,
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'M31 Target',
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
          childIds: const ['exposure1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'exposure1': exposureNode.copyWith(parentId: 'target1'),
          },
        );

        final startTime = DateTime(
          2024,
          9,
          15,
          22,
          0,
        ); // Good viewing time for M31

        final result = estimator.analyzeSequence(
          sequence,
          startTime,
          latitude: 40.0,
          longitude: -75.0,
        );

        // Should return all three components
        expect(result.timings, isNotEmpty);
        expect(result.windows, isNotEmpty);
        expect(result.windows.containsKey('target1'), isTrue);
        // Conflicts may or may not be present depending on timing
        expect(result.conflicts, isA<List<String>>());
      });
    });

    group('estimateTotalDuration', () {
      test('calculates total duration for simple sequence', () {
        final exposureNode = ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 10, // 10 * 60 + 10 * 2 = 620s
        );
        final targetNode = TargetHeaderNode(
          id: 'target1',
          name: 'Test Target',
          targetName: 'Test',
          raHours: 12.0,
          decDegrees: 45.0,
          childIds: const ['exposure1'],
        );

        final sequence = createSequence(
          nodes: {
            'target1': targetNode,
            'exposure1': exposureNode.copyWith(parentId: 'target1'),
          },
        );

        final startTime = DateTime(2024, 6, 15, 22, 0);
        final duration = estimator.estimateTotalDuration(sequence, startTime);

        // 620 seconds
        expect(duration.inSeconds, equals(620));
      });

      test('returns zero for empty sequence', () {
        final sequence = createSequence();
        final startTime = DateTime(2024, 6, 15, 22, 0);

        final duration = estimator.estimateTotalDuration(sequence, startTime);

        expect(duration, equals(Duration.zero));
      });
    });

    group('TargetWindow.isVisibleAt', () {
      test('returns false for never-rising target', () {
        final window = TargetWindow(
          targetId: 'test',
          targetName: 'Test',
          neverRises: true,
        );

        expect(window.isVisibleAt(DateTime.now()), isFalse);
      });

      test('returns true for circumpolar target', () {
        final window = TargetWindow(
          targetId: 'test',
          targetName: 'Test',
          isCircumpolar: true,
        );

        expect(window.isVisibleAt(DateTime.now()), isTrue);
      });

      test('returns true for time within normal window', () {
        final window = TargetWindow(
          targetId: 'test',
          targetName: 'Test',
          riseTime: DateTime(2024, 6, 15, 20, 0), // 8 PM
          transitTime: DateTime(2024, 6, 16, 0, 0),
          setTime: DateTime(2024, 6, 16, 4, 0), // 4 AM next day
        );

        // 10 PM should be visible
        expect(window.isVisibleAt(DateTime(2024, 6, 15, 22, 0)), isTrue);
      });

      test('returns false for time outside window', () {
        final window = TargetWindow(
          targetId: 'test',
          targetName: 'Test',
          riseTime: DateTime(2024, 6, 15, 20, 0), // 8 PM
          transitTime: DateTime(2024, 6, 16, 0, 0),
          setTime: DateTime(2024, 6, 16, 4, 0), // 4 AM
        );

        // 6 PM should not be visible (before rise)
        expect(window.isVisibleAt(DateTime(2024, 6, 15, 18, 0)), isFalse);
        // 6 AM should not be visible (after set)
        expect(window.isVisibleAt(DateTime(2024, 6, 16, 6, 0)), isFalse);
      });

      test('returns false when rise/set times are null', () {
        final window = TargetWindow(
          targetId: 'test',
          targetName: 'Test',
          riseTime: null,
          setTime: null,
        );

        expect(window.isVisibleAt(DateTime.now()), isFalse);
      });
    });
  });
}
