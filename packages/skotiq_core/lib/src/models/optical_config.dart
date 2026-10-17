import 'dart:math';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'optical_config.freezed.dart';
part 'optical_config.g.dart';

/// Optical configuration combining telescope and camera information
/// for computing field of view and image scale.
@freezed
abstract class OpticalConfig with _$OpticalConfig {
  const factory OpticalConfig({
    /// Name of the telescope/OTA
    String? telescopeName,

    /// Focal length in millimeters
    double? focalLength,

    /// Aperture in millimeters
    double? aperture,

    /// Focal ratio (f/number), computed from focalLength/aperture if not set
    double? focalRatio,

    /// Camera name
    String? cameraName,

    /// Sensor width in pixels
    int? sensorWidth,

    /// Sensor height in pixels
    int? sensorHeight,

    /// Pixel size in microns
    double? pixelSize,
  }) = _OpticalConfig;

  const OpticalConfig._();

  factory OpticalConfig.fromJson(Map<String, dynamic> json) =>
      _$OpticalConfigFromJson(json);

  /// Field of view in degrees (width, height)
  ///
  /// Returns null if any required value is missing or invalid.
  /// Uses the formula: FOV = 2 * atan(sensorSize / (2 * focalLength)) * 180 / pi
  (double, double)? get fieldOfView {
    if (focalLength == null ||
        sensorWidth == null ||
        sensorHeight == null ||
        pixelSize == null) {
      return null;
    }
    if (focalLength == 0) return null;

    // Convert sensor dimensions from pixels to mm
    final widthMm = sensorWidth! * pixelSize! / 1000;
    final heightMm = sensorHeight! * pixelSize! / 1000;

    // Calculate FOV using atan formula
    final fovWidth = 2 * atan(widthMm / (2 * focalLength!)) * 180 / pi;
    final fovHeight = 2 * atan(heightMm / (2 * focalLength!)) * 180 / pi;

    return (fovWidth, fovHeight);
  }

  /// Image scale in arcseconds per pixel
  ///
  /// Returns null if focal length or pixel size is missing/invalid.
  /// Uses the formula: scale = 206.265 * pixelSize / focalLength
  /// where 206.265 is the number of arcseconds in a radian divided by 1000
  /// (to convert microns to mm).
  double? get imageScale {
    if (focalLength == null || pixelSize == null) return null;
    if (focalLength == 0) return null;
    return 206.265 * pixelSize! / focalLength!;
  }

  /// Computed focal ratio from aperture and focal length
  ///
  /// Returns the explicit focalRatio if set, otherwise computes it.
  /// Returns null if aperture or focal length is missing/invalid.
  double? get computedFocalRatio {
    if (focalRatio != null) return focalRatio;
    if (aperture == null || aperture == 0) return null;
    if (focalLength == null) return null;
    return focalLength! / aperture!;
  }

  /// Formatted FOV string like "1.72 x 1.17 degrees"
  ///
  /// Returns null if field of view cannot be computed.
  String? get fovString {
    final fov = fieldOfView;
    if (fov == null) return null;
    return '${fov.$1.toStringAsFixed(2)}\u00B0 \u00D7 ${fov.$2.toStringAsFixed(2)}\u00B0';
  }

  /// Formatted scale string like "1.41"/px"
  ///
  /// Returns null if image scale cannot be computed.
  String? get scaleString {
    final scale = imageScale;
    if (scale == null) return null;
    return '${scale.toStringAsFixed(2)}"/px';
  }

  /// Returns true if all required values are present to compute FOV
  bool get canComputeFov {
    return focalLength != null &&
        focalLength! > 0 &&
        sensorWidth != null &&
        sensorHeight != null &&
        pixelSize != null;
  }

  /// Returns true if all required values are present to compute image scale
  bool get canComputeScale {
    return focalLength != null && focalLength! > 0 && pixelSize != null;
  }

  /// Sensor diagonal in millimeters
  ///
  /// Returns null if sensor dimensions or pixel size is missing.
  double? get sensorDiagonalMm {
    if (sensorWidth == null || sensorHeight == null || pixelSize == null) {
      return null;
    }
    final widthMm = sensorWidth! * pixelSize! / 1000;
    final heightMm = sensorHeight! * pixelSize! / 1000;
    return sqrt(widthMm * widthMm + heightMm * heightMm);
  }

  /// Field of view diagonal in degrees
  ///
  /// Returns null if FOV cannot be computed.
  double? get fovDiagonal {
    final fov = fieldOfView;
    if (fov == null) return null;
    return sqrt(fov.$1 * fov.$1 + fov.$2 * fov.$2);
  }
}
