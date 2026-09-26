// Thin adapter between [UpdateService] and the headless API's
// `UpdateHandlers`.
//
// Why the indirection: `UpdateService` is bound to the host filesystem
// (the install directory, the staging directory, the on-disk `ready.json`
// marker) and to `Process.start(updater.exe)` for apply. Substituting a
// real instance in a unit test would require either filesystem doubles or
// process doubles — both invasive. By having `UpdateHandlers` depend on
// this abstract surface, the headless test suite can pass a fake
// controller that records calls + drives the `events` stream synthetically
// without touching disk.
//
// The default implementation wraps a real `UpdateService` and bridges its
// state-changing methods onto a broadcast stream of typed `UpdateEvent`s
// so the headless server can fan-out update lifecycle to paired phones
// over the existing WebSocket transport.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/update_manifest.dart';
import 'update_service.dart';

/// Lifecycle states the headless API exposes to clients. Mirrors
/// `UpdateStatus` but with names tuned for the REST surface — e.g. the
/// REST surface combines `available` + `upToDate` into a single `idle`
/// view, while keeping `staged` as a discrete state because the apply
/// gate hinges on it.
enum UpdateLifecycleState {
  /// No update activity in progress.
  idle,

  /// A newer build was found and its verified manifest is cached in memory,
  /// so Download is a valid next action.
  available,

  /// `checkForUpdate` is in flight against the configured server.
  checking,

  /// `downloadUpdate` has started; bytes are streaming to the staging dir.
  downloading,

  /// Bytes are on disk and the manifest signature + per-file hashes are
  /// being verified before we promote to `staged`.
  verifying,

  /// Cancellation was requested, but the underlying future is still
  /// unwinding. A second update operation must not start in this window.
  cancelling,

  /// A verified update is staged and ready to apply.
  staged,

  /// Apply has been initiated; the host process is about to restart.
  installing,

  /// Last operation failed; check [UpdateControllerStatus.lastError].
  failed,
}

/// Wire-friendly name for [UpdateLifecycleState], used by both the JSON
/// response builder and the event payload.
extension UpdateLifecycleStateX on UpdateLifecycleState {
  String get wireName => name;
}

/// Snapshot exposed via `GET /api/system/update/status`. Immutable — the
/// controller rebuilds this on every state transition.
class UpdateControllerStatus {
  final UpdateLifecycleState state;
  final String? availableVersion;
  final int? availableBuildNumber;
  final bool requiresManualUpgrade;
  final String? stagedVersion;
  final DateTime? stagedAt;

  /// Download progress as a percentage in `[0, 100]`, or null outside the
  /// downloading / staging phases.
  final double? progressPct;
  final String? message;
  final String? lastError;

  const UpdateControllerStatus({
    required this.state,
    this.availableVersion,
    this.availableBuildNumber,
    this.requiresManualUpgrade = false,
    this.stagedVersion,
    this.stagedAt,
    this.progressPct,
    this.message,
    this.lastError,
  });

  Map<String, Object?> toJson() => {
    'state': state.wireName,
    if (availableVersion != null) 'availableVersion': availableVersion,
    if (availableBuildNumber != null)
      'availableBuildNumber': availableBuildNumber,
    if (requiresManualUpgrade) 'requiresManualUpgrade': true,
    if (stagedVersion != null) 'stagedVersion': stagedVersion,
    if (stagedAt != null) 'stagedAt': stagedAt!.toUtc().toIso8601String(),
    if (progressPct != null) 'progressPct': progressPct,
    if (message != null) 'message': message,
    if (lastError != null) 'lastError': lastError,
  };
}

/// Snapshot of a staged but-not-applied update exposed via
/// `GET /api/system/update/staged`. Built from the on-disk `ready.json`
/// marker + the persisted manifest.
class StagedUpdateInfo {
  final String stagedVersion;
  final int stagedBuildNumber;
  final DateTime stagedAt;
  final String? manifestHash;
  final int fileCount;
  final int totalBytes;
  final String? sourceUrl;
  final Map<String, String> expectedHashes;

  const StagedUpdateInfo({
    required this.stagedVersion,
    required this.stagedBuildNumber,
    required this.stagedAt,
    required this.fileCount,
    required this.totalBytes,
    required this.expectedHashes,
    this.manifestHash,
    this.sourceUrl,
  });

