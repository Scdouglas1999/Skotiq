// "The night" before a run and "Coming up" during one.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/upcoming_provider.dart';
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
      UpcomingKind.astroDawn,
    ]);
    // M74's L step dithers after every frame; none taken in this step yet
    // and one frame in the session, so the dither follows frame #2.
    expect(items[0].afterFrame, 2);
    expect(items[1].everyFrames, 6);
    expect(items[1].tempDeltaC, 1.0);
    expect(items[2].subject, 'NGC 891');
    expect(items[2].at!.isAfter(DateTime(2026, 10, 19, 19, 50)), isTrue);
    expect(items[3].passed, isFalse);
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
}
