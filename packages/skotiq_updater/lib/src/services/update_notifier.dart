import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Directory;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/update_manifest.dart';
import '../models/update_state.dart';
import 'update_compatibility.dart';
import 'update_controller.dart';
import 'update_prompt_store.dart';
import 'update_service.dart';

typedef UpdateApplySafetyCheck = Future<void> Function();

/// What a window shows of the process's update state.
///
/// [UpdateController] is the state machine; this is a view of it for the
/// update dialog and Settings > About. It adds only what a prompt needs and a
/// REST client does not: the version the operator skipped, the "not now"
/// deferral, the check throttle, and how a refused or failed install is
/// worded on screen.
class UpdateNotifier extends StateNotifier<UpdateState> {
  final UpdateController _controller;
  final bool _ownsController;
  final UpdatePromptStore _promptStore;
  final Duration _checkInterval;
  final Duration _remindAfter;
  UpdatePromptState _promptState = const UpdatePromptState();
  StreamSubscription<UpdateControllerStatus>? _statusSubscription;

  String? _skippedVersion;
  DateTime? _lastCheckTime;
  bool _checkedThisRun = false;

  /// True from the press of Install until the controller has answered.
  bool _applying = false;

  /// An install the controller refused or could not start, as the window
  /// words it. Cleared by the next thing the operator does.
  String? _applyError;

  static int _nextJob = 0;

  /// [controller] is the process's update controller. Tests may instead pass
  /// an [updateService] (and an [applySafetyCheck]); the notifier then builds
  /// a controller of its own over it and disposes it with itself.
  UpdateNotifier({
    required String currentVersion,
    required int currentBuildNumber,
    required Future<Directory> Function() dataDirectory,
    UpdateController? controller,
    UpdateService? updateService,
    UpdateApplySafetyCheck? applySafetyCheck,
    UpdatePromptStore? promptStore,
    Duration checkInterval = defaultUpdateCheckInterval,
    Duration remindAfter = defaultUpdateRemindAfter,
  }) : assert(
         controller == null ||
             (updateService == null && applySafetyCheck == null),
         'a shared controller already has its service and its safety check',
       ),
       _promptStore = promptStore ?? UpdatePromptStore(dataDirectory),
       _checkInterval = checkInterval,
       _remindAfter = remindAfter,
       _ownsController = controller == null,
       _controller =
           controller ??
           UpdateController.forApp(
             currentVersion: currentVersion,
             currentBuildNumber: currentBuildNumber,
             dataDirectory: dataDirectory,
             service: updateService,
             applySafetyCheck: applySafetyCheck,
           ),
       super(
         UpdateState(
           currentVersion: currentVersion,
           currentBuildNumber: currentBuildNumber,
         ),
       ) {
    _statusSubscription = _controller.statusChanges.listen((_) => _project());
    _project();
    _startupState = _initializeStartupState();
    unawaited(_startupState);
  }

  /// Completes once the persisted prompt state has been loaded. Anything that
  /// reads or writes [_promptState] waits on it first: the load is async and
  /// the startup check fires on a timer, so without this the disk read could
  /// land after a check had already recorded its timestamp and overwrite it
  /// with the stale value, making the next launch check again.
  late final Future<void> _startupState;

  Future<void> _initializeStartupState() async {
    _promptState = await _promptStore.read();
    _skippedVersion = await _controller.readSkippedVersion();
    await _controller.bootstrap();
    final status = _controller.status;
    if (status.message != null || status.lastError != null) {
      developer.log(
        status.lastError ?? status.message!,
        name: 'UpdateNotifier',
        level: status.state == UpdateLifecycleState.failed ? 1000 : 800,
      );
    }
    _project();
  }

