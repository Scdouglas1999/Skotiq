import 'package:freezed_annotation/freezed_annotation.dart';

part 'auto_stretch_settings.freezed.dart';
part 'auto_stretch_settings.g.dart';

/// Method used for auto-stretching astronomical images.
///
/// Each method has different characteristics suitable for different image types:
/// - [stf]: PixInsight-style Screen Transfer Function, excellent for linear data
/// - [histogram]: Histogram equalization, good for bringing out faint details
/// - [asinh]: Arcsinh stretch, preserves star colors well
/// - [log]: Logarithmic stretch, good for high dynamic range
/// - [gamma]: Simple gamma correction, fast and predictable
enum AutoStretchMethod {
  /// PixInsight-style Screen Transfer Function.
  /// Uses median-based scaling with configurable shadow/highlight clipping.
  /// Best for linear astronomical data with faint nebulosity.
  stf,

  /// Histogram equalization stretch.
  /// Redistributes pixel values to maximize contrast across the full range.
  /// Good for bringing out faint details but can oversaturate bright areas.
  histogram,

  /// Arcsinh (inverse hyperbolic sine) stretch.
  /// Provides smooth transition from linear to logarithmic behavior.
  /// Excellent for preserving star colors while stretching faint details.
  asinh,

  /// Logarithmic stretch.
  /// Compresses high values while expanding low values.
  /// Useful for high dynamic range images with bright cores.
  log,

  /// Simple gamma correction.
  /// Applies power-law transformation with configurable gamma value.
  /// Fast and predictable, good for quick previews.
  gamma,
}

/// Settings for automatic image stretching during live preview and capture review.
///
/// Auto-stretch applies a non-linear transformation to make faint astronomical
/// details visible in linear camera data. The settings control how aggressively
/// the stretch is applied and which algorithm is used.
@freezed
abstract class AutoStretchSettings with _$AutoStretchSettings {
  const AutoStretchSettings._();

  const factory AutoStretchSettings({
    /// Whether auto-stretch is enabled for image display.
    @Default(false) bool enabled,

    /// The stretch method to use.
    @Default(AutoStretchMethod.stf) AutoStretchMethod method,

    /// Shadow clipping parameter (in standard deviations from median).
    /// Lower (more negative) values clip more shadows.
    /// Typical range: -4.0 to -1.0. Default -2.8 is standard for STF.
    @Default(-2.8) double shadowClip,

    /// Highlight clipping parameter (in standard deviations from median).
    /// Lower (more negative) values clip more highlights.
    /// Typical range: -1.0 to 0.0. Default -0.5 protects highlights.
    @Default(-0.5) double highlightClip,

    /// Target median level for the stretched image (0.0 to 1.0).
    /// Higher values produce brighter midtones.
    /// Default 0.25 places the median in the lower quarter for natural appearance.
    @Default(0.25) double targetMedian,

    /// Whether to link RGB channels during stretch calculation.
    /// When true, uses the same stretch parameters for all channels to preserve
    /// color balance. When false, each channel is stretched independently.
    @Default(true) bool linkedChannels,

    /// Gamma value for gamma correction method.
    /// Only used when [method] is [AutoStretchMethod.gamma].
    /// Standard display gamma is 2.2. Lower values brighten, higher values darken.
    @Default(2.2) double gammaValue,
  }) = _AutoStretchSettings;

  /// Creates settings with sensible defaults for general astrophotography.
  factory AutoStretchSettings.defaults() => const AutoStretchSettings(
    enabled: false,
    method: AutoStretchMethod.stf,
    shadowClip: -2.8,
    highlightClip: -0.5,
    targetMedian: 0.25,
    linkedChannels: true,
    gammaValue: 2.2,
  );

  /// Creates optimized settings for a specific stretch method.
  ///
  /// Returns settings tuned for the characteristics of each method:
  /// - [AutoStretchMethod.stf]: Standard PixInsight STF parameters
  /// - [AutoStretchMethod.histogram]: Moderate clipping to prevent oversaturation
  /// - [AutoStretchMethod.asinh]: Gentle stretch preserving star colors
  /// - [AutoStretchMethod.log]: Aggressive stretch for high dynamic range
  /// - [AutoStretchMethod.gamma]: Standard 2.2 gamma for display
  factory AutoStretchSettings.forMethod(AutoStretchMethod method) {
    switch (method) {
      case AutoStretchMethod.stf:
        return const AutoStretchSettings(
          enabled: true,
          method: AutoStretchMethod.stf,
          shadowClip: -2.8,
          highlightClip: -0.5,
          targetMedian: 0.25,
          linkedChannels: true,
          gammaValue: 2.2,
        );
      case AutoStretchMethod.histogram:
        return const AutoStretchSettings(
          enabled: true,
          method: AutoStretchMethod.histogram,
          shadowClip: -2.0,
          highlightClip: -0.2,
          targetMedian: 0.5,
          linkedChannels: true,
          gammaValue: 2.2,
        );
      case AutoStretchMethod.asinh:
        return const AutoStretchSettings(
          enabled: true,
          method: AutoStretchMethod.asinh,
          shadowClip: -3.0,
          highlightClip: -0.3,
          targetMedian: 0.2,
          linkedChannels: true,
          gammaValue: 2.2,
        );
      case AutoStretchMethod.log:
        return const AutoStretchSettings(
          enabled: true,
          method: AutoStretchMethod.log,
          shadowClip: -2.5,
          highlightClip: -0.8,
          targetMedian: 0.3,
          linkedChannels: true,
          gammaValue: 2.2,
        );
      case AutoStretchMethod.gamma:
        return const AutoStretchSettings(
          enabled: true,
          method: AutoStretchMethod.gamma,
          shadowClip: -2.8,
          highlightClip: -0.5,
          targetMedian: 0.25,
          linkedChannels: false,
          gammaValue: 2.2,
        );
    }
  }

  factory AutoStretchSettings.fromJson(Map<String, dynamic> json) =>
      _$AutoStretchSettingsFromJson(json);
}