  Map<String, Object?> toJson() => {
    'stagedVersion': stagedVersion,
    'stagedBuildNumber': stagedBuildNumber,
    'stagedAt': stagedAt.toUtc().toIso8601String(),
    if (manifestHash != null) 'manifestHash': manifestHash,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    'expectedHashes': expectedHashes,
  };
}

/// Result of `POST /api/system/update/check`. The check job resolves to
/// this payload when complete.
class UpdateCheckOutcome {
  final bool available;
  final String? latestVersion;
  final int? latestBuildNumber;
  final String? releaseNotes;
  final String? downloadUrl;
  final int? downloadSize;
  final String? signature;
  final bool isPrerelease;
  final bool requiresManualUpgrade;

  const UpdateCheckOutcome({
    required this.available,
    this.latestVersion,
    this.latestBuildNumber,
    this.releaseNotes,
    this.downloadUrl,
    this.downloadSize,
    this.signature,
    this.isPrerelease = false,
    this.requiresManualUpgrade = false,
  });

  Map<String, Object?> toJson() => {
    'available': available,
    if (latestVersion != null) 'latestVersion': latestVersion,
    if (latestBuildNumber != null) 'latestBuildNumber': latestBuildNumber,
    if (releaseNotes != null) 'releaseNotes': releaseNotes,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (downloadSize != null) 'downloadSize': downloadSize,
    if (signature != null) 'signature': signature,
    'isPrerelease': isPrerelease,
    if (requiresManualUpgrade) 'requiresManualUpgrade': requiresManualUpgrade,
  };
}

/// Typed event broadcast by [UpdateController.events]. The headless API
/// server translates each variant into a `NightshadeEvent` with
/// `category: EventCategory.system`; the eventType is the variant name.
sealed class UpdateEvent {
  const UpdateEvent();

  /// Discriminator used as `NightshadeEvent.eventType`.
  String get type;

  /// Data payload merged into `NightshadeEvent.data`.
  Map<String, Object?> get data;
}

class UpdateAvailableEvent extends UpdateEvent {
  final String currentVersion;
  final String latestVersion;
  final String? downloadUrl;
  final String? releaseNotes;
  final int? downloadSize;

  const UpdateAvailableEvent({
    required this.currentVersion,
    required this.latestVersion,
    this.downloadUrl,
    this.releaseNotes,
    this.downloadSize,
  });

  @override
  String get type => 'UpdateAvailable';

  @override
  Map<String, Object?> get data => {
    'currentVersion': currentVersion,
    'latestVersion': latestVersion,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (releaseNotes != null) 'releaseNotes': releaseNotes,
    if (downloadSize != null) 'downloadSize': downloadSize,
  };
}

class UpdateDownloadStartedEvent extends UpdateEvent {
  final String jobId;
  final String version;
  final int totalBytes;

  const UpdateDownloadStartedEvent({
    required this.jobId,
    required this.version,
    required this.totalBytes,
  });

  @override
  String get type => 'UpdateDownloadStarted';

  @override
  Map<String, Object?> get data => {
    'jobId': jobId,
    'version': version,
    'totalBytes': totalBytes,
  };
}

class UpdateDownloadProgressEvent extends UpdateEvent {
  final String jobId;
  final int downloadedBytes;
  final int totalBytes;

  /// Download progress as a fraction in `[0, 1]`.
  final double pct;

  const UpdateDownloadProgressEvent({
    required this.jobId,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.pct,
  });

  @override
  String get type => 'UpdateDownloadProgress';

  @override
  Map<String, Object?> get data => {
    'jobId': jobId,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'pct': pct,
  };
}

class UpdateDownloadCompleteEvent extends UpdateEvent {
  final String jobId;
  final String stagedPath;
  final String version;

  const UpdateDownloadCompleteEvent({
    required this.jobId,
    required this.stagedPath,
    required this.version,
  });

  @override
  String get type => 'UpdateDownloadComplete';

  @override
  Map<String, Object?> get data => {
    'jobId': jobId,
    'stagedPath': stagedPath,
    'version': version,
  };
}

class UpdateVerificationFailedEvent extends UpdateEvent {
  final String jobId;
  final String reason;
  final String? expectedHash;
  final String? actualHash;

  const UpdateVerificationFailedEvent({
    required this.jobId,
    required this.reason,
    this.expectedHash,
    this.actualHash,
  });

  @override
  String get type => 'UpdateVerificationFailed';

  @override
  Map<String, Object?> get data => {
    'jobId': jobId,
    'reason': reason,
    if (expectedHash != null) 'expectedHash': expectedHash,
    if (actualHash != null) 'actualHash': actualHash,
  };
}

