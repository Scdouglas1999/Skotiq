import 'package:drift/drift.dart';

import '../database/database.dart' as db;
import 'equipment_profile.dart' as remote_profile;

/// Canonical, lossless converters between the SQLite Drift row
/// (`db.EquipmentProfile`) and the REST wire model
/// (`remote_profile.EquipmentProfile`).
///
/// This is the SINGLE source of truth for equipment-profile mapping shared by
/// BOTH the host's remote profile handlers (`/api/profiles`) and the slave's
/// remote-poll stream (`database_provider._equipmentProfileFromRemote`). Both
/// sites MUST route through these functions so the two never drift apart and so
/// every column the slave's equipment cards need (device ids/names — including
/// `safetyMonitorName`/`switchName` — optics, camera defaults, filter config,
/// AND `meridianFlipOverrides`) survives the round-trip. The REST wire model and
/// `EquipmentProfileModel.toRemoteProfile()` both carry these fields, so neither
/// path is lossy any longer.

/// READER: Drift row -> REST wire model (for GET /api/profiles and the active
/// profile endpoint). Maps every column the wire model can carry.
remote_profile.EquipmentProfile dbProfileToRemote(db.EquipmentProfile row) {
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

    // Telescope/OTA (db columns are nullable; the wire model defaults to 0.0)
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

/// CREATE: REST wire model -> Companion for `dao.createProfile`.
///
/// Used only on the create path (no existing row). `createProfile` auto-flips
/// `isDefault`/`isActive` for the very first row, so we deliberately do NOT
/// force those flags here — let the DAO own first-row semantics. The `id` is
/// left absent so SQLite assigns the autoincrement key.
db.EquipmentProfilesCompanion remoteProfileToCompanion(
  remote_profile.EquipmentProfile profile,
) {
  return db.EquipmentProfilesCompanion.insert(
    name: profile.name,
    description: Value(profile.description),

    cameraId: Value(profile.cameraId),
    mountId: Value(profile.mountId),
    focuserId: Value(profile.focuserId),
    filterWheelId: Value(profile.filterWheelId),
    guiderId: Value(profile.guiderId),
    guideCameraId: Value(profile.guideCameraId),
    guideFocalLength: Value(profile.guideFocalLength),
    rotatorId: Value(profile.rotatorId),
    domeId: Value(profile.domeId),
    weatherId: Value(profile.weatherId),
    safetyMonitorId: Value(profile.safetyMonitorId),
    switchId: Value(profile.switchId),
    coverCalibratorId: Value(profile.coverCalibratorId),

    focalLength: Value(profile.focalLength),
    aperture: Value(profile.aperture),
    focalRatio: Value(profile.focalRatio),

    defaultGain: Value(profile.defaultGain),
    defaultOffset: Value(profile.defaultOffset),
    defaultBinX: Value(profile.defaultBinX),
    defaultBinY: Value(profile.defaultBinY),
    defaultCoolingTemp: Value(profile.defaultCoolingTemp),
    coolOnConnect: Value(profile.coolOnConnect),
    defaultCenteringExposure: Value(profile.defaultCenteringExposure),

    filterNames: Value(profile.filterNames),
    filterFocusOffsets: Value(profile.filterFocusOffsets),

    meridianFlipOverrides: Value(profile.meridianFlipOverrides),

    cameraName: Value(profile.cameraName),
    mountName: Value(profile.mountName),
    focuserName: Value(profile.focuserName),
    filterWheelName: Value(profile.filterWheelName),
    guiderName: Value(profile.guiderName),
    guideCameraName: Value(profile.guideCameraName),
    rotatorName: Value(profile.rotatorName),
    safetyMonitorName: Value(profile.safetyMonitorName),
    switchName: Value(profile.switchName),

    telescopeName: Value(profile.telescopeName),
    telescopeFocalLength: Value(profile.telescopeFocalLength),
    telescopeAperture: Value(profile.telescopeAperture),

    profileIcon: Value(profile.profileIcon),
    profileColor: Value(profile.profileColor),
    sortOrder: Value(profile.sortOrder),
  );
}

/// UPDATE / SLAVE-POLL READER: REST wire model -> full Drift row for
/// `dao.updateProfile(...)` (which does a full-row `.replace`).
///
/// When [existing] is supplied (the host update path), `isDefault`/`isActive`/
/// `sortOrder`/`createdAt` are PRESERVED from the existing row so a slave POST
/// can never silently clear the default/active flags or reorder profiles.
/// When [existing] is null (the slave's poll-stream mapping in
/// database_provider), the remote payload's own flags are carried through so
/// the slave's `allProfilesProvider`/`activeProfileProvider` stream produces
/// rows identical to the host's.
db.EquipmentProfile remoteProfileToDbRow(
  remote_profile.EquipmentProfile profile, {
  db.EquipmentProfile? existing,
  DateTime? now,
}) {
  // Injectable write clock keeps the updatedAt bump deterministic under test.
  final writeStamp = now ?? DateTime.now().toUtc();
  return db.EquipmentProfile(
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
    defaultBinX: profile.defaultBinX,
    defaultBinY: profile.defaultBinY,
    defaultCoolingTemp: profile.defaultCoolingTemp,
    coolOnConnect: profile.coolOnConnect,
    defaultCenteringExposure: profile.defaultCenteringExposure,

    filterNames: profile.filterNames,
    filterFocusOffsets: profile.filterFocusOffsets,

    // Meridian flip overrides. The slave's REST/UI model now carries
    // meridianFlipOverrides losslessly, so a slave save emits the real value.
    // We still fall back to the existing host row when the payload's value is
    // null so a slave that simply omits the field (or an older client) can never
    // silently wipe host-side overrides. On the slave-poll path (existing ==
    // null) the host's value is carried through unchanged.
    meridianFlipOverrides:
        profile.meridianFlipOverrides ?? existing?.meridianFlipOverrides,

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
    // Preserve sort order / default / active flags from the existing row on the
    // host update path so an ordinary slave save cannot reorder or clear them
    // (a raw update honouring isDefault would leave multiple rows flagged
    // default). Intentional default/order changes from a slave go through the
    // dedicated host endpoints (POST /api/profiles/<id>/default and
    // POST /api/profiles/reorder), which mutate these flags atomically; the
    // ACTIVE profile is switched via the separate load/setActive path.
    sortOrder: existing?.sortOrder ?? profile.sortOrder,
    isDefault: existing?.isDefault ?? profile.isDefault,
    isActive: existing?.isActive ?? profile.isActive,

    // Timestamps: preserve createdAt from the existing row; bump updatedAt.
    createdAt:
        existing?.createdAt ??
        profile.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: profile.updatedAt ?? writeStamp,
  );
}
