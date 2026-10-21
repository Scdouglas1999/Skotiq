// "The night" before a run and "Coming up" during one.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/upcoming_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import 'plan_test_support.dart';

/// [TwoTargetPlan] plus the two autofocus triggers the boards show:
/// every 6 frames, or a 1 °C change.
Sequence _planWithAutofocusTriggers() {
  final plan = TwoTargetPlan().sequence;
  final everySix = RecoveryNode(
    id: 'af-frames',
    parentId: 'root',
    recoveryAction: RecoveryActionType.autofocus,
    triggerType: TriggerType.autofocusInterval,
    triggerEveryNFrames: 6,
  );
  final onTemperature = RecoveryNode(
    id: 'af-temp',
    parentId: 'root',
    recoveryAction: RecoveryActionType.autofocus,
    triggerType: TriggerType.temperatureShift,
    triggerThreshold: 1.0,
  );
  final root = plan.nodes['root']!;
  return plan.copyWith(
    nodes: {
      ...plan.nodes,
      'root': root.copyWith(
        childIds: ['af-frames', 'af-temp', ...root.childIds],
      ),
      everySix.id: everySix,
      onTemperature.id: onTemperature,
    },
  );
}

void main() {
  test('before a run: the night in time order, with what has passed', () {
    final container = planContainer(
      now: DateTime(2026, 10, 19, 18, 36),
      sequence: TwoTargetPlan().sequence,
    );
    addTearDown(container.dispose);

    final items = container.read(nightUpcomingProvider);
    expect(items.map((i) => i.kind), [
      UpcomingKind.sunset,
      UpcomingKind.astroDark,
      UpcomingKind.moon,
      UpcomingKind.astroDawn,
    ]);
    expect(items[0].passed, isTrue);
    expect(items[1].passed, isFalse);
    expect(items[2].moonIlluminationPct, 44);
    expect(items[2].at, DateTime(2026, 10, 19, 23, 9));
    expect(items[3].at, DateTime(2026, 10, 20, 5, 44));
  });

  test('no site: no night rows', () {
    final container = planContainer(
      now: DateTime(2026, 10, 19, 18, 36),
      sequence: TwoTargetPlan().sequence,
      site: false,
    );
    addTearDown(container.dispose);

    expect(container.read(nightUpcomingProvider), isEmpty);
  });

  test('running: next dither, autofocus cadence, target switch, dawn', () {
    final now = DateTime(2026, 10, 19, 20, 2);
    final container = planContainer(
      now: now,
      sequence: _planWithAutofocusTriggers(),
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'm74-l',
        currentTarget: 'M74',
        nodeStatuses: {'m74': NodeStatus.running, 'm74-l': NodeStatus.running},
        nodeProgressStructuredDetail: {
          'm74-l': ExposureInstructionProgressDetail(
            frame: 0,
            total: 3,
            durationSecs: 60,
          ),
        },
      ),
      sessionFrames: [
        lightFrame('1', 'L', DateTime(2026, 10, 19, 19, 55)),
      ],
    );
    addTearDown(container.dispose);

    final items = container.read(nightUpcomingProvider);
    expect(items.map((i) => i.kind), [
      UpcomingKind.dither,
      UpcomingKind.autofocus,
      UpcomingKind.targetSwitch,
      UpcomingKind.planEnd,
      UpcomingKind.moon,
      UpcomingKind.astroDawn,
    ]);
    // M74's L step dithers after every frame; none taken in this step yet
    // and one frame in the session, so the dither follows frame #2.
    expect(items[0].afterFrame, 2);
    // Every 6 frames, no autofocus yet this session: after frame #6.
    expect(items[1].afterFrame, 6);
    expect(items[1].everyFrames, isNull);
    expect(items[1].tempDeltaC, 1.0);
    expect(items[2].subject, 'NGC 891');
    expect(items[2].at!.isAfter(DateTime(2026, 10, 19, 19, 50)), isTrue);
    expect(items[3].at!.isAfter(items[2].at!), isTrue);
    expect(items[4].at, DateTime(2026, 10, 19, 23, 9));
    expect(items[4].moonIlluminationPct, 44);
    expect(items[5].passed, isFalse);
  });

  test('no dither left in the step: no dither row', () {
    final container = planContainer(
      now: DateTime(2026, 10, 19, 20, 2),
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 19, 50),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'ngc891-ha',
        currentTarget: 'NGC 891',
        nodeProgressStructuredDetail: {
          'ngc891-ha': ExposureInstructionProgressDetail(
            frame: 1,
            total: 2,
            durationSecs: 120,
          ),
        },
      ),
    );
    addTearDown(container.dispose);

    final kinds = container.read(nightUpcomingProvider).map((i) => i.kind);
    expect(kinds, isNot(contains(UpcomingKind.dither)),
        reason: 'the executor never dithers after a burst\'s last frame');
    expect(kinds, isNot(contains(UpcomingKind.targetSwitch)),
        reason: 'NGC 891 is the last target');
  });

  test('past midnight: dawn is still ahead, sunset and dark are behind', () {
    final container = planContainer(
      now: DateTime(2026, 10, 20, 1),
      sequence: TwoTargetPlan().sequence,
    );
    addTearDown(container.dispose);

    final items = container.read(nightUpcomingProvider);
    final byKind = {for (final item in items) item.kind: item};
    expect(byKind[UpcomingKind.sunset]!.passed, isTrue);
    expect(byKind[UpcomingKind.astroDark]!.passed, isTrue);
    expect(byKind[UpcomingKind.moon]!.passed, isTrue);
    expect(byKind[UpcomingKind.astroDawn]!.passed, isFalse);
    expect(items.last.kind, UpcomingKind.astroDawn);
  });

  // The owner's run: one Smart Exposure node, no autofocus node or trigger in
  // the plan, autofocus from the interval setting every run gets.
  test('a Smart Exposure run: its dither cadence and the next autofocus', () {
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 't',
      batchSize: 4,
      plans: const [
        FilterPlan(
            filterName: 'L', count: 30, durationSecs: 90, ditherEvery: 2),
        FilterPlan(
            filterName: 'R', count: 10, durationSecs: 90, ditherEvery: 3),
      ],
    );
    final target = TargetHeaderNode(
      id: 't',
      parentId: 'root',
      targetName: 'NGC 891',
      raHours: 2.376,
      decDegrees: 42.349,
      childIds: const ['smart'],
    );
    final root = InstructionSetNode(id: 'root', childIds: const ['t']);
    final sequence = Sequence.create(
      name: 'NGC 891',
      rootNodeId: 'root',
      nodes: {root.id: root, target.id: target, smart.id: smart},
    );
    final first = DateTime(2026, 10, 19, 21);
    final container = planContainer(
      now: DateTime(2026, 10, 19, 22),
      sequence: sequence,
      execution: SequenceExecutionState.running,
      session: SessionState(isActive: true, startTime: first),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'smart',
        currentTarget: 'NGC 891',
        currentFilter: 'R',
        nodeStatuses: {'t': NodeStatus.running, 'smart': NodeStatus.running},
      ),
      sessionFrames: [
        for (var i = 0; i < 30; i++)
          lightFrame(
              '$i', i.isEven ? 'L' : 'R', first.add(Duration(minutes: 2 * i))),
      ],
    );
    addTearDown(container.dispose);
    // An autofocus ran after the tenth frame.
    // ignore: invalid_use_of_protected_member
    container.read(nightSessionEventsProvider.notifier).state =
        NightSessionEvents(
      autofocusRuns: [
        NightAutofocusRun(at: first.add(const Duration(minutes: 19))),
      ],
    );

    final items = container.read(nightUpcomingProvider);
    final dither = items.firstWhere((i) => i.kind == UpcomingKind.dither);
    expect(dither.everyFrames, 3, reason: 'R is exposing; R dithers every 3');
    final autofocus = items.firstWhere((i) => i.kind == UpcomingKind.autofocus);
    final every =
        container.read(sequencerDefaultsProvider).autofocusIntervalFrames;
    expect(autofocus.afterFrame, 10 + every);
  });

  test('one frame per filter visit never reaches a Smart Exposure dither', () {
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 'root',
      plans: const [
        FilterPlan(filterName: 'L', count: 30, ditherEvery: 2),
        FilterPlan(filterName: 'R', count: 30, ditherEvery: 2),
      ],
    );
    final root = InstructionSetNode(id: 'root', childIds: const ['smart']);
    final container = planContainer(
      now: DateTime(2026, 10, 19, 22),
      sequence: Sequence.create(
        name: 'LR',
        rootNodeId: 'root',
        nodes: {root.id: root, smart.id: smart},
      ),
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: DateTime(2026, 10, 19, 21),
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'smart',
        currentFilter: 'L',
        nodeStatuses: {'smart': NodeStatus.running},
      ),
    );
    addTearDown(container.dispose);

    expect(
      container.read(nightUpcomingProvider).map((i) => i.kind),
      isNot(contains(UpcomingKind.dither)),
    );
  });
}
