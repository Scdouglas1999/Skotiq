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
  Future<void> setBortleClass(int value) async {
    final clamped = value.clamp(1, 9);
    await _saveSetting('bortle_class', clamped.toString());
    _patchState((s) => s.copyWith(bortleClass: clamped));
  }

  Future<void> setHorizonProfileJson(String value) async {
    await _saveSetting('horizon_profile_json', value);
    _patchState((s) => s.copyWith(horizonProfileJson: value));
  }

  /// Set the effective horizon used by Run Dashboard, scheduler, and
  /// planetarium for time-to-set calculations. Clamped to [0, 60] degrees
  /// because anything above 60 makes most of the sky unreachable and is
  /// almost certainly a typo rather than an intentional value.
  Future<void> setEffectiveHorizonDeg(double value) async {
    final clamped = value.clamp(0.0, 60.0);
    await _saveSetting('effective_horizon_deg', clamped.toString());
    _patchState((s) => s.copyWith(effectiveHorizonDeg: clamped));
  }

  Future<void> setAudibleAlertsOnCritical(bool value) async {
    await _saveSetting('audible_alerts_on_critical', value.toString());
    _patchState((s) => s.copyWith(audibleAlertsOnCritical: value));
  }

  /// Set which sound the audible-alert path uses. Unknown values are
  /// rejected (we don't want a misspelled string silently muting alerts).
  Future<void> setCriticalAlertSound(String value) async {
    if (value != 'systemBell' && value != 'none') {
      throw ArgumentError(
        'criticalAlertSound must be "systemBell" or "none", got: $value',
      );
    }
    await _saveSetting('critical_alert_sound', value);
    _patchState((s) => s.copyWith(criticalAlertSound: value));
  }

  /// Toggle whether critical events are forwarded to paired mobile clients.
  Future<void> setPushCriticalAlerts(bool value) async {
    await _saveSetting('push_critical_alerts', value.toString());
    _patchState((s) => s.copyWith(pushCriticalAlerts: value));
  }

  /// Observer name stamped into FITS `OBSERVER`. Empty string => keyword
  /// omitted entirely (silent fallbacks are bugs).
  Future<void> setObserverName(String value) async {
    await _saveSetting('observer_name', value);
    _patchState((s) => s.copyWith(observerName: value));
  }
}