class UpdateApplyStartedEvent extends UpdateEvent {
  final String jobId;
  final String version;

  const UpdateApplyStartedEvent({required this.jobId, required this.version});

  @override
  String get type => 'UpdateApplyStarted';

  @override
  Map<String, Object?> get data => {'jobId': jobId, 'version': version};
}

class UpdateAppliedEvent extends UpdateEvent {
  final String fromVersion;
  final String toVersion;
  final bool restartRequired;

  const UpdateAppliedEvent({
    required this.fromVersion,
    required this.toVersion,
    this.restartRequired = true,
  });

  @override
  String get type => 'UpdateApplied';

  @override
  Map<String, Object?> get data => {
    'fromVersion': fromVersion,
    'toVersion': toVersion,
    'restartRequired': restartRequired,
  };
}

class UpdateFailedEvent extends UpdateEvent {
  final String? jobId;
  final String phase;
  final String error;

  const UpdateFailedEvent({
    required this.phase,
    required this.error,
    this.jobId,
  });

  @override
  String get type => 'UpdateFailed';

  @override
  Map<String, Object?> get data => {
    if (jobId != null) 'jobId': jobId,
    'phase': phase,
    'error': error,
  };
}

/// Adapter the headless API depends on. Wraps a real [UpdateService] and
/// bridges its state-changing methods onto a broadcast stream of typed
/// [UpdateEvent]s. Tests substitute a fake controller that records calls
/// and drives the [events] stream directly.
///
/// The controller owns the service lifecycle so the bootstrap does not
/// need to track disposal of two objects.
class UpdateController {
  final UpdateService _service;
  final Future<void> Function() _applySafetyCheck;
  final String _currentVersion;
  final int _currentBuildNumber;
  final String _channel;
  final String? _serverUrl;
  final DateTime Function() _now;

  /// Where the controller persists `last_update_check.txt` /
  /// `last_update_applied.txt`. Supplied by the bootstrap (the same
  /// `applicationSupport` directory the service uses for staging).
  final Directory _stateDir;

  final StreamController<UpdateEvent> _eventsController =
      StreamController<UpdateEvent>.broadcast();

  UpdateControllerStatus _status = const UpdateControllerStatus(
    state: UpdateLifecycleState.idle,
  );
  DateTime? _lastUpdateCheck;
  DateTime? _lastUpdateApplied;

  /// Cached manifest from the most recent [checkForUpdates] call.
  /// Reused by [downloadAndStage] so we don't have to re-fetch the
  /// manifest between check and download (and so a manifest signature
  /// is only verified once).
  UpdateManifest? _lastManifest;
  bool _lastOfferRequiresManualUpgrade = false;

  /// Monotonic counter bumped by [abortInFlight]. An in-flight
  /// [checkForUpdates] captures this on entry and skips its terminal status
  /// writes when it no longer matches, so a check that completes after an
  /// operator abort cannot clobber the aborted status.
  int _opGeneration = 0;
  String? _activeOperation;

  /// [applySafetyCheck] is the host's gate on [applyStagedUpdate]: it throws to
  /// refuse the apply. Omitting it refuses every apply — see
  /// [_denyUnwiredUpdateApply].
  UpdateController({
    required UpdateService service,
    required String currentVersion,
    required int currentBuildNumber,
    required Directory stateDirectory,
    String channel = 'stable',
    String? serverUrl,
    DateTime Function()? now,
    Future<void> Function()? applySafetyCheck,
  }) : _service = service,
       _applySafetyCheck = applySafetyCheck ?? _denyUnwiredUpdateApply,
       _currentVersion = currentVersion,
       _currentBuildNumber = currentBuildNumber,
       _channel = channel,
       _serverUrl = serverUrl,
       _stateDir = stateDirectory,
       _now = now ?? DateTime.now;

