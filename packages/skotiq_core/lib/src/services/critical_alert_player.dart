import 'package:flutter/services.dart';

/// Plays an audible alert when a critical executor event fires.
///
/// Why a class (not a static call): the alert path needs to be mockable in
/// the integration test that proves [audibleAlertsOnCritical] actually
/// reaches a speaker. Tests inject a `_FakeCriticalAlertPlayer` via
/// `criticalAlertPlayerProvider` to capture invocations without touching
/// the real platform channel.
///
/// Plays Flutter's `SystemSound.alert`, which is supported on every Flutter
/// target platform (Windows / macOS / Linux / iOS / Android). On platforms
/// that don't have a system "alert" sound (some Linux desktop environments),
/// Flutter falls back to a no-op rather than raising — the user will still
/// see the banner and toast, so a missing audio cue is not a critical
/// failure.
class CriticalAlertPlayer {
  const CriticalAlertPlayer();

  /// Play the configured alert sound. Must be cheap to call repeatedly
  /// because the run-dashboard bridge may call us once per critical event.
  /// The bridge itself applies a 5-second cooldown so we don't need to
  /// throttle internally.
  ///
  /// [sound] is the persisted `criticalAlertSound` value
  /// (`systemBell` | `none`). Any unknown value is treated as `systemBell`
  /// rather than silently doing nothing — an unknown value shouldn't
  /// suppress alerts the user wanted.
  Future<void> play({required String sound}) async {
    if (sound == 'none') return;
    // `systemBell` (and unknown — see play docs).
    await SystemSound.play(SystemSoundType.alert);
  }
}
