import 'dart:math' as math;

/// Named dither-settle scenarios. Each maps a real-world observing condition to
/// a target guide-error tolerance (in arcseconds) and a settle dwell time (in
/// seconds). The pixel threshold is derived from the tolerance and the rig's
/// pixel scale so the chips mean the same thing across very different optics.
enum DitherSettlePreset {
  /// Steady atmosphere: tight tolerance for round stars, moderate dwell so we
  /// are confident the guider has actually recovered before resuming.
  goodSeeing,

  /// Gusty / unstable mount: loose tolerance and a long dwell so settling can
  /// ride out wind buffeting instead of timing out.
  windy,

  /// Short focal length / low f-ratio: forgiving per-pixel error and a short
  /// dwell to keep cadence high and maximise frame count.
  fastOptics,
}

extension DitherSettlePresetLabel on DitherSettlePreset {
  /// Short human label for chip UI.
  String get label => switch (this) {
    DitherSettlePreset.goodSeeing => 'Good seeing',
    DitherSettlePreset.windy => 'Windy',
    DitherSettlePreset.fastOptics => 'Fast optics',
  };

  /// Target guide-error tolerance in arcseconds for this scenario. The pixel
  /// threshold is `toleranceArcsec / pixelScale`, so a wider sensor scale
  /// (arcsec/px) yields a smaller pixel number for the same physical tolerance.
  double get toleranceArcsec => switch (this) {
    DitherSettlePreset.goodSeeing => 1.0,
    DitherSettlePreset.windy => 2.5,
    DitherSettlePreset.fastOptics => 1.5,
  };

  /// Settle dwell time in seconds (how long the guide error must stay below the
  /// threshold before settling is declared complete).
  double get settleTimeSeconds => switch (this) {
    DitherSettlePreset.goodSeeing => 8.0,
    DitherSettlePreset.windy => 20.0,
    DitherSettlePreset.fastOptics => 5.0,
  };
}

/// A derived settle threshold + dwell time pair for a given preset and rig.
class DitherSettleValues {
  /// Settle threshold in guide-camera pixels.
  final double settlePixels;

  /// Settle dwell time in seconds.
  final double settleTime;

  const DitherSettleValues({
    required this.settlePixels,
    required this.settleTime,
  });

  @override
  bool operator ==(Object other) =>
      other is DitherSettleValues &&
      other.settlePixels == settlePixels &&
      other.settleTime == settleTime;

  @override
  int get hashCode => Object.hash(settlePixels, settleTime);

  @override
  String toString() =>
      'DitherSettleValues(settlePixels: $settlePixels, settleTime: $settleTime)';
}

/// Standard small-angle pixel scale in arcsec/pixel: `206.265 * pixelSizeUm /
/// focalLengthMm`. Returns `null` when either input is missing/non-positive —
/// we never invent a scale from a single dimension.
double? ditherPixelScaleArcsecPerPixel({
  double? pixelSizeUm,
  double? focalLengthMm,
}) {
  if (pixelSizeUm == null ||
      pixelSizeUm <= 0 ||
      focalLengthMm == null ||
      focalLengthMm <= 0) {
    return null;
  }
  return 206.265 * pixelSizeUm / focalLengthMm;
}

/// Lower/upper clamps on the derived pixel threshold. Below ~0.3px the guider
/// chases noise and never settles; above ~6px the "settled" frame can still
/// carry visible trailing, so we never derive an out-of-band threshold even on
/// extreme rigs.
const double kDitherSettleMinPixels = 0.3;
const double kDitherSettleMaxPixels = 6.0;

/// Derive a sane settle threshold (px) + dwell time (s) for [preset] from the
/// rig's [pixelScaleArcsecPerPixel] (arcsec/px). Pure and side-effect free so
/// the "presets compute sane values for a focal length + pixel scale" rule is
/// unit-testable directly.
///
/// The pixel threshold is `preset.toleranceArcsec / pixelScale`, rounded to one
/// decimal and clamped to [[kDitherSettleMinPixels], [kDitherSettleMaxPixels]].
/// When [pixelScaleArcsecPerPixel] is missing or non-positive we fall back to
/// the preset's tolerance interpreted directly as pixels (still clamped), so a
/// chip always produces a usable value.
DitherSettleValues deriveDitherSettleValues({
  required DitherSettlePreset preset,
  double? pixelScaleArcsecPerPixel,
}) {
  final scale = pixelScaleArcsecPerPixel;
  final rawPixels = (scale != null && scale > 0)
      ? preset.toleranceArcsec / scale
      : preset.toleranceArcsec;
  final clamped = rawPixels.clamp(
    kDitherSettleMinPixels,
    kDitherSettleMaxPixels,
  );
  // Round to one decimal to match the settle-pixel input's precision.
  final settlePixels = (clamped * 10).roundToDouble() / 10;
  return DitherSettleValues(
    settlePixels: math.max(kDitherSettleMinPixels, settlePixels),
    settleTime: preset.settleTimeSeconds,
  );
}

/// Convenience: derive directly from sensor pitch + focal length (the two
/// numbers the user already entered in their equipment profile).
DitherSettleValues deriveDitherSettleValuesFromRig({
  required DitherSettlePreset preset,
  double? pixelSizeUm,
  double? focalLengthMm,
}) {
  return deriveDitherSettleValues(
    preset: preset,
    pixelScaleArcsecPerPixel: ditherPixelScaleArcsecPerPixel(
      pixelSizeUm: pixelSizeUm,
      focalLengthMm: focalLengthMm,
    ),
  );
}
