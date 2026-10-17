part of '../scheduler_provider.dart';

/// Live stream of every integration goal. Driven by
/// `IntegrationGoalService.watchAll`; used by [_schedulerAutoReevalProvider]
/// to wake the engine whenever the operator edits goals.
final integrationGoalsStreamProvider = StreamProvider<List<IntegrationGoal>>((
  ref,
) {
  return ref.watch(integrationGoalServiceProvider).watchAll();
});

/// Live stream of every constraint. Driven by
/// `TargetConstraintService.watchAll`.
final targetConstraintsStreamProvider = StreamProvider<List<TargetConstraint>>((
  ref,
) {
  return ref.watch(targetConstraintServiceProvider).watchAll();
});

/// Durable store for the operator-tuned [SchedulerConfig]. The scoring sliders
/// write through [save]; [schedulerEngineProvider] hydrates from [load] at
/// cold start so tuned weights / min-altitude / hysteresis survive a restart.
class SchedulerConfigStore {
  SchedulerConfigStore(this._dao);

  final SettingsDao _dao;
  static const String _key = 'scheduler_config';

  Future<SchedulerConfig> load() async {
    final raw = await _dao.getSetting(_key);
    if (raw == null || raw.isEmpty) return SchedulerConfig.defaults;
    try {
      return SchedulerConfig.fromStorageJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (error) {
      throw FormatException(
        'Persisted scheduler configuration is invalid',
        error,
      );
    }
  }

  Future<void> save(SchedulerConfig config) {
    return _dao.setSetting(_key, jsonEncode(config.toStorageJson()));
  }
}

final schedulerConfigStoreProvider = Provider<SchedulerConfigStore>((ref) {
  return SchedulerConfigStore(ref.read(settingsDaoProvider));
});

/// One-shot cold-start load of the persisted scheduler config. Not invalidated
/// on slider edits (those update the engine in place via `updateConfig`), so
/// the engine is not torn down on every tweak.
final schedulerPersistedConfigProvider = FutureProvider<SchedulerConfig>((ref) {
  return ref.read(schedulerConfigStoreProvider).load();
});

/// Set as soon as the operator changes scheduler tuning in this process. It
/// prevents a late cold-start read from overwriting an edit made while the
/// settings row was still loading.
final schedulerConfigUserDirtyProvider = StateProvider<bool>((ref) => false);

/// The site's minimum imaging altitude in degrees — the ONE number.
///
/// The scheduler's [SchedulerConfig.minAltitudeDegrees] is the only
/// operator-editable minimum altitude in the product (Plan Tonight → Schedule →
/// Scoring weights), so it is the authority. Everything that gates on "is this
/// target high enough" reads it here instead of carrying a private constant:
/// the Smart Night sequence builder, the mosaic panel altitude waits, and the
/// threshold line the altitude charts draw. A private constant anywhere lets
/// one screen admit a target another refuses.
///
/// Per-target overrides (`targets.min_altitude`, carried on
/// `ForecastTarget.minAltitudeDeg`) are a deliberate exception: a specific
/// target may need to clear more than the site does. This provider is the
/// FLOOR, not a replacement for those.
final siteMinimumAltitudeDegProvider = Provider<double>((ref) {
  final persisted = ref.watch(schedulerPersistedConfigProvider).valueOrNull;
  // Before the durable row has loaded (or when it has never been written) the
  // engine itself runs on SchedulerConfig.defaults, so that is the honest
  // answer here too — never a second hard-coded number.
  return persisted?.minAltitudeDegrees ??
      SchedulerConfig.defaults.minAltitudeDegrees;
});
