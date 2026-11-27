// The plan's Target Scheduler as the run uses it: the node, the picks it has
// made (its `SchedulerDecision` events) and, when the node swaps targets on
// the sky's conditions, the executor's swap state.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
// The typed event union collides by name with the wire event model the barrel
// keeps canonical; it comes from the core's typed-event seam.
import 'package:skotiq_core/bridge_events.dart' as sk_events;

import '../../../../services/night_session/night_scheduler_picks.dart';

/// One pick of the Target Scheduler.
class SchedulerDecisionView {
  const SchedulerDecisionView({
    required this.time,
    required this.decisionCounter,
    required this.pickedTargetName,
    required this.pickedScore,
    required this.scores,
  });

  /// When it was made, on the operator's clock.
  final DateTime time;

  /// 1-based count of the scheduler's decisions in this run.
  final int decisionCounter;

  /// Null when no target cleared the node's minimum score.
  final String? pickedTargetName;

  /// 0 to 100; null when nothing was picked.
  final double? pickedScore;

  /// Runnable candidates first, then by descending score.
  final List<SchedulerScoreEntry> scores;
}

/// The plan's enabled Target Scheduler, or null when the plan has none.
final nightPlanSchedulerProvider = Provider<TargetSchedulerNode?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;
  for (final node in sequence.nodes.values) {
    if (node is TargetSchedulerNode && node.isEnabled) return node;
  }
  return null;
});

/// The scheduler's newest pick in this run, or null before its first.
final latestSchedulerDecisionProvider = Provider<SchedulerDecisionView?>((ref) {
  final event = ref.watch(schedulerPicksProvider);
  if (event == null) return null;
  final session = ref.watch(sessionStateProvider);
  // A pick from before this run's session is an earlier run's. The margin
  // covers the session being stamped a moment after the executor began.
  final runStart = session.isActive
      ? session.startTime?.subtract(const Duration(seconds: 5))
      : null;
  final at = DateTime.fromMillisecondsSinceEpoch(event.timestamp.toInt());
  if (runStart != null && at.isBefore(runStart)) return null;
  return _schedulerDecision(event, ref.watch(clockProvider));
});

SchedulerDecisionView? _schedulerDecision(
  sk_events.SkotiqEvent event,
  Clock clock,
) {
  final payload = event.payload;
  if (payload is! EventPayload_Sequencer) return null;
  final sequencer = payload.field0;
  if (sequencer is! SequencerEvent_SchedulerDecision) return null;
  return SchedulerDecisionView(
    time: clock.wallClockOf(
      DateTime.fromMillisecondsSinceEpoch(event.timestamp.toInt()),
    ),
    decisionCounter: sequencer.decisionCounter,
    pickedTargetName: sequencer.pickedTargetName,
    pickedScore: sequencer.pickedScore,
    scores: sequencer.scores,
  );
}

/// The executor's conditions score and target-swap state, read every 30
/// seconds while something shows it.
final adaptiveSwapSnapshotProvider =
    FutureProvider.autoDispose<AdaptiveSwapSnapshot?>((ref) {
  ref.watch(tickerProvider(TickerCadence.thirtySeconds));
  return ref.watch(sequencerBackendProvider).sequencerGetAdaptiveSwapSnapshot();
});
