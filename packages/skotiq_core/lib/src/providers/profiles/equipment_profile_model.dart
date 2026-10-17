part of '../profiles_provider.dart';

/// A fully-typed model representing an equipment profile
class EquipmentProfileModel {
  final int? id;
  final String name;
  final String? description;
  final bool isActive;

  // Device identifiers
  final String? cameraId;
  final String? mountId;
  final String? focuserId;
  final String? filterWheelId;
  final String? guiderId;
  final String? rotatorId;
  final String? domeId;
  final String? weatherId;
  final String? safetyMonitorId;
  final String? switchId;
  final String? coverCalibratorId;

  // User-friendly device names (can be auto-generated or custom)
  final String? cameraName;
  final String? mountName;
  final String? focuserName;
  final String? filterWheelName;
  final String? guiderName;
  final String? rotatorName;
  final String? safetyMonitorName;
  final String? switchName;

  // Telescope/OTA information
  final String? telescopeName;
  final double? telescopeFocalLength;
  final double? telescopeAperture;

  // Optical setup (profile-level, may differ from telescope if using reducers/barlows)
  final double focalLength;
  final double aperture;
  final double? focalRatio;

  // Camera defaults
  final int? defaultGain;
  final int? defaultOffset;
  final int defaultBinX;
  final int defaultBinY;
  final double? defaultCoolingTemp;
  final bool coolOnConnect;

  // Centering/plate-solve default exposure (seconds)
  final double? defaultCenteringExposure;

  // Filter configuration
  final List<String> filterNames;
  final Map<String, int> filterFocusOffsets;

  // Meridian flip settings overrides (raw JSON; null = use global defaults)
  final String? meridianFlipOverrides;

  // Profile customization
  final String? profileIcon;
  final int? profileColor;
  final int sortOrder;
  final bool isDefault;

  // Timestamps
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const EquipmentProfileModel({
    this.id,
    required this.name,
    this.description,
    this.isActive = false,
    this.cameraId,
    this.mountId,
    this.focuserId,
    this.filterWheelId,
    this.guiderId,
    this.rotatorId,
    this.domeId,
    this.weatherId,
    this.safetyMonitorId,
    this.switchId,
    this.coverCalibratorId,
    this.cameraName,
    this.mountName,
    this.focuserName,
    this.filterWheelName,
    this.guiderName,
    this.rotatorName,
    this.safetyMonitorName,
    this.switchName,
    this.telescopeName,
    this.telescopeFocalLength,
    this.telescopeAperture,
    this.focalLength = 0.0,
    this.aperture = 0.0,
    this.focalRatio,
    this.defaultGain,
    this.defaultOffset,
    this.defaultBinX = 1,
    this.defaultBinY = 1,
    this.defaultCoolingTemp,
    this.coolOnConnect = false,
    this.defaultCenteringExposure,
    this.filterNames = const [],
    this.filterFocusOffsets = const {},
    this.meridianFlipOverrides,
    this.profileIcon,
    this.profileColor,
    this.sortOrder = 0,
    this.isDefault = false,
    this.createdAt,
    this.updatedAt,
  });

  /// Returns telescope name + camera name as subtitle, or fallback
  String get subtitle {
    if (telescopeName != null && cameraName != null) {
      return '$telescopeName + $cameraName';
    }
    if (cameraName != null) return cameraName!;
    if (mountName != null) return mountName!;
    return '$deviceCount devices';
  }

  /// Count of assigned devices (non-null device IDs)
  int get deviceCount {
    int count = 0;
    if (cameraId != null) count++;
    if (mountId != null) count++;
    if (focuserId != null) count++;
    if (filterWheelId != null) count++;
    if (guiderId != null) count++;
    if (rotatorId != null) count++;
    if (domeId != null) count++;
    if (weatherId != null) count++;
    if (safetyMonitorId != null) count++;
    if (switchId != null) count++;
    if (coverCalibratorId != null) count++;
    return count;
  }

