// Per-device-type equipment defaults surfaced in Settings → Equipment
// (and the equipment-profile editor). Owns the connect-time defaults for
// camera, mount, focuser, and guider hardware behaviours.
//
// Owns:
//   * Camera: defaultGain, defaultOffset
//   * Mount: enableMeridianFlip
//   * Focuser: tempCompensation, tempCoefficient, backlashCompensation
//   * Guider: ditherScale, settleThreshold, settleTimeout, settleTime,
//     ditherRaOnly
//
// Does NOT own:
//   * Per-device connection details (those live in EquipmentProfile) —
//     these are the FALLBACK defaults when a profile has no override.
//   * Autofocus algorithm tuning → see `autofocus.dart`.
//   * PHD2 connection (host/port/path) → see `phd2.dart`.
//   * Meridian-flip timing knob (`meridianFlipMinutes`) → see
//     `sequencer.dart`. The `enableMeridianFlip` toggle here owns whether
//     the mount supports flips at all; the timing is a sequencer concern.
part of '../settings_provider.dart';

/// Setters for per-device-type equipment-default knobs.
extension EquipmentSettingsSection on AppSettingsNotifier {
  // Camera defaults
  Future<void> setDefaultGain(int value) async {
    await _saveSetting('default_gain', value.toString());
    _patchState((s) => s.copyWith(defaultGain: value));
  }

  Future<void> setDefaultOffset(int value) async {
    await _saveSetting('default_offset', value.toString());
    _patchState((s) => s.copyWith(defaultOffset: value));
  }

  // Mount defaults
  Future<void> setEnableMeridianFlip(bool value) async {
    await _saveSetting('enable_meridian_flip', value.toString());
    _patchState((s) => s.copyWith(enableMeridianFlip: value));
  }

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
  }) async {
    await _saveSettings({
      'enable_meridian_flip': enableFlip.toString(),
      'meridian_flip_minutes': minutes.toString(),
    });
    _patchState(
      (s) => s.copyWith(
        enableMeridianFlip: enableFlip,
        meridianFlipMinutes: minutes,
      ),
    );
  }

  // Focuser defaults
  Future<void> setTempCompensation(bool value) async {
    await _saveSetting('temp_compensation', value.toString());
    _patchState((s) => s.copyWith(tempCompensation: value));
  }

  Future<void> setTempCoefficient(double value) async {
    await _saveSetting('temp_coefficient', value.toString());
    _patchState((s) => s.copyWith(tempCoefficient: value));
  }

  Future<void> setBacklashCompensation(int value) async {
    await _saveSetting('backlash_compensation', value.toString());
    _patchState((s) => s.copyWith(backlashCompensation: value));
  }

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
  }) async {
    await _saveSettings({
      'temp_compensation': tempCompensation.toString(),
      'temp_coefficient': tempCoefficient.toString(),
      'backlash_compensation': backlashCompensation.toString(),
    });
    _patchState(
      (s) => s.copyWith(
        tempCompensation: tempCompensation,
        tempCoefficient: tempCoefficient,
        backlashCompensation: backlashCompensation,
      ),
    );
  }

  // Guider defaults
  Future<void> setDitherScale(String value) async {
    await _saveSetting('dither_scale', value);
    _patchState((s) => s.copyWith(ditherScale: value));
  }

  Future<void> setSettleThreshold(double value) async {
    await _saveSetting('settle_threshold', value.toString());
    _patchState((s) => s.copyWith(settleThreshold: value));
  }

  Future<void> setSettleTimeout(int value) async {
    await _saveSetting('settle_timeout', value.toString());
    _patchState((s) => s.copyWith(settleTimeout: value));
  }

  Future<void> setSettleTime(int value) async {
    await _saveSetting('settle_time', value.toString());
    _patchState((s) => s.copyWith(settleTime: value));
  }

  Future<void> setDitherRaOnly(bool value) async {
    await _saveSetting('dither_ra_only', value.toString());
    _patchState((s) => s.copyWith(ditherRaOnly: value));
  }
}