  /// Hydrate persisted state markers from disk. Must be awaited before
  /// the controller is exposed via the API.
  Future<void> bootstrap() async {
    _lastUpdateCheck = await _readTimestamp('last_update_check.txt');
    _lastUpdateApplied = await _readTimestamp('last_update_applied.txt');

    // An apply request is only a handoff to the external updater. The first
    // launch of the target build is the earliest point at which Nightshade can
    // truthfully call it applied, so verify the pending marker here and record
    // the timestamp only after that proof succeeds.
    final pending = await _service.verifyPendingInstall();
    if (pending.state == PendingInstallState.verified) {
      _lastUpdateApplied = _now();
      await _writeTimestamp('last_update_applied.txt', _lastUpdateApplied!);
    } else if (pending.state == PendingInstallState.requiresAttention) {
      _status = UpdateControllerStatus(
        state: UpdateLifecycleState.failed,
        message: 'The previous update handoff could not be verified.',
        lastError: pending.message,
      );
    } else if (pending.state == PendingInstallState.rolledBack) {
      _status = UpdateControllerStatus(
        state: UpdateLifecycleState.idle,
        message: pending.message,
      );
    }

    // Surface any existing staged update so `GET /api/system/update/status`
    // shows `staged` immediately on startup (not just after the first
    // check).
    final staged = await _service.getStagedUpdate();
    if (staged != null) {
      if (_status.state == UpdateLifecycleState.failed) {
        _status = UpdateControllerStatus(
          state: UpdateLifecycleState.failed,
          stagedVersion: staged.version,
          stagedAt: staged.stagedAt,
          message: _status.message,
          lastError: _status.lastError,
        );
      } else {
        _status = UpdateControllerStatus(
          state: UpdateLifecycleState.staged,
          stagedVersion: staged.version,
          stagedAt: staged.stagedAt,
          message: _status.message,
        );
      }
    }
  }

  /// Lifecycle event stream. Replays nothing on subscribe; clients should
  /// pair this with [status] to discover the current snapshot.
  Stream<UpdateEvent> get events => _eventsController.stream;

  /// Current snapshot. Cheap synchronous read; the controller maintains
  /// this in memory and rebuilds on every state transition.
  UpdateControllerStatus get status => _status;

  /// The running app's version string (e.g. `2.5.0`).
  String get currentVersion => _currentVersion;

  /// The running app's build number.
  int get currentBuildNumber => _currentBuildNumber;

  /// Configured channel (`stable`, `beta`, ...).
  String get channel => _channel;

  /// Configured update-server URL, or null when the server is not set.
  String? get updateServerUrl => _serverUrl;

  /// Where this controller looks for updates, for logs and status payloads.
  ///
  /// A null [updateServerUrl] no longer means "nothing configured" — it is
  /// the normal state of a build reading GitHub releases — so reporting it as
  /// `unconfigured` would tell an operator OTA was off while it was working.
  String get updateSourceLabel =>
      _serverUrl?.isNotEmpty == true ? _serverUrl! : 'github-releases';

  /// Whether this build can cryptographically authenticate update manifests
  /// (a trusted Ed25519 public key is compiled in and not revoked). False
  /// means OTA is check-only: downloads/applies fail closed. The bootstrap
  /// warns on this so a server-configured build that cannot accept updates
  /// is not silently mistaken for live OTA.
  bool get canAuthenticateUpdates => _service.canAuthenticateUpdates;

  /// True from admission until the active controller future has fully
  /// unwound. Unlike [status], this remains true while an aborted HTTP check
  /// is returning, which lets the REST layer reject a racing second command.
  bool get hasActiveOperation => _activeOperation != null;

  /// Persisted moment of the last successful check, or null when no
  /// check has run during this process lifetime.
  DateTime? get lastUpdateCheck => _lastUpdateCheck;

  /// Persisted moment of the last successfully applied update on this
  /// host, or null. Surfaced by `GET /api/system/version`.
  DateTime? get lastUpdateApplied => _lastUpdateApplied;

