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

class _InitialLocationCancelled implements Exception {
  const _InitialLocationCancelled();
}

extension LocationSettingsSection on AppSettingsNotifier {
  /// Includes edits that have not reached the database yet.
  int get locationEditRevision => _locationEditRevision;

  /// A partially typed coordinate takes precedence over a startup lookup.
  void noteLocationEdit() => _locationEditRevision++;

  void _recordLocationEdit(Iterable<String> keys) {
    if (keys.any(
      (key) =>
          key == AppSettingDefs.latitude.key ||
          key == AppSettingDefs.longitude.key ||
          key == AppSettingDefs.elevation.key,
    )) {
      noteLocationEdit();
    }
  }

  /// Apply a startup estimate only while the original host remains unset and
  /// untouched. The check shares the settings write queue, so an edit waiting
  /// on persistence cannot be overwritten by a late lookup.
  Future<bool> initializeLocation({
    required double latitude,
    required double longitude,
    required int expectedRevision,
    required bool Function() isCurrent,
  }) async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final dao = ref.read(settingsDaoProvider);
    var applied = false;
    await _serializeSettingsWrite(
      'initial observing location',
      generation,
      () async {
        if (!isCurrent() ||
            !backend.runsRigHere ||
            ref.backendScopeOver(backend).isStale ||
            ref.scopeOver(settingsDaoProvider, dao).isStale ||
            _locationEditRevision != expectedRevision)
          return;
        final current = _requireLoadedSettings('setting the initial location');
        if (current.hasObserverLocation) return;
        try {
          await dao.transaction(() async {
            await dao.setSettings({
              AppSettingDefs.latitude.key: latitude.toString(),
              AppSettingDefs.longitude.key: longitude.toString(),
            });
            if (!isCurrent() ||
                generation != _backendGeneration ||
                _locationEditRevision != expectedRevision ||
                ref.backendScopeOver(backend).isStale ||
                ref.scopeOver(settingsDaoProvider, dao).isStale) {
              // Roll back both rows when typing or a host switch overtakes
              // the database write, rather than only hiding its result.
              throw const _InitialLocationCancelled();
            }
          });
        } on _InitialLocationCancelled {
          return;
        }
        if (!isCurrent() ||
            generation != _backendGeneration ||
            ref.backendScopeOver(backend).isStale ||
            ref.scopeOver(settingsDaoProvider, dao).isStale)
          return;
        _patchState(
          (value) => value.copyWith(latitude: latitude, longitude: longitude),
        );
        applied = true;
      },
    );
    return applied;
  }

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
