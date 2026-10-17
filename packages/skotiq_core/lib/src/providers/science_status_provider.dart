import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/science/science_status.dart';

/// Single shared tracker. Owned by the provider so [ScienceProcessingService]
/// and the UI agree on a single source of truth without an explicit DI dance.
final scienceProcessingStatusTrackerProvider =
    Provider<ScienceProcessingStatusTracker>((ref) {
      final tracker = ScienceProcessingStatusTracker();
      ref.onDispose(tracker.dispose);
      return tracker;
    });

/// Live snapshot of the science processing queue. Rebuilds every time a stage
/// starts or completes, so UI consumers stay in lockstep with the pipeline.
final scienceProcessingStatusProvider =
    StreamProvider<ScienceProcessingStatusSnapshot>((ref) {
      final tracker = ref.watch(scienceProcessingStatusTrackerProvider);

      final controller = StreamController<ScienceProcessingStatusSnapshot>();

      void push() {
        if (controller.isClosed) return;
        controller.add(
          ScienceProcessingStatusSnapshot(
            queueDepth: tracker.queueDepth,
            inflight: tracker.inflight,
            history: List<ScienceFrameStatus>.unmodifiable(
              tracker.snapshot().skip(tracker.inflight == null ? 0 : 1),
            ),
            lastFailure: tracker.lastFailure,
          ),
        );
      }

      // Seed the stream so consumers don't have to wait for the first event.
      push();

      final sub = tracker.events.listen((_) => push());
      ref.onDispose(() {
        sub.cancel();
        controller.close();
      });

      return controller.stream;
    });

/// Convenience: latest stage result for the currently in-flight frame, or
/// the most recently finished frame if no work is in flight.
final scienceProcessingLatestStageProvider = Provider<ScienceStageResult?>((
  ref,
) {
  final snapshot = ref.watch(scienceProcessingStatusProvider).valueOrNull;
  if (snapshot == null) return null;
  final inflight = snapshot.inflight;
  if (inflight != null) {
    final stages = inflight.stages.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return stages.isEmpty ? null : stages.first;
  }
  if (snapshot.history.isEmpty) return null;
  final stages = snapshot.history.first.stages.values.toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return stages.isEmpty ? null : stages.first;
});

/// Aggregate snapshot the UI listens to.
class ScienceProcessingStatusSnapshot {
  final int queueDepth;
  final ScienceFrameStatus? inflight;
  final List<ScienceFrameStatus> history;
  final ScienceStageResult? lastFailure;

  const ScienceProcessingStatusSnapshot({
    required this.queueDepth,
    required this.inflight,
    required this.history,
    required this.lastFailure,
  });

  bool get isIdle => inflight == null && queueDepth == 0;

  bool get isBusy => inflight != null || queueDepth > 0;

  /// Total frames processed since the provider started listening.
  int get processedCount => history.length;

  /// Frames that had at least one failed stage.
  int get failedFrameCount => history.where((frame) => frame.hasFailure).length;

  /// Most recent successful frame, if any.
  ScienceFrameStatus? get lastSuccess {
    for (final frame in history) {
      if (!frame.hasFailure) return frame;
    }
    return null;
  }
}
