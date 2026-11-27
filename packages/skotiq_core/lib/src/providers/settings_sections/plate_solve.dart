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
//     only thing the solve dispatcher reads. The `plateSolver`, `astapPath`
//     and `astrometryPath` settings are held there ([Setting.heldNatively]):
//     the settings document, backups and the host's settings store build
//     them from it, and a replace-restore writes a backup's rows into it.
part of '../settings_provider.dart';

/// The plate-solver preference [service] holds, as the settings document,
/// the host's settings store and backups report it: a fresh install's when
/// it cannot be read, never a stored copy, which can be behind it.
Future<PlateSolverPreference> reportedPlateSolverPreference(
  PlateSolveService service, {
  required String source,
}) async {
  try {
    return await service.getConfig();
  } on Object catch (error) {
    Log.warning(
      'The plate-solver preference could not be read; reporting a fresh '
      "install's solver settings: $error",
      source: source,
    );
    return const PlateSolverPreference();
  }
}

/// The settings rows that stand for [preference].
Map<String, String> plateSolverPreferenceRows(
  PlateSolverPreference preference,
) => {
  ...AppSettingDefs.plateSolver.toRows(preference.choice.settingLabel),
  ...AppSettingDefs.astapPath.toRows(preference.astapPath),
  ...AppSettingDefs.astrometryPath.toRows(preference.astrometryPath),
};

/// The settings document's plate-solver fields for [preference], by wire
/// name.
Map<String, Object?> plateSolverWireValues(PlateSolverPreference preference) =>
    {
      AppSettingDefs.plateSolver.wire: preference.choice.settingLabel,
      AppSettingDefs.astapPath.wire: preference.astapPath,
      AppSettingDefs.astrometryPath.wire: preference.astrometryPath,
    };

extension PlateSolveSettingsSection on AppSettingsNotifier {
  /// Write solver program paths to the plate-solver preference, the store
  /// the solver reads.
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
