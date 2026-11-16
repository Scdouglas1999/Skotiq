part of '../network_backend.dart';

/// The software version of a linked imaging host and its update flow.
mixin HostUpdates on NetworkBackendTransport {
  /// POST /api/system/update/abort — abort any in-flight check or
  /// download.
  ///
  /// Returns the ids of the jobs the host actually cancelled; the list is
  /// empty when nothing was in flight, which is the host's answer and not an
  /// error. The endpoint answers `{aborted: bool, cancelledJobs: [...]}` and
  /// never mints a job of its own, so neither does this.
  Future<List<String>> abortUpdate() async {
    final response = await _post(UpdateApi.abort);
    final cancelled = response['cancelledJobs'];
    if (cancelled is! List) return const <String>[];
    return cancelled
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  /// POST /api/system/update/apply — apply the staged update. The server
  /// process may exit during the apply (the host is replaced by the
  /// updater binary), so clients should reconnect after the WS drops.
  Future<RemoteJob> applyUpdate() async {
    final response = await _post(UpdateApi.apply);
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.apply',
    );
  }

  /// POST /api/system/update/check — dispatch a check job.
  Future<RemoteJob> checkForUpdate({String? channel}) async {
    final response = await _post(
      UpdateApi.checkForUpdate,
      body: {if (channel != null && channel.isNotEmpty) 'channel': channel},
    );
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.check',
    );
  }

  /// DELETE /api/system/update/staged — discard the staged update.
  Future<void> discardStagedUpdate() async {
    await _delete(UpdateApi.discardStaged);
  }

  /// POST /api/system/update/download — start downloading the staged
  /// update. Returns a job handle for progress tracking.
  Future<RemoteJob> downloadUpdate() async {
    final response = await _post(UpdateApi.download);
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.download',
    );
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
    final response = await _get(SystemApi.version);
    return RemoteVersionInfo.fromJson(response);
  }

  /// GET /api/system/update/status — current update phase snapshot.
  Future<RemoteUpdateStatus> getUpdateStatus() async {
    final response = await _get(UpdateApi.getStatus);
    return RemoteUpdateStatus.fromJson(response);
  }

  /// POST /api/system/update/rollback — roll back the last applied update
  /// to the build it replaced. Only available while a restore point exists
  /// (after an apply, before the next launch confirms the build healthy);
  /// the server returns 501 otherwise. The host process may restart during
  /// the rollback, so clients should reconnect after the WS drops.
  Future<RemoteJob> rollbackUpdate() async {
    final response = await _post(UpdateApi.rollback);
    return RemoteJob.fromJson(
      response,
      fallbackOperation: 'system.update.rollback',
    );
  }
}
