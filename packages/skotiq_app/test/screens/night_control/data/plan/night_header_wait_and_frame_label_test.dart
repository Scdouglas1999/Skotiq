// What the header says about the step under way: why a run holds its next
// frame, and what kind of frame it is taking.
//
// The engine reports a hold or a wait as the step's report, by its kind; the
// run's message is overwritten by "Progress: n/N exposures" after every
// update, so the step's report is what the header reads.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'plan_test_support.dart';

void main() {
  final evening = bostonTime(2026, 10, 19, 20, 10);

  String? waitingFor(SequenceProgress progress) {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: bostonTime(2026, 10, 19, 19, 50),
      ),
      progress: progress,
    );
    addTearDown(container.dispose);
    return container.read(nightHeaderProvider).waitingFor;
  }

  const flipHold = FlipHoldProgressDetail(
    exposureSecs: 120,
    firesInSecs: 70,
    hourAngleHours: 0.06,
    thresholdMin: 5,
  );

  test('a flip hold on the running step shows on the header', () {
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        message: 'Progress: 3/175 exposures',
        nodeStatuses: {'m74-l': NodeStatus.running},
        nodeLatestReport: {'m74-l': flipHold},
      )),
      'Waiting for the flip',
    );
  });

  test('a target waiting to start shows its own words', () {
    const words = 'Waiting for M74 to clear the altitude floor: 12° up, '
        'floor 25° in that direction';
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74',
        nodeStatuses: {'m74': NodeStatus.running},
        nodeProgressDetail: {'m74': words},
        nodeLatestReport: {
          'm74': TargetWaitingProgressDetail(
            target: 'M74',
            condition: 'above the site\'s altitude floor',
            altitudeDeg: 12,
            floorDeg: 25,
          ),
        },
      )),
      words,
    );
  });

  test('a step that only says "Waiting for" is not a wait', () {
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        nodeStatuses: {'m74-l': NodeStatus.running},
        nodeProgressDetail: {
          'm74-l': 'Waiting for the meridian flip before the next frame',
        },
        nodeLatestReport: {
          'm74-l': UnknownInstructionProgressDetail(
            kind: kGenericProgressDetailKind,
            rawJson: {},
          ),
        },
      )),
      isNull,
    );
  });

  test('the step back at work clears it', () {
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        nodeStatuses: {'m74-l': NodeStatus.running},
        nodeProgressDetail: {'m74-l': 'Frame 4/30 (120.0s)'},
        nodeLatestReport: {
          'm74-l': ExposureInstructionProgressDetail(
            frame: 4,
            total: 30,
            durationSecs: 120,
          ),
        },
      )),
      isNull,
    );
  });

  test('a hold left on another step is not this step\'s wait', () {
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        nodeStatuses: {'m74-l': NodeStatus.running},
        nodeLatestReport: {'ngc891-ha': flipHold},
      )),
      isNull,
    );
  });

  test('a dark reads as a dark, not as the filter the wheel was left on', () {
    final plan = TwoTargetPlan().sequence;
    final dark = (plan.nodes['m74-l']! as ExposureNode)
        .copyWith(frameType: FrameType.dark);
    final container = planContainer(
      now: evening,
      sequence: plan.copyWith(nodes: {...plan.nodes, 'm74-l': dark}),
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: bostonTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        currentFilter: 'G',
        nodeStatuses: {'m74-l': NodeStatus.running},
      ),
    );
    addTearDown(container.dispose);
    expect(container.read(nightHeaderProvider).currentFilter, 'Dark');
  });

  test('a flat reads as a flat through the filter it is taken in', () {
    final plan = TwoTargetPlan().sequence;
    final flat = (plan.nodes['m74-l']! as ExposureNode)
        .copyWith(frameType: FrameType.flat);
    final container = planContainer(
      now: evening,
      sequence: plan.copyWith(nodes: {...plan.nodes, 'm74-l': flat}),
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: bostonTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        currentFilter: 'Ha',
        nodeStatuses: {'m74-l': NodeStatus.running},
      ),
    );
    addTearDown(container.dispose);
    expect(container.read(nightHeaderProvider).currentFilter, 'Flat Ha');
  });

  // A plan the phone does not hold (the end-of-night darks, a dark plan the
  // desktop started): the run engine names the step's frame type when the
  // step starts. Its header read "G 55 s" (night test finding 40).
  test('a dark from a plan the phone does not hold reads as a dark', () {
    for (final (id, frameType, label) in [
      ('eon-dark-3', FrameType.dark, 'Dark'),
      ('eon-bias-4', FrameType.bias, 'Bias'),
      ('darks-30s', FrameType.dark, 'Dark'),
    ]) {
      final container = planContainer(
        now: evening,
        sequence: TwoTargetPlan().sequence,
        execution: SequenceExecutionState.running,
        session: SessionState(
          isActive: true,
          startTime: bostonTime(2026, 10, 19, 19, 50),
        ),
        progress: SequenceProgress(
          state: SequenceExecutionState.running,
          currentNodeId: id,
          currentFilter: 'G',
          currentFrameType: frameType,
          nodeStatuses: {id: NodeStatus.running},
        ),
      );
      addTearDown(container.dispose);
      expect(container.read(nightHeaderProvider).currentFilter, label);
    }
  });
}
