// Sky-quality / environment context and critical-alert delivery toggles.
// Owns the observing-environment knobs the scheduler and run dashboard
// consult to compute "how good is the sky right now" and the audible /
// push paths used when something goes wrong.
//
// Owns:
//   * bortleClass, horizonProfileJson, effectiveHorizonDeg
//   * audibleAlertsOnCritical, criticalAlertSound, pushCriticalAlerts
//   * observerName (FITS `OBSERVER` keyword)
//
// Does NOT own:
//   * Latitude / longitude / elevation → see `location.dart`.
//   * Recovery-mode toggles (which include a separate audible-alert flag)
//     → see `recovery.dart`.
part of '../settings_provider.dart';

/// Setters for observing-environment, critical-alert delivery, and the
/// FITS observer-name field.
extension EnvironmentSettingsSection on AppSettingsNotifier {
  Future<void> setBortleClass(int value) => _set(AppSettingDefs.bortleClass, value);

  Future<void> setHorizonProfileJson(String value) =>
      _set(AppSettingDefs.horizonProfileJson, value);

  /// Set the effective horizon used by Run Dashboard, scheduler, and
  /// planetarium for time-to-set calculations. Clamped to [0, 60] degrees
  /// because anything above 60 makes most of the sky unreachable and is
  /// almost certainly a typo rather than an intentional value.
  Future<void> setEffectiveHorizonDeg(double value) =>
      _set(AppSettingDefs.effectiveHorizonDeg, value);

  Future<void> setAudibleAlertsOnCritical(bool value) =>
      _set(AppSettingDefs.audibleAlertsOnCritical, value);

  /// Set which sound the audible-alert path uses. Unknown values are
  /// rejected (we don't want a misspelled string silently muting alerts).
  Future<void> setCriticalAlertSound(String value) async {
    if (value != 'systemBell' && value != 'none') {
      throw ArgumentError(
        'criticalAlertSound must be "systemBell" or "none", got: $value',
      );
    }
    await _set(AppSettingDefs.criticalAlertSound, value);
  }

  /// Toggle whether critical events are forwarded to paired mobile clients.
  Future<void> setPushCriticalAlerts(bool value) =>
      _set(AppSettingDefs.pushCriticalAlerts, value);

  /// Observer name stamped into FITS `OBSERVER`. Empty string => keyword
  /// omitted entirely (silent fallbacks are bugs).
  Future<void> setObserverName(String value) =>
      _set(AppSettingDefs.observerName, value);
}
