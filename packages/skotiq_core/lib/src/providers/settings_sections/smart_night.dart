// Smart Night auto-builder defaults. Owns the knobs the
// "Plan Tonight" wizard consults when composing a sequence for the user.
//
// Also owns the [promptForNotesAfterRun] toggle because
// the dashboard auto-prompt and the post-run notes prompt share the same
// "after a Smart Night sequence ends, what does the UI do?" decision
// branch — keeping them in the same file makes the dependency obvious.
//
// Owns:
//   * smartNightMaxSessionHours, smartNightDefaultAfCadenceFrames
//   * smartNightDefaultIntegrationBudgetMinsPerTarget,
//     smartNightIncludeFlatsAtEnd
//   * smartNightUseSchedulerForMultiTarget,
//     smartNightSchedulerTargetThreshold
//   * smartNightDefaultStrategy, smartNightPolarAlignmentStaleAfterDays
//   * smartNightSubExposureFloorSecs, smartNightSubExposureCeilingSecs
//   * smartNightTargetSnr, smartNightAutoPromptEnabled
// * promptForNotesAfterRun (post-run notes prompt)
//
// Does NOT own:
// * Per-target campaign rollup → see `session_lifecycle.dart`.
//   * Pre-flight polar-alignment staleness (different knob, different
//     semantics) → see `preflight.dart`.
// * Adaptive sky-conditions defaults → see
//     `session_lifecycle.dart`.
part of '../settings_provider.dart';

const _allowedSmartNightStrategies = {
  'auto_lrgb',
  'mono_lrgb',
  'narrowband_hoo',
  'narrowband_sho',
  'osc_one_shot',
};

/// Setters for Smart Night auto-builder defaults and the post-run notes
/// prompt toggle.
extension SmartNightSettingsSection on AppSettingsNotifier {
  /// Maximum session wall-clock duration (hours) the Smart Night wizard
  /// uses to cap the planning window. Pass `null` to clear back to "use
  /// the full dark window".
  Future<void> setSmartNightMaxSessionHours(double? value) async {
    final clamped = value?.clamp(1.0, 14.0);
    await _saveSetting(
      'smart_night_max_session_hours',
      clamped == null ? 'null' : clamped.toString(),
    );
    _patchState((s) => s.copyWith(smartNightMaxSessionHours: clamped));
  }

  /// Default autofocus cadence (frames). Clamped to [1, 9999] for the
  /// same reasons as the standard autofocus interval knob.
  Future<void> setSmartNightDefaultAfCadenceFrames(int value) async {
    final clamped = value.clamp(1, 9999);
    await _saveSetting(
      'smart_night_default_af_cadence_frames',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(smartNightDefaultAfCadenceFrames: clamped));
  }

  /// Default integration budget per target (minutes). Clamped to one
  /// full day at the upper end — anyone asking for >24 h per target is
  /// either testing limits or mis-entering hours as minutes.
  Future<void> setSmartNightDefaultIntegrationBudgetMinsPerTarget(
    int value,
  ) async {
    final clamped = value.clamp(1, 24 * 60);
    await _saveSetting(
      'smart_night_default_integration_budget_mins_per_target',
      clamped.toString(),
    );
    _patchState(
      (s) =>
          s.copyWith(smartNightDefaultIntegrationBudgetMinsPerTarget: clamped),
    );
  }

  /// Whether the wizard appends end-of-session flats when the active
  /// profile has a cover calibrator.
  Future<void> setSmartNightIncludeFlatsAtEnd(bool value) async {
    await _saveSetting('smart_night_include_flats_at_end', value.toString());
    _patchState((s) => s.copyWith(smartNightIncludeFlatsAtEnd: value));
  }

  /// Whether the wizard wraps multi-target plans in a TargetSchedulerNode.
  Future<void> setSmartNightUseSchedulerForMultiTarget(bool value) async {
    await _saveSetting(
      'smart_night_use_scheduler_for_multi_target',
      value.toString(),
    );
    _patchState((s) => s.copyWith(smartNightUseSchedulerForMultiTarget: value));
  }

