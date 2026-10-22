// Recovery Mode user-tunable defaults. Owns the knobs that
// configure the executor's automatic-retry loop after a recoverable
// failure (guide-star loss, dew, wind, weather drift, etc.).
//
// Owns:
//   * recoveryDefaultRetryIntervalMins, recoveryDefaultMaxDurationMins
//   * recoveryStopTrackingDuringRecovery, recoveryAbortOnMeridian
//   * recoveryAudibleAlertWhenEntered
//
// Does NOT own:
//   * The general audible-alerts toggle / sound selection → see
//     `environment.dart`. The recovery audible alert here re-uses the same
//     sound path but has its own enable bit (a user can want
//     critical-event sounds but not recovery-entry sounds, or vice versa).
//   * Pre-flight checks → see `preflight.dart`.
part of '../settings_provider.dart';

/// Setters for Recovery Mode defaults.
extension RecoverySettingsSection on AppSettingsNotifier {
  /// Minutes between auto-retry attempts during a recovery loop. Clamped
  /// to [1, 240] — a zero/negative interval would spin the executor at
  /// 100 % CPU, and a 4 h interval is already absurdly conservative.
  Future<void> setRecoveryDefaultRetryIntervalMins(double value) async {
    final clamped = value.clamp(1.0, 240.0);
    await _saveSetting(
      'recovery_default_retry_interval_mins',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(recoveryDefaultRetryIntervalMins: clamped));
  }

  /// Total minutes before the recovery loop gives up. Clamped to
  /// [1, 1440] (one full day) for the same reason as the retry interval.
  Future<void> setRecoveryDefaultMaxDurationMins(double value) async {
    final clamped = value.clamp(1.0, 1440.0);
    await _saveSetting(
      'recovery_default_max_duration_mins',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(recoveryDefaultMaxDurationMins: clamped));
  }

  /// Whether the mount stops tracking on recovery entry. Off by default, and
  /// never applied to a lost guide star or a weather hold: those are mostly
  /// cloud, and a tracking mount is still on the target when it passes.
  Future<void> setRecoveryStopTrackingDuringRecovery(bool value) async {
    await _saveSetting(
      'recovery_stop_tracking_during_recovery_v2',
      value.toString(),
    );
    _patchState((s) => s.copyWith(recoveryStopTrackingDuringRecovery: value));
  }

  /// Whether an imminent meridian crossing inside the recovery window
  /// aborts the loop instead of trying to retry across the flip.
  Future<void> setRecoveryAbortOnMeridian(bool value) async {
    await _saveSetting('recovery_abort_on_meridian', value.toString());
    _patchState((s) => s.copyWith(recoveryAbortOnMeridian: value));
  }

  /// Whether to ring the platform alert sound on recovery entry. Re-uses
  /// the audibleAlertsOnCritical sound selection.
  Future<void> setRecoveryAudibleAlertWhenEntered(bool value) async {
    await _saveSetting('recovery_audible_alert_when_entered', value.toString());
    _patchState((s) => s.copyWith(recoveryAudibleAlertWhenEntered: value));
  }
}
