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
//
// Does NOT own:
//   * Per-instruction recovery defaults → see `recovery.dart`.
//   * Per-filter dither scale / settle parameters → see `equipment.dart`
//     (those describe the guider hardware, not sequence orchestration).
//   * Autofocus algorithm knobs → see `autofocus.dart`.
//   * Smart Night auto-builder defaults → see `smart_night.dart`.
part of '../settings_provider.dart';

/// Setters for sequencer-execution defaults.
extension SequencerSettingsSection on AppSettingsNotifier {
  Future<void> setParkOnUnsafeWeather(bool value) async {
    await _saveSetting('park_on_unsafe_weather', value.toString());
    _patchState((s) => s.copyWith(parkOnUnsafeWeather: value));
  }

  Future<void> setParkBeforeDawn(bool value) async {
    await _saveSetting('park_before_dawn', value.toString());
    _patchState((s) => s.copyWith(parkBeforeDawn: value));
  }

  /// Whether quality problems the sequencer judges stop the run (off by
  /// default: the operator is notified and the run keeps imaging).
  Future<void> setStopRunOnQualityProblems(bool value) async {
    await _saveSetting('stop_run_on_quality_problems', value.toString());
    _patchState((s) => s.copyWith(stopRunOnQualityProblems: value));
  }

  Future<void> setSafetyFailMode(SafetyFailMode value) async {
    await _saveSetting('safety_fail_mode', value.name);
    _patchState((s) => s.copyWith(safetyFailMode: value));
  }

  Future<void> setMeridianFlipMinutes(int value) async {
    await _saveSetting('meridian_flip_minutes', value.toString());
    _patchState((s) => s.copyWith(meridianFlipMinutes: value));
  }

  Future<void> setAutoFocusOnFilterChange(bool value) async {
    await _saveSetting('auto_focus_on_filter_change', value.toString());
    _patchState((s) => s.copyWith(autoFocusOnFilterChange: value));
  }

  Future<void> setUseFilterFocusOffsets(bool value) async {
    await _saveSetting('use_filter_focus_offsets', value.toString());
    _patchState((s) => s.copyWith(useFilterFocusOffsets: value));
  }

  Future<void> setAutoFocusEveryMinutes(int value) async {
    await _saveSetting('auto_focus_every_minutes', value.toString());
    _patchState((s) => s.copyWith(autoFocusEveryMinutes: value));
  }

  Future<void> setDitherEnabled(bool value) async {
    await _saveSetting('dither_enabled', value.toString());
    _patchState((s) => s.copyWith(ditherEnabled: value));
  }

  Future<void> setDitherEveryFrames(int value) async {
    await _saveSetting('dither_every_frames', value.toString());
    _patchState((s) => s.copyWith(ditherEveryFrames: value));
  }

  // Sequencer editor layout — cross-restart UI persistence. The sequencer
  // screen seeds its in-session StateProviders from these on first read and
  // writes back through these setters on change.
  Future<void> setSequencerToolboxCollapsed(bool value) async {
    await _saveSetting('sequencer.toolbox_collapsed', value.toString());
    _patchState((s) => s.copyWith(sequencerToolboxCollapsed: value));
  }

  Future<void> setSequencerPropertiesCollapsed(bool value) async {
    await _saveSetting('sequencer.properties_collapsed', value.toString());
    _patchState((s) => s.copyWith(sequencerPropertiesCollapsed: value));
  }

  Future<void> setSequencerSnippetPaletteVisible(bool value) async {
    await _saveSetting('sequencer.snippet_palette_visible', value.toString());
    _patchState((s) => s.copyWith(sequencerSnippetPaletteVisible: value));
  }

  Future<void> setSequencerToolboxTab(String value) async {
    await _saveSetting('sequencer.toolbox_tab', value);
    _patchState((s) => s.copyWith(sequencerToolboxTab: value));
  }

  Future<void> setSequencerActiveTab(int value) async {
    await _saveSetting('sequencer.active_tab', value.toString());
    _patchState((s) => s.copyWith(sequencerActiveTab: value));
  }

  Future<void> setSequencerLeftPanelWidth(double value) async {
    await _saveSetting('sequencer.left_panel_width', value.toString());
    _patchState((s) => s.copyWith(sequencerLeftPanelWidth: value));
  }

  Future<void> setSequencerRightPanelWidth(double value) async {
    await _saveSetting('sequencer.right_panel_width', value.toString());
    _patchState((s) => s.copyWith(sequencerRightPanelWidth: value));
  }
}
