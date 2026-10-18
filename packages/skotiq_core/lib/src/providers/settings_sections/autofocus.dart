// Autofocus algorithm and per-filter configuration surfaced in
// Settings → Autofocus. The biggest single section because the autofocus
// system has the most tunable parameters (curve fitting, step sizing,
// crop ratios, R² threshold, backlash compensation, per-filter overrides).
//
// Owns:
//   * Algorithm: afMethod, afCurveFitting, afStepSize, afExposureTime,
//     afInitialOffsetSteps, afNumberOfAttempts, afUseBrightestNStars
//   * Frame processing: afOuterCropRatio, afInnerCropRatio, afBinning,
//     afRSquaredThreshold
//   * Orchestration: afDisableGuidingDuringAf, afFocuserSettleTimeMs,
//     afExposuresPerPoint
//   * Backlash: afBacklashCompMethod, afBacklashIn, afBacklashOut,
//     focuserBacklashCalibrationJson (the calibration dialog's saved choices —
//     they live here because they are seeded from the AF fields above)
//   * Per-filter: afAutofocusFilterName, afFilterSettingsJson +
//     setFilterAutofocusConfig / removeFilterAutofocusConfig helpers
//
// Does NOT own:
//   * Sequence-level AF cadence (`autoFocusEveryMinutes`,
//     `autoFocusOnFilterChange`, `useFilterFocusOffsets`) → see
//     `sequencer.dart`.
//   * Smart Night default AF cadence (separate planning system) → see
//     `smart_night.dart`.
//   * Focuser hardware defaults (temp compensation, backlash compensation
//     on the focuser itself) → see `equipment.dart`.
part of '../settings_provider.dart';

/// Setters for autofocus algorithm and per-filter configuration.
extension AutofocusSettingsSection on AppSettingsNotifier {
  FilterAutofocusConfig _validateFilterAutofocusConfig(
    FilterAutofocusConfig config,
  ) {
    final exposure = config.afExposureTime;
    if (exposure != null &&
        (!exposure.isFinite || exposure < 0.1 || exposure > 300)) {
      throw ArgumentError.value(
        exposure,
        'afExposureTime',
        'must be between 0.1 and 300 seconds',
      );
    }
    if (config.binning < 1 || config.binning > 4) {
      throw ArgumentError.value(
        config.binning,
        'binning',
        'must be between 1 and 4',
      );
    }
    if (config.gain != null && config.gain! < 0) {
      throw ArgumentError.value(config.gain, 'gain', 'cannot be negative');
    }
    if (config.offset != null && config.offset! < 0) {
      throw ArgumentError.value(config.offset, 'offset', 'cannot be negative');
    }
    if (config.afFilterName != null && config.afFilterName!.trim().isEmpty) {
      throw ArgumentError.value(
        config.afFilterName,
        'afFilterName',
        'cannot be blank',
      );
    }
    return config;
  }

