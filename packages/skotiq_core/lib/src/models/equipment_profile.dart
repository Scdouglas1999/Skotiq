import 'package:freezed_annotation/freezed_annotation.dart';

part 'equipment_profile.freezed.dart';
part 'equipment_profile.g.dart';

@freezed
abstract class EquipmentProfile with _$EquipmentProfile {
  const factory EquipmentProfile({
    required String id,
    required String name,
    String? description,

    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterWheelId,
    String? guiderId,
    String? guideCameraId,
    double? guideFocalLength,
    String? rotatorId,
    String? domeId,
    String? weatherId,
    String? safetyMonitorId,
    String? switchId,
    String? coverCalibratorId,

    @Default(0.0) double focalLength,
    @Default(0.0) double aperture,
    double? focalRatio,

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

    String? cameraName,
    String? mountName,
    String? focuserName,
    String? filterWheelName,
    String? guiderName,
    String? guideCameraName,
    String? rotatorName,
    String? safetyMonitorName,
    String? switchName,

    String? telescopeName,
    @Default(0.0) double telescopeFocalLength,
    @Default(0.0) double telescopeAperture,

    String? profileIcon,
    int? profileColor,
    @Default(0) int sortOrder,
    @Default(false) bool isDefault,

    DateTime? createdAt,
    DateTime? updatedAt,

    @Default(false) bool isActive,

    // Camera pixel size in microns (not in DB, used by bridge)
    double? pixelSize,
  }) = _EquipmentProfile;

  factory EquipmentProfile.fromJson(Map<String, dynamic> json) =>
      _$EquipmentProfileFromJson(json);
}

extension EquipmentProfileExtension on EquipmentProfile {
  /// Get effective focal length (uses focalLength if set, otherwise telescopeFocalLength)
  double get effectiveFocalLength {
    return focalLength > 0 ? focalLength : telescopeFocalLength;
  }

  /// Get effective aperture (uses aperture if set, otherwise telescopeAperture)
  double get effectiveAperture {
    return aperture > 0 ? aperture : telescopeAperture;
  }

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