  /// Check for updates against the configured server. Emits a
  /// `UpdateAvailable` event if a newer version exists. Honours
  /// [channelOverride] for one-off `?channel=` query params.
  Future<UpdateCheckOutcome> checkForUpdates({String? channelOverride}) async {
    _beginOperation('check');
    final gen = _opGeneration;
    final hasChannelOverride =
        channelOverride != null && channelOverride.isNotEmpty;
    if (hasChannelOverride) {
      _service.setChannel(channelOverride);
    }
    // A fresh check supersedes the prior in-memory offer. This prevents a
    // failed/aborted re-check from downloading a manifest the operator no
    // longer sees on screen.
    _lastManifest = null;
    _lastOfferRequiresManualUpgrade = false;
    _updateStatus(
      _status = UpdateControllerStatus(
        state: UpdateLifecycleState.checking,
        stagedVersion: _status.stagedVersion,
        stagedAt: _status.stagedAt,
      ),
    );

    try {
      final result = await _service.checkForUpdates();

      // Abort is generation based because the HTTP check itself is not
      // cancellable. Once invalidated, it must have no late cache, timestamp,
      // status, or event side effects; the JobManager will mark the cancelled
      // job after this future returns.
      if (gen != _opGeneration) {
        return const UpdateCheckOutcome(available: false);
      }
      _lastManifest = result.manifest;
      _lastOfferRequiresManualUpgrade = result.requiresManualUpgrade;
      _lastUpdateCheck = _now();
      await _writeTimestamp('last_update_check.txt', _lastUpdateCheck!);

      if (result.hasUpdate && result.manifest != null) {
        final manifest = result.manifest!;
        if (gen == _opGeneration) {
          _updateStatus(
            UpdateControllerStatus(
              state: _status.stagedVersion != null
                  ? UpdateLifecycleState.staged
                  : UpdateLifecycleState.available,
              availableVersion: manifest.version,
              availableBuildNumber: manifest.buildNumber,
              requiresManualUpgrade: result.requiresManualUpgrade,
              stagedVersion: _status.stagedVersion,
              stagedAt: _status.stagedAt,
              message:
                  'Update ${manifest.version}+${manifest.buildNumber} available',
            ),
          );
        }
        _eventsController.add(
          UpdateAvailableEvent(
            currentVersion: _currentVersion,
            latestVersion: manifest.version,
            downloadUrl: manifest.downloadUrl,
            releaseNotes: manifest.releaseNotes,
            downloadSize: manifest.compressedSize,
          ),
        );
        return UpdateCheckOutcome(
          available: true,
          latestVersion: manifest.version,
          latestBuildNumber: manifest.buildNumber,
          releaseNotes: manifest.releaseNotes,
          downloadUrl: manifest.downloadUrl,
          downloadSize: manifest.compressedSize,
          signature: manifest.signature,
          requiresManualUpgrade: result.requiresManualUpgrade,
        );
      }

      // No update — reset to idle (or staged if a previously-staged
      // update still exists).
      if (gen == _opGeneration) {
        _updateStatus(
          UpdateControllerStatus(
            state: _status.stagedVersion != null
                ? UpdateLifecycleState.staged
                : UpdateLifecycleState.idle,
            stagedVersion: _status.stagedVersion,
            stagedAt: _status.stagedAt,
          ),
        );
      }
      return const UpdateCheckOutcome(available: false);
    } catch (e) {
      if (gen != _opGeneration) {
        return const UpdateCheckOutcome(available: false);
      }
      _updateStatus(
        UpdateControllerStatus(
          state: UpdateLifecycleState.failed,
          stagedVersion: _status.stagedVersion,
          stagedAt: _status.stagedAt,
          lastError: e.toString(),
        ),
      );
      _eventsController.add(
        UpdateFailedEvent(phase: 'check', error: e.toString()),
      );
      rethrow;
    } finally {
      // A channelOverride is explicitly one-shot. Restore the controller's
      // configured channel even when the request fails or is aborted so a
      // later ordinary check cannot silently keep using beta/nightly.
      if (hasChannelOverride) {
        _service.setChannel(_channel);
      }
      _endOperation('check');
      _settleCancellation();
    }
  }

