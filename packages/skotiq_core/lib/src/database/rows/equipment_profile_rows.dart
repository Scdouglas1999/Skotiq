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

// BEGIN GENERATED equipment-profile rows
// dart format off
EquipmentProfileModel _profileFromRow(
  DbEquipmentProfile db, {
  required int? id,
  required DateTime? createdAt,
  required DateTime? updatedAt,
}) {
  return EquipmentProfileModel(
    id: id,
    name: db.name,
    description: db.description,
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
    focalLength: db.focalLength > 0 ? db.focalLength : (_positiveOrNull(db.telescopeFocalLength) ?? 0.0),
    aperture: db.aperture > 0 ? db.aperture : (_positiveOrNull(db.telescopeAperture) ?? 0.0),
    focalRatio: db.focalRatio,
    defaultGain: db.defaultGain,
    defaultOffset: db.defaultOffset,
    defaultReadoutMode: db.defaultReadoutMode,
    defaultBinX: db.defaultBinX,
    defaultBinY: db.defaultBinY,
    defaultCoolingTemp: db.defaultCoolingTemp,
    coolOnConnect: db.coolOnConnect,
    defaultCenteringExposure: db.defaultCenteringExposure,
    filterNames: _storedFilterNames(db.filterNames, field: 'filterNames', column: 'filter_names', profile: db.name),
    filterFocusOffsets: _storedFocusOffsets(db.filterFocusOffsets, field: 'filterFocusOffsets', column: 'filter_focus_offsets', profile: db.name),
    meridianFlipOverrides: db.meridianFlipOverrides,
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
    telescopeFocalLength: _positiveOrNull(db.telescopeFocalLength),
    telescopeAperture: _positiveOrNull(db.telescopeAperture),
    profileIcon: db.profileIcon,
    profileColor: db.profileColor,
    isActive: db.isActive,
    sortOrder: db.sortOrder,
    isDefault: db.isDefault,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

extension EquipmentProfileModelRow on EquipmentProfileModel {
  /// The row a save of this profile writes.
  EquipmentProfilesCompanion toCompanion() {
    return EquipmentProfilesCompanion(
      id: id != null ? Value(id!) : const Value.absent(),
      name: Value(name),
      description: Value(description),
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
      filterNames: Value(filterNames.isNotEmpty ? jsonEncode(filterNames) : null),
      filterFocusOffsets: Value(filterFocusOffsets.isNotEmpty ? jsonEncode(filterFocusOffsets) : null),
      meridianFlipOverrides: Value(meridianFlipOverrides),
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
      profileIcon: Value(profileIcon),
      profileColor: Value(profileColor),
      isActive: Value(isActive),
      sortOrder: Value(sortOrder),
      isDefault: Value(isDefault),
      updatedAt: Value(DateTime.now()),
    );
  }
}
// dart format on
// END GENERATED equipment-profile rows

double? _positiveOrNull(double? value) =>
    value != null && value > 0 ? value : null;

List<String> _storedFilterNames(
  String? stored, {
  required String field,
  required String column,
  required String profile,
}) {
  if (stored == null) return <String>[];
  try {
    return decodeStringListJson(
      stored,
      context: 'equipment_profiles.$column for "$profile"',
    );
  } catch (e) {
    _log.warning('Failed to parse $field JSON for profile "$profile": $e');
    return <String>[];
  }
}

Map<String, int> _storedFocusOffsets(
  String? stored, {
  required String field,
  required String column,
  required String profile,
}) {
  if (stored == null) return <String, int>{};
  try {
    return decodeStringIntMapJson(
      stored,
      context: 'equipment_profiles.$column for "$profile"',
    );
  } catch (e) {
    _log.warning('Failed to parse $field JSON for profile "$profile": $e');
    return <String, int>{};
  }
}
