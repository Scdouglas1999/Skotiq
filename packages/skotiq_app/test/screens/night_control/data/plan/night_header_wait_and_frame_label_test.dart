// What the header says about the step under way: why a run holds its next
// frame, and what kind of frame it is taking.
//
// The header says why a run holds its next frame for a meridian flip. The
// engine reports the hold as the running step's progress detail, not as the
// run's message (which "Progress: n/N exposures" overwrites after every
// update), so this is the field the header has to read.

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

  test('a flip hold on the running step shows on the header', () {
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        message: 'Progress: 3/175 exposures',
        nodeStatuses: {'m74-l': NodeStatus.running},
        nodeProgressDetail: {
          'm74-l': 'Waiting for the meridian flip before the next 120s '
              'exposure: the flip fires in ~70s (hour angle +0.06h, '
              'threshold 5 min past meridian) and would interrupt the frame',
        },
      )),
      'Waiting for the flip',
    );
  });

  test('the step back at work clears it', () {
    expect(
      waitingFor(const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        nodeStatuses: {'m74-l': NodeStatus.running},
        nodeProgressDetail: {'m74-l': 'Frame 4/30 (120.0s)'},
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
        nodeProgressDetail: {
          'ngc891-ha': 'Waiting for the meridian flip before the next frame',
        },
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

  // The end-of-night darks run a plan of their own, which a linked phone
  // never holds: its header read "G 55 s" (night test finding 40).
  test('an end-of-night dark reads as a dark too', () {
    for (final (id, label) in [
      ('eon-dark-3', 'Dark'),
      ('eon-bias-4', 'Bias')
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
          nodeStatuses: {id: NodeStatus.running},
        ),
      );
      addTearDown(container.dispose);
      expect(container.read(nightHeaderProvider).currentFilter, label);
    }
  });
}
