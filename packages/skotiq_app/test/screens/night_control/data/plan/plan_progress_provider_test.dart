// The Plan section: per-filter frames and integration, plan length and ETA.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_progress_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'plan_test_support.dart';
import 'package:skotiq_app/services/night_session/night_session_frames.dart';

/// A session row: [filter], [secs] long, kept or rejected.
DbCapturedImage _row(
  int id,
  String filter,
  double secs, {
  bool kept = true,
  DateTime? at,
}) {
  final capturedAt = at ?? bostonTime(2026, 10, 19, 20);
  return DbCapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    filter: filter,
    exposureDuration: secs,
    binX: 1,
    binY: 1,
    capturedAt: capturedAt,
    createdAt: capturedAt,
    isAccepted: kept,
    isPlateSolved: false,
  );
}

/// The M74 plan, one Smart Exposure of L and R at 90 s, and the checkpoint
/// of a run stopped with 4 L and 3 R taken.
(Sequence, CheckpointInfo) _restoredM74() {
  final smart = SmartExposureNode(
    id: 'smart',
    parentId: 't',
    plans: const [
      FilterPlan(filterName: 'L', count: 24, durationSecs: 90),
      FilterPlan(filterName: 'R', count: 17, durationSecs: 90),
    ],
  );
  final target = TargetHeaderNode(
    id: 't',
    parentId: 'root',
    targetName: 'M74',
    raHours: 1.6,
    decDegrees: 15.8,
    childIds: const ['smart'],
  );
  final root = InstructionSetNode(id: 'root', childIds: const ['t']);
  final sequence = Sequence.create(
    name: 'M74 Plan',
    rootNodeId: 'root',
    nodes: {root.id: root, target.id: target, smart.id: smart},
  );
  final restored = CheckpointInfo(
    sequenceName: sequence.name,
    timestamp: bostonTime(2026, 10, 19, 19),
    completedExposures: 7,
    completedIntegrationSecs: 630,
    canResume: true,
    ageSeconds: 60,
    filterFramesDoneByStep: const {
      'smart': {'L': 4, 'R': 3},
    },
  );
  return (sequence, restored);
}

