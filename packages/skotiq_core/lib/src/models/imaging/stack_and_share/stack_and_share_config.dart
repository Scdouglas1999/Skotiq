part of '../stack_and_share_models.dart';

/// Configuration for a single Stack-and-Share run.
///
/// Wraps the underlying [LiveStackingConfig] (alignment + pixel-rejection
/// parameters) and layers the share-loop concerns on top: calibration,
/// auto-stretch, and frame-quality gating.
class StackAndShareConfig {
  /// Alignment and pixel-rejection parameters handed to the live-stacking
  /// engine. Defaults to the engine's own sensible defaults.
  final LiveStackingConfig stackingConfig;

  /// Whether each light frame should be calibrated (dark/flat/bias subtraction
  /// via the dark library) before being added to the stack.
  final bool applyCalibration;

  /// Whether the final integrated result should be auto-stretched for display
  /// and export.
  ///
  /// The integrated buffer lives only in memory during a run, so the stretch
  /// goes through the engine's in-memory screen-transfer (STF) path
  /// (`apiAutoStretchImage`) — the only stretch the engine can apply to an
  /// in-memory u16 buffer. There is deliberately no stretch-*method* knob: the
  /// method-aware path (`apiApplyStretch`) operates on a FITS file on disk, not
  /// the in-memory result, so a method picker here would offer five choices
  /// that all produced the same STF output. The result viewer offers the same
  /// STF/Linear-only pair.
  final bool autoStretch;

  /// Minimum per-frame quality score required for a frame to be included in the
  /// stack. Frames scoring below this threshold are excluded. A value of `0`
  /// admits every frame (no quality gate).
  final double minQualityScore;

  /// Whether frames the user (or runtime grading) marked as not accepted should
  /// be rejected from the stack.
  final bool rejectUnaccepted;

  /// Sensor acquisition mode for the run: `"auto"`, `"mono"`, or `"osc"`.
  ///
  /// This is the Stack-and-Share-level OSC knob; it is folded into the
  /// underlying [LiveStackingConfig.sensorMode] by [resolvedStackingConfig].
  /// Unlike the live engine, which defaults to `"mono"`, this path defaults to
  /// `"auto"` so a colour camera's frames are debayered when they carry Bayer
  /// geometry without the user having to opt in. The three cases are defined
  /// on `ApiLiveStackingConfig.sensorMode`
  /// (skotiq_bridge/lib/src/api/imaging.dart).
  final String sensorMode;

  /// Explicit Bayer pattern override (`"RGGB"`/`"BGGR"`/`"GRBG"`/`"GBRG"`), or
  /// `null` to let an OSC/auto run fall back to the pattern the reference frame
  /// declares via its FITS `BAYERPAT` geometry. Folded into
  /// [LiveStackingConfig.bayerPattern]. An unrecognised string is a hard error
  /// native-side rather than a silent best-guess.
  final String? bayerPatternOverride;

  /// Demosaic quality for the OSC path: `"bilinear"`, `"vng"`, or
  /// `"superpixel"`. Folded into [LiveStackingConfig.demosaicQuality].
  ///
  /// Defaults to `"vng"` here — the Stack-and-Share path is the
  /// quality-oriented, post-capture integration, so it favours the
  /// higher-fidelity VNG demosaic over the live engine's `"bilinear"` default
  /// (which trades quality for the throughput a real-time EAA preview needs).
  /// An unrecognised value is a hard error native-side rather than a silent
  /// best-guess.
  final String demosaicQuality;

  const StackAndShareConfig({
    this.stackingConfig = const LiveStackingConfig(),
    this.applyCalibration = true,
    this.autoStretch = true,
    this.minQualityScore = 0,
    this.rejectUnaccepted = true,
    this.sensorMode = 'auto',
    this.bayerPatternOverride,
    this.demosaicQuality = 'vng',
  });

  /// Default configuration for a typical Stack-and-Share run.
  static const defaults = StackAndShareConfig();

  /// The [stackingConfig] with this config's OSC knobs ([sensorMode],
  /// [bayerPatternOverride], [demosaicQuality]) folded in.
  ///
  /// This is the config the orchestrator hands to the live-stacking engine: it
  /// guarantees the Stack-and-Share-level colour intent always reaches the
  /// engine, regardless of what defaults the wrapped [stackingConfig] carried.
  LiveStackingConfig get resolvedStackingConfig => stackingConfig.copyWith(
    sensorMode: sensorMode,
    bayerPattern: bayerPatternOverride,
    demosaicQuality: demosaicQuality,
  );

  StackAndShareConfig copyWith({
    LiveStackingConfig? stackingConfig,
    bool? applyCalibration,
    bool? autoStretch,
    double? minQualityScore,
    bool? rejectUnaccepted,
    String? sensorMode,
    String? bayerPatternOverride,
    String? demosaicQuality,
  }) {
    return StackAndShareConfig(
      stackingConfig: stackingConfig ?? this.stackingConfig,
      applyCalibration: applyCalibration ?? this.applyCalibration,
      autoStretch: autoStretch ?? this.autoStretch,
      minQualityScore: minQualityScore ?? this.minQualityScore,
      rejectUnaccepted: rejectUnaccepted ?? this.rejectUnaccepted,
      sensorMode: sensorMode ?? this.sensorMode,
      bayerPatternOverride: bayerPatternOverride ?? this.bayerPatternOverride,
      demosaicQuality: demosaicQuality ?? this.demosaicQuality,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StackAndShareConfig &&
          runtimeType == other.runtimeType &&
          stackingConfig == other.stackingConfig &&
          applyCalibration == other.applyCalibration &&
          autoStretch == other.autoStretch &&
          minQualityScore == other.minQualityScore &&
          rejectUnaccepted == other.rejectUnaccepted &&
          sensorMode == other.sensorMode &&
          bayerPatternOverride == other.bayerPatternOverride &&
          demosaicQuality == other.demosaicQuality;

  @override
  int get hashCode => Object.hash(
    stackingConfig,
    applyCalibration,
    autoStretch,
    minQualityScore,
    rejectUnaccepted,
    sensorMode,
    bayerPatternOverride,
    demosaicQuality,
  );
}