  /// Create from database entity
  factory EquipmentProfileModel.fromDatabase(EquipmentProfile db) {
    List<String> filters = [];
    Map<String, int> offsets = {};
    final rawTelescopeFocalLength = db.telescopeFocalLength;
    final rawTelescopeAperture = db.telescopeAperture;
    final telescopeFocalLength =
        rawTelescopeFocalLength != null && rawTelescopeFocalLength > 0
        ? rawTelescopeFocalLength
        : null;
    final telescopeAperture =
        rawTelescopeAperture != null && rawTelescopeAperture > 0
        ? rawTelescopeAperture
        : null;
    final effectiveFocalLength = db.focalLength > 0
        ? db.focalLength
        : (telescopeFocalLength ?? 0.0);
    final effectiveAperture = db.aperture > 0
        ? db.aperture
        : (telescopeAperture ?? 0.0);

    if (db.filterNames != null) {
      try {
        filters = decodeStringListJson(
          db.filterNames,
          context: 'equipment_profiles.filter_names for "${db.name}"',
        );
      } catch (e) {
        _log.warning(
          'Failed to parse filterNames JSON for profile "${db.name}": $e',
        );
      }
    }

    if (db.filterFocusOffsets != null) {
      try {
        offsets = decodeStringIntMapJson(
          db.filterFocusOffsets,
          context: 'equipment_profiles.filter_focus_offsets for "${db.name}"',
        );
      } catch (e) {
        _log.warning(
          'Failed to parse filterFocusOffsets JSON for profile "${db.name}": $e',
        );
      }
    }

    return EquipmentProfileModel(
      id: db.id,
      name: db.name,
      description: db.description,
      isActive: db.isActive,
      cameraId: db.cameraId,
      mountId: db.mountId,
      focuserId: db.focuserId,
      filterWheelId: db.filterWheelId,
      guiderId: db.guiderId,
      rotatorId: db.rotatorId,
      domeId: db.domeId,
      weatherId: db.weatherId,
      safetyMonitorId: db.safetyMonitorId,
      switchId: db.switchId,
      coverCalibratorId: db.coverCalibratorId,
      cameraName: db.cameraName,
      mountName: db.mountName,
      focuserName: db.focuserName,
      filterWheelName: db.filterWheelName,
      guiderName: db.guiderName,
      rotatorName: db.rotatorName,
      safetyMonitorName: db.safetyMonitorName,
      switchName: db.switchName,
      telescopeName: db.telescopeName,
      telescopeFocalLength: telescopeFocalLength,
      telescopeAperture: telescopeAperture,
      focalLength: effectiveFocalLength,
      aperture: effectiveAperture,
      focalRatio: db.focalRatio,
      defaultGain: db.defaultGain,
      defaultOffset: db.defaultOffset,
      defaultBinX: db.defaultBinX,
      defaultBinY: db.defaultBinY,
      defaultCoolingTemp: db.defaultCoolingTemp,
      coolOnConnect: db.coolOnConnect,
      defaultCenteringExposure: db.defaultCenteringExposure,
      filterNames: filters,
      filterFocusOffsets: offsets,
      meridianFlipOverrides: db.meridianFlipOverrides,
      profileIcon: db.profileIcon,
      profileColor: db.profileColor,
      sortOrder: db.sortOrder,
      isDefault: db.isDefault,
      createdAt: db.createdAt,
      updatedAt: db.updatedAt,
    );
  }