  /// Minimum target count before the wizard auto-picks scheduler mode.
  /// Clamped to [2, 20] — below 2 the toggle is meaningless, above 20
  /// no one is running that many targets in one night.
  Future<void> setSmartNightSchedulerTargetThreshold(int value) async {
    final clamped = value.clamp(2, 20);
    await _saveSetting(
      'smart_night_scheduler_target_threshold',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(smartNightSchedulerTargetThreshold: clamped));
  }

  /// Default Smart Night strategy. Values are the snake_case strategy
  /// names (`auto_lrgb`, `mono_lrgb`, `narrowband_hoo`, `narrowband_sho`,
  /// `osc_one_shot`); the wizard maps them back to [SmartNightStrategy]
  /// enum values.
  Future<void> setSmartNightDefaultStrategy(String value) async {
    if (!_allowedSmartNightStrategies.contains(value)) {
      throw ArgumentError(
        'smartNightDefaultStrategy must be one of '
        '$_allowedSmartNightStrategies, got: $value',
      );
    }
    await _saveSetting('smart_night_default_strategy', value);
    _patchState((s) => s.copyWith(smartNightDefaultStrategy: value));
  }

  /// Days after which a polar alignment is "stale" enough for the Smart
  /// Night wizard to prepend an alignment node. Clamped to [1, 365].
  Future<void> setSmartNightPolarAlignmentStaleAfterDays(int value) async {
    final clamped = value.clamp(1, 365);
    await _saveSetting(
      'smart_night_polar_alignment_stale_after_days',
      clamped.toString(),
    );
    _patchState(
      (s) => s.copyWith(smartNightPolarAlignmentStaleAfterDays: clamped),
    );
  }

  /// Smart Night sub-exposure floor in seconds. Clamped to [1, 3600].
  Future<void> setSmartNightSubExposureFloorSecs(double value) async {
    final clamped = value.clamp(1.0, 3600.0);
    await _saveSetting(
      'smart_night_sub_exposure_floor_secs',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(smartNightSubExposureFloorSecs: clamped));
  }

  /// Smart Night sub-exposure ceiling in seconds. Clamped to [1, 7200].
  Future<void> setSmartNightSubExposureCeilingSecs(double value) async {
    final clamped = value.clamp(1.0, 7200.0);
    await _saveSetting(
      'smart_night_sub_exposure_ceiling_secs',
      clamped.toString(),
    );
    _patchState((s) => s.copyWith(smartNightSubExposureCeilingSecs: clamped));
  }

  /// Smart Night exposure-planning SNR target. Clamped to [1, 500].
  Future<void> setSmartNightTargetSnr(double value) async {
    final clamped = value.clamp(1.0, 500.0);
    await _saveSetting('smart_night_target_snr', clamped.toString());
    _patchState((s) => s.copyWith(smartNightTargetSnr: clamped));
  }

  /// Whether the dashboard Smart Night auto-prompt may appear. This does
  /// not disable the manual Plan Tonight buttons.
  Future<void> setSmartNightAutoPromptEnabled(bool value) async {
    await _saveSetting('smart_night.auto_prompt_enabled', value.toString());
    _patchState((s) => s.copyWith(smartNightAutoPromptEnabled: value));
  }

  /// Whether the Smart Night wizard defaults to auto-picking the top N
  /// targets. Persisted so the choice survives across launches.
  Future<void> setSmartNightAutoSelect(bool value) async {
    await _saveSetting('smart_night.auto_select', value.toString());
    _patchState((s) => s.copyWith(smartNightAutoSelect: value));
  }

  /// How many targets the Smart Night wizard auto-picks. Clamped to a
  /// sane lower bound of 1 so an auto-select run always picks at least one.
  Future<void> setSmartNightAutoSelectCount(int value) async {
    final clamped = value < 1 ? 1 : value;
    await _saveSetting('smart_night.auto_select_count', clamped.toString());
    _patchState((s) => s.copyWith(smartNightAutoSelectCount: clamped));
  }

