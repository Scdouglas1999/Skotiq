/// An adaptive exposure decision as the sequencer's `ExposureAdjusted` event
/// reports it, which the night panel reads.
library;

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show SequencerEvent_ExposureAdjusted;

/// Why the adapter chose a length, by the Rust `AdaptiveExposureReason` wire
/// word (`test_fixtures/wire_words/adaptive_exposure_reasons.json`).
enum AdaptiveExposureReason {
  adapted('adapted'),
  clampedMin('clamped_min'),
  clampedMax('clamped_max'),
  unavailable('unavailable'),
  disabled('disabled'),
  outOfNominalBounds('out_of_nominal_bounds'),

  /// A word this build does not know.
  unknown('');

  const AdaptiveExposureReason(this.wire);

  final String wire;

  static AdaptiveExposureReason fromWire(String s) =>
      values
          .where((reason) => reason != unknown && reason.wire == s)
          .firstOrNull ??
      unknown;
}

/// Typed payload for the sky-brightness adaptive exposure event.
class AdaptiveExposureEvent {
  /// Sequencer node id of the originating TakeExposure.
  final String nodeId;

  /// Effective exposure duration the camera will use (seconds).
  final double adaptedSecs;

  /// User-configured nominal duration (seconds).
  final double nominalSecs;

  /// Live sky brightness used in the decision (mag/arcsec²). `null`
  /// when the adapter fell back due to missing telemetry.
  final double? skyBrightnessMag;

  /// Filter being captured through. `null` for monochrome / no
  /// filter wheel rigs.
  final String? filter;

  /// Tag describing why the value was chosen.
  final AdaptiveExposureReason reason;

  /// The burst is taken at its planned length, as the sequencer decided.
  final bool unchanged;

  /// Wall-clock receipt timestamp (used to expire stale snapshots in
  /// the dashboard).
  final DateTime receivedAt;

  const AdaptiveExposureEvent({
    required this.nodeId,
    required this.adaptedSecs,
    required this.nominalSecs,
    required this.skyBrightnessMag,
    required this.filter,
    required this.reason,
    required this.unchanged,
    required this.receivedAt,
  });

  /// The decision a sequencer `ExposureAdjusted` event reports.
  factory AdaptiveExposureEvent.fromEvent(
    SequencerEvent_ExposureAdjusted event,
  ) => AdaptiveExposureEvent(
    nodeId: event.nodeId,
    adaptedSecs: event.adaptedSecs,
    nominalSecs: event.nominalSecs,
    skyBrightnessMag: event.skyBrightnessMag,
    filter: event.filter,
    reason: AdaptiveExposureReason.fromWire(event.reason),
    unchanged: event.unchanged,
    receivedAt: DateTime.now(),
  );
}
