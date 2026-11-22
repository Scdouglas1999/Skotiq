import 'package:skotiq_core/backend.dart'
    show
        ImagingEvent_IntegrationProgress,
        SequencerEvent_DitherPerformed,
        SequencerEvent_FrameWatchReport,
        imagingEventOf,
        isPerTickTelemetry,
        sequencerEventOf;
import 'package:skotiq_core/models.dart';

/// The host's events of the night that a person reads in a log, kept apart
/// from the replay buffer so the telemetry that fills that buffer cannot push
/// them out.
///
/// A client that links in the middle of the night seeds its event log from
/// here (`GET /api/runtime/recent-events`). The replay buffer holds 5000
/// events, and a guided run sends a guide step every few seconds, so a
/// failure at start-up (a device that did not connect) was gone from it a few
/// hours later.
class NightEventLog {
  NightEventLog({this.capacity = 200}) : assert(capacity > 0);

  final int capacity;
  final List<SkotiqEvent> _events = [];

  /// Left out: per-tick telemetry that says nothing once it is old (and,
  /// for autofocus, carries star crops), and the per-dither and frame-watch
  /// reports the run's own record keeps.
  static bool _leftOut(SkotiqEvent event) =>
      isPerTickTelemetry(event) ||
      switch (sequencerEventOf(event)) {
        SequencerEvent_DitherPerformed() ||
        SequencerEvent_FrameWatchReport() => true,
        _ => false,
      };

  static String? _integrationPhase(SkotiqEvent event) =>
      switch (imagingEventOf(event)) {
        ImagingEvent_IntegrationProgress(:final phase) => phase,
        _ => null,
      };

  /// Keep [event] when it is one a person reads; the sync envelopes a client
  /// applies rather than logs are left out too.
  void append(SkotiqEvent event) {
    if (isHostSyncEnvelope(event) || _leftOut(event)) return;
    // Integration progress is a line per phase in the host's log
    // (registering, integrating, writing, done), but it reports each phase
    // many times; only the newest report of a phase is kept.
    final phase = _integrationPhase(event);
    if (phase != null &&
        _events.isNotEmpty &&
        _integrationPhase(_events.last) == phase) {
      _events.removeLast();
    }
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
  }

  /// The newest [limit] events kept, oldest first.
  List<SkotiqEvent> newest(int limit) => _events.length > limit
      ? List.unmodifiable(_events.sublist(_events.length - limit))
      : List.unmodifiable(_events);
}
