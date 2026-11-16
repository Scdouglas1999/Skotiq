part of '../network_backend.dart';

/// Sessions, captured-image rows and targets in a linked imaging host's
/// database, as wire rows.
final class HostImagingRecords {
  HostImagingRecords(this._host);

  final NetworkBackend _host;

  /// Create a captured-image metadata row on the host.
  Future<int> createCapturedImage(Map<String, dynamic> image) async {
    final response = await _host._post(SessionApi.createImage, body: image);
    return _host._sessionScienceNumber(response, 'id', 'POST /api/images').toInt();
  }

  Future<int> createSession(Map<String, dynamic> session) async {
    final response = await _host._post(AnalyticsApi.createSession, body: session);
    return _host._sessionScienceNumber(response, 'id', 'POST /api/sessions').toInt();
  }

  Future<void> endSession(
    int id, {
    SessionStatus status = SessionStatus.completed,
  }) async {
    await _host._post(
      AnalyticsApi.endSession,
      path: {'id': id},
      body: {'status': status.token},
    );
  }

  Future<List<Map<String, dynamic>>> getAllSessions() async {
    final response = await _host._get(AnalyticsApi.getAllSessions);
    return _host._sessionScienceObjectList(response, 'sessions', 'GET /api/sessions');
  }

  Future<Map<String, dynamic>?> getCapturedImageById(int id) async {
    try {
      final response = await _host._get(
        SessionApi.getImageById,
        path: {'imageId': id},
      );
      return _host._sessionScienceNullableObject(
        response,
        'image',
        'GET /api/images/$id',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Thumbnail-strip rows for a producing exposure node.
  Future<List<Map<String, dynamic>>> getImagesByProducingNode(
    String producingNodeId, {
    String? producingRunId,
    int? limit,
  }) async {
    final params = <String, String>{
      'producingNodeId': producingNodeId,
      if (producingRunId != null) 'producingRunId': producingRunId,
      if (limit != null) 'limit': limit.toString(),
    };
    final response = await _host._get(SessionApi.getAllImages, query: params);
    return _host._sessionScienceObjectList(response, 'images', 'GET /api/images');
  }

  Future<List<Map<String, dynamic>>> getImagesForTarget(int targetId) async {
    final response = await _host._get(
      SessionApi.getAllImages,
      query: {'targetId': targetId.toString()},
    );
    return _host._sessionScienceObjectList(response, 'images', 'GET /api/images');
  }

  Future<Map<String, dynamic>?> getSessionById(int id) async {
    try {
      final response = await _host._get(
        AnalyticsApi.getSessionById,
        path: {'id': id},
      );
      return _host._sessionScienceNullableObject(
        response,
        'session',
        'GET /api/sessions/$id',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getSessionsForTarget(int targetId) async {
    final response = await _host._get(
      AnalyticsApi.getSessionsForTarget,
      path: {'targetId': targetId},
    );
    return _host._sessionScienceObjectList(
      response,
      'sessions',
      'GET /api/sessions/target/$targetId',
    );
  }

  /// Patch captured-image metadata on the host.
  Future<void> updateCapturedImage(int id, Map<String, dynamic> patch) async {
    await _host._put(SessionApi.updateImage, path: {'imageId': id}, body: patch);
  }

  /// Update session fields (stats, notes, status).
  Future<void> updateSession(int id, Map<String, dynamic> body) async {
    await _host._put(AnalyticsApi.updateSession, path: {'id': id}, body: body);
  }

  Future<List<Map<String, dynamic>>> getAllImages() async {
    final response = await _host._get(SessionApi.getAllImages);
    return _host._sessionScienceObjectList(response, 'images', 'GET /api/images');
  }

  /// Count "untracked" library targets eligible for the Analytics cleanup
  /// (no integration goal, not a favorite, no captured subs, no integration
  /// time, not referenced by any session). The session-aware predicate runs
  /// against the host DB, so a remote client asks the host instead of guessing.
  Future<int> countUntrackedTargets() async {
    final response = await _host._get(AnalyticsApi.getUntrackedTargetsCount);
    return _host._sessionScienceNumber(
      response,
      'count',
      'GET /api/analytics/untracked-targets/count',
    ).toInt();
  }

  /// Permanently remove every untracked library target on the host and return
  /// the number deleted. Irreversible — the caller confirms with the user first.
  Future<int> removeUntrackedTargets() async {
    final response = await _host._post(
      AnalyticsApi.removeUntrackedTargets,
      body: const {},
    );
    return _host._sessionScienceNumber(
      response,
      'deleted',
      'POST /api/analytics/untracked-targets/remove',
    ).toInt();
  }

  /// Get all targets from the headless server
  /// Returns JSON maps that can be used to construct CelestialTarget objects
  Future<List<Map<String, dynamic>>> getAllTargets() async {
    final response = await _host._get(TargetApi.getAllTargets);
    return _host._domainObjectRows(response, 'targets', 'GET /api/targets');
  }

  Future<int> createTarget(Map<String, dynamic> target) async {
    final response = await _host._post(TargetApi.createTarget, body: target);
    return _host._domainId(response, 'POST /api/targets');
  }

  Future<List<Map<String, dynamic>>> searchTargets(String query) async {
    final response = await _host._get(
      TargetApi.searchTargets,
      query: {'query': query},
    );
    return _host._domainObjectRows(response, 'targets', 'GET /api/targets/search');
  }

  Future<void> updateTarget(int id, Map<String, dynamic> target) async {
    await _host._put(TargetApi.updateTarget, path: {'id': id}, body: target);
  }

  Future<Map<String, dynamic>?> getTargetById(int id) async {
    try {
      final response = await _host._get(TargetApi.getTargetById, path: {'id': id});
      return _host._domainNullableObject(response, 'target', 'GET /api/targets/$id');
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getSessionImageRows(int sessionId) async {
    if (sessionId <= 0) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must be positive');
    }
    final response = await _host._get(
      SessionApi.getSessionImages,
      path: {'sessionId': sessionId},
    );
    return _rowsFromJson<Map<String, dynamic>>(
      response['images'],
      (row) => row,
    );
  }

  Future<List<Map<String, dynamic>>> getAllImageRows() async {
    final response = await _host._get(SessionApi.getAllImages);
    return _rowsFromJson<Map<String, dynamic>>(
      response['images'],
      (row) => row,
    );
  }

  Future<Uint8List> getImageThumbnail(int imageId) async {
    if (imageId <= 0) {
      throw ArgumentError.value(imageId, 'imageId', 'must be positive');
    }
    final endpoint = _host._endpointPath(
      SessionApi.getImageThumbnail,
      ApiMethod.get,
      {'imageId': imageId},
    );
    final response = await _host._openRawGetWithAuthRefresh(endpoint);
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.transform(utf8.decoder).join();
      throw _host._errorFromResponse(response.statusCode, body, 'GET', endpoint);
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (bytes.isEmpty) {
      throw FormatException('$endpoint returned an empty thumbnail');
    }
    return Uint8List.fromList(bytes);
  }

  Future<List<Map<String, dynamic>>> getStandaloneImageRows() async {
    final response = await _host._get(SessionApi.getStandaloneImages);
    return _rowsFromJson<Map<String, dynamic>>(
      response['images'],
      (row) => row,
    );
  }

  /// GET /api/sequence-runs?sequenceId=&limit=&offset=
  Future<RemotePage<RemoteSequenceRun>> fetchSequenceRuns({
    int? sequenceId,
    int limit = 200,
    int offset = 0,
  }) async {
    if (sequenceId != null && sequenceId <= 0) {
      throw ArgumentError.value(sequenceId, 'sequenceId', 'must be positive');
    }
    _host._validateReplayPageRequest(limit: limit, offset: offset);
    final response = await _host._get(
      DbReadApi.listSequenceRuns,
      query: {
        if (sequenceId != null) 'sequenceId': sequenceId.toString(),
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return RemotePage.fromJson(response, RemoteSequenceRun.fromJson);
  }

  // Replay scrubber — per-run endpoints.
  Future<RemoteSequenceRunDetail> fetchSequenceRunById(int runId) async {
    _host._validateReplayRunId(runId);
    final response = await _host._get(
      DbReadApi.getSequenceRunById,
      path: {'runId': runId},
    );
    final run = response['run'];
    if (run is! Map) {
      throw StateError(
        'Malformed /sequence-runs/$runId response: missing run object',
      );
    }
    final parsed = RemoteSequenceRunDetail.fromJson(
      run.cast<String, dynamic>(),
    );
    if (parsed.id != runId) {
      throw FormatException(
        'GET /api/sequence-runs/$runId returned run ${parsed.id}',
      );
    }
    return parsed;
  }

  Future<RemoteReplayEventsPage> fetchSequenceRunEvents(
    int runId, {
    int? sinceMs,
    int? untilMs,
    String? severityMin,
    int limit = 200,
    int offset = 0,
  }) async {
    _host._validateReplayRunId(runId);
    _host._validateReplayPageRequest(limit: limit, offset: offset);
    if (sinceMs != null && sinceMs <= 0) {
      throw ArgumentError.value(sinceMs, 'sinceMs', 'must be positive');
    }
    if (untilMs != null && untilMs <= 0) {
      throw ArgumentError.value(untilMs, 'untilMs', 'must be positive');
    }
    if (sinceMs != null && untilMs != null && sinceMs > untilMs) {
      throw ArgumentError('sinceMs must not be after untilMs');
    }
    final response = await _host._get(
      DbReadApi.getSequenceRunEvents,
      path: {'runId': runId},
      query: {
        if (sinceMs != null) 'since': sinceMs.toString(),
        if (untilMs != null) 'until': untilMs.toString(),
        if (severityMin != null && severityMin.isNotEmpty)
          'severityMin': severityMin,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return RemoteReplayEventsPage.fromJson(response);
  }

  Future<RemotePage<RemoteReplayFrame>> fetchSequenceRunFrames(
    int runId, {
    int limit = 200,
    int offset = 0,
  }) async {
    _host._validateReplayRunId(runId);
    _host._validateReplayPageRequest(limit: limit, offset: offset);
    final response = await _host._get(
      DbReadApi.getSequenceRunFrames,
      path: {'runId': runId},
      query: {'limit': limit.toString(), 'offset': offset.toString()},
    );
    return RemotePage.fromJson(response, RemoteReplayFrame.fromJson);
  }
}
