// Headless OTA update endpoints.
//
// The desktop GUI wires `UpdateService` + `LanPushReceiver` through
// `desktop_app_bootstrap.dart`. These handlers are the REST surface that lets
// a paired phone drive the same update flow against a headless host:
//
//   GET    /api/system/version            — current build info (view)
//   POST   /api/system/update/check       — kick off a check job (admin)
//   GET    /api/system/update/status      — current update phase (view)
//   POST   /api/system/update/download    — start staged download (admin)
//   POST   /api/system/update/apply       — apply staged update (admin)
//   POST   /api/system/update/abort       — cancel in-flight check/download
//   POST   /api/system/update/rollback    — manual rollback (501 if no restore point)
//   GET    /api/system/update/staged      — info about the staged update (view)
//   DELETE /api/system/update/staged      — discard a staged update (admin)
//
// Underlying state changes flow back to clients as `NightshadeEvent`s
// with `category: EventCategory.system`. The bootstrap subscribes
// [UpdateController.events] and forwards each variant to the server's
// broadcast.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:nightshade_core/nightshade_core.dart'
    show sanitizeEndpointForDisplay;
import 'package:nightshade_updater/nightshade_updater.dart';
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';

/// REST surface for the headless OTA update flow.
///
/// The handler is stateless beyond the [UpdateController] / [JobManager]
/// pair it receives. Long-running operations (check, download, apply,
/// rollback) are dispatched through the JobManager so the caller receives
/// a `{jobId, status: 'queued'}` response immediately and tracks progress
/// via the existing `/api/jobs/{id}` endpoints + the WS event stream.
class UpdateHandlers {
  final UpdateController controller;
  final JobManager jobManager;

  UpdateHandlers({required this.controller, required this.jobManager});

  /// `GET /api/system/version` — current build metadata.
  Future<Response> handleGetVersion(Request request) async {
    final rawUpdateServerUrl = controller.updateServerUrl;
    final safeUpdateServerUrl = rawUpdateServerUrl == null
        ? ''
        : sanitizeEndpointForDisplay(rawUpdateServerUrl);
    return jsonOk({
      'currentVersion': controller.currentVersion,
      'buildNumber': controller.currentBuildNumber,
      'channel': controller.channel,
      'platform': _platformName(),
      'dataDir': _resolvedExecutableDir(),
      if (safeUpdateServerUrl.isNotEmpty)
        'updateServerUrl': safeUpdateServerUrl,
      // Where updates come from. A host reading GitHub releases has no server
      // URL, so without this the client cannot tell "OTA is off" from "OTA
      // works, just not from a server you configured".
      'updateSource': safeUpdateServerUrl.isNotEmpty
          ? safeUpdateServerUrl
          : controller.updateSourceLabel,
      if (controller.lastUpdateCheck != null)
        'lastUpdateCheck': controller.lastUpdateCheck!
            .toUtc()
            .toIso8601String(),
      if (controller.lastUpdateApplied != null)
        'lastUpdateApplied': controller.lastUpdateApplied!
            .toUtc()
            .toIso8601String(),
    });
  }

  /// `POST /api/system/update/check` — dispatch an async update check.
  /// Body / query may carry an optional `channel` override.
  Future<Response> handleCheckForUpdate(Request request) async {
    final conflict = _activeOperationConflict();
    if (conflict != null) return conflict;
    final channelOverride = await _readOptionalChannel(request);

    final job = jobManager.start(
      operation: 'system.update.check',
      work: (sink, cancellation) async {
        sink.update(null, 'Querying update server');
        final outcome = await controller.checkForUpdates(
          channelOverride: channelOverride,
        );
        if (cancellation.isCancelled) {
          throw const JobCancelledException('check_cancelled');
        }
        return outcome.toJson();
      },
    );
    return jsonOk({'jobId': job.jobId, 'status': job.state.wireName});
  }