  /// Create from the host's REST `/api/profiles` payload when running as a
  /// remote companion (NetworkBackend).
  factory EquipmentProfileModel.fromRemoteProfile(
    remote_profile.EquipmentProfile profile,
  ) {
    List<String> filters = [];
    Map<String, int> offsets = {};

    if (profile.filterNames != null && profile.filterNames!.isNotEmpty) {
      try {
        filters = decodeStringListJson(
          profile.filterNames,
          context: 'remote profile "${profile.name}" filterNames',
        );
      } catch (e) {
        _log.warning(
          'Failed to parse remote filterNames for "${profile.name}": $e',
        );
      }
    }

    if (profile.filterFocusOffsets != null &&
        profile.filterFocusOffsets!.isNotEmpty) {
      try {
        offsets = decodeStringIntMapJson(
          profile.filterFocusOffsets,
          context: 'remote profile "${profile.name}" filterFocusOffsets',
        );
      } catch (e) {
        _log.warning(
          'Failed to parse remote filterFocusOffsets for "${profile.name}": $e',
        );
      }
    }

    final remoteId = int.tryParse(profile.id);

    return EquipmentProfileModel(
      id: remoteId,
      name: profile.name,
      description: profile.description,
      isActive: profile.isActive,
      cameraId: profile.cameraId,
      mountId: profile.mountId,
      focuserId: profile.focuserId,
      filterWheelId: profile.filterWheelId,
      guiderId: profile.guiderId,
      rotatorId: profile.rotatorId,
      domeId: profile.domeId,
      weatherId: profile.weatherId,
      safetyMonitorId: profile.safetyMonitorId,
      switchId: profile.switchId,
      coverCalibratorId: profile.coverCalibratorId,
      cameraName: profile.cameraName,
      mountName: profile.mountName,
      focuserName: profile.focuserName,
      filterWheelName: profile.filterWheelName,
      guiderName: profile.guiderName,
      rotatorName: profile.rotatorName,
      safetyMonitorName: profile.safetyMonitorName,
      switchName: profile.switchName,
      telescopeName: profile.telescopeName,
      telescopeFocalLength: profile.telescopeFocalLength > 0
          ? profile.telescopeFocalLength
          : null,
      telescopeAperture: profile.telescopeAperture > 0
          ? profile.telescopeAperture
          : null,
      focalLength: profile.focalLength,
      aperture: profile.aperture,
      focalRatio: profile.focalRatio,
      defaultGain: profile.defaultGain,
      defaultOffset: profile.defaultOffset,
      defaultBinX: profile.defaultBinX,
      defaultBinY: profile.defaultBinY,
      defaultCoolingTemp: profile.defaultCoolingTemp,
      coolOnConnect: profile.coolOnConnect,
      defaultCenteringExposure: profile.defaultCenteringExposure,
      filterNames: filters,
      filterFocusOffsets: offsets,
      meridianFlipOverrides: profile.meridianFlipOverrides,
      profileIcon: profile.profileIcon,
      profileColor: profile.profileColor,
      sortOrder: profile.sortOrder,
      isDefault: profile.isDefault,
      createdAt: profile.createdAt,
      updatedAt: profile.updatedAt,
    );
  }

  /// Convert to database companion for insert/update
  EquipmentProfilesCompanion toCompanion() {
    return EquipmentProfilesCompanion(
      id: id != null ? Value(id!) : const Value.absent(),
      name: Value(name),
      description: Value(description),
      isActive: Value(isActive),
      cameraId: Value(cameraId),
      mountId: Value(mountId),
      focuserId: Value(focuserId),
      filterWheelId: Value(filterWheelId),
      guiderId: Value(guiderId),
      rotatorId: Value(rotatorId),
      domeId: Value(domeId),
      weatherId: Value(weatherId),
      safetyMonitorId: Value(safetyMonitorId),
      switchId: Value(switchId),
      coverCalibratorId: Value(coverCalibratorId),
      cameraName: Value(cameraName),
      mountName: Value(mountName),
      focuserName: Value(focuserName),
      filterWheelName: Value(filterWheelName),
      guiderName: Value(guiderName),
      rotatorName: Value(rotatorName),
      safetyMonitorName: Value(safetyMonitorName),
      switchName: Value(switchName),
      telescopeName: Value(telescopeName),
      telescopeFocalLength: Value(telescopeFocalLength),
      telescopeAperture: Value(telescopeAperture),
      focalLength: Value(focalLength),
      aperture: Value(aperture),
      focalRatio: Value(focalRatio),
      defaultGain: Value(defaultGain),
      defaultOffset: Value(defaultOffset),
      defaultBinX: Value(defaultBinX),
      defaultBinY: Value(defaultBinY),
      defaultCoolingTemp: Value(defaultCoolingTemp),
      coolOnConnect: Value(coolOnConnect),
      defaultCenteringExposure: Value(defaultCenteringExposure),
      filterNames: Value(
        filterNames.isNotEmpty ? jsonEncode(filterNames) : null,
      ),
      filterFocusOffsets: Value(
        filterFocusOffsets.isNotEmpty ? jsonEncode(filterFocusOffsets) : null,
      ),
      meridianFlipOverrides: Value(meridianFlipOverrides),
      profileIcon: Value(profileIcon),
      profileColor: Value(profileColor),
      sortOrder: Value(sortOrder),
      isDefault: Value(isDefault),
      updatedAt: Value(DateTime.now()),
    );
  }

