// Plate-solver defaults surfaced in Settings → Plate Solving. Owns the
// solver-selection knob plus the per-solver path / search radius / timeout
// fields the PlateSolveService consults.
//
// Owns:
//   * astapPath, astrometryPath
//   * plateSolveTimeout, plateSolveSearchRadius, blindSolve
//   * centeringSyncMount — whether centering syncs the mount to the solved
//     position between iterations, read by the callers that build a
//     CenteringConfig
//
// Does NOT own:
//   * Centering tolerance / framing-assistant defaults — those live in the
//     CenteringService config, not in app settings.
//   * WHICH solver runs. That is `PlateSolverPreference` in the native store
//     (`platesolver.json`) — the only thing the solve dispatcher reads. The
//     `plate_solver` app-setting is a PROJECTION of it kept for backup export
//     and the remote wire model; see [setPlateSolver].
part of '../settings_provider.dart';

/// Setters for plate-solver defaults.
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
    await _saveSetting('plate_solver', label);
    _patchState((s) => s.copyWith(plateSolver: label));
  }

  Future<void> setAstapPath(String value) async {
    await _saveSetting('astap_path', value);
    _patchState((s) => s.copyWith(astapPath: value));
  }

  Future<void> setAstrometryPath(String value) async {
    await _saveSetting('astrometry_path', value);
    _patchState((s) => s.copyWith(astrometryPath: value));
  }

  Future<void> setPlateSolveTimeout(int value) async {
    await _saveSetting('plate_solve_timeout', value.toString());
    _patchState((s) => s.copyWith(plateSolveTimeout: value));
  }

  Future<void> setPlateSolveSearchRadius(double value) async {
    await _saveSetting('plate_solve_search_radius', value.toString());
    _patchState((s) => s.copyWith(plateSolveSearchRadius: value));
  }

  Future<void> setBlindSolve(bool value) async {
    await _saveSetting('blind_solve', value.toString());
    _patchState((s) => s.copyWith(blindSolve: value));
  }

  Future<void> setCenteringSyncMount(bool value) async {
    await _saveSetting('centering_sync_mount', value.toString());
    _patchState((s) => s.copyWith(centeringSyncMount: value));
  }
}