  /// Download + stage the most recently checked available update.
  /// [jobId] is the JobManager id so the controller can stamp progress
  /// events with the same handle the client polls.
  Future<void> downloadAndStage({required String jobId}) async {
    final manifest = _lastManifest;
    if (manifest == null) {
      throw StateError('No manifest available; call checkForUpdates first.');
    }
    if (_lastOfferRequiresManualUpgrade) {
      throw UnsupportedError(
        'Update ${manifest.version} requires a manual upgrade and cannot be '
        'downloaded or staged by this Nightshade build.',
      );
    }
    _beginOperation('download');

    _eventsController.add(
      UpdateDownloadStartedEvent(
        jobId: jobId,
        version: manifest.version,
        totalBytes: manifest.compressedSize,
      ),
    );
    _updateStatus(
      UpdateControllerStatus(
        state: UpdateLifecycleState.downloading,
        progressPct: 0,
        message: 'Downloading ${manifest.version}',
      ),
    );

    try {
      await _service.downloadAndStage(
        manifest,
        onProgress: (downloaded, total, progress) {
          _updateStatus(
            UpdateControllerStatus(
              state: UpdateLifecycleState.downloading,
              progressPct: progress * 100,
              message:
                  'Downloading ${manifest.version} (${(progress * 100).toStringAsFixed(1)}%)',
            ),
          );
          _eventsController.add(
            UpdateDownloadProgressEvent(
              jobId: jobId,
              downloadedBytes: downloaded,
              totalBytes: total == 0 ? manifest.compressedSize : total,
              pct: progress,
            ),
          );
        },
        onVerifying: () {
          _updateStatus(
            UpdateControllerStatus(
              state: UpdateLifecycleState.verifying,
              progressPct: 100,
              message: 'Verifying ${manifest.version}',
            ),
          );
        },
      );

      // By the time downloadAndStage returns the staged tree carries a
      // `staged_verified.marker`, so the state can move to staged.
      final staged = await _service.getStagedUpdate();
      if (staged == null) {
        // Defensive: downloadAndStage succeeded but the marker isn't on
        // disk. Surface loudly rather than silently flipping back to
        // idle.
        throw StateError(
          'Download completed but no staged marker was written. The '
          'staging directory may have been wiped concurrently.',
        );
      }

      _updateStatus(
        UpdateControllerStatus(
          state: UpdateLifecycleState.staged,
          stagedVersion: staged.version,
          stagedAt: staged.stagedAt,
          progressPct: 100.0,
        ),
      );
      _eventsController.add(
        UpdateDownloadCompleteEvent(
          jobId: jobId,
          stagedPath: staged.extractPath,
          version: staged.version,
        ),
      );
    } catch (e) {
      // Operator abort surfaces as a cancellation from the downloader. Treat
      // it as a clean stop — return to staged/idle without a failure event.
      final cancelled =
          e.runtimeType.toString().contains('Cancel') ||
          e.toString().toLowerCase().contains('cancel');
      if (cancelled) {
        final manifest = _lastManifest;
        _updateStatus(
          UpdateControllerStatus(
            state: _status.stagedVersion != null
                ? UpdateLifecycleState.staged
                : manifest != null
                ? UpdateLifecycleState.available
                : UpdateLifecycleState.idle,
            availableVersion: manifest?.version,
            availableBuildNumber: manifest?.buildNumber,
            stagedVersion: _status.stagedVersion,
            stagedAt: _status.stagedAt,
            message: 'Download cancelled',
          ),
        );
        return;
      }
      _updateStatus(
        UpdateControllerStatus(
          state: UpdateLifecycleState.failed,
          availableVersion: manifest.version,
          availableBuildNumber: manifest.buildNumber,
          lastError: e.toString(),
        ),
      );
      // Verification failures surface as `UpdateVerificationFailed` so
      // the client can distinguish "the bytes were bad" from "the network
      // dropped".
      if (e is UpdateException && e.message.toLowerCase().contains('verif')) {
        _eventsController.add(
          UpdateVerificationFailedEvent(jobId: jobId, reason: e.message),
        );
      } else {
        _eventsController.add(
          UpdateFailedEvent(
            jobId: jobId,
            phase: 'download',
            error: e.toString(),
          ),
        );
      }
      rethrow;
    } finally {
      _endOperation('download');
      _settleCancellation();
    }
  }

  /// Apply the staged update. On success the host process restarts (the
  /// returned future MAY never complete because `exit(0)` is called
  /// before the future resolves). Always emits `UpdateApplyStarted`
  /// before invoking the underlying applier.
  Future<void> applyStagedUpdate({required String jobId}) async {
    _beginOperation('apply');
    try {
      final staged = await _service.getStagedUpdate();
      if (staged == null) {
        throw StateError('No staged update available to apply');
      }

      try {
        await _applySafetyCheck();
      } catch (e) {
        _updateStatus(
          UpdateControllerStatus(
            state: UpdateLifecycleState.staged,
            stagedVersion: staged.version,
            stagedAt: staged.stagedAt,
            message: 'Update apply blocked by host safety state',
            lastError: e.toString(),
          ),
        );
        _eventsController.add(
          UpdateFailedEvent(jobId: jobId, phase: 'safety', error: e.toString()),
        );
        rethrow;
      }

      _eventsController.add(
        UpdateApplyStartedEvent(jobId: jobId, version: staged.version),
      );
      _updateStatus(
        UpdateControllerStatus(
          state: UpdateLifecycleState.installing,
          stagedVersion: staged.version,
          stagedAt: staged.stagedAt,
          message: 'Applying ${staged.version}',
        ),
      );

      try {
        final outcome = await _service.applyUpdate();
        // Production normally exits inside applyUpdate after the updater process
        // is launched, so this branch is primarily for embedders/tests where the
        // handoff can return — and for a platform installer, which by design
        // leaves this process running. Never publish `UpdateApplied` before the
        // spawn has at least succeeded; the definitive applied timestamp is
        // written by bootstrap after the new build verifies its
        // pending-install marker.
        _eventsController.add(
          UpdateAppliedEvent(
            fromVersion: _currentVersion,
            toVersion: staged.version,
            // A platform install is not finished when this returns: the OS is
            // still waiting on the user, and nothing here can restart it.
            restartRequired:
                outcome != UpdateApplyOutcome.handedToPlatformInstaller,
          ),
        );
      } catch (e) {
        _updateStatus(
          UpdateControllerStatus(
            state: UpdateLifecycleState.failed,
            stagedVersion: staged.version,
            stagedAt: staged.stagedAt,
            lastError: e.toString(),
          ),
        );
        _eventsController.add(
          UpdateFailedEvent(jobId: jobId, phase: 'apply', error: e.toString()),
        );
        rethrow;
      }
    } finally {
      _endOperation('apply');
    }
  }