  EquipmentProfileModel copyWith({
    int? id,
    String? name,
    String? description,
    bool? isActive,
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
    String? cameraName,
    String? mountName,
    String? focuserName,
    String? filterWheelName,
    String? guiderName,
    String? rotatorName,
    String? safetyMonitorName,
    String? switchName,
    String? telescopeName,
    double? telescopeFocalLength,
    double? telescopeAperture,
    double? focalLength,
    double? aperture,
    double? focalRatio,
    int? defaultGain,
    int? defaultOffset,
    int? defaultBinX,
    int? defaultBinY,
    double? defaultCoolingTemp,
    bool? coolOnConnect,
    double? defaultCenteringExposure,
    List<String>? filterNames,
    Map<String, int>? filterFocusOffsets,
    String? meridianFlipOverrides,
    String? profileIcon,
    int? profileColor,
    int? sortOrder,
    bool? isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return EquipmentProfileModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      isActive: isActive ?? this.isActive,
      cameraId: cameraId ?? this.cameraId,
      mountId: mountId ?? this.mountId,
      focuserId: focuserId ?? this.focuserId,
      filterWheelId: filterWheelId ?? this.filterWheelId,
      guiderId: guiderId ?? this.guiderId,
      rotatorId: rotatorId ?? this.rotatorId,
      domeId: domeId ?? this.domeId,
      weatherId: weatherId ?? this.weatherId,
      safetyMonitorId: safetyMonitorId ?? this.safetyMonitorId,
      switchId: switchId ?? this.switchId,
      coverCalibratorId: coverCalibratorId ?? this.coverCalibratorId,
      cameraName: cameraName ?? this.cameraName,
      mountName: mountName ?? this.mountName,
      focuserName: focuserName ?? this.focuserName,
      filterWheelName: filterWheelName ?? this.filterWheelName,
      guiderName: guiderName ?? this.guiderName,
      rotatorName: rotatorName ?? this.rotatorName,
      safetyMonitorName: safetyMonitorName ?? this.safetyMonitorName,
      switchName: switchName ?? this.switchName,
      telescopeName: telescopeName ?? this.telescopeName,
      telescopeFocalLength: telescopeFocalLength ?? this.telescopeFocalLength,
      telescopeAperture: telescopeAperture ?? this.telescopeAperture,
      focalLength: focalLength ?? this.focalLength,
      aperture: aperture ?? this.aperture,
      focalRatio: focalRatio ?? this.focalRatio,
      defaultGain: defaultGain ?? this.defaultGain,
      defaultOffset: defaultOffset ?? this.defaultOffset,
      defaultBinX: defaultBinX ?? this.defaultBinX,
      defaultBinY: defaultBinY ?? this.defaultBinY,
      defaultCoolingTemp: defaultCoolingTemp ?? this.defaultCoolingTemp,
      coolOnConnect: coolOnConnect ?? this.coolOnConnect,
      defaultCenteringExposure:
          defaultCenteringExposure ?? this.defaultCenteringExposure,
      filterNames: filterNames ?? this.filterNames,
      filterFocusOffsets: filterFocusOffsets ?? this.filterFocusOffsets,
      meridianFlipOverrides:
          meridianFlipOverrides ?? this.meridianFlipOverrides,
      profileIcon: profileIcon ?? this.profileIcon,
      profileColor: profileColor ?? this.profileColor,
      sortOrder: sortOrder ?? this.sortOrder,
      isDefault: isDefault ?? this.isDefault,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Build a fresh INSERTION copy of this profile: no id, inert
  /// active/default flags, fresh timestamps, and the supplied [name]. Every
  /// other device id/name, optical, camera-default, filter, meridian-flip and
  /// customization field is preserved verbatim.
  ///
  /// Why not `copyWith`: `copyWith`'s nullable `id ?? this.id` semantics CANNOT
  /// clear the id — `copyWith(id: null)` silently keeps the source id, which on
  /// the remote path makes the host UPDATE (rename) the source instead of
  /// creating a copy, and it also retains `isDefault`. This constructs a genuine
  /// create with `id == null` (so `toRemoteProfile()` emits an empty id the host
  /// treats as a create) and `isActive == false` / `isDefault == false`.
  EquipmentProfileModel toInsertionCopy({required String name}) {
    return EquipmentProfileModel(
      // id intentionally omitted -> null -> host/DAO treats this as a CREATE.
      name: name,
      description: description,
      isActive: false,
      isDefault: false,
      cameraId: cameraId,
      mountId: mountId,
      focuserId: focuserId,
      filterWheelId: filterWheelId,
      guiderId: guiderId,
      rotatorId: rotatorId,
      domeId: domeId,
      weatherId: weatherId,
      safetyMonitorId: safetyMonitorId,
      switchId: switchId,
      coverCalibratorId: coverCalibratorId,
      cameraName: cameraName,
      mountName: mountName,
      focuserName: focuserName,
      filterWheelName: filterWheelName,
      guiderName: guiderName,
      rotatorName: rotatorName,
      safetyMonitorName: safetyMonitorName,
      switchName: switchName,
      telescopeName: telescopeName,
      telescopeFocalLength: telescopeFocalLength,
      telescopeAperture: telescopeAperture,
      focalLength: focalLength,
      aperture: aperture,
      focalRatio: focalRatio,
      defaultGain: defaultGain,
      defaultOffset: defaultOffset,
      defaultBinX: defaultBinX,
      defaultBinY: defaultBinY,
      defaultCoolingTemp: defaultCoolingTemp,
      coolOnConnect: coolOnConnect,
      defaultCenteringExposure: defaultCenteringExposure,
      filterNames: filterNames,
      filterFocusOffsets: filterFocusOffsets,
      meridianFlipOverrides: meridianFlipOverrides,
      profileIcon: profileIcon,
      profileColor: profileColor,
      sortOrder: sortOrder,
      // createdAt/updatedAt omitted -> null -> fresh timestamps on insert.
    );
  }

  /// Calculate f/ratio from focal length and aperture, or null when the numbers
  /// cannot describe a real optical system.
  ///
  /// Validation now bounds every path that can WRITE optics, but rows written
  /// before that — or restored from a backup, which deliberately reproduces
  /// prior state verbatim — can still hold an implausible pair. Reporting
  /// `f/9999999990000.00` as a derived fact is the same defect class as the
  /// original: the app stating something untrue. Every caller already handles
  /// null (Settings renders a dash), so refusing to compute is strictly better
  /// than computing nonsense.
  double? get calculatedFocalRatio {
    final ratio = focalRatio ?? (aperture > 0 ? focalLength / aperture : null);
    if (ratio == null || !ratio.isFinite) return null;
    if (ratio < OpticalTrainLimits.minFRatio ||
        ratio > OpticalTrainLimits.maxFRatio) {
      return null;
    }
    return ratio;
  }

  /// Get field of view for given sensor dimensions
  (double width, double height) getFieldOfView({
    required double sensorWidthMm,
    required double sensorHeightMm,
  }) {
    if (focalLength <= 0) return (0, 0);
    final widthDeg = 2 * (57.3 * (sensorWidthMm / (2 * focalLength)));
    final heightDeg = 2 * (57.3 * (sensorHeightMm / (2 * focalLength)));
    return (widthDeg, heightDeg);
  }

  /// REST `/api/profiles` payload for host-authoritative writes.
  remote_profile.EquipmentProfile toRemoteProfile() {
    return remote_profile.EquipmentProfile(
      id: id?.toString() ?? '',
      name: name,
      description: description,
      cameraId: cameraId,
      mountId: mountId,
      focuserId: focuserId,
      filterWheelId: filterWheelId,
      guiderId: guiderId,
      rotatorId: rotatorId,
      domeId: domeId,
      weatherId: weatherId,
      safetyMonitorId: safetyMonitorId,
      switchId: switchId,
      coverCalibratorId: coverCalibratorId,
      focalLength: focalLength,
      aperture: aperture,
      focalRatio: focalRatio,
      defaultGain: defaultGain,
      defaultOffset: defaultOffset,
      defaultBinX: defaultBinX,
      defaultBinY: defaultBinY,
      defaultCoolingTemp: defaultCoolingTemp,
      coolOnConnect: coolOnConnect,
      defaultCenteringExposure: defaultCenteringExposure,
      filterNames: filterNames.isNotEmpty ? jsonEncode(filterNames) : null,
      filterFocusOffsets: filterFocusOffsets.isNotEmpty
          ? jsonEncode(filterFocusOffsets)
          : null,
      meridianFlipOverrides: meridianFlipOverrides,
      cameraName: cameraName,
      mountName: mountName,
      focuserName: focuserName,
      filterWheelName: filterWheelName,
      guiderName: guiderName,
      rotatorName: rotatorName,
      safetyMonitorName: safetyMonitorName,
      switchName: switchName,
      telescopeName: telescopeName,
      telescopeFocalLength: telescopeFocalLength ?? 0.0,
      telescopeAperture: telescopeAperture ?? 0.0,
      profileIcon: profileIcon,
      profileColor: profileColor,
      sortOrder: sortOrder,
      isDefault: isDefault,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      isActive: isActive,
    );
  }
}