void main() {
  final evening = bostonTime(2026, 10, 19, 20, 10);

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

  // The launch's frame list spans runs: a second run read "15 of 40" with 9
  // taken because the first run's 6 still counted.
  test("a run counts only frames taken since it started", () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: bostonTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        estimatedRemainingSecs: 600,
      ),
      sessionFrames: [
        lightFrame('earlier', 'L', bostonTime(2026, 10, 19, 19, 20)),
        lightFrame('1', 'L', bostonTime(2026, 10, 19, 19, 52)),
      ],
      run: RunRecord(startedAt: bostonTime(2026, 10, 19, 19, 51)),
      extra: [
        nightRunLightRowsProvider.overrideWithValue([
          _row(1, 'L', 60, at: bostonTime(2026, 10, 19, 19, 20)),
          _row(2, 'L', 60, at: bostonTime(2026, 10, 19, 19, 52)),
        ]),
      ],
    );
    addTearDown(container.dispose);

    final plan = container.read(nightPlanProgressProvider)!;
    expect(plan.rows.firstWhere((r) => r.filter == 'L').framesDone, 1);
  });

  // Restored from its checkpoint, a run read "L 0/6" although four frames of
  // it were on disk, and after it finished it counted only its own.
  test(
    'a run continued from its checkpoint counts the frames taken before it',
    () {
      final plan = TwoTargetPlan().sequence;
      final lNode = plan.nodes.values.whereType<ExposureNode>().firstWhere(
            (node) => node.filter == 'L',
          );
      final restored = CheckpointInfo(
        sequenceName: plan.name,
        timestamp: bostonTime(2026, 10, 19, 19),
        completedExposures: 2,
        completedIntegrationSecs: 120,
        canResume: true,
        ageSeconds: 60,
        ended: 'stopped',
        framesDoneByStep: {lNode.id: 2},
      );
      final ready = planContainer(
        now: evening,
        sequence: plan,
        run: RunRecord(
          restoredCheckpoint: restored,
          framesDoneBeforeRun: restored.framesDoneByStep,
        ),
      );
      addTearDown(ready.dispose);
      expect(
        ready.read(nightPlanProgressProvider)!.rows.map((r) => r.framesDone),
        [2, 0],
        reason: 'restored, not started yet',
      );

      final running = planContainer(
        now: evening,
        sequence: plan,
        execution: SequenceExecutionState.running,
        session: SessionState(
          isActive: true,
          startTime: bostonTime(2026, 10, 19, 19, 50),
        ),
        progress: const SequenceProgress(state: SequenceExecutionState.running),
        sessionFrames: [lightFrame('3', 'L', bostonTime(2026, 10, 19, 19, 52))],
        run: RunRecord(
          startedAt: bostonTime(2026, 10, 19, 19, 51),
          framesDoneBeforeRun: restored.framesDoneByStep,
        ),
        extra: [
          nightRunLightRowsProvider.overrideWithValue([
            _row(3, 'L', 60, at: bostonTime(2026, 10, 19, 19, 52)),
          ]),
        ],
      );
      addTearDown(running.dispose);
      expect(
        running.read(nightPlanProgressProvider)!.rows.first.framesDone,
        3,
        reason: "the two before the restore and this run's one",
      );
    },
  );

  // Restored at 7 frames, a Smart Exposure plan read "L 0/24" on Tonight.
  test('a restored Smart Exposure counts the frames each filter has', () {
    final (sequence, restored) = _restoredM74();
    final container = planContainer(
      now: evening,
      sequence: sequence,
      run: RunRecord(
        restoredCheckpoint: restored,
        filterFramesDoneBeforeRun: restored.filterFramesDoneByStep,
      ),
    );
    addTearDown(container.dispose);

    final plan = container.read(nightPlanProgressProvider)!;
    expect(plan.rows.map((r) => r.framesDone), [4, 3]);
    // The frames it has, at the length each filter takes them: a row with
    // frames and no integration read "0h00".
    expect(
      plan.rows.map((r) => r.integrated),
      [const Duration(seconds: 360), const Duration(seconds: 270)],
    );
    expect(plan.integrated, const Duration(seconds: 630));
  });

  test(
    'a continued run adds its own frames to what its checkpoint integrated',
    () {
      final (sequence, restored) = _restoredM74();
      final startedAt = bostonTime(2026, 10, 19, 20);
      final container = planContainer(
        now: evening,
        sequence: sequence,
        execution: SequenceExecutionState.running,
        progress: const SequenceProgress(
          state: SequenceExecutionState.running,
        ),
        run: RunRecord(
          startedAt: startedAt,
          filterFramesDoneBeforeRun: restored.filterFramesDoneByStep,
        ),
        extra: [
          nightRunLightRowsProvider.overrideWithValue([
            // A frame of the interrupted run, already in the checkpoint.
            _row(1, 'L', 90, at: startedAt.subtract(const Duration(hours: 1))),
            _row(2, 'L', 90, at: startedAt.add(const Duration(minutes: 5))),
          ]),
        ],
      );
      addTearDown(container.dispose);

      final plan = container.read(nightPlanProgressProvider)!;
      expect(plan.rows.map((r) => r.framesDone), [5, 3]);
      // Started in a session without the interrupted run's rows, it read 0h00.
      expect(
        plan.rows.map((r) => r.integrated),
        [const Duration(seconds: 450), const Duration(seconds: 270)],
      );
    },
  );

  test(
    'running: frames from the session, accepted integration, current row',
    () {
      final container = planContainer(
        now: evening,
        sequence: TwoTargetPlan().sequence,
        execution: SequenceExecutionState.running,
        session: SessionState(
          isActive: true,
          startTime: bostonTime(2026, 10, 19, 19, 50),
        ),
        progress: const SequenceProgress(
          state: SequenceExecutionState.running,
          estimatedRemainingSecs: 600,
        ),
        sessionFrames: [
          lightFrame('1', 'L', bostonTime(2026, 10, 19, 19, 52)),
          lightFrame('2', 'L', bostonTime(2026, 10, 19, 19, 53)),
          lightFrame('3', 'L', bostonTime(2026, 10, 19, 19, 54)),
          lightFrame('4', 'Ha', bostonTime(2026, 10, 19, 19, 58)),
        ],
        totals: const RunDashboardFilterTotals(
          integrationSecs: {},
          totalAcquiredSecs: {},
          goalSecs: {'L': 180, 'Ha': 240},
          inFlightFilter: 'Ha',
        ),
        extra: [
          nightRunLightRowsProvider.overrideWithValue([
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
      expect(
        l.integrated,
        const Duration(minutes: 2),
        reason: 'accepted only: one L frame was rejected',
      );
      expect(l.isCurrent, isFalse);
      expect(ha.framesDone, 1);
      expect(ha.isCurrent, isTrue);
      expect(plan.integrated, const Duration(minutes: 4));
      expect(plan.eta, evening.add(const Duration(minutes: 10)));
    },
  );

  test('an exposure under an open-ended loop has no planned count', () {
    final loop = LoopNode(
      id: 'loop',
      parentId: 'root',
      conditionType: LoopConditionType.untilTime,
      repeatUntil: bostonTime(2026, 10, 20, 5),
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
        startTime: bostonTime(2026, 10, 19, 19, 50),
      ),
      sessionFrames: [
        lightFrame('1', 'L', bostonTime(2026, 10, 19, 19, 52)),
        lightFrame('2', 'R', bostonTime(2026, 10, 19, 19, 54)),
        lightFrame('3', 'L', bostonTime(2026, 10, 19, 19, 56)),
      ],
      totals: const RunDashboardFilterTotals(
        integrationSecs: {},
        totalAcquiredSecs: {},
        goalSecs: {'L': 2700, 'R': 900},
        inFlightFilter: 'R',
      ),
      extra: [
        nightRunLightRowsProvider.overrideWithValue([
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

  test('a rejected light counts as taken and not as integration', () {
    final plan = TwoTargetPlan();
    final start = bostonTime(2026, 10, 19, 19, 51);
    final container = planContainer(
      now: evening,
      sequence: plan.sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(isActive: true, startTime: start),
      progress: const SequenceProgress(state: SequenceExecutionState.running),
      run: RunRecord(startedAt: start, framesDoneBeforeRun: {plan.m74L.id: 2}),
      extra: [
        nightRunLightRowsProvider.overrideWithValue([
          _row(1, 'L', 120, at: start.subtract(const Duration(hours: 1))),
          _row(
            2,
            'L',
            60,
            kept: false,
            at: start.add(const Duration(minutes: 1)),
          ),
        ]),
      ],
    );
    addTearDown(container.dispose);

    final row = container
        .read(nightPlanProgressProvider)!
        .rows
        .firstWhere((r) => r.filter == 'L');
    expect(row.framesDone, 3);
    expect(row.integrated, const Duration(seconds: 120));
  });

  test('a flip disables start now and leaves an armed start-at-dark', () {
    final ready = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
    );
    addTearDown(ready.dispose);
    ready
        .read(flipMonitorProgressProvider.notifier)
        .update((p) => p.copyWith(state: FlipExecutionState.executing));
    final blocked = ready.read(nightHeaderProvider);
    expect(blocked.startNow!.enabled, isFalse);
    expect(
      blocked.startNow!.disabledReason,
      const NightText('nightActBusyFlip'),
    );
    expect(blocked.startAtDark!.enabled, isFalse);

    final armed = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      armedStartAt: bostonTime(2026, 10, 19, 19, 48),
    );
    addTearDown(armed.dispose);
    armed
        .read(flipMonitorProgressProvider.notifier)
        .update((p) => p.copyWith(state: FlipExecutionState.executing));
    final header = armed.read(nightHeaderProvider);
    expect(header.startNow!.enabled, isFalse);
    expect(header.startAtDark!.enabled, isTrue);

    ready
        .read(flipMonitorProgressProvider.notifier)
        .update((p) => p.copyWith(state: FlipExecutionState.idle));
    expect(ready.read(nightHeaderProvider).startNow!.enabled, isTrue);
  });
}
