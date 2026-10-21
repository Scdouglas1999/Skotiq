// The Plan section: per-filter frames and integration, plan length and ETA.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_progress_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import 'plan_test_support.dart';

/// A session row: [filter], [secs] long, kept or rejected.
DbCapturedImage _row(int id, String filter, double secs, {bool kept = true}) =>
    DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      filter: filter,
      exposureDuration: secs,
      binX: 1,
      binY: 1,
      capturedAt: DateTime(2026, 10, 19, 20),
      createdAt: DateTime(2026, 10, 19, 20),
      isAccepted: kept,
      isPlateSolved: false,
    );

void main() {
  final evening = DateTime(2026, 10, 19, 20, 10);

  test('no plan: no plan section', () {
    final container = planContainer(now: evening);
    addTearDown(container.dispose);

    expect(container.read(nightPlanProgressProvider), isNull);
  });

  test('before a run: planned counts, nothing done, an estimated end', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      // Frames from an earlier session must not count toward this plan.
      sessionFrames: [lightFrame('old', 'L', DateTime(2026, 10, 18, 23))],
    );
    addTearDown(container.dispose);

    final plan = container.read(nightPlanProgressProvider)!;
    expect(plan.rows.map((r) => r.filter), ['L', 'Ha']);
    expect(plan.rows.map((r) => r.framesPlanned), [3, 2]);
    expect(plan.rows.map((r) => r.framesDone), [0, 0]);
    expect(plan.rows.any((r) => r.isCurrent), isFalse);
    expect(plan.integrated, Duration.zero);
    expect(plan.planned, isNotNull);
    expect(plan.eta, evening.add(plan.planned!));
  });

  test('running: frames from the session, accepted integration, current row',
      () {
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
        estimatedRemainingSecs: 600,
      ),
      sessionFrames: [
        lightFrame('1', 'L', DateTime(2026, 10, 19, 19, 52)),
        lightFrame('2', 'L', DateTime(2026, 10, 19, 19, 53)),
        lightFrame('3', 'L', DateTime(2026, 10, 19, 19, 54)),
        lightFrame('4', 'Ha', DateTime(2026, 10, 19, 19, 58)),
      ],
      totals: const RunDashboardFilterTotals(
        integrationSecs: {},
        totalAcquiredSecs: {},
        goalSecs: {'L': 180, 'Ha': 240},
        inFlightFilter: 'Ha',
      ),
      extra: [
        nightSessionLightRowsProvider.overrideWithValue([
          _row(1, 'L', 60),
          _row(2, 'L', 60, kept: false),
          _row(3, 'L', 60),
          _row(4, 'Ha', 120),
        ]),
      ],
    );
    addTearDown(container.dispose);

    final plan = container.read(nightPlanProgressProvider)!;
    final l = plan.rows[0];
    final ha = plan.rows[1];
    expect(l.framesDone, 3);
    expect(l.fraction, 1.0);
    expect(l.integrated, const Duration(minutes: 2),
        reason: 'accepted only: one L frame was rejected');
    expect(l.isCurrent, isFalse);
    expect(ha.framesDone, 1);
    expect(ha.isCurrent, isTrue);
    expect(plan.integrated, const Duration(minutes: 4));
    expect(plan.eta, evening.add(const Duration(minutes: 10)));
  });

  test('an exposure under an open-ended loop has no planned count', () {
    final loop = LoopNode(
      id: 'loop',
      parentId: 'root',
      conditionType: LoopConditionType.untilTime,
      repeatUntil: DateTime(2026, 10, 20, 5),
      childIds: const ['ha'],
    );
    final ha = ExposureNode(id: 'ha', parentId: 'loop', filter: 'Ha');
    final root = InstructionSetNode(id: 'root', childIds: const ['loop']);
    final sequence = Sequence.create(
      name: 'Until dawn',
      rootNodeId: 'root',
      nodes: {root.id: root, loop.id: loop, ha.id: ha},
    );
    final container = planContainer(now: evening, sequence: sequence);
    addTearDown(container.dispose);

    final plan = container.read(nightPlanProgressProvider)!;
    expect(plan.rows.single.framesPlanned, isNull);
    expect(plan.rows.single.fraction, isNull);
    expect(plan.planned, isNull);
    expect(plan.eta, isNull);
  });

  test('a count loop multiplies the planned frames', () {
    final loop = LoopNode(
      id: 'loop',
      parentId: 'root',
      conditionType: LoopConditionType.count,
      repeatCount: 4,
      childIds: const ['ha'],
    );
    final ha = ExposureNode(id: 'ha', parentId: 'loop', filter: 'Ha', count: 5);
    final root = InstructionSetNode(id: 'root', childIds: const ['loop']);
    final sequence = Sequence.create(
      name: 'Repeat',
      rootNodeId: 'root',
      nodes: {root.id: root, loop.id: loop, ha.id: ha},
    );
    final container = planContainer(now: evening, sequence: sequence);
    addTearDown(container.dispose);

    expect(
      container.read(nightPlanProgressProvider)!.rows.single.framesPlanned,
      20,
    );
  });

  // The owner's run: a saved sequence whose only exposures are one Smart
  // Exposure node read "No plan loaded" while it ran.
  test('a Smart Exposure plans one row per filter', () {
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 't',
      plans: const [
        FilterPlan(filterName: 'L', count: 30, durationSecs: 90),
        FilterPlan(filterName: 'R', count: 10, durationSecs: 90),
      ],
    );
    final target = TargetHeaderNode(
      id: 't',
      parentId: 'root',
      targetName: 'NGC 891',
      raHours: 2.376,
      decDegrees: 42.35,
      childIds: const ['smart'],
    );
    final root = InstructionSetNode(id: 'root', childIds: const ['t']);
    final sequence = Sequence.create(
      name: 'NGC 891',
      rootNodeId: 'root',
      nodes: {root.id: root, target.id: target, smart.id: smart},
    );
    final container = planContainer(
      now: evening,
      sequence: sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 19, 50),
      ),
      sessionFrames: [
        lightFrame('1', 'L', DateTime(2026, 10, 19, 19, 52)),
        lightFrame('2', 'R', DateTime(2026, 10, 19, 19, 54)),
        lightFrame('3', 'L', DateTime(2026, 10, 19, 19, 56)),
      ],
      totals: const RunDashboardFilterTotals(
        integrationSecs: {},
        totalAcquiredSecs: {},
        goalSecs: {'L': 2700, 'R': 900},
        inFlightFilter: 'R',
      ),
      extra: [
        nightSessionLightRowsProvider.overrideWithValue([
          _row(1, 'L', 90),
          _row(2, 'R', 90),
          _row(3, 'L', 90),
        ]),
      ],
    );
    addTearDown(container.dispose);

    final plan = container.read(nightPlanProgressProvider)!;
    expect(plan.rows.map((r) => r.filter), ['L', 'R']);
    expect(plan.rows.map((r) => r.framesPlanned), [30, 10]);
    expect(plan.rows.map((r) => r.framesDone), [2, 1]);
    expect(plan.rows[1].isCurrent, isTrue);
    expect(plan.integrated, const Duration(seconds: 270));
  });

  test('"Loop until stopped" leaves the Smart Exposure rows open', () {
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 'root',
      loopUntilStopped: true,
      plans: const [FilterPlan(filterName: 'Ha', count: 5)],
    );
    final root = InstructionSetNode(id: 'root', childIds: const ['smart']);
    final sequence = Sequence.create(
      name: 'Until stopped',
      rootNodeId: 'root',
      nodes: {root.id: root, smart.id: smart},
    );
    final container = planContainer(now: evening, sequence: sequence);
    addTearDown(container.dispose);

    expect(
      container.read(nightPlanProgressProvider)!.rows.single.framesPlanned,
      isNull,
    );
  });

  test('a plan with no exposures is still a plan, with no rows', () {
    final slew = SlewNode(id: 'slew', parentId: 'root');
    final root = InstructionSetNode(id: 'root', childIds: const ['slew']);
    final sequence = Sequence.create(
      name: 'Slew only',
      rootNodeId: 'root',
      nodes: {root.id: root, slew.id: slew},
    );
    final container = planContainer(now: evening, sequence: sequence);
    addTearDown(container.dispose);

    expect(container.read(nightPlanProgressProvider)!.rows, isEmpty);
  });
}