  /// Rebuilds [state] from the controller and the prompt answers held here.
  void _project() {
    if (!mounted) return;
    final status = _controller.status;
    final check = _controller.lastCheckResult;
    final staged = _controller.staged;
    final offered = _controller.offeredManifest;

    final hasStaged = staged != null && status.stagedVersion != null;
    UpdateManifest? manifest = offered;
    if (hasStaged && manifest?.version != staged.version) {
      manifest =
          _controller.stagedManifest ??
          UpdateManifest(
            version: staged.version,
            buildNumber: staged.buildNumber,
            releaseDate: staged.stagedAt,
            // Only reached when the staged manifest is unreadable, where the
            // staged build's real target is unknown. Naming this host's own
            // platform states what it would have to be for the staged update
            // to be installable here at all; apply re-reads the real manifest
            // and refuses if it disagrees.
            platform: currentUpdatePlatform(),
            arch: currentUpdateArchitecture(),
            files: {},
            totalSize: 0,
            compressedSize: 0,
            downloadUrl: '',
          );
    }

    final skipped =
        _skippedVersion != null && offered?.version == _skippedVersion;
    var viewStatus = switch (status.state) {
      UpdateLifecycleState.idle =>
        _checkedThisRun ? UpdateStatus.upToDate : UpdateStatus.idle,
      UpdateLifecycleState.available =>
        skipped ? UpdateStatus.upToDate : UpdateStatus.available,
      UpdateLifecycleState.checking => UpdateStatus.checking,
      UpdateLifecycleState.downloading ||
      UpdateLifecycleState.cancelling => UpdateStatus.downloading,
      UpdateLifecycleState.verifying => UpdateStatus.verifying,
      UpdateLifecycleState.staged => UpdateStatus.staged,
      UpdateLifecycleState.installing => UpdateStatus.applying,
      UpdateLifecycleState.failed => UpdateStatus.error,
    };
    String? error = status.state == UpdateLifecycleState.failed
        ? status.lastError ?? status.message
        : null;
    if (_applying && viewStatus == UpdateStatus.staged) {
      viewStatus = UpdateStatus.applying;
    } else if (_applyError != null) {
      viewStatus = UpdateStatus.error;
      error = _applyError;
    } else if (viewStatus == UpdateStatus.staged) {
      // The one message a staged update carries is what to do about an
      // install the platform refused.
      error = status.message;
    } else if (viewStatus == UpdateStatus.available &&
        status.requiresManualUpgrade) {
      error =
          'This build is older than the minimum version supported by '
          'automatic updates. Download the latest full release and '
          'reinstall Skotiq manually.';
    }

    final showOffer = viewStatus != UpdateStatus.upToDate || !skipped;
    state = UpdateState(
      status: viewStatus,
      currentVersion: state.currentVersion,
      currentBuildNumber: state.currentBuildNumber,
      availableUpdate: showOffer ? manifest : null,
      downloadProgress: (status.progressPct ?? 0) / 100,
      downloadedBytes: _controller.downloadedBytes,
      totalBytes: _controller.totalBytes,
      errorMessage: error,
      stagingPath: hasStaged ? staged.extractPath : null,
      lastCheckTime: _lastCheckTime,
      skippedVersion: _skippedVersion,
      requiresManualUpgrade: showOffer && status.requiresManualUpgrade,
      updateServerUrl: _controller.updateServerUrl,
      sourceConfigured: _controller.hasUpdateSource,
      releaseNotes: showOffer ? check?.releaseNotes : null,
      releasePageUrl: check?.releasePageUrl,
      unavailableReason: check?.unavailableReason,
      channel: _controller.channel,
    );
  }

  String _jobId(String kind) => 'window-$kind-${_nextJob++}';

  /// Run a check only if the throttle interval has elapsed since the last one.
  ///
  /// This is what startup calls. [checkForUpdates] stays unthrottled so a
  /// button labelled "Check for updates" always actually checks — a button
  /// that silently does nothing is worse than no button.
  Future<void> checkForUpdatesIfDue({DateTime? now}) async {
    await _startupState;
    final at = now ?? DateTime.now().toUtc();
    if (!_promptState.isCheckDue(at, _checkInterval)) {
      developer.log(
        'Update check not due yet (last checked ${_promptState.lastCheckAt})',
        name: 'UpdateNotifier',
      );
      return;
    }
    await checkForUpdates(now: at);
  }

  /// Whether an available update should be surfaced to the operator now.
  ///
  /// False while the version is deferred or skipped. The caller adds the
  /// hardware gate; this half only knows what the operator already answered.
  bool shouldPrompt({DateTime? now}) {
    final update = state.availableUpdate;
    if (update == null) return false;
    if (state.status != UpdateStatus.available) return false;
    if (state.skippedVersion == update.version) return false;
    final at = now ?? DateTime.now().toUtc();
    return !_promptState.isDeferred(update.version, at, _remindAfter);
  }

  /// "Not now": silence this version for [defaultUpdateRemindAfter], then ask
  /// again. Distinct from [skipUpdate], which silences it for good.
  Future<void> deferUpdate({DateTime? now}) async {
    await _startupState;
    final update = state.availableUpdate;
    if (update == null) return;
    _promptState = _promptState.copyWith(
      deferredVersion: update.version,
      deferredAt: now ?? DateTime.now().toUtc(),
    );
    await _promptStore.write(_promptState);
  }

