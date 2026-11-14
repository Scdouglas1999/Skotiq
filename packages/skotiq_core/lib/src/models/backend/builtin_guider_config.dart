/// Configuration for the built-in multi-star guider.
///
/// Mirrors the Rust `GuiderConfig` struct in `builtin_guider.rs`.
/// All fields have sensible defaults matching the Rust defaults.
class BuiltinGuiderConfig {
  /// Guide camera exposure time in seconds
  final double exposureSecs;

  final int gain;

  final int offset;

  final int binning;

  /// Calibration pulse duration in milliseconds
  final int calibrationMs;

  /// Sleep between settle checks in milliseconds
  final int settleSleepMs;

  /// Minimum guide pulse length in milliseconds (pulses smaller than this are skipped)
  final double minPulseMs;

  /// Maximum guide pulse length in milliseconds (pulses are clamped to this)
  final double maxPulseMs;

  const BuiltinGuiderConfig({
    this.exposureSecs = 1.0,
    this.gain = 100,
    this.offset = 10,
    this.binning = 1,
    this.calibrationMs = 250,
    this.settleSleepMs = 200,
    this.minPulseMs = 75.0,
    this.maxPulseMs = 1200.0,
  });

  /// Default configuration matching Rust defaults
  static const defaults = BuiltinGuiderConfig();

  BuiltinGuiderConfig copyWith({
    double? exposureSecs,
    int? gain,
    int? offset,
    int? binning,
    int? calibrationMs,
    int? settleSleepMs,
    double? minPulseMs,
    double? maxPulseMs,
  }) {
    return BuiltinGuiderConfig(
      exposureSecs: exposureSecs ?? this.exposureSecs,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      binning: binning ?? this.binning,
      calibrationMs: calibrationMs ?? this.calibrationMs,
      settleSleepMs: settleSleepMs ?? this.settleSleepMs,
      minPulseMs: minPulseMs ?? this.minPulseMs,
      maxPulseMs: maxPulseMs ?? this.maxPulseMs,
    );
  }

  /// Why this configuration cannot be sent to the guider, or null when it can.
  /// [mountPulseRangeMs] is the pulse-guide range the connected mount
  /// reports; without one the pulses only have to be in order.
  String? problem({({double min, double max})? mountPulseRangeMs}) {
    if (!exposureSecs.isFinite || exposureSecs <= 0 || exposureSecs > 30) {
      return 'Exposure must be more than 0 and at most 30 seconds.';
    }
    if (gain < 0) return 'Gain must be 0 or more.';
    if (offset < 0) return 'Offset must be 0 or more.';
    if (binning < 1 || binning > 4) return 'Binning must be from 1 to 4.';
    if (calibrationMs < 50 || calibrationMs > 5000) {
      return 'The calibration pulse must be from 50 to 5000 ms.';
    }
    if (settleSleepMs < 0) return 'Settle sleep must be 0 ms or more.';
    if (!minPulseMs.isFinite || !maxPulseMs.isFinite || minPulseMs < 0) {
      return 'Min pulse must be 0 ms or more.';
    }
    if (maxPulseMs <= minPulseMs) {
      return 'Max pulse must be longer than min pulse.';
    }
    final range = mountPulseRangeMs;
    if (range != null && (minPulseMs < range.min || maxPulseMs > range.max)) {
      return 'The mount pulse-guides from ${range.min.round()} to '
          '${range.max.round()} ms; keep min and max pulse inside that.';
    }
    return null;
  }

  factory BuiltinGuiderConfig.fromJson(Map<String, dynamic> json) {
    return BuiltinGuiderConfig(
      exposureSecs: (json['exposureSecs'] as num?)?.toDouble() ?? 1.0,
      gain: (json['gain'] as num?)?.toInt() ?? 100,
      offset: (json['offset'] as num?)?.toInt() ?? 10,
      binning: (json['binning'] as num?)?.toInt() ?? 1,
      calibrationMs: (json['calibrationMs'] as num?)?.toInt() ?? 250,
      settleSleepMs: (json['settleSleepMs'] as num?)?.toInt() ?? 200,
      minPulseMs: (json['minPulseMs'] as num?)?.toDouble() ?? 75.0,
      maxPulseMs: (json['maxPulseMs'] as num?)?.toDouble() ?? 1200.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'exposureSecs': exposureSecs,
    'gain': gain,
    'offset': offset,
    'binning': binning,
    'calibrationMs': calibrationMs,
    'settleSleepMs': settleSleepMs,
    'minPulseMs': minPulseMs,
    'maxPulseMs': maxPulseMs,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BuiltinGuiderConfig &&
          runtimeType == other.runtimeType &&
          exposureSecs == other.exposureSecs &&
          gain == other.gain &&
          offset == other.offset &&
          binning == other.binning &&
          calibrationMs == other.calibrationMs &&
          settleSleepMs == other.settleSleepMs &&
          minPulseMs == other.minPulseMs &&
          maxPulseMs == other.maxPulseMs;

  @override
  int get hashCode => Object.hash(
    exposureSecs,
    gain,
    offset,
    binning,
    calibrationMs,
    settleSleepMs,
    minPulseMs,
    maxPulseMs,
  );
}
