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
//   * smartNightTargetSnr
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
    await _set(AppSettingDefs.smartNightMaxSessionHours, clamped);
  }

  /// Default autofocus cadence (frames). Clamped to [1, 9999] for the
  /// same reasons as the standard autofocus interval knob.
  Future<void> setSmartNightDefaultAfCadenceFrames(int value) =>
      _set(AppSettingDefs.smartNightDefaultAfCadenceFrames, value);

  /// Default integration budget per target (minutes). Clamped to one
  /// full day at the upper end — anyone asking for >24 h per target is
  /// either testing limits or mis-entering hours as minutes.
  Future<void> setSmartNightDefaultIntegrationBudgetMinsPerTarget(int value) =>
      _set(AppSettingDefs.smartNightDefaultIntegrationBudgetMinsPerTarget, value);

  /// Whether the wizard appends end-of-session flats when the active
  /// profile has a cover calibrator.
  Future<void> setSmartNightIncludeFlatsAtEnd(bool value) =>
      _set(AppSettingDefs.smartNightIncludeFlatsAtEnd, value);

  /// Whether the wizard wraps multi-target plans in a TargetSchedulerNode.
  Future<void> setSmartNightUseSchedulerForMultiTarget(bool value) =>
      _set(AppSettingDefs.smartNightUseSchedulerForMultiTarget, value);

  /// Minimum target count before the wizard auto-picks scheduler mode.
  /// Clamped to [2, 20] — below 2 the toggle is meaningless, above 20
  /// no one is running that many targets in one night.
  Future<void> setSmartNightSchedulerTargetThreshold(int value) =>
      _set(AppSettingDefs.smartNightSchedulerTargetThreshold, value);

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
    await _set(AppSettingDefs.smartNightDefaultStrategy, value);
  }

  /// Days after which a polar alignment is "stale" enough for the Smart
  /// Night wizard to prepend an alignment node. Clamped to [1, 365].
  Future<void> setSmartNightPolarAlignmentStaleAfterDays(int value) =>
      _set(AppSettingDefs.smartNightPolarAlignmentStaleAfterDays, value);

  /// Smart Night sub-exposure floor in seconds. Clamped to [1, 3600].
  Future<void> setSmartNightSubExposureFloorSecs(double value) =>
      _set(AppSettingDefs.smartNightSubExposureFloorSecs, value);

  /// Smart Night sub-exposure ceiling in seconds. Clamped to [1, 7200].
  Future<void> setSmartNightSubExposureCeilingSecs(double value) =>
      _set(AppSettingDefs.smartNightSubExposureCeilingSecs, value);

  /// Smart Night exposure-planning SNR target. Clamped to [1, 500].
  Future<void> setSmartNightTargetSnr(double value) =>
      _set(AppSettingDefs.smartNightTargetSnr, value);

  /// Whether the Smart Night wizard defaults to auto-picking the top N
  /// targets. Persisted so the choice survives across launches.
  Future<void> setSmartNightAutoSelect(bool value) =>
      _set(AppSettingDefs.smartNightAutoSelect, value);

  /// How many targets the Smart Night wizard auto-picks. Clamped to a
  /// sane lower bound of 1 so an auto-select run always picks at least one.
  Future<void> setSmartNightAutoSelectCount(int value) =>
      _set(AppSettingDefs.smartNightAutoSelectCount, value);

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

    await _setAll([
      AppSettingDefs.smartNightMaxSessionHours.to(clampedMaxHours),
      AppSettingDefs.smartNightDefaultAfCadenceFrames.to(clampedAfCadence),
      AppSettingDefs.smartNightDefaultIntegrationBudgetMinsPerTarget.to(
        clampedBudget,
      ),
      AppSettingDefs.smartNightIncludeFlatsAtEnd.to(includeFlatsAtEnd),
      AppSettingDefs.smartNightUseSchedulerForMultiTarget.to(
        useSchedulerForMultiTarget,
      ),
      AppSettingDefs.smartNightSchedulerTargetThreshold.to(clampedThreshold),
      AppSettingDefs.smartNightPolarAlignmentStaleAfterDays.to(clampedStaleDays),
      AppSettingDefs.smartNightSubExposureFloorSecs.to(clampedFloor),
      AppSettingDefs.smartNightSubExposureCeilingSecs.to(clampedCeiling),
      AppSettingDefs.smartNightTargetSnr.to(clampedSnr),
      AppSettingDefs.smartNightDefaultStrategy.to(strategy),
      AppSettingDefs.smartNightAutoSelect.to(autoSelect),
      AppSettingDefs.smartNightAutoSelectCount.to(clampedAutoSelectCount),
    ]);
  }

  /// Astronomical-day key the dashboard auto-prompt was dismissed for via
  /// "Hide for tonight". Persisted so the dismissal survives a same-night
  /// restart; pass an empty string to clear it.
  Future<void> setSmartNightPromptDismissedDayKey(String dayKey) async {
    await _set(AppSettingDefs.smartNightPromptDismissedDayKey, dayKey);
  }

  /// Whether the auto-prompt note dialog appears after a sequence run
  /// completes. Stored under the same `notes.prompt_after_run` key the
  /// NotesService reads via `promptForNotesAfterRunProvider`, so the
  /// two paths stay in sync.
  Future<void> setPromptForNotesAfterRun(bool value) =>
      _set(AppSettingDefs.promptForNotesAfterRun, value);
}
