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

/// Setters for observer-location settings.
extension LocationSettingsSection on AppSettingsNotifier {
  Future<void> setLatitude(double value) async {
    await _saveSetting('observer_latitude', value.toString());
    _patchState((s) => s.copyWith(latitude: value));
    // Sync to planetarium provider is handled at app level in settings screen
  }

  Future<void> setLongitude(double value) async {
    await _saveSetting('observer_longitude', value.toString());
    _patchState((s) => s.copyWith(longitude: value));
    // Sync to planetarium provider is handled at app level in settings screen
  }

  Future<void> setElevation(double value) async {
    await _saveSetting('observer_elevation', value.toString());
    _patchState((s) => s.copyWith(elevation: value));
    // Sync to planetarium provider is handled at app level in settings screen
  }

  Future<void> setTimezone(String value) async {
    await _saveSetting('timezone', value);
    _patchState((s) => s.copyWith(timezone: value));
  }

  /// What to do when a connected mount's site/time disagrees with this
  /// computer's: `ask`, `computerToMount`, `mountToComputer` or `never`.
  Future<void> setMountSiteSyncMode(String value) async {
    await _saveSetting('mount_site_sync_mode', value);
    _patchState((s) => s.copyWith(mountSiteSyncMode: value));
  }

  Future<void> setUseSystemTime(bool value) async {
    await _saveSetting('use_system_time', value.toString());
    _patchState((s) => s.copyWith(useSystemTime: value));
  }

  /// Batched location update — writes lat/lon/elev in one Drift transaction
  /// instead of three sequential round-trips. Each parameter is optional;
  /// only the supplied fields are persisted.
  Future<void> updateLocation({
    double? latitude,
    double? longitude,
    double? elevation,
  }) async {
    final settings = <String, String>{};
    if (latitude != null) settings['observer_latitude'] = latitude.toString();
    if (longitude != null) {
      settings['observer_longitude'] = longitude.toString();
    }
    if (elevation != null) {
      settings['observer_elevation'] = elevation.toString();
    }

    if (settings.isNotEmpty) {
      await _saveSettings(settings);
      _patchState(
        (s) => s.copyWith(
          latitude: latitude,
          longitude: longitude,
          elevation: elevation,
        ),
      );
    }
  }
}
