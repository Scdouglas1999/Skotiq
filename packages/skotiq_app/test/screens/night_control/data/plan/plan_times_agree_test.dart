// Tonight's plan and the Sequencer's ETA column are two views of one
// estimate: during a run both time the plan from the run's start, so a step
// that waits for a clock time lands on the same minute in both.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/visual_timeline.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'plan_test_support.dart';

class _StoppedClock implements Clock {
  const _StoppedClock(this.at);

  final DateTime at;

  @override
  DateTime now() => at;

  @override
  DateTime nowUtc() => at.toUtc();

  @override
  Duration get utcOffset => at.timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

void main() {
  final runStart = DateTime(2026, 10, 19, 21, 0);

  // 21:00 a (60 min), wait until 23:00, b (60 min), c (30 min).
  Sequence waitingPlan() {
    const rootId = 'root';
    final a =
        DelayNode(id: 'a', parentId: rootId, orderIndex: 0, seconds: 3600);
    final wait = WaitTimeNode(
      id: 'wait',
      parentId: rootId,
      orderIndex: 1,
      waitUntil: DateTime(2026, 10, 19, 23, 0),
    );
    final b =
        DelayNode(id: 'b', parentId: rootId, orderIndex: 2, seconds: 3600);
    final c =
        DelayNode(id: 'c', parentId: rootId, orderIndex: 3, seconds: 1800);
    final root = InstructionSetNode(
      id: rootId,
      name: 'Night',
      childIds: const ['a', 'wait', 'b', 'c'],
    );
    return Sequence.create(
      name: 'Night',
      rootNodeId: rootId,
      nodes: {
        for (final n in <SequenceNode>[root, a, wait, b, c]) n.id: n
      },
    );
  }

  test('during a run Tonight and the Sequencer give the same start times', () {
    final now = DateTime(2026, 10, 19, 23, 10);
    final container = planContainer(
      now: now,
      clock: _StoppedClock(now),
      sequence: waitingPlan(),
      execution: SequenceExecutionState.running,
      progress: const SequenceProgress(currentNodeId: 'b'),
      session: SessionState(isActive: true, startTime: runStart),
      extra: [
        preSessionTwilightTimesProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    final tonight = container.read(nightPlanTimingProvider)!;
    final ledger = container.read(ledgerEtaProvider);
    for (final id in ['a', 'b', 'c']) {
      expect(
        ledger[id]!.start.toUtc(),
        tonight.of(id)!.estimatedStart.toUtc(),
        reason: 'step $id',
      );
    }
    expect(
      tonight.of('c')!.estimatedStart.toLocal(),
      DateTime(2026, 10, 20, 0, 0),
    );
  });
}
