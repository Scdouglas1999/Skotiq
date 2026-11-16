import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';

import '../../models/equipment_profile.dart' as remote_profile;
import '../../models/equipment_profile_model.dart';
import '../../utils/json_validation.dart';
import '../database.dart';
import 'equipment_profile_remote_mapping.dart';

final _log = Logger('ProfilesProvider');

extension EquipmentProfileRowModel on DbEquipmentProfile {
  /// The profile this row stores.
  EquipmentProfileModel toModel() =>
      _profileFromRow(this, id: id, createdAt: createdAt, updatedAt: updatedAt);
}

/// The host's REST `/api/profiles` payload, read as the row it describes so
/// a linked client and the host derive every field by one rule.
EquipmentProfileModel equipmentProfileFromRemote(
  remote_profile.EquipmentProfile profile,
) => _profileFromRow(
  remoteProfileToDbRow(profile),
  id: int.tryParse(profile.id),
  createdAt: profile.createdAt,
  updatedAt: profile.updatedAt,
);

EquipmentProfileModel _profileFromRow(
  DbEquipmentProfile db, {
  required int? id,
  required DateTime? createdAt,
  required DateTime? updatedAt,
}) {
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
    id: id,
    name: db.name,
    description: db.description,
    isActive: db.isActive,
    cameraId: db.cameraId,
    mountId: db.mountId,
    focuserId: db.focuserId,
    filterWheelId: db.filterWheelId,
    guiderId: db.guiderId,
    guideCameraId: db.guideCameraId,
    guideFocalLength: db.guideFocalLength,
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
    guideCameraName: db.guideCameraName,
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
    defaultReadoutMode: db.defaultReadoutMode,
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
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

extension EquipmentProfileModelRow on EquipmentProfileModel {
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
      guideCameraId: Value(guideCameraId),
      guideFocalLength: Value(guideFocalLength),
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
      guideCameraName: Value(guideCameraName),
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
      defaultReadoutMode: Value(defaultReadoutMode),
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
}
