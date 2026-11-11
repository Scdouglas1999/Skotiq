// The plan's Target Scheduler as the run uses it: the node, the picks it has
// made (its `SchedulerDecision` events) and, when the node swaps targets on
// the sky's conditions, the executor's swap state.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The typed event union collides by name with the wire event model the barrel
// keeps canonical; it comes from the core's typed-event seam.
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

import 'night_plan_inputs.dart';

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

bool _isSchedulerDecision(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  return payload is EventPayload_Sequencer &&
      payload.field0 is SequencerEvent_SchedulerDecision;
}

/// The newest Target Scheduler pick the event stream has carried.
///
/// Kept apart from the event history, which holds only the last hundred
/// events: an autofocus run at the start of a plan pushes the scheduler's
/// first pick out of it within a minute.
class _LatestPickNotifier extends StateNotifier<sk_events.SkotiqEvent?> {
  _LatestPickNotifier(Ref ref)
      : super(
          ref
              .read(eventHistoryProvider)
              .where(_isSchedulerDecision)
              .firstOrNull,
        ) {
    ref.listen<List<sk_events.SkotiqEvent>>(eventHistoryProvider, (
      previous,
      next,
    ) {
      // The history only gains events at its front (newest first).
      final head = previous == null || previous.isEmpty ? null : previous.first;
      for (final event in next) {
        if (identical(event, head)) return;
        if (_isSchedulerDecision(event)) {
          state = event;
          return;
        }
      }
    });
  }
}

/// The scheduler's newest pick as the stream carried it. An always-on
/// service, so a pick made while Tonight is closed is still known.
final schedulerPicksProvider =
    StateNotifierProvider<_LatestPickNotifier, sk_events.SkotiqEvent?>(
  _LatestPickNotifier.new,
);

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
    time: clock.toNightClock(
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
