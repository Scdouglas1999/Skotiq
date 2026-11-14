part of '../scheduler_provider.dart';

/// The scheduler of whichever machine is the imaging host: its start checks,
/// its run controls and its settings. Screens call this and never ask which
/// side they got.
abstract interface class SchedulerControl {
  /// What stands between the scheduler and a start, as the host sees it now.
  Future<SchedulerStartReadiness> startReadiness();

  /// [confirmWarnings] goes ahead past the warnings of [startReadiness].
  Future<void> start({bool confirmWarnings = false});

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  /// Scores the candidates again now. [reason] is written to the scheduler
  /// log where the scheduler runs here.
  Future<void> evaluate({required String reason});

  /// Puts [config] in force at once where the scheduler runs here, before it
  /// is saved, so the queue follows a slider while it moves. A linked host
  /// takes the settings when they are saved.
  void preview(SchedulerConfig config);

  /// Stores [config] and answers the settings the host now holds.
  Future<SchedulerConfig> save(SchedulerConfig config);
}

final schedulerControlProvider = hostRoleProvider<SchedulerControl>(
  here: _LocalSchedulerControl.new,
  linked: (ref, host) => _HostSchedulerControl(host.planning),
);

final class _LocalSchedulerControl implements SchedulerControl {
  _LocalSchedulerControl(this._ref);

  final Ref _ref;

  // Pause and Stop stay available for an engine that is already running even
  // when an unrelated settings refresh is failing; what evaluates or
  // dispatches waits for the cold-start authority gate.
  Future<SchedulerEngine> _ready() =>
      _ref.read(schedulerEngineReadyProvider.future);

  SchedulerEngine get _running => _ref.read(schedulerEngineProvider);

  @override
  Future<SchedulerStartReadiness> startReadiness() async =>
      _ref.read(schedulerStartReadinessProvider);

  @override
  Future<void> start({bool confirmWarnings = false}) async =>
      (await _ready()).start();

  @override
  Future<void> pause() => _running.pause();

  @override
  Future<void> resume() async => (await _ready()).resume();

  @override
  Future<void> stop() => _running.stop();

  @override
  Future<void> evaluate({required String reason}) async =>
      (await _ready()).evaluateNow(reason: reason);

  @override
  void preview(SchedulerConfig config) {
    _ref.read(schedulerConfigUserDirtyProvider.notifier).state = true;
    _running.updateConfig(config);
  }

  @override
  Future<SchedulerConfig> save(SchedulerConfig config) async {
    await _ref.read(schedulerConfigStoreProvider).save(config);
    // The stored row's minimum altitude is half of altitudeFloorProvider,
    // which the sequence builders and the altitude charts read. The engine takes it through
    // ref.listen and skips it while schedulerConfigUserDirtyProvider is set,
    // so its live config is not overwritten.
    _ref.invalidate(schedulerPersistedConfigProvider);
    return config;
  }
}

final class _HostSchedulerControl implements SchedulerControl {
  _HostSchedulerControl(this._host);

  final HostPlanningData _host;

  @override
  Future<SchedulerStartReadiness> startReadiness() async =>
      SchedulerRemoteSnapshot.fromJson(
        await _host.getSchedulerState(),
      ).readiness;

  @override
  Future<void> start({bool confirmWarnings = false}) =>
      _host.controlScheduler('start', confirmWarnings: confirmWarnings);

  @override
  Future<void> pause() => _host.controlScheduler('pause');

  @override
  Future<void> resume() => _host.controlScheduler('resume');

  @override
  Future<void> stop() => _host.controlScheduler('stop');

  @override
  Future<void> evaluate({required String reason}) =>
      _host.controlScheduler('evaluate');

  @override
  void preview(SchedulerConfig config) {}

  @override
  Future<SchedulerConfig> save(SchedulerConfig config) async =>
      SchedulerRemoteSnapshot.fromJson(
        await _host.updateSchedulerConfig(
          config.toStorageJson().cast<String, dynamic>(),
        ),
      ).config;
}
