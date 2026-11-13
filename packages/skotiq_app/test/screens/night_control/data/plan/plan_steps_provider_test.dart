// The Steps list and the header's progress line while a run is live.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

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

  // The run gives a Smart Exposure looping until stopped no total and ignores
  // its per-filter counts, so the step's frames have no planned number.
  test('an active Smart Exposure looping until stopped shows frames, no total',
      () {
    const rootId = 'root';
    final target = TargetHeaderNode(
      id: 'm31',
      targetName: 'M31',
      raHours: 0.712,
      decDegrees: 41.269,
      parentId: rootId,
      childIds: const ['m31-smart'],
    );
    final smart = SmartExposureNode(
      id: 'm31-smart',
      parentId: 'm31',
      loopUntilStopped: true,
      plans: const [
        FilterPlan(filterName: 'L', count: 20),
        FilterPlan(filterName: 'R', count: 10),
      ],
    );
    final root = InstructionSetNode(
      id: rootId,
      name: 'Tonight',
      childIds: const ['m31'],
    );
    final sequence = Sequence.create(
      name: 'Loop plan',
      rootNodeId: rootId,
      nodes: {rootId: root, 'm31': target, 'm31-smart': smart},
    );
    final container = planContainer(
      now: evening,
      sequence: sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm31-smart',
        nodeStatuses: {
          'm31': NodeStatus.running,
          'm31-smart': NodeStatus.running,
        },
        nodeProgressDetail: {'m31-smart': 'Completed 7/0'},
      ),
    );
    addTearDown(container.dispose);

    final active = container
        .read(nightPlanStepsProvider)
        .singleWhere((s) => s.nodeId == 'm31-smart');
    expect(active.when, const StepWhenProgress(7, null));
    final header = container.read(nightHeaderProvider);
    expect(header.framesDone, 7);
    expect(header.framesTotal, isNull);
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

  // A step the operator's Stop ended ran, and may have taken frames; a step
  // the run passed over did not. The list told both as "skipped".
  test('a step the operator stopped is stopped, not skipped', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        nodeStatuses: {
          'm74-l': NodeStatus.cancelled,
          'ngc891-ha': NodeStatus.skipped,
        },
      ),
    );
    addTearDown(container.dispose);

    final steps = container.read(nightPlanStepsProvider);
    expect(steps[0].status, PlanStepStatus.stopped);
    expect(steps[1].status, PlanStepStatus.skipped);
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
