// Sequencer-execution defaults surfaced in Settings → Sequencer. Owns the
// behaviour-tree-level knobs the executor consults: park triggers, the
// meridian-flip warning window, autofocus cadence, dither cadence.
//
// Owns:
//   * parkOnUnsafeWeather, parkBeforeDawn, safetyFailMode
//   * stopRunOnQualityProblems
//   * meridianFlipMinutes, autoFocusOnFilterChange, useFilterFocusOffsets
//   * autoFocusEveryMinutes
//   * ditherEnabled, ditherEveryFrames
//   * cameraRetries, filterWheelRetries
//
// Does NOT own:
//   * Per-instruction recovery defaults → see `recovery.dart`.
//   * Per-filter dither scale / settle parameters → see `equipment.dart`
//     (those describe the guider hardware, not sequence orchestration).
//   * Autofocus algorithm knobs → see `autofocus.dart`.
//   * Smart Night auto-builder defaults → see `smart_night.dart`.
part of '../settings_provider.dart';

extension SequencerSettingsSection on AppSettingsNotifier {
  Future<void> setParkOnUnsafeWeather(bool value) =>
      _set(AppSettingDefs.parkOnUnsafeWeather, value);

  Future<void> setParkBeforeDawn(bool value) =>
      _set(AppSettingDefs.parkBeforeDawn, value);

  /// Whether quality problems the sequencer judges stop the run (off by
  /// default: the operator is notified and the run keeps imaging).
  Future<void> setStopRunOnQualityProblems(bool value) =>
      _set(AppSettingDefs.stopRunOnQualityProblems, value);

  /// Whether a run held by a mount fault solves, syncs and resumes on its
  /// own (off by default: the operator recovers the mount).
  Future<void> setMountGuardAutoSyncResume(bool value) =>
      _set(AppSettingDefs.mountGuardAutoSyncResume, value);

  Future<void> setSafetyFailMode(SafetyFailMode value) =>
      _set(AppSettingDefs.safetyFailMode, value);

  Future<void> setMeridianFlipMinutes(int value) =>
      _set(AppSettingDefs.meridianFlipMinutes, value);

  Future<void> setAutoFocusOnFilterChange(bool value) =>
      _set(AppSettingDefs.autoFocusOnFilterChange, value);

  Future<void> setUseFilterFocusOffsets(bool value) =>
      _set(AppSettingDefs.useFilterFocusOffsets, value);

  Future<void> setAutoFocusEveryMinutes(int value) =>
      _set(AppSettingDefs.autoFocusEveryMinutes, value);

  Future<void> setDitherEnabled(bool value) =>
      _set(AppSettingDefs.ditherEnabled, value);

  Future<void> setDitherEveryFrames(int value) =>
      _set(AppSettingDefs.ditherEveryFrames, value);

  Future<void> setCameraRetries(int value) =>
      _set(AppSettingDefs.cameraRetries, value);

  Future<void> setFilterWheelRetries(int value) =>
      _set(AppSettingDefs.filterWheelRetries, value);

  // Sequencer editor layout — cross-restart UI persistence. The sequencer
  // screen seeds its in-session StateProviders from these on first read and
  // writes back through these setters on change.
  Future<void> setSequencerToolboxCollapsed(bool value) =>
      _set(AppSettingDefs.sequencerToolboxCollapsed, value);

  Future<void> setSequencerPropertiesCollapsed(bool value) =>
      _set(AppSettingDefs.sequencerPropertiesCollapsed, value);

  Future<void> setSequencerSnippetPaletteVisible(bool value) =>
      _set(AppSettingDefs.sequencerSnippetPaletteVisible, value);

  Future<void> setSequencerToolboxTab(String value) =>
      _set(AppSettingDefs.sequencerToolboxTab, value);

  Future<void> setSequencerActiveTab(int value) =>
      _set(AppSettingDefs.sequencerActiveTab, value);

  Future<void> setSequencerLeftPanelWidth(double value) =>
      _set(AppSettingDefs.sequencerLeftPanelWidth, value);

  Future<void> setSequencerRightPanelWidth(double value) =>
      _set(AppSettingDefs.sequencerRightPanelWidth, value);
}
