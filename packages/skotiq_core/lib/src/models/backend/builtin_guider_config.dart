/// Configuration for the built-in multi-star guider.
///
/// Mirrors the Rust `GuiderConfig` struct in `builtin_guider.rs`.
/// All fields have sensible defaults matching the Rust defaults.
class BuiltinGuiderConfig {
  /// Guide camera exposure time in seconds
  final double exposureSecs;

  /// Guide camera gain
  final int gain;

  /// Guide camera offset
  final int offset;

  /// Guide camera binning
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

  /// Create from JSON (for network transport)
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

  /// Convert to JSON (for network transport)
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
