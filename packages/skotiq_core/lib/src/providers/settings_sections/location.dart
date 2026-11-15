// Observer-location knobs surfaced in Settings → Location and the
// equipment-profile location card. Owns the geodetic coordinates and the
// time-source toggle that drive every sky calculation, planetarium camera
// pose, and FITS `SITELAT` / `SITELONG` field.
//
// Owns:
//   * latitude, longitude, elevation, timezone, useSystemTime
//   * `updateLocation` batched setter (three values, one Drift write)
//
// Does NOT own:
//   * Bortle-class / horizon profile / effective-horizon → see
//     `environment.dart` (those are sky-quality, not location).
part of '../settings_provider.dart';

extension LocationSettingsSection on AppSettingsNotifier {
  // The planetarium follows these through the settings screen, not here.
  Future<void> setLatitude(double value) =>
      _set(AppSettingDefs.latitude, value);

  Future<void> setLongitude(double value) =>
      _set(AppSettingDefs.longitude, value);

  Future<void> setElevation(double value) =>
      _set(AppSettingDefs.elevation, value);

  Future<void> setTimezone(String value) =>
      _set(AppSettingDefs.timezone, value);

  /// What to do when a connected mount's site/time disagrees with this
  /// computer's: `ask`, `computerToMount`, `mountToComputer` or `never`.
  Future<void> setMountSiteSyncMode(String value) =>
      _set(AppSettingDefs.mountSiteSyncMode, value);

  Future<void> setUseSystemTime(bool value) =>
      _set(AppSettingDefs.useSystemTime, value);

  /// Batched location update — writes lat/lon/elev in one Drift transaction
  /// instead of three sequential round-trips. Each parameter is optional;
  /// only the supplied fields are persisted.
  Future<void> updateLocation({
    double? latitude,
    double? longitude,
    double? elevation,
  }) async {
    final values = [
      if (latitude != null) AppSettingDefs.latitude.to(latitude),
      if (longitude != null) AppSettingDefs.longitude.to(longitude),
      if (elevation != null) AppSettingDefs.elevation.to(elevation),
    ];
    if (values.isNotEmpty) await _setAll(values);
  }
}