  /// `GET /api/system/update/status` — current update phase snapshot.
  Future<Response> handleGetStatus(Request request) async {
    final body = controller.status.toJson();
    // Rollback support depends on whether the updater's restore point still
    // exists on disk, so it cannot be inferred from the lifecycle enum. Expose
    // the real capability and let clients disable the action before a 501.
    body['rollbackAvailable'] = await controller.rollbackSupported();
    body['canAuthenticateUpdates'] = controller.canAuthenticateUpdates;
    return jsonOk(body);
  }

  /// `POST /api/system/update/download` — start streaming the staged
  /// download.
  Future<Response> handleDownload(Request request) async {
    final conflict = _activeOperationConflict();
    if (conflict != null) return conflict;
    // The work callback runs in a microtask scheduled after start() returns,
    // so `job` is assigned by the time the controller call executes; capturing
    // it lets the controller stamp the REAL jobId onto every WS event so
    // /api/jobs/{id} polling correlates with the event stream.
    late final Job job;
    job = jobManager.start(
      operation: 'system.update.download',
      work: (sink, cancellation) async {
        sink.update(0, 'Downloading update');
        await controller.downloadAndStage(jobId: job.jobId);
        if (cancellation.isCancelled) {
          throw const JobCancelledException('download_cancelled');
        }
        return {'status': 'downloaded'};
      },
    );

    return jsonOk({'jobId': job.jobId, 'status': job.state.wireName});
  }

  /// `POST /api/system/update/apply` — apply the staged update.
  ///
  /// The job's work invokes `UpdateController.applyStagedUpdate`, which
  /// in production calls `exit(0)` on success — the host process is
  /// replaced by the updater binary. Clients should treat
  /// `UpdateApplyStarted` followed by a WebSocket disconnect as the expected
  /// handoff and reconnect to verify the running build. `UpdateApplied` is
  /// emitted only when an embedder's apply implementation returns instead of
  /// terminating the process.
  Future<Response> handleApply(Request request) async {
    final conflict = _activeOperationConflict();
    if (conflict != null) return conflict;
    late final Job job;
    job = jobManager.start(
      operation: 'system.update.apply',
      work: (sink, cancellation) async {
        sink.update(null, 'Applying staged update');
        await controller.applyStagedUpdate(jobId: job.jobId);
        // applyStagedUpdate typically exits the process; reaching here
        // means the apply returned without restart, which is rare but
        // surface it explicitly.
        return {
          'status': 'apply_returned_without_restart',
          'restartRequired': true,
        };
      },
    );
    return jsonOk({
      'jobId': job.jobId,
      'status': job.state.wireName,
      'restartRequired': true,
      'message':
          'Server may restart imminently. Clients should reconnect after WS drops.',
    });
  }

  /// `POST /api/system/update/abort` — cancel an in-flight check or
  /// download. 409 when nothing is in flight.
  Future<Response> handleAbort(Request request) async {
    try {
      controller.abortInFlight();
    } on StateError catch (e) {
      return jsonConflict({
        'error': 'no_update_in_flight',
        'message': e.message,
      });
    }

    // Cancel any matching jobs so the caller's polling loop terminates
    // promptly.
    final cancelled = <String>[];
    for (final job in jobManager.list()) {
      if (job.operation == 'system.update.check' ||
          job.operation == 'system.update.download') {
        if (!job.state.isTerminal) {
          try {
            jobManager.cancel(job.jobId);
            cancelled.add(job.jobId);
          } on StateError {
            // Raced terminal — fine, the job already completed.
          }
        }
      }
    }
    return jsonOk({'aborted': true, 'cancelledJobs': cancelled});
  }

