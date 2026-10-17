import 'package:freezed_annotation/freezed_annotation.dart';

part 'equipment_profile.freezed.dart';
part 'equipment_profile.g.dart';

@freezed
abstract class EquipmentProfile with _$EquipmentProfile {
  const factory EquipmentProfile({
    required String id,
    required String name,
    String? description,

    // Device identifiers
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterWheelId,
    String? guiderId,
    String? rotatorId,
    String? domeId,
    String? weatherId,
    String? safetyMonitorId,
    String? switchId,
    String? coverCalibratorId,

    // Optical setup
    @Default(0.0) double focalLength,
    @Default(0.0) double aperture,
    double? focalRatio,

    // Camera defaults
    int? defaultGain,
    int? defaultOffset,
    @Default(1) int defaultBinX,
    @Default(1) int defaultBinY,
    double? defaultCoolingTemp,
    @Default(false) bool coolOnConnect,

    // Centering/plate-solve exposure default (seconds)
    double? defaultCenteringExposure,

    // Filter configuration (JSON-serialized in DB)
    String? filterNames,
    String? filterFocusOffsets,

    // Meridian flip settings overrides (JSON)
    String? meridianFlipOverrides,

    // User-friendly device names
    String? cameraName,
    String? mountName,
    String? focuserName,
    String? filterWheelName,
    String? guiderName,
    String? rotatorName,
    String? safetyMonitorName,
    String? switchName,

    // Telescope/OTA information
    String? telescopeName,
    @Default(0.0) double telescopeFocalLength,
    @Default(0.0) double telescopeAperture,

    // Profile customization
    String? profileIcon,
    int? profileColor,
    @Default(0) int sortOrder,
    @Default(false) bool isDefault,

    // Timestamps
    DateTime? createdAt,
    DateTime? updatedAt,

    // State flags
    @Default(false) bool isActive,

    // Camera pixel size in microns (not in DB, used by bridge)
    double? pixelSize,
  }) = _EquipmentProfile;

  factory EquipmentProfile.fromJson(Map<String, dynamic> json) =>
      _$EquipmentProfileFromJson(json);
}

// Extension to provide computed properties and compatibility
extension EquipmentProfileExtension on EquipmentProfile {
  /// Get effective focal length (uses focalLength if set, otherwise telescopeFocalLength)
  double get effectiveFocalLength {
    // Use focalLength field if it's set (> 0), otherwise fall back to telescopeFocalLength
    return focalLength > 0 ? focalLength : telescopeFocalLength;
  }

  /// Get effective aperture (uses aperture if set, otherwise telescopeAperture)
  double get effectiveAperture {
    // Use aperture field if it's set (> 0), otherwise fall back to telescopeAperture
    return aperture > 0 ? aperture : telescopeAperture;
  }

  /// Get computed focal ratio
  double? get computedFocalRatio {
    if (focalRatio != null) return focalRatio;
    final ap = effectiveAperture;
    final fl = effectiveFocalLength;
    if (ap > 0 && fl > 0) {
      return fl / ap;
    }
    return null;
  }
}
