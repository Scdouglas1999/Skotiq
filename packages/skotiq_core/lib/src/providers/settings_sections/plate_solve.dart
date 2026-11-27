// Plate-solver defaults surfaced in Settings → Plate Solving.
//
// Owns:
//   * plateSolveTimeout, plateSolveSearchRadius, blindSolve
//   * centeringSyncMount — whether centering syncs the mount to the solved
//     position between iterations, read by the callers that build a
//     CenteringConfig
//   * centeringToleranceArcsec — how close counts as centered, for the
//     Center step, every recenter of a run and centering started by hand
//
// Does NOT own:
//   * Framing-assistant defaults — those live in the CenteringService
//     config, not in app settings.
//   * WHICH solver runs, or the solver program paths. Those are
//     `PlateSolverPreference` in the native store (`platesolver.json`), the
//     only thing the solve dispatcher reads. The `plate_solver`, `astap_path`
//     and `astrometry_path` app-settings are copies of it. The settings
//     document, backups and the host's settings store read the preference
//     itself ([plateSolverPreferenceRows]); the stored rows are what a
//     restored backup brings back.
part of '../settings_provider.dart';

/// The app-setting rows that copy [preference].
Map<String, String> plateSolverPreferenceRows(
  PlateSolverPreference preference,
) => {
  ...AppSettingDefs.plateSolver.toRows(preference.choice.settingLabel),
  ...AppSettingDefs.astapPath.toRows(preference.astapPath),
  ...AppSettingDefs.astrometryPath.toRows(preference.astrometryPath),
};

extension PlateSolveSettingsSection on AppSettingsNotifier {
  /// Select the solver engine.
  ///
  /// Update the dispatcher preference first, then its exported settings
  /// projection, so an acknowledged value always selects the running engine.
  Future<void> setPlateSolver(String value) async {
    final choice = PlateSolverChoice.fromSettingLabel(value);
    if (choice == null) {
      throw ArgumentError.value(
        value,
        'plateSolver',
        'Unknown solver. Expected one of Auto, ASTAP, Astrometry.net',
      );
    }
    final service = ref.read(plateSolveServiceProvider);
    final current = await service.getConfig();
    await service.setConfig(current.copyWith(choice: choice));
    await _syncPlateSolverProjection(choice);
  }

  /// Update the `plate_solver` projection after the preference itself changed
  /// (the Plate Solving page writes the preference directly). Deliberately
  /// does NOT call back into the preference — that would recurse.
  Future<void> syncPlateSolverFromPreference(PlateSolverChoice choice) =>
      _syncPlateSolverProjection(choice);

  Future<void> _syncPlateSolverProjection(PlateSolverChoice choice) async {
    final label = choice.settingLabel;
    await _set(AppSettingDefs.plateSolver, label);
  }

  /// Write solver program paths to the plate-solver preference, the store
  /// the solver reads; the settings rows are copies of it.
  Future<void> _writeSolverPaths({
    String? astapPath,
    String? astrometryPath,
  }) async {
    final service = ref.read(plateSolveServiceProvider);
    final current = await service.getConfig();
    await service.setConfig(
      current.copyWith(astapPath: astapPath, astrometryPath: astrometryPath),
    );
    ref
      ..invalidate(plateSolverPreferenceProvider)
      ..invalidate(plateSolverDetectionProvider);
  }

  Future<void> setPlateSolveTimeout(int value) =>
      _set(AppSettingDefs.plateSolveTimeout, value);

  Future<void> setPlateSolveSearchRadius(double value) =>
      _set(AppSettingDefs.plateSolveSearchRadius, value);

  Future<void> setBlindSolve(bool value) =>
      _set(AppSettingDefs.blindSolve, value);

  Future<void> setCenteringSyncMount(bool value) =>
      _set(AppSettingDefs.centeringSyncMount, value);

  Future<void> setCenteringToleranceArcsec(double value) =>
      _set(AppSettingDefs.centeringToleranceArcsec, value);
}
