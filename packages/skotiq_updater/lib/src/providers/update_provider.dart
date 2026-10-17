import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        DeviceConnectionState,
        SequenceExecutionState,
        appVersionProvider,
        sequencerBackendProvider,
        cameraStateProvider,
        mountStateProvider,
        sequenceExecutionStateProvider,
        resolveSkotiqDataDirectory;

import '../models/update_manifest.dart';
import '../models/update_state.dart';
import '../services/android_installer.dart';
import '../services/github_release_source.dart';
import '../services/update_compatibility.dart';
import '../services/update_downloader.dart';
import '../services/update_prompt_store.dart';
import '../services/update_service.dart';
import '../services/lan_push_receiver.dart';

/// The GitHub project shipped builds read releases from.
const String kSkotiqReleaseOwner = 'Scdouglas1999';
const String kSkotiqReleaseRepo = 'Skotiq';

typedef UpdateApplySafetyCheck = Future<void> Function();
typedef UpdateApplySafetyReader = T Function<T>(ProviderListenable<T> provider);

/// Provider for the update state.
///
/// Reads the running app's version from `skotiq_core`'s
/// [appVersionProvider], and lets that provider's error bubble when it has not
/// been overridden at startup: the update server decides whether to advertise a
/// newer build from this string, so a substituted default breaks update polling
/// with nothing on screen to say so.
final updateProvider = StateNotifierProvider<UpdateNotifier, UpdateState>((
  ref,
) {
  final versionInfo = ref.watch(appVersionProvider);
  return UpdateNotifier(
    currentVersion: versionInfo.version,
    currentBuildNumber: versionInfo.buildNumber,
    applySafetyCheck: () => defaultUpdateApplySafetyCheck(ref),
  );
});

bool _isActiveSequenceState(SequenceExecutionState state) {
  return state == SequenceExecutionState.running ||
      state == SequenceExecutionState.paused ||
      state == SequenceExecutionState.stopping ||
      state == SequenceExecutionState.recovering;
}

Future<void> _checkpointIfSessionLoaded(UpdateApplySafetyReader read) async {
  final sequenceState = read(sequenceExecutionStateProvider);
  if (sequenceState == SequenceExecutionState.idle) {
    return;
  }

  await read(sequencerBackendProvider).saveCheckpoint();
}