  /// Abort an in-flight check / download. Throws [StateError] when there
  /// is nothing to abort.
  void abortInFlight() {
    final wasDownloading = _status.state == UpdateLifecycleState.downloading;
    final inFlight =
        _status.state == UpdateLifecycleState.checking || wasDownloading;
    if (!inFlight) {
      throw StateError(
        'No update operation is currently in flight '
        '(state=${_status.state.wireName}).',
      );
    }
    if (wasDownloading && !_service.canCancelDownload) {
      throw StateError(
        'The package transfer has completed and verification can no longer be aborted.',
      );
    }
    _opGeneration++;
    _service.cancelDownload();
    final manifest = wasDownloading ? _lastManifest : null;
    _updateStatus(
      UpdateControllerStatus(
        state: UpdateLifecycleState.cancelling,
        availableVersion: manifest?.version,
        availableBuildNumber: manifest?.buildNumber,
        requiresManualUpgrade: _lastOfferRequiresManualUpgrade,
        stagedVersion: _status.stagedVersion,
        stagedAt: _status.stagedAt,
        message: 'Waiting for the cancelled operation to stop',
      ),
    );
  }

  /// Return the current staged update, or null when no staged update is
  /// present (or the marker was corrupted and discarded).
  Future<StagedUpdateInfo?> stagedUpdate() async {
    final staged = await _service.getStagedUpdate();
    if (staged == null) return null;

    // Try to read the persisted manifest so we can include accurate file
    // counts + expected hashes. The marker file alone doesn't carry
    // that detail, but the manifest does (it's persisted next to
    // ready.json by [persistStagedManifest]).
    final stagingRoot = Directory(p.dirname(staged.extractPath));
    final manifestFile = File(p.join(stagingRoot.path, 'manifest.json'));
    Map<String, String> expectedHashes = {};
    int totalBytes = 0;
    int fileCount = 0;
    String? manifestHash;
    String? sourceUrl;
    if (await manifestFile.exists()) {
      try {
        final raw = await manifestFile.readAsString();
        if (raw.isNotEmpty) {
          final manifestJson = jsonDecode(raw);
          if (manifestJson is Map) {
            final manifest = UpdateManifest.fromJson(
              manifestJson.cast<String, dynamic>(),
            );
            manifest.files.forEach((path, info) {
              expectedHashes[path.replaceAll('\\', '/')] = info.sha256;
              totalBytes += info.size;
            });
            fileCount = manifest.files.length;
            manifestHash = computeStagedManifestHash(manifest);
            sourceUrl = manifest.downloadUrl;
          }
        }
      } catch (_) {
        // Defensive: corrupted manifest. Leave hashes empty — the caller
        // still learns about the staged version + time from the marker
        // fields populated below.
      }
    }

    return StagedUpdateInfo(
      stagedVersion: staged.version,
      stagedBuildNumber: staged.buildNumber,
      stagedAt: staged.stagedAt,
      fileCount: fileCount,
      totalBytes: totalBytes,
      expectedHashes: expectedHashes,
      manifestHash: manifestHash,
      sourceUrl: sourceUrl,
    );
  }