  /// Persist the wizard's complete working defaults as one logical update.
  /// The dialog changes several related knobs together; issuing one full
  /// remote settings POST per field made a single edit fan out into thirteen
  /// queued writes and exposed partially updated defaults on failure.
  Future<void> updateSmartNightWizardDefaults({
    required double? maxSessionHours,
    required int afCadenceFrames,
    required int integrationBudgetMinsPerTarget,
    required bool includeFlatsAtEnd,
    required bool useSchedulerForMultiTarget,
    required int schedulerTargetThreshold,
    required int polarAlignmentStaleAfterDays,
    required double subExposureFloorSecs,
    required double subExposureCeilingSecs,
    required double targetSnr,
    required String strategy,
    required bool autoSelect,
    required int autoSelectCount,
  }) async {
    if (!_allowedSmartNightStrategies.contains(strategy)) {
      throw ArgumentError(
        'strategy must be one of $_allowedSmartNightStrategies, got: $strategy',
      );
    }
    final clampedMaxHours = maxSessionHours?.clamp(1.0, 14.0);
    final clampedAfCadence = afCadenceFrames.clamp(1, 9999);
    final clampedBudget = integrationBudgetMinsPerTarget.clamp(1, 24 * 60);
    final clampedThreshold = schedulerTargetThreshold.clamp(2, 20);
    final clampedStaleDays = polarAlignmentStaleAfterDays.clamp(1, 365);
    final clampedFloor = subExposureFloorSecs.clamp(1.0, 3600.0);
    final clampedCeiling = subExposureCeilingSecs.clamp(1.0, 7200.0);
    final clampedSnr = targetSnr.clamp(1.0, 500.0);
    final clampedAutoSelectCount = autoSelectCount < 1 ? 1 : autoSelectCount;

    await _saveSettings({
      'smart_night_max_session_hours': clampedMaxHours == null
          ? 'null'
          : clampedMaxHours.toString(),
      'smart_night_default_af_cadence_frames': clampedAfCadence.toString(),
      'smart_night_default_integration_budget_mins_per_target': clampedBudget
          .toString(),
      'smart_night_include_flats_at_end': includeFlatsAtEnd.toString(),
      'smart_night_use_scheduler_for_multi_target': useSchedulerForMultiTarget
          .toString(),
      'smart_night_scheduler_target_threshold': clampedThreshold.toString(),
      'smart_night_polar_alignment_stale_after_days': clampedStaleDays
          .toString(),
      'smart_night_sub_exposure_floor_secs': clampedFloor.toString(),
      'smart_night_sub_exposure_ceiling_secs': clampedCeiling.toString(),
      'smart_night_target_snr': clampedSnr.toString(),
      'smart_night_default_strategy': strategy,
      'smart_night.auto_select': autoSelect.toString(),
      'smart_night.auto_select_count': clampedAutoSelectCount.toString(),
    });
    _patchState(
      (s) => s.copyWith(
        smartNightMaxSessionHours: clampedMaxHours,
        smartNightDefaultAfCadenceFrames: clampedAfCadence,
        smartNightDefaultIntegrationBudgetMinsPerTarget: clampedBudget,
        smartNightIncludeFlatsAtEnd: includeFlatsAtEnd,
        smartNightUseSchedulerForMultiTarget: useSchedulerForMultiTarget,
        smartNightSchedulerTargetThreshold: clampedThreshold,
        smartNightPolarAlignmentStaleAfterDays: clampedStaleDays,
        smartNightSubExposureFloorSecs: clampedFloor,
        smartNightSubExposureCeilingSecs: clampedCeiling,
        smartNightTargetSnr: clampedSnr,
        smartNightDefaultStrategy: strategy,
        smartNightAutoSelect: autoSelect,
        smartNightAutoSelectCount: clampedAutoSelectCount,
      ),
    );
  }

  /// Astronomical-day key the dashboard auto-prompt was dismissed for via
  /// "Hide for tonight". Persisted so the dismissal survives a same-night
  /// restart; pass an empty string to clear it.
  Future<void> setSmartNightPromptDismissedDayKey(String dayKey) async {
    await _saveSetting('smart_night.prompt_dismissed_day_key', dayKey);
    _patchState((s) => s.copyWith(smartNightPromptDismissedDayKey: dayKey));
  }

  /// Whether the auto-prompt note dialog appears after a sequence run
  /// completes. Stored under the same `notes.prompt_after_run` key the
  /// NotesService reads via `promptForNotesAfterRunProvider`, so the
  /// two paths stay in sync.
  Future<void> setPromptForNotesAfterRun(bool value) async {
    await _saveSetting('notes.prompt_after_run', value.toString());
    _patchState((s) => s.copyWith(promptForNotesAfterRun: value));
  }
}
