import 'package:drift/drift.dart';

import '../database.dart' as db;
import '../../models/equipment_profile.dart' as remote_profile;

// Converters between the stored Drift row (`db.DbEquipmentProfile`) and the
// REST body (`remote_profile.EquipmentProfile`), used by the host's
// `/api/profiles` handlers and by a linked client reading the host's
// profiles, so both derive every field by one rule.

// BEGIN GENERATED equipment-profile remote
// dart format off
/// The REST body for a stored row (GET /api/profiles and the
/// active-profile endpoint).
remote_profile.EquipmentProfile dbProfileToRemote(db.DbEquipmentProfile row) {
  return remote_profile.EquipmentProfile(
    id: row.id.toString(),
    name: row.name,
    description: row.description,
    cameraId: row.cameraId,
    mountId: row.mountId,
    focuserId: row.focuserId,
    filterWheelId: row.filterWheelId,
    guiderId: row.guiderId,
    guideCameraId: row.guideCameraId,
    guideFocalLength: row.guideFocalLength,
    rotatorId: row.rotatorId,
    domeId: row.domeId,
    weatherId: row.weatherId,
    safetyMonitorId: row.safetyMonitorId,
    switchId: row.switchId,
    coverCalibratorId: row.coverCalibratorId,
    focalLength: row.focalLength,
    aperture: row.aperture,
    focalRatio: row.focalRatio,
    defaultGain: row.defaultGain,
    defaultOffset: row.defaultOffset,
    defaultReadoutMode: row.defaultReadoutMode,
    defaultBinX: row.defaultBinX,
    defaultBinY: row.defaultBinY,
    defaultCoolingTemp: row.defaultCoolingTemp,
    coolOnConnect: row.coolOnConnect,
    defaultCenteringExposure: row.defaultCenteringExposure,
    filterNames: row.filterNames,
    filterFocusOffsets: row.filterFocusOffsets,
    meridianFlipOverrides: row.meridianFlipOverrides,
    cameraName: row.cameraName,
    mountName: row.mountName,
    focuserName: row.focuserName,
    filterWheelName: row.filterWheelName,
    guiderName: row.guiderName,
    guideCameraName: row.guideCameraName,
    rotatorName: row.rotatorName,
    safetyMonitorName: row.safetyMonitorName,
    switchName: row.switchName,
    telescopeName: row.telescopeName,
    telescopeFocalLength: row.telescopeFocalLength ?? 0.0,
    telescopeAperture: row.telescopeAperture ?? 0.0,
    profileIcon: row.profileIcon,
    profileColor: row.profileColor,
    sortOrder: row.sortOrder,
    isDefault: row.isDefault,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    isActive: row.isActive,
  );
}

/// The full stored row a REST body describes, for
/// `dao.updateProfile` (a full-row replace) and the linked
/// client's reading of the host's profiles.
///
/// With [existing] (the host update path) the sort order, the
/// default and active flags and `createdAt` stay the host
/// row's, so a client's save cannot reorder profiles or clear
/// the flags; those change through their own endpoints
/// (`/api/profiles/<id>/default`, `/api/profiles/reorder`, load).
/// A field the body omits that keeps the host value does so
/// too. Without it (the linked client) the body is carried
/// through, so the client's rows equal the host's.
db.DbEquipmentProfile remoteProfileToDbRow(
  remote_profile.EquipmentProfile profile, {
  db.DbEquipmentProfile? existing,
  DateTime? now,
}) {
  final writeStamp = now ?? DateTime.now().toUtc();
  return db.DbEquipmentProfile(
    id: int.tryParse(profile.id) ?? 0,
    name: profile.name,
    description: profile.description,
    cameraId: profile.cameraId,
    mountId: profile.mountId,
    focuserId: profile.focuserId,
    filterWheelId: profile.filterWheelId,
    guiderId: profile.guiderId,
    guideCameraId: profile.guideCameraId,
    guideFocalLength: profile.guideFocalLength,
    rotatorId: profile.rotatorId,
    domeId: profile.domeId,
    weatherId: profile.weatherId,
    safetyMonitorId: profile.safetyMonitorId,
    switchId: profile.switchId,
    coverCalibratorId: profile.coverCalibratorId,
    focalLength: profile.focalLength,
    aperture: profile.aperture,
    focalRatio: profile.focalRatio,
    defaultGain: profile.defaultGain,
    defaultOffset: profile.defaultOffset,
    defaultReadoutMode: profile.defaultReadoutMode,
    defaultBinX: profile.defaultBinX,
    defaultBinY: profile.defaultBinY,
    defaultCoolingTemp: profile.defaultCoolingTemp,
    coolOnConnect: profile.coolOnConnect,
    defaultCenteringExposure: profile.defaultCenteringExposure,
    filterNames: profile.filterNames,
    filterFocusOffsets: profile.filterFocusOffsets,
    meridianFlipOverrides: profile.meridianFlipOverrides ?? existing?.meridianFlipOverrides,
    cameraName: profile.cameraName,
    mountName: profile.mountName,
    focuserName: profile.focuserName,
    filterWheelName: profile.filterWheelName,
    guiderName: profile.guiderName,
    guideCameraName: profile.guideCameraName,
    rotatorName: profile.rotatorName,
    safetyMonitorName: profile.safetyMonitorName,
    switchName: profile.switchName,
    telescopeName: profile.telescopeName,
    telescopeFocalLength: profile.telescopeFocalLength,
    telescopeAperture: profile.telescopeAperture,
    profileIcon: profile.profileIcon,
    profileColor: profile.profileColor,
    sortOrder: existing?.sortOrder ?? profile.sortOrder,
    isDefault: existing?.isDefault ?? profile.isDefault,
    isActive: existing?.isActive ?? profile.isActive,
    createdAt:
        existing?.createdAt ??
        profile.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: profile.updatedAt ?? writeStamp,
  );
}
// dart format on
// END GENERATED equipment-profile remote

/// CREATE: REST wire model -> Companion for `dao.createProfile`.
///
/// Used only on the create path (no existing row). `createProfile` auto-flips
/// `isDefault`/`isActive` for the very first row, so we deliberately do NOT
/// force those flags here — let the DAO own first-row semantics. The `id` is
/// left absent so SQLite assigns the autoincrement key.
db.EquipmentProfilesCompanion remoteProfileToCompanion(
  remote_profile.EquipmentProfile profile,
) => remoteProfileToDbRow(profile)
    .toCompanion(false)
    .copyWith(
      id: const Value.absent(),
      isDefault: const Value.absent(),
      isActive: const Value.absent(),
      createdAt: const Value.absent(),
      updatedAt: const Value.absent(),
    );
