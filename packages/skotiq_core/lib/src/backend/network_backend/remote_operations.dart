part of '../network_backend.dart';

mixin _NetworkBackendRemoteOperations on _NetworkBackendTransport {
  // /  — Long-running operation job client API

  /// Snapshot of a server-side job. Mirrors the wire shape of
  /// `apps/desktop/lib/headless_api/job_manager.dart#Job.toJson`. We
  /// deliberately keep the model loose (no enum for state) so a server
  /// that adds a new state value does not crash an older client; the
  /// caller branches on the string.
  Future<RemoteJob> getJob(String jobId) async {
    final response = await _get('jobs/$jobId');
    return RemoteJob.fromJson(response);
  }

  /// Cancel a long-running job. Throws when the server replies 409 (the
  /// job is already terminal) — the caller may want to log it but not
  /// abort their workflow.
  Future<RemoteJob> cancelJob(String jobId) async {
    final response = await _post('jobs/$jobId/cancel');
    return RemoteJob.fromJson(response);
  }

  /// List jobs (filtered).
  Future<List<RemoteJob>> listJobs({String? state, String? operation}) async {
    final response = await _get('jobs', {
      if (state != null) 'state': state,
      if (operation != null) 'operation': operation,
    });
    return _rowsFromJson(response['jobs'], RemoteJob.fromJson);
  }

  /// Stream WS-broadcast snapshots for a single [jobId]. The stream
  /// terminates when the job reaches a terminal state or when the
  /// underlying event subscription closes (server restart, network
  /// drop). Callers that want to keep observing across reconnects must
  /// re-subscribe after `connectionStateStream` emits `connected`.
  Stream<RemoteJob> watchJob(String jobId) {
    return eventStream
        .where(
          (e) => e.category == EventCategory.job && e.data['jobId'] == jobId,
        )
        .map((e) => RemoteJob.fromEventData(e.data));
  }

  /// Await the terminal state of [jobId]. Returns the final snapshot
  /// (succeeded / failed / cancelled). Polls the snapshot endpoint when
  /// the WS stream is unavailable so we don't deadlock if the operator
  /// is on a flaky link.
  ///
  /// [timeout] caps the wait. The audit's spec recommends:
  ///   * 30 minutes for autofocus
  ///   * 5 minutes for plate solve
  ///   * 10 minutes for center-on-target
  ///   * 5 minutes for mosaic plan
  ///   * 10 minutes for polar alignment
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 5),
  }) async {
    final initial = await getJob(jobId);
    if (_isTerminalRemoteJobState(initial.state)) {
      return initial;
    }
    final completer = Completer<RemoteJob>();
    StreamSubscription<RemoteJob>? sub;
    Timer? pollTimer;
    Timer? timeoutTimer;
    void finish(RemoteJob job) {
      if (completer.isCompleted) return;
      sub?.cancel();
      pollTimer?.cancel();
      timeoutTimer?.cancel();
      completer.complete(job);
    }

    sub = watchJob(jobId).listen((snapshot) {
      if (_isTerminalRemoteJobState(snapshot.state)) {
        finish(snapshot);
      }
    });

    // Concurrent poll to catch terminations the WS stream might miss
    // (e.g. when we reconnect after the JobCompleted frame). Use a one-shot
    // timer that reschedules only after the request settles: Timer.periodic
    // would overlap slow host requests and amplify a degraded connection.
    late final Future<void> Function() poll;
    void schedulePoll() {
      if (completer.isCompleted) return;
      pollTimer = Timer(pollInterval, () => unawaited(poll()));
    }

    poll = () async {
      if (completer.isCompleted) return;
      try {
        final snap = await getJob(jobId);
        if (_isTerminalRemoteJobState(snap.state)) {
          finish(snap);
        }
      } catch (_) {
        // Silent retry — the next poll tick will try again. The timeout
        // protects against indefinite hangs.
      } finally {
        schedulePoll();
      }
    };
    schedulePoll();

    timeoutTimer = Timer(timeout, () {
      if (completer.isCompleted) return;
      sub?.cancel();
      pollTimer?.cancel();
      completer.completeError(
        TimeoutException(
          'Job $jobId did not reach a terminal state within $timeout',
        ),
      );
    });

    return completer.future;
  }

  /// Resolve an endpoint that may be either a legacy synchronous response or
  /// the current `{jobId, status: queued}` envelope. This keeps clients
  /// compatible with older hosts while ensuring new hosts return the actual
  /// operation result rather than a queued acknowledgement.
  Future<Map<String, dynamic>> awaitJobResultOrLegacy(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  }) async {
    final jobId = response['jobId'] as String?;
    if (jobId == null || jobId.isEmpty) return response;

    final job = await awaitJobCompletion(jobId, timeout: timeout);
    if (job.state == 'cancelled') {
      throw ImagingException(
        message: '$operation cancelled',
        userMessage: 'The operation was cancelled.',
      );
    }
    if (job.state != 'succeeded') {
      final detail = job.error?['message'] ?? job.error?['code'] ?? job.state;
      throw IoException(
        message: '$operation job $jobId ended ${job.state}: $detail',
        userMessage: 'The operation failed on the imaging host.',
      );
    }
    final result = job.result;
    if (result == null) {
      throw ValidationException(
        message: '$operation job $jobId succeeded without a result',
        userMessage: 'The imaging host returned an empty result.',
      );
    }
    return result;
  }

  static bool _isTerminalRemoteJobState(String state) {
    return state == 'succeeded' || state == 'failed' || state == 'cancelled';
  }

  // Session ownership client API

  /// POST /api/session/claim — returns true on success, false when the
  /// slot is already taken.
  Future<bool> claimSession({String? clientName, String? clientId}) async {
    final uri = _apiUri('session/claim');
    final headers = _addAuthHeaders({}, endpoint: 'session/claim');
    headers[HttpHeaders.contentTypeHeader] = 'application/json';
    final response = await _http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        if (clientName != null) 'clientName': clientName,
        if (clientId != null) 'clientId': clientId,
      }),
    );
    if (response.statusCode == 200) {
      return true;
    }
    if (response.statusCode == 409) {
      return false; // Slot taken — caller may decide to take-over.
    }
    throw _parseErrorResponse(
      response.statusCode,
      response.body,
      'POST',
      'session/claim',
    );
  }

  /// POST /api/session/take-over — always succeeds (any control-scope
  /// client can preempt). The previous owner observes the displacement
  /// via the WS event stream.
  Future<void> takeOverSession({
    required String reason,
    String? clientName,
    String? clientId,
  }) async {
    await _post('session/take-over', {
      'reason': reason,
      if (clientName != null) 'clientName': clientName,
      if (clientId != null) 'clientId': clientId,
    });
  }

  /// POST /api/session/release — voluntary release by the owner. 403 if
  /// called by a non-owner.
  Future<void> releaseSession() async {
    await _post('session/release');
  }

  /// GET /api/session/status — combined snapshot + caller-relative view.
  Future<RemoteSessionStatus> getSessionStatus() async {
    final response = await _get('session/status');
    return RemoteSessionStatus.fromJson(response);
  }

  // Remote OTA update management.
  //
  // Mirrors the headless server's `/api/system/version` and
  // `/api/system/update/*` surface. Long-running operations (check,
  // download, apply, rollback) return a [RemoteJob] handle; the caller
  // polls via [getJob]/[awaitJobCompletion] or subscribes to the WS
  // event stream filtered by `category == EventCategory.system`.

  /// GET /api/system/version — current build info.
  Future<RemoteVersionInfo> getSystemVersion() async {
    final response = await _get('system/version');
    return RemoteVersionInfo.fromJson(response);
  }

  /// POST /api/system/update/check — dispatch a check job.
  Future<RemoteJob> checkForUpdate({String? channel}) async {
    final response = await _post('system/update/check', {
      if (channel != null && channel.isNotEmpty) 'channel': channel,
    });
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.check',
    );
  }

  /// GET /api/system/update/status — current update phase snapshot.
  Future<RemoteUpdateStatus> getUpdateStatus() async {
    final response = await _get('system/update/status');
    return RemoteUpdateStatus.fromJson(response);
  }

  /// POST /api/system/update/download — start downloading the staged
  /// update. Returns a job handle for progress tracking.
  Future<RemoteJob> downloadUpdate() async {
    final response = await _post('system/update/download');
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.download',
    );
  }

  /// POST /api/system/update/apply — apply the staged update. The server
  /// process may exit during the apply (the host is replaced by the
  /// updater binary), so clients should reconnect after the WS drops.
  Future<RemoteJob> applyUpdate() async {
    final response = await _post('system/update/apply');
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.apply',
    );
  }

  /// POST /api/system/update/rollback — roll back the last applied update
  /// to the build it replaced. Only available while a restore point exists
  /// (after an apply, before the next launch confirms the build healthy);
  /// the server returns 501 otherwise. The host process may restart during
  /// the rollback, so clients should reconnect after the WS drops.
  Future<RemoteJob> rollbackUpdate() async {
    final response = await _post('system/update/rollback');
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.rollback',
    );
  }

  /// POST /api/system/update/abort — abort any in-flight check or
  /// download.
  ///
  /// Returns the ids of the jobs the host actually cancelled; the list is
  /// empty when nothing was in flight, which is the host's answer and not an
  /// error. The endpoint answers `{aborted: bool, cancelledJobs: [...]}` and
  /// never mints a job of its own, so neither does this.
  Future<List<String>> abortUpdate() async {
    final response = await _post('system/update/abort');
    final cancelled = response['cancelledJobs'];
    if (cancelled is! List) return const <String>[];
    return cancelled
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  /// GET /api/system/update/staged — info about the staged update, or
  /// null when nothing is staged.
  Future<RemoteStagedUpdate?> getStagedUpdate() async {
    final response = await _get('system/update/staged');
    final raw = response['staged'];
    if (raw == null) return null;
    if (raw is! Map) return null;
    return RemoteStagedUpdate.fromJson(Map<String, dynamic>.from(raw));
  }

  /// DELETE /api/system/update/staged — discard the staged update.
  Future<void> discardStagedUpdate() async {
    await _delete('system/update/staged');
  }

  /// GET /api/push/targets — whether a critical alert could actually reach a
  /// phone right now (registered push tokens + a configured delivery channel).
  ///
  /// Counts and a verdict only; the host never returns token values.
  Future<PushDeliveryTargets> getPushDeliveryTargets() async {
    final response = await _get('push/targets');
    return PushDeliveryTargets.fromJson(response);
  }
}