  /// Check for updates
  Future<void> checkForUpdates({DateTime? now}) async {
    // Also awaited here, not just in the throttled path: the Settings button
    // reaches this directly, and a press during startup would otherwise race
    // the prompt-state load and overwrite it.
    await _startupState;
    if (state.isBusy || _controller.hasActiveOperation) return;
    _applyError = null;
    if (!_controller.hasUpdateSource) {
      developer.log(
        'No update source configured, skipping update check',
        name: 'UpdateNotifier',
      );
      _checkedThisRun = true;
      _lastCheckTime = DateTime.now();
      _project();
      return;
    }

    // Record the attempt before it resolves. A source that is down or rate
    // limited must not turn startup into a retry loop that hammers it every
    // launch; the next check comes at the normal interval either way.
    _promptState = _promptState.copyWith(
      lastCheckAt: now ?? DateTime.now().toUtc(),
    );
    unawaited(_promptStore.write(_promptState));

    try {
      final outcome = await _controller.checkForUpdates();
      // A different version is being offered; forget any earlier skip so it
      // does not silently suppress this newer build on the next run.
      if (outcome.available &&
          _skippedVersion != null &&
          outcome.latestVersion != _skippedVersion) {
        _skippedVersion = null;
        unawaited(_controller.writeSkippedVersion(null));
      }
    } catch (_) {
      // The controller's status carries the failure.
    }
    _checkedThisRun = true;
    _lastCheckTime = DateTime.now();
    _project();
  }

  /// Download and stage the available update
  Future<void> downloadUpdate() async {
    // Builds below minVersion for OTA must be reinstalled manually; the
    // download/apply path is intentionally unreachable for them.
    if (state.requiresManualUpgrade) return;
    if (state.availableUpdate == null) return;
    if (_controller.hasActiveOperation) return;
    _applyError = null;
    try {
      await _controller.downloadAndStage(jobId: _jobId('download'));
    } catch (_) {
      // The controller's status carries the failure.
    }
    _project();
  }

  /// Cancel an in-progress download
  void cancelDownload() {
    if (state.status != UpdateStatus.downloading) return;
    try {
      _controller.abortInFlight();
    } on StateError {
      // Past the point where the transfer can be stopped.
    }
  }

  /// Apply the staged update (will restart the app)
  Future<void> applyUpdate() async {
    if (state.status != UpdateStatus.staged) return;
    _applyError = null;
    _applying = true;
    _project();
    try {
      await _controller.applyStagedUpdate(jobId: _jobId('apply'));
      // The desktop path exits inside the apply once the helper is launched.
      // Still being here, and not staged for a platform installer, means the
      // handoff failed.
      if (_controller.status.state == UpdateLifecycleState.installing) {
        _applyError =
            'Update process did not launch correctly. The app should have '
            'restarted.';
      }
    } catch (e, stackTrace) {
      developer.log(
        'Error applying update: $e',
        name: 'UpdateNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      _applyError = e.toString();
    } finally {
      _applying = false;
      _project();
    }
  }

  /// Skip the current available update
  void skipUpdate() {
    final version = state.availableUpdate?.version;
    if (version == null) return;
    _skippedVersion = version;
    _checkedThisRun = true;
    _project();
    unawaited(_controller.writeSkippedVersion(version));
    // A permanent skip subsumes any "not now" on the same version; leaving
    // both would re-offer the build the moment the deferral aged out.
    _promptState = _promptState.copyWith(clearDeferral: true);
    unawaited(_promptStore.write(_promptState));
  }

  /// Clear any staged update
  Future<void> clearStagedUpdate() async {
    _applyError = null;
    await _controller.discardStaged();
    _checkedThisRun = true;
    _project();
  }

  /// Pop the most recent one-shot UI banner queued by the underlying
  /// [UpdateService] (e.g. corrupted-marker recovery). Returns
  /// null if no notice is pending. Subsequent calls return null until a
  /// new notice is queued.
  UpdateNotice? takePendingNotice() => _controller.takePendingNotice();

  /// Why an update pushed over the LAN was refused or broke off, each time
  /// it happens.
  Stream<String> get lanPushFailures => _controller.events
      .where(
        (event) =>
            event is UpdateFailedEvent &&
            event.phase == UpdateController.lanPushPhase,
      )
      .map((event) => (event as UpdateFailedEvent).error);

  /// Waits until the staged update an earlier run left, if any, is in
  /// [state].
  Future<void> checkStagedUpdate() => _startupState;

  @override
  void dispose() {
    unawaited(_statusSubscription?.cancel());
    if (_ownsController) unawaited(_controller.dispose());
    super.dispose();
  }
}
