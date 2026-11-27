// The Target Scheduler's newest pick, kept by an always-on service so a pick
// made while Tonight is closed is still known when it opens.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
// The typed event union collides by name with the wire event model the barrel
// keeps canonical; it comes from the core's typed-event seam.
import 'package:skotiq_core/bridge_events.dart' as sk_events;

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
