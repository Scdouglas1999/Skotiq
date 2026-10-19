// The Steps list and the header's progress line while a run is live.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import 'plan_test_support.dart';

void main() {
  final evening = DateTime(2026, 10, 19, 20, 10);

  test('no plan: no steps', () {
    final container = planContainer(now: evening);
    addTearDown(container.dispose);

    expect(container.read(nightPlanStepsProvider), isEmpty);
  });

  test('before a run every step is pending with a planned time', () {
    final plan = TwoTargetPlan();
    final container = planContainer(now: evening, sequence: plan.sequence);
    addTearDown(container.dispose);

    final steps = container.read(nightPlanStepsProvider);
    expect(steps.map((s) => s.nodeId), ['m74-l', 'ngc891-ha', 'warm']);
    expect(steps.map((s) => s.label),
        ['L 3 × 60 s', 'Ha 2 × 120 s', 'Warm Camera']);
    expect(steps.map((s) => s.depth), [1, 1, 0]);
    expect(steps.every((s) => s.status == PlanStepStatus.pending), isTrue);
    expect(steps.every((s) => s.when is StepWhenPlanned), isTrue);
    final starts = steps.map((s) => (s.when! as StepWhenPlanned).at).toList();
    expect(starts.first, evening, reason: 'anchored at now before a run');
    expect(starts[1].isAfter(starts[0]), isTrue);
    expect(starts[2].isAfter(starts[1]), isTrue);
  });

  test('running: the active step shows its frames, a finished one its time',
      () {
    final plan = TwoTargetPlan();
    final sessionStart = DateTime(2026, 10, 19, 19, 50);
    final finishedAt = DateTime(2026, 10, 19, 19, 54, 30);
    final container = planContainer(
      now: evening,
      sequence: plan.sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(isActive: true, startTime: sessionStart),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'ngc891-ha',
        currentTarget: 'NGC 891',
        currentFilter: 'Ha',
        nodeStatuses: {
          'm74': NodeStatus.success,
          'm74-l': NodeStatus.success,
          'ngc891': NodeStatus.running,
          'ngc891-ha': NodeStatus.running,
        },
        nodeProgressStructuredDetail: {
          'ngc891-ha': ExposureInstructionProgressDetail(
            frame: 1,
            total: 2,
            durationSecs: 120,
          ),
        },
      ),
      events: [
        nodeEvent('m74-l', finishedAt, completedStatus: 'success'),
        // A finish from an earlier run of the same plan must not show.
        nodeEvent(
          'ngc891-ha',
          DateTime(2026, 10, 18, 23),
          completedStatus: 'success',
        ),
      ],
    );
    addTearDown(container.dispose);

    final steps = container.read(nightPlanStepsProvider);
    expect(steps[0].status, PlanStepStatus.done);
    expect(steps[0].when, StepWhenActual(finishedAt));
    expect(steps[1].status, PlanStepStatus.active);
    expect(steps[1].when, const StepWhenProgress(1, 2));
    expect(steps[2].status, PlanStepStatus.pending);
    expect(steps[2].when, isA<StepWhenPlanned>());

    final header = container.read(nightHeaderProvider);
    expect(header.runStartedAt, sessionStart);
    expect(header.targetIndex, 2);
    expect(header.targetCount, 2);
    expect(header.stepIndex, 2);
    expect(header.stepCount, 3);
    expect(header.currentFilter, 'Ha');
    expect(header.currentExposureSecs, 120);
    expect(header.framesDone, 1);
    expect(header.framesTotal, 2);
  });

  test('an active step with no frame reported yet shows its planned time', () {
    final plan = TwoTargetPlan();
    final container = planContainer(
      now: evening,
      sequence: plan.sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        nodeStatuses: {'m74-l': NodeStatus.running},
      ),
    );
    addTearDown(container.dispose);

    final active = container.read(nightPlanStepsProvider).first;
    expect(active.status, PlanStepStatus.active);
    expect(active.when, isA<StepWhenPlanned>(),
        reason: 'not a "0/3" the run never reported');
    final header = container.read(nightHeaderProvider);
    expect(header.framesDone, isNull);
    expect(header.framesTotal, isNull);
  });

  test('statuses a previous run left do not mark a waiting plan done', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      progress: const SequenceProgress(
        nodeStatuses: {'m74-l': NodeStatus.success},
      ),
    );
    addTearDown(container.dispose);

    expect(
      container.read(nightPlanStepsProvider).first.status,
      PlanStepStatus.pending,
    );
  });
}
