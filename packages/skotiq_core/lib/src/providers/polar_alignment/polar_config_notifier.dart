part of '../polar_alignment_provider.dart';

// Polar alignment configuration provider (persisted)

/// Provider for persisted polar alignment configuration
final polarAlignmentConfigProvider =
    StateNotifierProvider<PolarAlignmentConfigNotifier, PolarAlignmentConfig>((
      ref,
    ) {
      return PolarAlignmentConfigNotifier(ref);
    });

/// Surfaces the last polar-alignment config persistence failure (null when the
/// most recent save succeeded). The UI watches this to show a truthful "not
/// saved" indication instead of the settings silently looking persisted.
final polarAlignmentConfigSaveErrorProvider = StateProvider<String?>(
  (ref) => null,
);

/// Notifier that persists polar alignment configuration to database
class PolarAlignmentConfigNotifier extends StateNotifier<PolarAlignmentConfig> {
  final Ref ref;
  static const String _settingsKey = 'polar_alignment_config';

  /// Bumped on every user edit. The async initial load captures the revision
  /// before its `await` and only applies the loaded config if the revision is
  /// unchanged — so a load that resolves *after* the user has already edited
  /// cannot clobber those edits.
  int _revision = 0;

  PolarAlignmentConfigNotifier(this.ref) : super(const PolarAlignmentConfig()) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final revisionAtStart = _revision;
    try {
      final db = ref.read(databaseProvider);
      final setting = await db.settingsDao.getSetting(_settingsKey);

      // If the user edited while we were reading the DB, honour their edit and
      // discard the stale on-disk value rather than overwriting it.
      if (_revision != revisionAtStart) {
        developer.log(
          '[PolarAlignmentConfigNotifier] Skipping stale load — user edited during load',
          name: 'PolarAlignmentConfigNotifier',
          level: 700,
        );
        return;
      }

      if (setting != null && setting.isNotEmpty) {
        final json = jsonDecode(setting) as Map<String, dynamic>;
        state = PolarAlignmentConfig.fromJson(json);
        developer.log(
          '[PolarAlignmentConfigNotifier] Loaded config from DB',
          name: 'PolarAlignmentConfigNotifier',
          level: 800,
        );
      }
    } catch (e) {
      developer.log(
        '[PolarAlignmentConfigNotifier] Failed to load config: $e',
        name: 'PolarAlignmentConfigNotifier',
        level: 1000,
        error: e,
      );
    }
  }

  Future<void> updateConfig(PolarAlignmentConfig config) async {
    _revision++;
    state = config;
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final db = ref.read(databaseProvider);
      final json = jsonEncode(state.toJson());
      await db.settingsDao.setSetting(_settingsKey, json);
      // Clear any previously-surfaced save error now that a save succeeded.
      ref.read(polarAlignmentConfigSaveErrorProvider.notifier).state = null;
      developer.log(
        '[PolarAlignmentConfigNotifier] Saved config to DB',
        name: 'PolarAlignmentConfigNotifier',
        level: 800,
      );
    } catch (e) {
      // Surface the failure so the UI can show the settings were NOT persisted,
      // and rethrow so awaited callers (and tests) observe it rather than
      // seeing an apparent success.
      ref.read(polarAlignmentConfigSaveErrorProvider.notifier).state =
          'Failed to save polar alignment settings: $e';
      developer.log(
        '[PolarAlignmentConfigNotifier] Failed to save config: $e',
        name: 'PolarAlignmentConfigNotifier',
        level: 1000,
        error: e,
      );
      rethrow;
    }
  }

  /// UI-facing edit: apply + persist, swallowing the persistence error *after*
  /// it has been surfaced via [polarAlignmentConfigSaveErrorProvider], so a
  /// fire-and-forget UI callback never raises an unhandled exception. Direct
  /// [updateConfig] still rethrows for programmatic callers and tests.
  Future<void> _edit(PolarAlignmentConfig config) async {
    try {
      await updateConfig(config);
    } catch (_) {
      // Already surfaced via polarAlignmentConfigSaveErrorProvider.
    }
  }

  /// Update a single field
  Future<void> setExposureTime(double value) =>
      _edit(state.copyWith(exposureTime: value));

  Future<void> setStepSize(double value) =>
      _edit(state.copyWith(stepSize: value));

  Future<void> setBinning(int value) => _edit(state.copyWith(binning: value));

  Future<void> setIsNorth(bool value) => _edit(state.copyWith(isNorth: value));

  Future<void> setManualRotation(bool value) =>
      _edit(state.copyWith(manualRotation: value));

  Future<void> setRotateEast(bool value) =>
      _edit(state.copyWith(rotateEast: value));

  Future<void> setSolveTimeout(double value) =>
      _edit(state.copyWith(solveTimeout: value));

  Future<void> setAutoCompleteThreshold(double value) =>
      _edit(state.copyWith(autoCompleteThreshold: value));

  /// Start mode: true = measure from current pointing; false = slew to the
  /// pole region first (needs the site location, enforced by the backend).
  Future<void> setStartFromCurrent(bool value) =>
      _edit(state.copyWith(startFromCurrent: value));

  Future<void> setGain(int? value) => _edit(state.copyWith(gain: value));

  Future<void> setOffset(int? value) => _edit(state.copyWith(offset: value));

  /// Reset to defaults
  Future<void> resetToDefaults() => _edit(const PolarAlignmentConfig());
}
