// Adapter that converts a Drift-row `DbEquipmentProfile` (returned by
// `activeProfileProvider`) into the freezed `EquipmentProfile` model
// consumed by `SmartNightOrchestrator.buildPlanForTonight`.
//
// The two types carry the same columns but are unrelated classes —
// neither defines a converter. We keep the conversion in the dashboard
// widgets directory because only Smart Night UI surfaces consume the
// freezed model directly; the rest of the app works with the Drift row
// or with `EquipmentProfileModel` (UI-friendly variant) instead.

import 'package:skotiq_core/skotiq_core.dart';

/// Convert a Drift-row [DbEquipmentProfile] into the freezed
/// [EquipmentProfile] model that `SmartNightOrchestrator` expects.
///
/// Column names line up 1:1; the only adaptation is the id type (int in
/// the DB row, String on the freezed model — the orchestrator round-trips
/// it through the draft's `profileId` text column).
EquipmentProfile smartNightProfileFromDb(DbEquipmentProfile row) {
  return EquipmentProfile(
    id: row.id.toString(),
    name: row.name,
    description: row.description,
    cameraId: row.cameraId,
    mountId: row.mountId,
    focuserId: row.focuserId,
    filterWheelId: row.filterWheelId,
    guiderId: row.guiderId,
    rotatorId: row.rotatorId,
    domeId: row.domeId,
    weatherId: row.weatherId,
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
    rotatorName: row.rotatorName,
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
