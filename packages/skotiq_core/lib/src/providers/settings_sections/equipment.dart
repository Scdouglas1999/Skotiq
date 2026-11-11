// Per-device-type equipment defaults surfaced in Settings → Equipment
// (and the equipment-profile editor). Owns the connect-time defaults for
// camera, mount, focuser, and guider hardware behaviours.
//
// Owns:
//   * Camera: defaultGain, defaultOffset
//   * Mount: enableMeridianFlip
//   * Focuser: tempCompensation, tempCoefficient, tempCompensationMinSteps,
//     backlashCompensation
//   * Guider: ditherScale, settleThreshold, settleTimeout, settleTime,
//     ditherRaOnly
//
// Does NOT own:
//   * Per-device connection details (those live in EquipmentProfile) —
//     these are the FALLBACK defaults when a profile has no override.
//   * Autofocus algorithm tuning → see `autofocus.dart`.
//   * PHD2 connection (host/port/path) → see `phd2.dart`.
//   * Meridian flips. Every run arms its flip trigger from the meridian flip
//     settings (`globalMeridianFlipSettingsProvider`); `enableMeridianFlip`
//     only remembers the Quick-Start wizard's choice of adding a flip check
//     to the plans it builds, and no run reads it.
part of '../settings_provider.dart';

/// Setters for per-device-type equipment-default knobs.
extension EquipmentSettingsSection on AppSettingsNotifier {
  // Camera defaults
  Future<void> setDefaultGain(int value) => _set(AppSettingDefs.defaultGain, value);

  Future<void> setDefaultOffset(int value) =>
      _set(AppSettingDefs.defaultOffset, value);

  // Mount defaults
  Future<void> setEnableMeridianFlip(bool value) =>
      _set(AppSettingDefs.enableMeridianFlip, value);

  /// Persist the mount meridian-flip configuration — the enable toggle plus
  /// the warning-window minutes — in ONE batched transaction so the mount
  /// configuration dialog can never leave the two knobs out of sync.
  ///
  /// The prior dialog issued two sequential `setEnableMeridianFlip` /
  /// `setMeridianFlipMinutes` writes; a failure between them (or a malformed
  /// minutes value swallowed by `int.tryParse(...) ?? old`) could persist the
  /// toggle while dropping the minutes and still report success. Batching both
  /// keys through [_saveSettings] makes persistence atomic, and the in-memory
  /// [_patchState] runs only after the write resolves, so a failed write leaves
  /// state unchanged and the dialog retryable.
  ///
  /// `meridian_flip_minutes` is the sequencer-owned timing key (see
  /// `sequencer.dart`); it is co-written here because the mount configuration
  /// dialog edits it together with the equipment-owned enable flag. Callers
  /// validate `minutes` against the canonical 0..120 window
  /// ([MeridianFlipSettings.validate]) before invoking.
  Future<void> setMeridianFlipConfig({
    required bool enableFlip,
    required int minutes,
  }) => _setAll([
    AppSettingDefs.enableMeridianFlip.to(enableFlip),
    AppSettingDefs.meridianFlipMinutes.to(minutes),
  ]);

  // Focuser defaults
  Future<void> setTempCompensation(bool value) =>
      _set(AppSettingDefs.tempCompensation, value);

  Future<void> setTempCoefficient(double value) =>
      _set(AppSettingDefs.tempCoefficient, value);

  Future<void> setTempCompensationMinSteps(int value) =>
      _set(AppSettingDefs.tempCompensationMinSteps, value);

  /// The "Exposure calibration attempts" flat setting, 1..100.
  Future<void> setFlatCalibrationAttempts(int value) =>
      _set(AppSettingDefs.flatCalibrationAttempts, value);

  Future<void> setBacklashCompensation(int value) =>
      _set(AppSettingDefs.backlashCompensation, value);

  /// Persist the focuser temperature-compensation configuration — the enable
  /// toggle, the steps/°C coefficient, and the backlash steps — in ONE batched
  /// transaction so the focuser configuration dialog can never persist a
  /// partial change.
  ///
  /// All three keys go through one [_saveSettings], and [_patchState] runs
  /// only after that write resolves, so a mid-write failure leaves state
  /// unchanged and the dialog retryable rather than persisting an
  /// inconsistent trio.
  ///
  /// Callers validate `tempCoefficient` is finite (the continuous compensator
  /// multiplies it by a temperature delta and rounds — a NaN/∞ coefficient
  /// would throw there) and `backlashCompensation` is within 0..10000 (the
  /// canonical device/backlash limit used by the autofocus settings) before
  /// invoking. Negative and zero coefficients are intentionally allowed: zero
  /// is the documented "track temperature but do not move" state and the
  /// default is a negative -12 steps/°C.
  Future<void> setFocuserCompensationConfig({
    required bool tempCompensation,
    required double tempCoefficient,
    required int backlashCompensation,
  }) => _setAll([
    AppSettingDefs.tempCompensation.to(tempCompensation),
    AppSettingDefs.tempCoefficient.to(tempCoefficient),
    AppSettingDefs.backlashCompensation.to(backlashCompensation),
  ]);

  // Guider defaults
  Future<void> setDitherScale(String value) =>
      _set(AppSettingDefs.ditherScale, value);

  Future<void> setSettleThreshold(double value) =>
      _set(AppSettingDefs.settleThreshold, value);

  Future<void> setSettleTimeout(int value) =>
      _set(AppSettingDefs.settleTimeout, value);

  Future<void> setSettleTime(int value) => _set(AppSettingDefs.settleTime, value);

  Future<void> setDitherRaOnly(bool value) =>
      _set(AppSettingDefs.ditherRaOnly, value);
}
