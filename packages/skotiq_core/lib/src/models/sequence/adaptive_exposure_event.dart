/// Typed wrapper for the
/// `SequencerEvent::ExposureAdjusted` event. The dashboard quality
/// panel reads the latest decision from this model to render
/// "L 142s (nominal 60s, sky 19.2 mag/arcsec²)".
///
/// An earlier build relied on parsing `InstructionProgress.detail`
/// strings; this typed payload follows the same model as
/// `FrameGradeEvent` and keeps the dashboard free of string parsing.
library;

/// Reason tag mirroring the Rust `AdaptiveExposureReason`. Plain enum
/// with a `fromWire` builder so we don't drag in freezed for a five-
/// variant tag.
enum AdaptiveExposureReason {
  adapted,
  clampedMin,
  clampedMax,
  unavailable,
  disabled,
  outOfNominalBounds,
  unknown;

  /// Build from the lowercase wire-format string emitted by Rust.
  /// Unknown strings map to [unknown] so a future bridge variant
  /// doesn't crash the dashboard.
  static AdaptiveExposureReason fromWire(String s) {
    switch (s) {
      case 'adapted':
        return AdaptiveExposureReason.adapted;
      case 'clamped_min':
        return AdaptiveExposureReason.clampedMin;
      case 'clamped_max':
        return AdaptiveExposureReason.clampedMax;
      case 'unavailable':
        return AdaptiveExposureReason.unavailable;
      case 'disabled':
        return AdaptiveExposureReason.disabled;
      case 'out_of_nominal_bounds':
        return AdaptiveExposureReason.outOfNominalBounds;
      default:
        return AdaptiveExposureReason.unknown;
    }
  }

  /// Human-readable label for the dashboard.
  String get label {
    switch (this) {
      case AdaptiveExposureReason.adapted:
        return 'adapted';
      case AdaptiveExposureReason.clampedMin:
        return 'clamped to min';
      case AdaptiveExposureReason.clampedMax:
        return 'clamped to max';
      case AdaptiveExposureReason.unavailable:
        return 'sky brightness unavailable';
      case AdaptiveExposureReason.disabled:
        return 'disabled';
      case AdaptiveExposureReason.outOfNominalBounds:
        return 'nominal out of bounds';
      case AdaptiveExposureReason.unknown:
        return 'unknown';
    }
  }
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
    required this.receivedAt,
  });

  /// Build from a typed `ExposureAdjusted` event's `data` map.
  /// Returns `null` for any event type other than `ExposureAdjusted`.
  static AdaptiveExposureEvent? fromTypedData(
    String eventType,
    Map<String, dynamic> data,
  ) {
    if (eventType != 'ExposureAdjusted') return null;
    final adapted = (data['adapted_secs'] as num?)?.toDouble();
    final nominal = (data['nominal_secs'] as num?)?.toDouble();
    if (adapted == null || nominal == null) return null;
    return AdaptiveExposureEvent(
      nodeId: data['node_id'] as String? ?? '',
      adaptedSecs: adapted,
      nominalSecs: nominal,
      skyBrightnessMag: (data['sky_brightness_mag'] as num?)?.toDouble(),
      filter: data['filter'] as String?,
      reason: AdaptiveExposureReason.fromWire(data['reason'] as String? ?? ''),
      receivedAt: DateTime.now(),
    );
  }

  /// Percent change from nominal. Positive => stretched (sky brighter
  /// than reference), negative => shortened.
  double get changePercent {
    if (nominalSecs <= 0) return 0;
    return ((adaptedSecs - nominalSecs) / nominalSecs) * 100;
  }

  /// Whether this decision actually changed the exposure duration
  /// noticeably (>1 % delta — anything smaller is rounding noise on
  /// the pipeline).
  bool get isNontrivialAdjustment => changePercent.abs() > 1.0;
}