  /// Discard any staged update on disk. No-op when nothing is staged.
  Future<void> discardStaged() async {
    if (_activeOperation != null) {
      throw StateError(
        'Cannot discard a staged update while update $_activeOperation is in progress.',
      );
    }
    await _service.clearStagedUpdate();
    _updateStatus(
      const UpdateControllerStatus(
        state: UpdateLifecycleState.idle,
        message: 'Staged update discarded',
      ),
    );
  }

  /// Whether a manual rollback is currently possible. True only while a
  /// retained restore point exists on disk — i.e. an update was applied on
  /// this host and the next launch has not yet confirmed it healthy (the
  /// boot verifier reclaims the backup once it does). When false, the
  /// handler returns 501. Async because it probes the filesystem.
  Future<bool> rollbackSupported() => _service.hasRestorePoint();

  /// Roll back the last applied update by relaunching the external updater
  /// in `--rollback` mode (the same binary + backup machinery the
  /// auto-rollback path uses on failure). On success the host process
  /// restarts, so the returned future MAY never complete. Emits
  /// `UpdateApplyStarted` before the handoff. If the handoff returns, an
  /// `UpdateApplied` event follows; in production the process normally exits
  /// first and clients instead observe the disconnect/reconnect boundary.
  Future<void> rollback({required String jobId}) async {
    _beginOperation('rollback');
    try {
      if (!await _service.hasRestorePoint()) {
        throw UnsupportedError(
          'No restore point is available to roll back to. A rollback is only '
          'possible after an update is applied and before the next launch '
          'confirms it healthy.',
        );
      }

      _eventsController.add(
        UpdateApplyStartedEvent(jobId: jobId, version: 'rollback'),
      );
      _updateStatus(
        const UpdateControllerStatus(
          state: UpdateLifecycleState.installing,
          message: 'Rolling back to the previous version',
        ),
      );

      try {
        await _service.rollbackToPrevious();
        _eventsController.add(
          UpdateAppliedEvent(
            fromVersion: _currentVersion,
            toVersion: 'previous',
            restartRequired: true,
          ),
        );
      } catch (e) {
        _updateStatus(
          UpdateControllerStatus(
            state: UpdateLifecycleState.failed,
            lastError: e.toString(),
          ),
        );
        _eventsController.add(
          UpdateFailedEvent(
            jobId: jobId,
            phase: 'rollback',
            error: e.toString(),
          ),
        );
        rethrow;
      }
    } finally {
      _endOperation('rollback');
    }
  }

  /// Release any resources held by the controller (HTTP client, sockets).
  Future<void> dispose() async {
    await _eventsController.close();
    _service.dispose();
  }

  void _updateStatus(UpdateControllerStatus next) {
    _status = next;
  }

  void _beginOperation(String operation) {
    final active = _activeOperation;
    if (active != null) {
      throw StateError(
        'Cannot start update $operation while update $active is still in progress.',
      );
    }
    _activeOperation = operation;
  }

  void _endOperation(String operation) {
    if (_activeOperation == operation) _activeOperation = null;
  }

  void _settleCancellation() {
    if (_status.state != UpdateLifecycleState.cancelling) return;
    final manifest = _lastManifest;
    _updateStatus(
      UpdateControllerStatus(
        state: _status.stagedVersion != null
            ? UpdateLifecycleState.staged
            : manifest != null
            ? UpdateLifecycleState.available
            : UpdateLifecycleState.idle,
        availableVersion: manifest?.version,
        availableBuildNumber: manifest?.buildNumber,
        requiresManualUpgrade: _lastOfferRequiresManualUpgrade,
        stagedVersion: _status.stagedVersion,
        stagedAt: _status.stagedAt,
        message: 'Cancelled by operator',
      ),
    );
  }

  Future<DateTime?> _readTimestamp(String fileName) async {
    final file = File(p.join(_stateDir.path, fileName));
    if (!await file.exists()) return null;
    try {
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeTimestamp(String fileName, DateTime ts) async {
    final file = File(p.join(_stateDir.path, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsString(ts.toUtc().toIso8601String());
  }
}

/// The apply gate used when the host wires none.
///
/// Applying restarts the process, so a controller with no host gate cannot
/// know whether a sequence is running or the camera is exposing. It refuses
/// rather than assume the rig is idle; hosts pass their own check to allow
/// applies.
Future<void> _denyUnwiredUpdateApply() async {
  throw StateError(
    'Update apply refused: no host safety check is wired into this '
    'UpdateController, so imaging state cannot be verified.',
  );
}