  Future<void> _mutateFilterAutofocusSettings(
    void Function(Map<String, FilterAutofocusConfig>) mutation,
  ) {
    final operation = _filterAutofocusWriteTail.then((_) async {
      final currentJson = _currentValueOrNull?.afFilterSettingsJson ?? '{}';
      final map = AutofocusSettings.parseFilterSettingsJson(currentJson);
      mutation(map);
      final newJson = AutofocusSettings.encodeFilterSettingsJson(map);
      await setAfFilterSettingsJson(newJson);
    });
    _filterAutofocusWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> setAfMethod(String value) async {
    await _saveSetting('af_method', value);
    _patchState((s) => s.copyWith(afMethod: value));
  }

  Future<void> setAfCurveFitting(String value) async {
    await _saveSetting('af_curve_fitting', value);
    _patchState((s) => s.copyWith(afCurveFitting: value));
  }

  Future<void> setAfStepSize(int value) async {
    await _saveSetting('af_step_size', value.toString());
    _patchState((s) => s.copyWith(afStepSize: value));
  }

  Future<void> setAfExposureTime(double value) async {
    await _saveSetting('af_exposure_time', value.toString());
    _patchState((s) => s.copyWith(afExposureTime: value));
  }

  Future<void> setAfInitialOffsetSteps(int value) async {
    await _saveSetting('af_initial_offset_steps', value.toString());
    _patchState((s) => s.copyWith(afInitialOffsetSteps: value));
  }

  Future<void> setAfNumberOfAttempts(int value) async {
    await _saveSetting('af_number_of_attempts', value.toString());
    _patchState((s) => s.copyWith(afNumberOfAttempts: value));
  }

  Future<void> setAfUseBrightestNStars(int value) async {
    await _saveSetting('af_use_brightest_n_stars', value.toString());
    _patchState((s) => s.copyWith(afUseBrightestNStars: value));
  }

  Future<void> setAfOuterCropRatio(double value) async {
    await _saveSetting('af_outer_crop_ratio', value.toString());
    _patchState((s) => s.copyWith(afOuterCropRatio: value));
  }

  Future<void> setAfInnerCropRatio(double value) async {
    await _saveSetting('af_inner_crop_ratio', value.toString());
    _patchState((s) => s.copyWith(afInnerCropRatio: value));
  }

  Future<void> setAfBinning(int value) async {
    await _saveSetting('af_binning', value.toString());
    _patchState((s) => s.copyWith(afBinning: value));
  }

  Future<void> setAfRSquaredThreshold(double value) async {
    await _saveSetting('af_r_squared_threshold', value.toString());
    _patchState((s) => s.copyWith(afRSquaredThreshold: value));
  }

  /// How far above the reference HFR a failed autofocus may leave the frames
  /// and still be called usable in the operator's notice. The run carries on
  /// either way: a failed autofocus never parks or ends it. Clamped at zero —
  /// a negative tolerance has no meaning.
  Future<void> setAfFailureHfrToleranceRatio(double value) async {
    final clamped = value.isFinite && value > 0 ? value : 0.0;
    await _saveSetting('af_failure_hfr_tolerance_ratio', clamped.toString());
    _patchState((s) => s.copyWith(afFailureHfrToleranceRatio: clamped));
  }

  Future<void> setAfDisableGuidingDuringAf(bool value) async {
    await _saveSetting('af_disable_guiding', value.toString());
    _patchState((s) => s.copyWith(afDisableGuidingDuringAf: value));
  }

  Future<void> setAfFocuserSettleTimeMs(int value) async {
    await _saveSetting('af_focuser_settle_time_ms', value.toString());
    _patchState((s) => s.copyWith(afFocuserSettleTimeMs: value));
  }

  Future<void> setAfExposuresPerPoint(int value) async {
    await _saveSetting('af_exposures_per_point', value.toString());
    _patchState((s) => s.copyWith(afExposuresPerPoint: value));
  }

  Future<void> setAfBacklashCompMethod(String value) async {
    await _saveSetting('af_backlash_comp_method', value);
    _patchState((s) => s.copyWith(afBacklashCompMethod: value));
  }

  Future<void> setAfBacklashIn(int value) async {
    await _saveSetting('af_backlash_in', value.toString());
    _patchState((s) => s.copyWith(afBacklashIn: value));
  }

  /// Whether to keep offering to measure focuser backlash: `ask` or `never`.
  Future<void> setFocuserBacklashOfferMode(String value) async {
    await _saveSetting('focuser_backlash_offer_mode', value);
    _patchState((s) => s.copyWith(focuserBacklashOfferMode: value));
  }

  Future<void> setAfBacklashOut(int value) async {
    await _saveSetting('af_backlash_out', value.toString());
    _patchState((s) => s.copyWith(afBacklashOut: value));
  }

  Future<void> setAfAutofocusFilterName(String value) async {
    await _saveSetting('af_autofocus_filter_name', value);
    _patchState((s) => s.copyWith(afAutofocusFilterName: value));
  }

  Future<void> setAfFilterSettingsJson(String value) async {
    await _saveSetting('af_filter_settings', value);
    _patchState((s) => s.copyWith(afFilterSettingsJson: value));
  }

  /// The persisted blob of backlash-calibration choices. Passing '' clears
  /// the stored choices, which is how "reset to autofocus settings" works —
  /// with nothing stored the calibration dialog re-seeds from the autofocus
  /// settings.
  Future<void> setFocuserBacklashCalibrationJson(String value) async {
    await _saveSetting('focuser_backlash_calibration_settings', value);
    _patchState((s) => s.copyWith(focuserBacklashCalibrationJson: value));
  }

  /// Atomically update the saved backlash-calibration settings.
  ///
  /// The fields are one JSON row, so edits from two different field
  /// controllers are read-modify-write — serialize the whole mutation, not
  /// just the final write, or a fast second commit would rebuild the blob
  /// from the pre-first-commit snapshot and silently lose the first field's
  /// change. [fallback] is the seeded value the caller displayed: used when
  /// nothing is stored yet (or the stored blob is unreadable), so the first
  /// edit persists the whole seed and not just one field.
  Future<void> updateFocuserBacklashCalibrationSettings(
    FocuserBacklashCalibrationSettings Function(
      FocuserBacklashCalibrationSettings current,
    )
    update, {
    required FocuserBacklashCalibrationSettings fallback,
  }) {
    final operation = _focuserBacklashCalibrationWriteTail.then((_) async {
      final stored = _currentValueOrNull?.focuserBacklashCalibrationJson ?? '';
      final current =
          FocuserBacklashCalibrationSettings.tryParse(stored) ?? fallback;
      await setFocuserBacklashCalibrationJson(
        jsonEncode(update(current).toJson()),
      );
    });
    _focuserBacklashCalibrationWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// Update a single filter's autofocus configuration.
  ///
  /// Loads the current filter settings map, updates the entry for [filterName],
  /// serializes back to JSON, and persists to the database.
  Future<void> setFilterAutofocusConfig(
    String filterName,
    FilterAutofocusConfig config,
  ) {
    return updateFilterAutofocusConfig(filterName, (_) => config);
  }

  /// Atomically update one filter from the latest persisted configuration.
  /// This is the preferred UI path because separate field editors can commit
  /// while an earlier remote/database write is still in flight.
  Future<void> updateFilterAutofocusConfig(
    String filterName,
    FilterAutofocusConfig Function(FilterAutofocusConfig current) update,
  ) {
    final normalizedName = filterName.trim();
    if (normalizedName.isEmpty) {
      return Future<void>.error(
        ArgumentError.value(filterName, 'filterName', 'cannot be blank'),
      );
    }
    return _mutateFilterAutofocusSettings((map) {
      final current = map[normalizedName] ?? const FilterAutofocusConfig();
      map[normalizedName] = _validateFilterAutofocusConfig(update(current));
    });
  }

  /// Remove a filter's autofocus configuration.
  Future<void> removeFilterAutofocusConfig(String filterName) {
    final normalizedName = filterName.trim();
    return _mutateFilterAutofocusSettings((map) {
      map.remove(normalizedName);
    });
  }
}