  /// `POST /api/system/update/rollback` — admin-only rollback of the
  /// last applied update. Returns 501 when no restore point is currently
  /// available (no update applied, or the boot verifier already confirmed
  /// the current build healthy and reclaimed the backup).
  Future<Response> handleRollback(Request request) async {
    final conflict = _activeOperationConflict();
    if (conflict != null) return conflict;
    if (!await controller.rollbackSupported()) {
      return jsonNotImplemented({
        'error': 'rollback_unavailable',
        'message':
            'No restore point is available to roll back to. A manual rollback '
            'is only possible after an update is applied and before the next '
            'launch confirms it healthy; the boot verifier reclaims the backup '
            'once the new build proves stable.',
      });
    }
    late final Job job;
    job = jobManager.start(
      operation: 'system.update.rollback',
      work: (sink, cancellation) async {
        sink.update(null, 'Rolling back last applied update');
        await controller.rollback(jobId: job.jobId);
        return {'status': 'rolled_back'};
      },
    );
    return jsonOk({'jobId': job.jobId, 'status': job.state.wireName});
  }

  /// `GET /api/system/update/staged` — info about the staged update.
  /// 200 with body even when no staged update is present (body is null
  /// in that case so clients distinguish "no staged" from "request
  /// failed").
  Future<Response> handleGetStaged(Request request) async {
    final staged = await controller.stagedUpdate();
    if (staged == null) {
      return jsonOk({'staged': null});
    }
    return jsonOk({'staged': staged.toJson()});
  }

  /// `DELETE /api/system/update/staged` — discard the staged update.
  /// 204-style 200 with `{discarded: true}` so the client can confirm
  /// the operation took effect even when no staged update existed.
  Future<Response> handleDiscardStaged(Request request) async {
    final conflict = _activeOperationConflict();
    if (conflict != null) return conflict;
    await controller.discardStaged();
    return jsonOk({'discarded': true});
  }

  Response? _activeOperationConflict() {
    Job? activeJob;
    for (final job in jobManager.list()) {
      if (job.operation.startsWith('system.update.') && !job.state.isTerminal) {
        activeJob = job;
        break;
      }
    }
    if (!controller.hasActiveOperation && activeJob == null) return null;
    return jsonConflict({
      'error': 'update_operation_in_progress',
      'message': activeJob == null
          ? 'An update operation is still stopping. Try again shortly.'
          : 'Update operation ${activeJob.operation} is already ${activeJob.state.wireName}.',
      if (activeJob != null) 'jobId': activeJob.jobId,
    });
  }

  /// Honour `?channel=` query param OR a JSON body `{ "channel": ... }`.
  /// Both are accepted because the audit spec calls out the query form
  /// and operators reaching for `curl` will more naturally pass it as a
  /// body field.
  Future<String?> _readOptionalChannel(Request request) async {
    final fromQuery = request.url.queryParameters['channel'];
    if (fromQuery != null && fromQuery.trim().isNotEmpty) {
      return fromQuery.trim();
    }
    final method = request.method.toUpperCase();
    if (method != 'POST' && method != 'PUT' && method != 'PATCH') {
      return null;
    }
    final contentLength = request.contentLength ?? 0;
    if (contentLength <= 0) return null;
    // readJsonObject throws on malformed bodies; we want a missing
    // optional channel to be silent, so peek the body and route around
    // the validator when empty.
    try {
      final payload = await readJsonObject(request);
      return optionalString(payload, 'channel');
    } on BadRequestError {
      rethrow;
    }
  }

  String _platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  String _resolvedExecutableDir() {
    try {
      final exe = Platform.resolvedExecutable;
      final sep = Platform.pathSeparator;
      final idx = exe.lastIndexOf(sep);
      return idx >= 0 ? exe.substring(0, idx) : exe;
    } on Object catch (e) {
      // Why: best-effort install-dir resolution; fall back to the OS name
      // rather than failing the request if the executable path can't be parsed.
      developer.log(
        'Update handler: could not resolve executable dir, '
        'falling back to OS name: $e',
        name: 'nightshade.headless',
      );
      return Platform.operatingSystem;
    }
  }
}