/// Run the update-apply safety gate against any Riverpod reader.
///
/// Accepting the reader rather than only a widget/provider [Ref] lets the
/// headless OTA controller use the exact same checks through its root
/// [ProviderContainer]. This keeps GUI and remotely-triggered updates from
/// drifting into different hardware-safety behavior.
Future<void> defaultUpdateApplySafetyCheckWithReader(
  UpdateApplySafetyReader read,
) async {
  final sequenceState = read(sequenceExecutionStateProvider);
  if (_isActiveSequenceState(sequenceState)) {
    try {
      await read(sequencerBackendProvider).saveCheckpoint();
    } catch (e, stackTrace) {
      developer.log(
        'Failed to save checkpoint before refusing update apply: $e',
        name: 'UpdateNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
    }
    throw UpdateException(
      'Cannot apply an update while a sequence is ${sequenceState.name}. '
      'Stop the sequence before applying the update.',
    );
  }

  final cameraState = read(cameraStateProvider);
  if (cameraState.connectionState == DeviceConnectionState.connected) {
    if (cameraState.isExposing) {
      throw UpdateException(
        'Cannot apply an update while the camera is exposing.',
      );
    }
    final coolerPower = cameraState.coolerPower ?? 0;
    if (cameraState.isCooling || cameraState.isWarming || coolerPower > 2) {
      throw UpdateException(
        'Cannot apply an update while the camera cooler is active. '
        'Warm the camera and wait for cooler power to reach 0% first.',
      );
    }
  }

  final mountState = read(mountStateProvider);
  if (mountState.connectionState == DeviceConnectionState.connected) {
    if (mountState.isSlewing) {
      throw UpdateException(
        'Cannot apply an update while the mount is slewing.',
      );
    }
    if (!mountState.isParked) {
      throw UpdateException(
        'Cannot apply an update until the mount is parked.',
      );
    }
  }

  try {
    await _checkpointIfSessionLoaded(read);
  } catch (e) {
    throw UpdateException(
      'Cannot apply update because the current session checkpoint '
      'could not be saved: $e',
    );
  }
}

Future<void> defaultUpdateApplySafetyCheck(Ref ref) {
  return defaultUpdateApplySafetyCheckWithReader(ref.read);
}

/// Live view of [updatePromptHeldBackReason], so the UI can re-offer an
/// update the moment the rig goes idle.
///
/// Without this, a release found at the start of an imaging run is held back
/// and then not mentioned again until the next scheduled check — up to twelve
/// hours later, quite possibly while nobody is looking. Watching the hold
/// lets the offer arrive when the run ends, which is exactly when an operator
/// can act on it.
final updatePromptHoldProvider = Provider<String?>((ref) {
  // Watched, not read, so this recomputes as the rig's state changes.
  ref.watch(sequenceExecutionStateProvider);
  ref.watch(cameraStateProvider);
  ref.watch(mountStateProvider);
  return updatePromptHeldBackReason(ref.read);
});

/// Why an update prompt is being held back right now, or null when it may be
/// shown.
///
/// Deliberately weaker than the apply gate. Applying swaps the running binary
/// and so demands a parked mount and a cold camera; merely telling someone a
/// release exists demands only that the app not talk over the top of an
/// observing run. Requiring the apply conditions here would mean the prompt
/// never appeared on a rig that is doing its job.
///
/// Suppressing the prompt never suppresses the check: the update is found and
/// held in state, so it is waiting in Settings the moment the operator looks.
String? updatePromptHeldBackReason(UpdateApplySafetyReader read) {
  final sequenceState = read(sequenceExecutionStateProvider);
  if (_isActiveSequenceState(sequenceState)) {
    return 'a sequence is ${sequenceState.name}';
  }

  final cameraState = read(cameraStateProvider);
  if (cameraState.connectionState == DeviceConnectionState.connected &&
      cameraState.isExposing) {
    return 'the camera is exposing';
  }

  final mountState = read(mountStateProvider);
  if (mountState.connectionState == DeviceConnectionState.connected &&
      mountState.isSlewing) {
    return 'the mount is slewing';
  }

  return null;
}

/// The apply gate used when a notifier is built without one.
///
/// Applying swaps the binary out from under a running session, so a notifier
/// with no gate cannot see the sequencer or camera state it would have to check.
/// It refuses rather than assume the rig is idle.
Future<void> _denyUnwiredUpdateApply() async {
  throw UpdateException(
    'Cannot apply an update: no safety check is wired into this update '
    'notifier, so imaging state cannot be verified.',
  );
}

/// Notifier for managing update state
class UpdateNotifier extends StateNotifier<UpdateState> {
  final UpdateService _updateService;
  final LanPushReceiver _lanPushReceiver;
  final UpdateApplySafetyCheck _applySafetyCheck;
  final UpdatePromptStore _promptStore;
  final Duration _checkInterval;
  final Duration _remindAfter;
  UpdatePromptState _promptState = const UpdatePromptState();

  UpdateNotifier({
    required String currentVersion,
    required int currentBuildNumber,
    UpdateService? updateService,
    LanPushReceiver? lanPushReceiver,
    UpdateApplySafetyCheck? applySafetyCheck,
    UpdatePromptStore? promptStore,
    Duration checkInterval = defaultUpdateCheckInterval,
    Duration remindAfter = defaultUpdateRemindAfter,
  }) : _promptStore =
           promptStore ?? UpdatePromptStore(resolveSkotiqDataDirectory),
       _checkInterval = checkInterval,
       _remindAfter = remindAfter,
       _updateService =
           updateService ??
           UpdateService(
             currentVersion: currentVersion,
             currentBuildNumber: currentBuildNumber,
           ),
       _lanPushReceiver =
           lanPushReceiver ??
           LanPushReceiver(
             currentVersion: currentVersion,
             currentBuildNumber: currentBuildNumber,
           ),
       _applySafetyCheck = applySafetyCheck ?? _denyUnwiredUpdateApply,
       super(
         UpdateState(
           currentVersion: currentVersion,
           currentBuildNumber: currentBuildNumber,
         ),
       ) {
    // Set up LAN push callbacks
    _lanPushReceiver.onUpdateReceived = _onLanPushReceived;
    _lanPushReceiver.onProgress = _onLanPushProgress;
    _lanPushReceiver.onError = _onLanPushError;

    final envChannel = Platform.environment['SKOTIQ_UPDATE_CHANNEL'];
    final channel = (envChannel != null && envChannel.trim().isNotEmpty)
        ? envChannel.trim()
        : 'stable';

    // An explicit update server still wins: that is how an appliance is
    // pointed at a private build host, and how the OTA tests drive a loopback
    // mock. With none set, read the project's GitHub Releases, which is the
    // channel that actually publishes — the alternative is the pre-existing
    // behavior where no shipped build had any source at all and the updater
    // silently did nothing.
    final envServerUrl = Platform.environment['SKOTIQ_UPDATE_SERVER'];
    if (envServerUrl != null && envServerUrl.trim().isNotEmpty) {
      configure(serverUrl: envServerUrl.trim(), channel: channel);
    } else {
      configureGithubSource(channel: channel);
    }

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

    final skipped = await _updateService.readSkippedVersion();
    if (skipped != null) {
      state = state.copyWith(skippedVersion: skipped);
    }

    final pendingStatus = await _updateService.verifyPendingInstall();
    if (pendingStatus.message != null) {
      developer.log(
        pendingStatus.message!,
        name: 'UpdateNotifier',
        level: pendingStatus.state == PendingInstallState.requiresAttention
            ? 1000
            : 800,
      );
    }

    if (pendingStatus.state == PendingInstallState.requiresAttention) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: pendingStatus.message,
      );
    }

    await checkStagedUpdate();
  }

  /// Configure the update server
  void configure({required String serverUrl, String channel = 'stable'}) {
    _updateService.configure(serverUrl: serverUrl, channel: channel);
    state = state.copyWith(
      updateServerUrl: serverUrl,
      sourceConfigured: serverUrl.trim().isNotEmpty,
      channel: channel,
    );
  }

  /// Read updates from the project's GitHub Releases.
  void configureGithubSource({
    String owner = kSkotiqReleaseOwner,
    String repo = kSkotiqReleaseRepo,
    String channel = 'stable',
    GithubReleaseSource? source,
  }) {
    _updateService.configureGithubSource(
      owner: owner,
      repo: repo,
      channel: channel,
      source: source,
    );
    state = state.copyWith(
      updateServerUrl: null,
      sourceConfigured: true,
      channel: channel,
    );
  }

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
  /// hardware gate ([updatePromptHeldBackReason]); this half only knows what
  /// the operator already answered.
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

  /// Start listening for LAN push updates
  Future<void> startLanPushListener() async {
    await _lanPushReceiver.startServer();
  }

  /// Stop LAN push listener
  Future<void> stopLanPushListener() async {
    await _lanPushReceiver.stopServer();
  }

  /// Check for updates
  Future<void> checkForUpdates({DateTime? now}) async {
    // Also awaited here, not just in the throttled path: the Settings button
    // reaches this directly, and a press during startup would otherwise race
    // the prompt-state load and overwrite it.
    await _startupState;
    if (state.isBusy) return;
    if (!state.sourceConfigured) {
      developer.log(
        'No update source configured, skipping update check',
        name: 'UpdateNotifier',
      );
      state = state.copyWith(
        status: UpdateStatus.upToDate,
        lastCheckTime: DateTime.now(),
        errorMessage: null,
      );
      return;
    }

    state = state.copyWith(status: UpdateStatus.checking, errorMessage: null);

    // Record the attempt before it resolves. A source that is down or rate
    // limited must not turn startup into a retry loop that hammers it every
    // launch; the next check comes at the normal interval either way.
    _promptState = _promptState.copyWith(
      lastCheckAt: now ?? DateTime.now().toUtc(),
    );
    unawaited(_promptStore.write(_promptState));

    try {
      final result = await _updateService.checkForUpdates();

      if (result.hasUpdate && result.manifest != null) {
        // Check if this version was skipped
        if (state.skippedVersion == result.manifest!.version) {
          state = state.copyWith(
            status: UpdateStatus.upToDate,
            lastCheckTime: DateTime.now(),
          );
          return;
        }

        // A different version is being offered; forget any earlier skip so
        // it does not silently suppress this newer build on the next run.
        if (state.skippedVersion != null) {
          unawaited(_updateService.writeSkippedVersion(null));
        }

        if (result.requiresManualUpgrade) {
          // Build is below minVersion for OTA: surface the update but route
          // the user to a manual reinstall instead of the download/apply path.
          state = state.copyWith(
            status: UpdateStatus.available,
            availableUpdate: result.manifest,
            requiresManualUpgrade: true,
            skippedVersion: null,
            errorMessage:
                'This build is older than the minimum version supported by '
                'automatic updates. Download the latest full release and '
                'reinstall Skotiq manually.',
            releaseNotes: result.releaseNotes,
            releasePageUrl: result.releasePageUrl,
            lastCheckTime: DateTime.now(),
          );
          return;
        }

        state = state.copyWith(
          status: UpdateStatus.available,
          availableUpdate: result.manifest,
          requiresManualUpgrade: false,
          skippedVersion: null,
          releaseNotes: result.releaseNotes,
          releasePageUrl: result.releasePageUrl,
          unavailableReason: null,
          lastCheckTime: DateTime.now(),
        );
      } else {
        state = state.copyWith(
          status: UpdateStatus.upToDate,
          requiresManualUpgrade: false,
          // Carried so the UI can say a newer release exists but publishes
          // nothing for this platform, rather than reporting it as currency.
          unavailableReason: result.unavailableReason,
          releasePageUrl: result.releasePageUrl,
          lastCheckTime: DateTime.now(),
        );
      }
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
        lastCheckTime: DateTime.now(),
      );
    }
  }

  /// Download and stage the available update
  Future<void> downloadUpdate() async {
    // Builds below minVersion for OTA must be reinstalled manually; the
    // download/apply path is intentionally unreachable for them.
    if (state.requiresManualUpgrade) return;
    if (state.availableUpdate == null) return;
    if (state.status == UpdateStatus.downloading) return;

    state = state.copyWith(
      status: UpdateStatus.downloading,
      downloadProgress: 0,
      downloadedBytes: 0,
      totalBytes: state.availableUpdate!.compressedSize,
      errorMessage: null,
    );

    try {
      await _updateService.downloadAndStage(
        state.availableUpdate!,
        onProgress: (downloaded, total, progress) {
          state = state.copyWith(
            downloadProgress: progress,
            downloadedBytes: downloaded,
            totalBytes: total,
          );
        },
      );

      state = state.copyWith(
        status: UpdateStatus.staged,
        downloadProgress: 1.0,
      );
    } on DownloadCancelledException {
      // Download was cancelled - reset to available state
      state = state.copyWith(
        status: UpdateStatus.available,
        downloadProgress: 0,
        downloadedBytes: 0,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Cancel an in-progress download
  void cancelDownload() {
    if (state.status != UpdateStatus.downloading) return;

    _updateService.cancelDownload();
    // State will be updated when DownloadCancelledException is caught
  }

  /// Apply the staged update (will restart the app)
  Future<void> applyUpdate() async {
    developer.log(
      'applyUpdate() called, status: ${state.status}, staged: ${state.stagingPath}, version: ${state.availableUpdate?.version}',
      name: 'UpdateNotifier',
      level: 800,
    );

    if (state.status != UpdateStatus.staged) {
      developer.log(
        'Status is not staged, returning early',
        name: 'UpdateNotifier',
        level: 900,
      );
      return;
    }

    state = state.copyWith(status: UpdateStatus.applying);
    developer.log(
      'Status set to applying, calling service...',
      name: 'UpdateNotifier',
      level: 800,
    );

    try {
      await _applySafetyCheck();
      final outcome = await _updateService.applyUpdate();

      // Android hands the APK to the system installer and keeps running
      // until the user confirms, so returning here is the success path — not
      // the "we should have exited" failure the desktop path infers.
      if (outcome == UpdateApplyOutcome.handedToPlatformInstaller) {
        developer.log(
          'Handed the update to the platform installer; awaiting the '
          "user's confirmation.",
          name: 'UpdateNotifier',
          level: 800,
        );
        // Stay staged: if the user declines the system prompt, the verified
        // download is still on disk and Install can be pressed again.
        state = state.copyWith(status: UpdateStatus.staged, errorMessage: null);
        return;
      }

      // The desktop path exits inside applyUpdate once the helper is
      // launched, so reaching this line means the handoff failed.
      developer.log(
        'applyUpdate returned without exiting!',
        name: 'UpdateNotifier',
        level: 1000,
      );
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage:
            'Update process did not launch correctly. The app should have restarted.',
      );
    } on AndroidInstallException catch (e) {
      if (!e.isPermissionDenied) {
        state = state.copyWith(
          status: UpdateStatus.error,
          errorMessage: e.toString(),
        );
        return;
      }
      await _requestInstallPermission();
    } catch (e, stackTrace) {
      developer.log(
        'Error applying update: $e',
        name: 'UpdateNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Android 8+ keeps "install unknown apps" off for each app until the user
  /// allows it, so the first update on every phone is refused this way. Open
  /// the screen where it is granted and stay staged: the APK on disk is still
  /// verified, and Install works again once the switch is on.
  Future<void> _requestInstallPermission() async {
    developer.log(
      'Install permission not granted; opening the grant screen.',
      name: 'UpdateNotifier',
      level: 800,
    );
    var opened = true;
    try {
      await openInstallPermissionSettings();
    } on AndroidInstallException catch (e) {
      opened = false;
      developer.log(
        'Could not open the install-permission screen: $e',
        name: 'UpdateNotifier',
        level: 900,
      );
    }
    state = state.copyWith(
      status: UpdateStatus.staged,
      errorMessage: opened
          ? 'Allow Skotiq to install apps on the screen that just opened, '
                'then come back and install the update again.'
          : 'Allow Skotiq to install apps (Settings > Apps > Skotiq > '
                'Install unknown apps), then install the update again.',
    );
  }

  /// Skip the current available update
  void skipUpdate() {
    if (state.availableUpdate == null) return;

    final version = state.availableUpdate!.version;
    state = state.copyWith(
      status: UpdateStatus.upToDate,
      skippedVersion: version,
      availableUpdate: null,
      requiresManualUpgrade: false,
    );
    unawaited(_updateService.writeSkippedVersion(version));
    // A permanent skip subsumes any "not now" on the same version; leaving
    // both would re-offer the build the moment the deferral aged out.
    _promptState = _promptState.copyWith(clearDeferral: true);
    unawaited(_promptStore.write(_promptState));
  }

  /// Clear any staged update
  Future<void> clearStagedUpdate() async {
    await _updateService.clearStagedUpdate();
    state = state.copyWith(status: UpdateStatus.upToDate, stagingPath: null);
  }

  /// Pop the most recent one-shot UI banner queued by the underlying
  /// [UpdateService] (e.g. corrupted-marker recovery). Returns
  /// null if no notice is pending. Subsequent calls return null until a
  /// new notice is queued.
  UpdateNotice? takePendingNotice() => _updateService.takePendingNotice();

  /// Check for staged update on startup
  Future<void> checkStagedUpdate() async {
    final staged = await _updateService.getStagedUpdate();
    if (staged == null) return;

    // Prefer the manifest the update was staged from. The stand-in below
    // used to hardcode windows/x64, which is a claim about the staged build
    // that is false on Linux and Android — and one the UI shows.
    final manifest = await _updateService.readStagedManifest();
    state = state.copyWith(
      status: UpdateStatus.staged,
      stagingPath: staged.extractPath,
      availableUpdate:
          manifest ??
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
          ),
    );
  }

  // LAN Push callbacks

  void _onLanPushReceived(UpdateManifest manifest, String stagingPath) {
    setStagedFromLanPush(manifest, stagingPath);
  }

  /// Set the state to staged from an external LAN push notification
  /// Called when the LanPushNotifier stream receives an update
  void setStagedFromLanPush(UpdateManifest manifest, String stagingPath) {
    developer.log(
      'setStagedFromLanPush: ${manifest.version} at $stagingPath',
      name: 'UpdateNotifier',
      level: 800,
    );
    state = state.copyWith(
      status: UpdateStatus.staged,
      availableUpdate: manifest,
      stagingPath: stagingPath,
      downloadProgress: 1.0,
      errorMessage: null, // Clear any previous error
    );
  }

  void _onLanPushProgress(
    int receivedBytes,
    int totalBytes,
    double progress,
    String message,
  ) {
    state = state.copyWith(
      status: UpdateStatus.downloading,
      downloadedBytes: receivedBytes,
      totalBytes: totalBytes,
      downloadProgress: progress,
    );
  }

  void _onLanPushError(String error) {
    state = state.copyWith(status: UpdateStatus.error, errorMessage: error);
  }

  /// Get version info for discovery response
  Map<String, dynamic> get versionInfo => _lanPushReceiver.versionInfo;

  @override
  void dispose() {
    _updateService.dispose();
    _lanPushReceiver.dispose();
    super.dispose();
  }
}
