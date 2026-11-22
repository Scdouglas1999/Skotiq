part of '../scheduler_provider.dart';

/// The autopilot as the imaging host reports it: this machine's engine, or a
/// linked host's state. [AutopilotView.unavailable] when it cannot be read.
final class AutopilotView {
  const AutopilotView({
    required SchedulerStatus this.status,
    required this.decision,
    required SchedulerConfig this.config,
    required SchedulerStartReadiness this.readiness,
  }) : error = null,
       retry = null;

  const AutopilotView.unavailable({this.error, this.retry})
    : status = null,
      decision = null,
      config = null,
      readiness = null;

  final SchedulerStatus? status;
  final SchedulerDecision? decision;
  final SchedulerConfig? config;
  final SchedulerStartReadiness? readiness;
  final Object? error;
  final void Function()? retry;

  bool get hasCandidates => decision?.scoredCandidates.isNotEmpty ?? false;
}

/// The autopilot a screen shows. Where the engine runs here, an idle
/// autopilot shows its preview decision before the last live one, and a
/// running one the live decision first.
final autopilotViewProvider = Provider.autoDispose<AutopilotView>((ref) {
  final container = ref.container;
  if (ref.watch(isRemoteModeProvider)) {
    final remoteAsync = ref.watch(schedulerRemoteSnapshotProvider);
    final remote = remoteAsync.valueOrNull;
    if (remote == null) {
      return AutopilotView.unavailable(
        error: remoteAsync.hasError ? remoteAsync.error : null,
        retry: () => container.invalidate(schedulerRemoteSnapshotProvider),
      );
    }
    return AutopilotView(
      status: remote.status,
      decision: remote.decision,
      config: remote.config,
      readiness: remote.readiness,
    );
  }
  final readyAsync = ref.watch(schedulerEngineReadyProvider);
  final engine = readyAsync.valueOrNull;
  if (engine == null) {
    return AutopilotView.unavailable(
      error: readyAsync.hasError ? readyAsync.error : null,
      retry: () {
        container.invalidate(appSettingsProvider);
        container.invalidate(schedulerPersistedConfigProvider);
        container.invalidate(schedulerEngineReadyProvider);
      },
    );
  }
  final status = ref.watch(schedulerStatusProvider);
  final live = ref.watch(currentSchedulerDecisionProvider);
  final preview = ref.watch(schedulerPreviewDecisionProvider).valueOrNull;
  // The always-on services start this too; watching it here keeps rescoring
  // on data changes running while the autopilot is on screen.
  ref.watch(schedulerAutoReevalProvider);
  return AutopilotView(
    status: status,
    decision: status.state == SchedulerState.idle
        ? preview ?? live
        : live ?? preview,
    config: engine.config,
    readiness: ref.watch(schedulerStartReadinessProvider),
  );
});

/// An autopilot settings edit that has not been confirmed by the host yet.
final class AutopilotSettingsEdit {
  const AutopilotSettingsEdit([this.requested]);

  final SchedulerConfig? requested;
}

/// The autopilot settings a screen edits, saved to the imaging host one save
/// at a time, and the poll that keeps a linked host's autopilot current while
/// the screen is open.
final autopilotControllerProvider =
    StateNotifierProvider.autoDispose<
      AutopilotController,
      AutopilotSettingsEdit
    >(AutopilotController.new);

final class AutopilotController extends StateNotifier<AutopilotSettingsEdit> {
  AutopilotController(this._ref) : super(const AutopilotSettingsEdit()) {
    _hostScopes = AsyncScopes(
      _ref.container.read,
      backendProvider,
      alive: () => mounted,
    );
    _ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      // Nothing asked of the old host carries over to the new one.
      _hostScopes.cancelAll();
      _saveErrorShown = false;
      _confirmed = null;
      _saveTail = Future<void>.value();
      state = const AutopilotSettingsEdit();
    });
    _startPolling();
  }

  final Ref _ref;
  late final AsyncScopes<SkotiqBackend> _hostScopes;
  SchedulerConfig? _confirmed;
  Future<void> _saveTail = Future<void>.value();
  bool _saveErrorShown = false;
  Timer? _poll;

  static const _pollInterval = Duration(seconds: 3);

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!mounted || !_ref.read(isRemoteModeProvider)) return;
      _ref.invalidate(schedulerRemoteSnapshotProvider);
    });
  }

  /// Polls again after [pausePolling], unless it never stopped.
  void resumePolling() {
    final poll = _poll;
    if (poll == null || !poll.isActive) _startPolling();
  }

  /// Stops the linked-host poll while the app is in the background.
  void pausePolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// The settings to show beside [view]: an edit still saving, else what
  /// the host reports, else what it last confirmed.
  SchedulerConfig shownConfig(AutopilotView view) {
    final requested = state.requested;
    final hostConfig = view.config;
    if (requested == null && hostConfig != null) _confirmed = hostConfig;
    return requested ?? hostConfig ?? _confirmed ?? SchedulerConfig.defaults;
  }

  /// Puts [config] in force at once and saves it to the host after any save
  /// still running. A failed save puts the confirmed settings back.
  /// [onSaveFailed] is told the first failure on this host since the last
  /// save that went through.
  void apply(
    SchedulerConfig config, {
    required void Function(Object error) onSaveFailed,
  }) {
    final host = _hostScopes.begin();
    final scheduler = _ref.read(schedulerControlProvider);
    state = AutopilotSettingsEdit(config);
    scheduler.preview(config);

    _saveTail = _saveTail.then((_) async {
      try {
        final confirmed = await scheduler.save(config);
        if (!mounted || host.isStale) return;
        _confirmed = confirmed;
        state = AutopilotSettingsEdit(
          state.requested == config ? null : state.requested,
        );
        _ref.invalidate(schedulerRemoteSnapshotProvider);
        _saveErrorShown = false;
      } catch (error) {
        if (mounted && host.isCurrent) {
          if (state.requested == config) {
            scheduler.preview(_confirmed ?? SchedulerConfig.defaults);
            state = const AutopilotSettingsEdit();
          }
          _ref.invalidate(schedulerRemoteSnapshotProvider);
        }
        if (mounted && host.isCurrent && !_saveErrorShown) {
          _saveErrorShown = true;
          onSaveFailed(error);
        }
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
