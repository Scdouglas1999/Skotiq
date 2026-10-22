part of '../network_backend.dart';

mixin _NetworkBackendSessionScienceOperations on _NetworkBackendTransport {
  List<Map<String, dynamic>> _sessionScienceObjectList(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! List) {
      throw FormatException(
        '$request returned a missing or non-list `$field` field',
      );
    }
    final rows = <Map<String, dynamic>>[];
    for (var index = 0; index < raw.length; index++) {
      final row = raw[index];
      if (row is! Map) {
        throw FormatException(
          '$request returned a non-object `$field[$index]` row',
        );
      }
      rows.add(row.cast<String, dynamic>());
    }
    return rows;
  }

  Map<String, dynamic> _sessionScienceObject(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! Map) {
      throw FormatException(
        '$request returned a missing or non-object `$field` field',
      );
    }
    return raw.cast<String, dynamic>();
  }

  Map<String, dynamic>? _sessionScienceNullableObject(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    if (!response.containsKey(field)) {
      throw FormatException('$request returned no `$field` field');
    }
    final raw = response[field];
    if (raw == null) return null;
    if (raw is! Map) {
      throw FormatException('$request returned a non-object `$field` field');
    }
    return raw.cast<String, dynamic>();
  }

  num _sessionScienceNumber(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! num) {
      throw FormatException(
        '$request returned a missing or non-numeric `$field` field',
      );
    }
    return raw;
  }

  /// True pixel dimensions of a host FITS file. Used by the photometric
  /// calibration wizard to size images exactly on a remote client instead of
  /// estimating from the detected-star bounding box. Returns null if the host
  /// has no such file.
  Future<({int width, int height})?> getFitsDimensions(String hostPath) async {
    try {
      final response = await _get('imaging/fits-dimensions', {
        'path': hostPath,
      });
      return (
        width: _sessionScienceNumber(
          response,
          'width',
          'GET /api/imaging/fits-dimensions',
        ).toInt(),
        height: _sessionScienceNumber(
          response,
          'height',
          'GET /api/imaging/fits-dimensions',
        ).toInt(),
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404 || error.code == 'fits_not_found') {
        return null;
      }
      rethrow;
    } on dart_error.SkotiqError catch (error) {
      // Compatibility with hosts that predate the structured error envelope.
      final message = error.message.toLowerCase();
      if (message.contains('fits_not_found') || message.contains('http 404')) {
        return null;
      }
      rethrow;
    }
  }

  // Sessions & Analytics

  /// Get all imaging sessions
  Future<List<Map<String, dynamic>>> getAllSessions() async {
    final response = await _get('sessions');
    return _sessionScienceObjectList(response, 'sessions', 'GET /api/sessions');
  }

  /// Get active session
  Future<Map<String, dynamic>?> getActiveSession() async {
    final response = await _get('sessions/active');
    return _sessionScienceNullableObject(
      response,
      'session',
      'GET /api/sessions/active',
    );
  }

  /// Get session by ID
  Future<Map<String, dynamic>?> getSessionById(int id) async {
    try {
      final response = await _get('sessions/$id');
      return _sessionScienceNullableObject(
        response,
        'session',
        'GET /api/sessions/$id',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Create a new session
  Future<int> createSession(Map<String, dynamic> session) async {
    final response = await _post('sessions', session);
    return _sessionScienceNumber(response, 'id', 'POST /api/sessions').toInt();
  }

  /// Update session fields (stats, notes, status).
  Future<void> updateSession(int id, Map<String, dynamic> body) async {
    await _put('sessions/$id', body);
  }

  /// End a session with the given status.
  Future<void> endSession(int id, {String status = 'completed'}) async {
    await _post('sessions/$id/end', {'status': status});
  }

  /// Sessions for a target.
  Future<List<Map<String, dynamic>>> getSessionsForTarget(int targetId) async {
    final response = await _get('sessions/target/$targetId');
    return _sessionScienceObjectList(
      response,
      'sessions',
      'GET /api/sessions/target/$targetId',
    );
  }

  /// Create a captured-image metadata row on the host.
  Future<int> createCapturedImage(Map<String, dynamic> image) async {
    final response = await _post('images', image);
    return _sessionScienceNumber(response, 'id', 'POST /api/images').toInt();
  }

  /// Patch captured-image metadata on the host.
  Future<void> updateCapturedImage(int id, Map<String, dynamic> patch) async {
    await _put('images/$id', patch);
  }

  /// Fetch one captured-image row by id.
  Future<Map<String, dynamic>?> getCapturedImageById(int id) async {
    try {
      final response = await _get('images/$id');
      return _sessionScienceNullableObject(
        response,
        'image',
        'GET /api/images/$id',
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Every image row the host has recorded.
  Future<List<Map<String, dynamic>>> getAllImages() async {
    final response = await _get('images');
    return _sessionScienceObjectList(response, 'images', 'GET /api/images');
  }

  /// Images for a target.
  Future<List<Map<String, dynamic>>> getImagesForTarget(int targetId) async {
    final response = await _get('images', {'targetId': targetId.toString()});
    return _sessionScienceObjectList(response, 'images', 'GET /api/images');
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
    final response = await _get('images', params);
    return _sessionScienceObjectList(response, 'images', 'GET /api/images');
  }

  /// Get session statistics
  Future<Map<String, dynamic>> getSessionStats(int sessionId) async {
    final response = await _get('sessions/$sessionId/stats');
    return _sessionScienceObject(
      response,
      'stats',
      'GET /api/sessions/$sessionId/stats',
    );
  }

  Future<Uint8List> downloadSessionExport(int sessionId, String format) async {
    return _downloadBytes('sessions/$sessionId/export/$format');
  }

  Future<List<PsfFieldTileRow>> getSessionPsfTiles(int sessionId) async {
    final endpoint = 'GET /api/sessions/$sessionId/psf-tiles';
    final response = await _get('sessions/$sessionId/psf-tiles');
    final rows = _sessionScienceObjectList(response, 'psfTiles', endpoint);
    final seenIds = <int>{};
    final tiles = <PsfFieldTileRow>[];
    for (var index = 0; index < rows.length; index++) {
      final tile = _psfFieldTileFromJson(rows[index], endpoint, index);
      if (!seenIds.add(tile.id)) {
        throw FormatException(
          '$endpoint row $index field `id` duplicates id ${tile.id}',
        );
      }
      tiles.add(tile);
    }
    return tiles;
  }

  Future<List<AstrometryResidualVectorRow>> getSessionResidualVectors(
    int sessionId,
  ) async {
    final endpoint = 'GET /api/sessions/$sessionId/residuals';
    final response = await _get('sessions/$sessionId/residuals');
    final rows = _sessionScienceObjectList(response, 'residuals', endpoint);
    final seenIds = <int>{};
    final vectors = <AstrometryResidualVectorRow>[];
    for (var index = 0; index < rows.length; index++) {
      final vector = _residualVectorFromJson(rows[index], endpoint, index);
      if (!seenIds.add(vector.id)) {
        throw FormatException(
          '$endpoint row $index field `id` duplicates id ${vector.id}',
        );
      }
      vectors.add(vector);
    }
    return vectors;
  }

  /// Get analytics summary
  Future<Map<String, dynamic>> getAnalyticsSummary({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final params = <String, dynamic>{};
    if (startDate != null) {
      params['startDate'] = startDate.toUtc().toIso8601String();
    }
    if (endDate != null) {
      params['endDate'] = endDate.toUtc().toIso8601String();
    }
    final response = await _get(
      'analytics/summary',
      params.isEmpty ? null : params,
    );
    return response;
  }

  /// Get total integration time
  Future<Map<String, dynamic>> getTotalIntegrationTime({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final params = <String, dynamic>{};
    if (startDate != null) {
      params['startDate'] = startDate.toUtc().toIso8601String();
    }
    if (endDate != null) {
      params['endDate'] = endDate.toUtc().toIso8601String();
    }
    final response = await _get(
      'analytics/integration-time',
      params.isEmpty ? null : params,
    );
    return response;
  }

  /// Count "untracked" library targets eligible for the Analytics cleanup
  /// (no integration goal, not a favorite, no captured subs, no integration
  /// time, not referenced by any session). The session-aware predicate runs
  /// against the host DB, so a remote client asks the host instead of guessing.
  Future<int> countUntrackedTargets() async {
    final response = await _get('analytics/untracked-targets/count');
    return _sessionScienceNumber(
      response,
      'count',
      'GET /api/analytics/untracked-targets/count',
    ).toInt();
  }

  /// Permanently remove every untracked library target on the host and return
  /// the number deleted. Irreversible — the caller confirms with the user first.
  Future<int> removeUntrackedTargets() async {
    final response = await _post(
      'analytics/untracked-targets/remove',
      const {},
    );
    return _sessionScienceNumber(
      response,
      'deleted',
      'POST /api/analytics/untracked-targets/remove',
    ).toInt();
  }

  // Weather & Radar

  /// Get weather radar data
  Future<Map<String, dynamic>> getWeatherRadar(
    double lat,
    double lon, {
    bool forceRefresh = false,
  }) async {
    final response = await _get('weather/radar', {
      'lat': lat.toString(),
      'lon': lon.toString(),
      if (forceRefresh) 'refresh': 'true',
    });
    return response;
  }

  /// Get weather alerts
  Future<List<Map<String, dynamic>>> getWeatherAlerts() async {
    final response = await _get('weather/alerts');
    return _sessionScienceObjectList(
      response,
      'alerts',
      'GET /api/weather/alerts',
    );
  }

  /// Check safe imaging conditions
  Future<Map<String, dynamic>> checkSafeImaging() async {
    final response = await _get('weather/safe-imaging');
    return response;
  }

  /// Get weather settings
  Future<Map<String, dynamic>> getWeatherSettings() async {
    final response = await _get('weather/settings');
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/weather/settings',
    );
  }

  /// Update weather settings
  Future<void> updateWeatherSettings(Map<String, dynamic> settings) async {
    await _post('weather/settings', settings);
  }

  /// Clear weather cache
  Future<void> clearWeatherCache() async {
    await _post('weather/clear-cache');
  }

  // Night Narrator feed (read-only)

  /// Fetch the appliance's narrator feed for a session (pinned-first,
  /// newest-first). Returns the raw event maps; callers reconstruct
  /// `NarratorEvent` via `narratorEventFromWireJson`. The narrator runs on the
  /// host, so a remote client reads its feed here instead of the local DB.
  Future<List<Map<String, dynamic>>> getNarratorFeed(int sessionId) async {
    final json = await _get('narrator/feed', {
      'sessionId': sessionId.toString(),
    });
    return _narratorEventsList(json);
  }

  /// Fetch the appliance's sessionless recent narrator feed.
  Future<List<Map<String, dynamic>>> getRecentNarratorFeed({
    int limit = 50,
  }) async {
    final json = await _get('narrator/recent', {'limit': limit.toString()});
    return _narratorEventsList(json);
  }

  List<Map<String, dynamic>> _narratorEventsList(Map<String, dynamic> json) {
    return _sessionScienceObjectList(json, 'events', 'GET /api/narrator feed');
  }

  // First Light — difference-imaging transient discovery (read + triage)

  /// Fetch the appliance's First Light transient detections (newest-first).
  /// Pass [sessionId] for a single session, or null for the across-sessions
  /// feed. The difference pipeline runs on the host, so a remote client reads
  /// its persisted candidates here instead of the local DB. Callers
  /// reconstruct rows via `transientDetectionFromWireJson`.
  Future<List<Map<String, dynamic>>> getFirstLightCandidates({
    int? sessionId,
  }) async {
    final json = await _get(
      'firstlight/candidates',
      sessionId == null ? null : {'sessionId': sessionId.toString()},
    );
    return _sessionScienceObjectList(
      json,
      'candidates',
      'GET /api/firstlight/candidates',
    );
  }

  /// Fetch the host's cross-night history for one transient: every persisted
  /// detection within [radiusDeg] of ([raDeg], [decDeg]), oldest-first. Backs
  /// the multi-night light-curve detail view so the same source seen over
  /// several nights groups into one Δmag-vs-time history on a slave too.
  Future<List<Map<String, dynamic>>> getFirstLightHistory({
    required double raDeg,
    required double decDeg,
    double radiusDeg = 0.02,
  }) async {
    final json = await _get('firstlight/near', {
      'ra': raDeg.toString(),
      'dec': decDeg.toString(),
      'radius': radiusDeg.toString(),
    });
    return _sessionScienceObjectList(
      json,
      'detections',
      'GET /api/firstlight/near',
    );
  }

  /// Mark a First Light detection reviewed (confirmed) on the host.
  Future<void> reviewFirstLightCandidate(int id) async {
    await _post('firstlight/$id/review');
  }

  /// Dismiss a First Light detection as a triaged artefact on the host so the
  /// next difference scan suppresses the same position.
  Future<void> dismissFirstLightCandidate(int id) async {
    await _post('firstlight/$id/dismiss');
  }

  /// Fetch a REAL per-detection pixel postage stamp (PNG bytes) for detection
  /// [id], [stage] = `template` | `science` | `residual`. The host re-derives the
  /// deterministic crop filename from the persisted detection row and streams the
  /// PNG the difference pass wrote, so a companion tablet sees the actual pixels
  /// around the candidate — not a host-local file path. Maps to the advertised
  /// `GET /api/firstlight/<id>/crops/<stage>`.
  Future<Uint8List> getFirstLightCrop(int id, String stage) {
    return _downloadBytes('firstlight/$id/crops/$stage');
  }

  /// Trigger a REAL TNS submission for detection [id] ON THE HOST. The host
  /// holds the bot credentials + api key (the api key never crosses the wire);
  /// the slave only triggers and surfaces the result. Returns the host's
  /// `{success, atName?, reportId?, message}` payload.
  Future<Map<String, dynamic>> submitFirstLightToTns(int id) async {
    return _post('firstlight/$id/submit/tns');
  }

  /// Ask the host to generate an ingestible AAVSO Extended File Format report
  /// for detection [id] and return the bytes (the slave saves / share-sheets
  /// them — there is no per-observer AAVSO upload API; WebObs upload is manual).
  /// [magZeroPoint] is required (a calibrated magnitude); the host returns 400
  /// if unavailable.
  Future<Uint8List> exportFirstLightAavso(
    int id, {
    required double magZeroPoint,
    String? standardBand,
  }) async {
    return _postRawBytes('firstlight/$id/export/aavso', {
      'magZeroPoint': magZeroPoint,
      if (standardBand != null && standardBand.isNotEmpty)
        'standardBand': standardBand,
    });
  }

  /// Ask the host to generate an MPC ADES PSV astrometry report for detection
  /// [id] and return the bytes (MPC submission is via the web form / email).
  Future<Uint8List> exportFirstLightMpc(int id) async {
    return _postRawBytes('firstlight/$id/export/mpc', const {});
  }

  // Sky Atlas — Pillar A ("Your Sky") personal atlas

  /// Fetch the host's persisted atlas regions (the "Your Sky" browser list).
  /// The imaging pipeline that folds frames into the atlas runs on the host, so
  /// a remote client reads its regions here instead of its (empty) local store.
  /// Callers reconstruct rows via `skyAtlasRegionFromWireJson`.
  Future<List<Map<String, dynamic>>> getAtlasRegions() async {
    final json = await _get('atlas/regions');
    return _sessionScienceObjectList(json, 'regions', 'GET /api/atlas/regions');
  }

  /// Create or update a named region in the host-owned atlas. The companion
  /// sends only metadata; all tile/fold data remains on the imaging host.
  Future<int> createAtlasRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    required String kind,
    int? targetId,
  }) async {
    final response = await _post('atlas/regions', {
      'name': name,
      'centerRaDeg': centerRaDeg,
      'centerDecDeg': centerDecDeg,
      'radiusDeg': radiusDeg,
      'kind': kind,
      if (targetId != null) 'targetId': targetId,
    });
    final raw = response['id'];
    if (raw is! num || !raw.isFinite || raw.toInt() != raw || raw <= 0) {
      throw const FormatException(
        'POST /api/atlas/regions returned no positive whole-number `id`',
      );
    }
    return raw.toInt();
  }

  /// Fetch the host's per-tile atlas coverage (deepest first) — the heat-overlay
  /// / gallery feed and the source of the Constellation "your contribution" sum.
  /// The native coverage query runs on the host. Callers reconstruct rows via
  /// `AtlasTileCoverage.fromJson`.
  Future<List<Map<String, dynamic>>> getAtlasCoverage() async {
    final json = await _get('atlas/coverage');
    return _sessionScienceObjectList(json, 'tiles', 'GET /api/atlas/coverage');
  }

  /// Fetch one region's detail from the host: its row (`region`), live native
  /// cone coverage (`coverage`) and the region's tiles (`tiles`). Backs the
  /// companion's region-detail screen, which reads an empty local store on a
  /// slave and so must branch here. Maps to the already-advertised
  /// `GET /api/atlas/region/<id>` route (no catalog change).
  Future<Map<String, dynamic>> getAtlasRegion(int regionId) async {
    return _get('atlas/region/$regionId');
  }

  /// Fetch a region's fold timeline (`folds`) + deepening growth curve
  /// (`growth`) from the host — the scrubber stops + contributing-frames list on
  /// a slave. Maps to the advertised `GET /api/atlas/region/<id>/timeline`.
  Future<Map<String, dynamic>> getAtlasRegionTimeline(int regionId) async {
    return _get('atlas/region/$regionId/timeline');
  }

  /// Fetch the co-added region cone as PNG bytes (latest depth) so the companion
  /// renders the cutout via `Image.memory` — the host-local file path the FFI
  /// path uses is not portable over the wire. Maps to the advertised
  /// `GET /api/atlas/region/<id>/cutout`.
  Future<Uint8List> getAtlasRegionCutout(
    int regionId, {
    int outPixels = 2048,
    String? interp,
  }) {
    return _downloadBytes('atlas/region/$regionId/cutout', {
      'outPixels': outPixels.toString(),
      if (interp != null) 'interp': interp,
    });
  }

  // Target suggestions

  /// Get target suggestions for tonight
  Future<Map<String, dynamic>> getSuggestionsForTonight({
    double? minAltitude,
    double? minScore,
    int? maxResults,
    String? sortMode,
    bool? prioritizeIncomplete,
    List<String>? objectTypes,
  }) async {
    final params = <String, dynamic>{};
    if (minAltitude != null) params['minAltitude'] = minAltitude.toString();
    if (minScore != null) params['minScore'] = minScore.toString();
    if (maxResults != null) params['maxResults'] = maxResults.toString();
    if (sortMode != null) params['sortMode'] = sortMode;
    if (prioritizeIncomplete != null) {
      params['prioritizeIncomplete'] = prioritizeIncomplete.toString();
    }
    if (objectTypes != null && objectTypes.isNotEmpty) {
      params['objectTypes'] = objectTypes.join(',');
    }
    final response = await _get(
      'suggestions/tonight',
      params.isEmpty ? null : params,
    );
    return response;
  }

  /// Get target score
  Future<Map<String, dynamic>> getTargetScore(int targetId) async {
    final response = await _get('suggestions/score/$targetId');
    return response;
  }

  // Transient alerts

  /// Get active transient alerts
  Future<Map<String, dynamic>> getActiveTransients() async {
    final response = await _get('transients');
    return {
      ...response,
      'alerts': _sessionScienceObjectList(
        response,
        'alerts',
        'GET /api/transients',
      ),
    };
  }

  /// Get transient settings
  Future<Map<String, dynamic>> getTransientSettings() async {
    final response = await _get('transients/settings');
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/transients/settings',
    );
  }

  /// Update transient settings
  Future<void> updateTransientSettings(Map<String, dynamic> settings) async {
    await _post('transients/settings', settings);
  }

  /// Queue a transient for observation
  Future<void> queueTransient(String transientId) async {
    await _post('transients/$transientId/queue');
  }

  /// Dismiss a transient
  Future<void> dismissTransient(String transientId) async {
    await _post('transients/$transientId/dismiss');
  }

  /// Get the imaging host's durable per-alert action states.
  Future<Map<String, dynamic>> getTransientStates() async {
    final response = await _get('transients/states');
    return _sessionScienceObject(
      response,
      'states',
      'GET /api/transients/states',
    );
  }

  /// Persist an alert action state on the imaging host.
  Future<void> updateTransientState(String transientId, String state) async {
    await _post('transients/$transientId/state', {'state': state});
  }

  /// Remove all durable alert action states on the imaging host.
  Future<void> clearTransientStates() async {
    await _delete('transients/states');
  }

  /// Refresh transient alerts
  Future<void> refreshTransientAlerts() async {
    await _post('transients/refresh');
  }

  /// Get queued transients
  Future<Map<String, dynamic>> getQueuedTransients() async {
    final response = await _get('transients/queued');
    return response;
  }

  // Backup & Restore

  /// List available backups
  Future<List<Map<String, dynamic>>> listBackups() async {
    final response = await _get('backup/list');
    final backupsList = response['backups'];
    if (backupsList is! List) {
      throw const FormatException(
        'GET /api/backup/list returned a missing or non-list `backups` field',
      );
    }
    return backupsList
        .whereType<Map>()
        .map(
          (row) => Map<String, dynamic>.fromEntries(
            row.entries
                .where((entry) => entry.key is String)
                .map((entry) => MapEntry(entry.key as String, entry.value)),
          ),
        )
        .toList(growable: false);
  }

  /// Create a new backup
  Future<Map<String, dynamic>> createBackup({bool autoSave = false}) async {
    final response = await _post('backup/create', {'autoSave': autoSave});
    return response;
  }

  /// Restore from a backup identified by its stable [backupId].
  ///
  /// Preferred over [restoreBackup]: the host resolves [backupId] to a file
  /// inside its own backup directory, so no absolute server path crosses the
  /// wire and a client cannot point the host at an arbitrary file on disk.
  Future<Map<String, dynamic>> restoreBackupById(
    String backupId, {
    bool replaceExisting = false,
  }) async {
    final response = await _post('backup/restore', {
      'id': backupId,
      'replaceExisting': replaceExisting,
    });
    return response;
  }

  /// Restore from a backup by absolute server [filePath].
  ///
  /// Legacy/compat entry point retained for older hosts. Newer clients should
  /// use [restoreBackupById]; the host containment-checks any `filePath` to the
  /// backup directory regardless, so a path outside it is rejected.
  Future<Map<String, dynamic>> restoreBackup(
    String filePath, {
    bool replaceExisting = false,
  }) async {
    final response = await _post('backup/restore', {
      'filePath': filePath,
      'replaceExisting': replaceExisting,
    });
    return response;
  }

  /// Delete a backup
  Future<void> deleteBackup(String backupId) async {
    await _delete('backup/$backupId');
  }

  /// Get backup metadata
  Future<Map<String, dynamic>> getBackupMetadata(String backupId) async {
    final response = await _get('backup/$backupId/metadata');
    return response;
  }

  /// Download backup file bytes
  Future<Uint8List> downloadBackup(String backupId) async {
    return _downloadBytes('backup/$backupId/download');
  }

  Future<Map<String, dynamic>> uploadBackupAndRestore(
    Uint8List bytes,
    String fileName, {
    bool replaceExisting = false,
  }) async {
    return _postRaw(
      'backup/upload-restore',
      {'fileName': fileName, 'replaceExisting': replaceExisting},
      bytes,
      contentType: 'application/octet-stream',
    );
  }

  /// Read cloud-backup status from the imaging host. Cloud sync owns the host
  /// database and keyring; a remote controller must never inspect its own
  /// phone-local [SyncService] for this state.
  Future<SyncStatus> getCloudSyncStatus() async {
    final response = await _get('sync/status');
    return SyncStatus.fromJson(response);
  }

  /// Ask the imaging host to create and upload a configuration bundle now.
  Future<SyncPushResult> pushCloudSyncNow() async {
    final response = await _post('sync/push');
    if (response['status'] != 'pushed') {
      throw const FormatException(
        'POST /api/sync/push returned no pushed status',
      );
    }
    final rawTimestamp = response['timestamp'];
    if (rawTimestamp is! num) {
      throw const FormatException('POST /api/sync/push returned no timestamp');
    }
    return SyncPushResult(
      success: true,
      remotePath: response['remotePath'] as String?,
      sizeBytes: (response['sizeBytes'] as num?)?.toInt(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt()),
    );
  }

  Future<RemoteScienceBundle> getScienceSessionBundle(int sessionId) async {
    final response = await _get('science/session/$sessionId/bundle');
    return RemoteScienceBundle(
      photometry: _rowsFromJson<PhotometryMeasurementRow>(
        response['photometry'],
        PhotometryMeasurementRow.fromJson,
      ),
      calibrations: _rowsFromJson<FramePhotometricCalibrationRow>(
        response['calibrations'],
        FramePhotometricCalibrationRow.fromJson,
      ),
      transparency: _rowsFromJson<TransparencySampleRow>(
        response['transparency'],
        TransparencySampleRow.fromJson,
      ),
      psfTiles: _rowsFromJson<PsfFieldTileRow>(
        response['psfTiles'],
        PsfFieldTileRow.fromJson,
      ),
      frameQuality: _rowsFromJson<ScienceFrameQualityMetricsRow>(
        response['frameQuality'],
        ScienceFrameQualityMetricsRow.fromJson,
      ),
      tileMetrics: _rowsFromJson<ScienceTileMetricRow>(
        response['tileMetrics'],
        ScienceTileMetricRow.fromJson,
      ),
      residuals: _rowsFromJson<AstrometryResidualVectorRow>(
        response['residuals'],
        AstrometryResidualVectorRow.fromJson,
      ),
      movingObjects: _rowsFromJson<MovingObjectCandidateRow>(
        response['movingObjects'],
        MovingObjectCandidateRow.fromJson,
      ),
      lineRatios: _rowsFromJson<LineRatioProductRow>(
        response['lineRatios'],
        LineRatioProductRow.fromJson,
      ),
    );
  }

  Future<RemoteScienceBundle> getSessionlessScienceBundle() async {
    final response = await _get('science/sessionless/recent');
    return RemoteScienceBundle(
      photometry: _rowsFromJson<PhotometryMeasurementRow>(
        response['photometry'],
        PhotometryMeasurementRow.fromJson,
      ),
      calibrations: _rowsFromJson<FramePhotometricCalibrationRow>(
        response['calibrations'],
        FramePhotometricCalibrationRow.fromJson,
      ),
      transparency: _rowsFromJson<TransparencySampleRow>(
        response['transparency'],
        TransparencySampleRow.fromJson,
      ),
      psfTiles: _rowsFromJson<PsfFieldTileRow>(
        response['psfTiles'],
        PsfFieldTileRow.fromJson,
      ),
      frameQuality: _rowsFromJson<ScienceFrameQualityMetricsRow>(
        response['frameQuality'],
        ScienceFrameQualityMetricsRow.fromJson,
      ),
      tileMetrics: _rowsFromJson<ScienceTileMetricRow>(
        response['tileMetrics'],
        ScienceTileMetricRow.fromJson,
      ),
      residuals: _rowsFromJson<AstrometryResidualVectorRow>(
        response['residuals'],
        AstrometryResidualVectorRow.fromJson,
      ),
      movingObjects: _rowsFromJson<MovingObjectCandidateRow>(
        response['movingObjects'],
        MovingObjectCandidateRow.fromJson,
      ),
      lineRatios: _rowsFromJson<LineRatioProductRow>(
        response['lineRatios'],
        LineRatioProductRow.fromJson,
      ),
    );
  }

  Future<List<PhotometricTransformRow>> getPhotometricTransforms({
    int? profileId,
  }) async {
    final response = await _get(
      'science/transforms',
      profileId == null ? null : {'profileId': profileId.toString()},
    );
    return _rowsFromJson<PhotometricTransformRow>(
      response['transforms'],
      PhotometricTransformRow.fromJson,
    );
  }

  Future<List<CatalogStarMatch>> matchPhotometricCalibrationStars(
    int imageId,
  ) async {
    final response = await _post(
      'science/calibration/image/$imageId/match-stars',
      const {},
    );
    return _rowsFromJson<CatalogStarMatch>(
      response['starMatches'],
      CatalogStarMatch.fromJson,
    );
  }

  Future<PhotometricTransformCoefficients?> computePhotometricTransform({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
  }) async {
    try {
      final response = await _post('science/calibration/compute-transform', {
        'starMatches': starMatches.map((match) => match.toJson()).toList(),
        'filterName': filterName,
        if (equipmentProfileId != null)
          'equipmentProfileId': equipmentProfileId,
      });
      return PhotometricTransformCoefficients.fromJson(
        _sessionScienceObject(
          response,
          'coefficients',
          'POST /api/science/calibration/compute-transform',
        ),
      );
    } on ServerError catch (error) {
      // A valid request whose fit could not converge is the one documented
      // nullable outcome. Auth, transport, and malformed-success failures must
      // still surface to the wizard.
      if (error.httpStatus == 422) return null;
      rethrow;
    }
  }

  Future<int> savePhotometricTransform(
    PhotometricTransformCoefficients coefficients,
  ) async {
    final response = await _post('science/calibration/save-transform', {
      'coefficients': coefficients.toJson(),
    });
    return _sessionScienceNumber(
      response,
      'id',
      'POST /api/science/calibration/save-transform',
    ).toInt();
  }

  Future<Map<String, dynamic>> generateSessionLineRatios(int sessionId) async {
    return _post('science/session/$sessionId/generate-line-ratios', {});
  }

  Future<Map<String, String>> getScienceSettings() async {
    final response = await _get('science/settings');
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/science/settings',
    ).map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> updateScienceSettings(Map<String, String> settings) async {
    await _post('science/settings', {'settings': settings});
  }

  Future<Map<String, String>> getSmartNightSettings() async {
    final response = await _get('smart-night/settings');
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/smart-night/settings',
    ).map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> updateSmartNightSettings(Map<String, String> settings) async {
    await _post('smart-night/settings', {'settings': settings});
  }

  Future<ScienceSessionConfig?> getScienceSessionConfig(int sessionId) async {
    final response = await _get('science/session/$sessionId/config');
    final config = _sessionScienceNullableObject(
      response,
      'config',
      'GET /api/science/session/$sessionId/config',
    );
    return config == null ? null : ScienceSessionConfig.fromJson(config);
  }

  Future<void> updateScienceSessionConfig(
    int sessionId,
    ScienceSessionConfig config,
  ) async {
    await _post('science/session/$sessionId/config', {
      'config': config.toJson(),
    });
  }

  Future<Uint8List> exportSessionAavso(
    int sessionId, {
    required String targetStarName,
    String? filterBand,
    String? chartId,
  }) async {
    return _postRawBytes('science/session/$sessionId/export/aavso', {
      'targetStarName': targetStarName,
      if (filterBand != null && filterBand.isNotEmpty) 'filterBand': filterBand,
      if (chartId != null && chartId.isNotEmpty) 'chartId': chartId,
    });
  }

  Future<Uint8List> generateObservationReport(int sessionId) async {
    return _downloadBytes('science/session/$sessionId/report/pdf');
  }

  // Remote filesystem

  Future<RemoteDirectoryListing> browseRemoteDirectories({String? path}) async {
    final response = await _get(
      'files/browse',
      path == null || path.isEmpty ? null : {'path': path},
    );
    return RemoteDirectoryListing.fromJson(response);
  }

  Future<Map<String, dynamic>> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
  }) async {
    return _post('files/validate', {
      'path': path,
      'mustExist': mustExist,
      'mustBeWritable': mustBeWritable,
    });
  }

  int _sessionScienceRowInt(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex, {
    int? minimum,
  }) {
    final raw = json[field];
    if (raw is! num || !raw.isFinite || raw.toInt() != raw) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be a finite integer',
      );
    }
    final value = raw.toInt();
    if (minimum != null && value < minimum) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be at least $minimum',
      );
    }
    return value;
  }

  int? _sessionScienceRowNullableId(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex,
  ) {
    if (!json.containsKey(field) || json[field] == null) return null;
    return _sessionScienceRowInt(json, field, endpoint, rowIndex, minimum: 1);
  }

  double _sessionScienceRowDouble(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex, {
    double? minimum,
    double? maximum,
  }) {
    final raw = json[field];
    if (raw is! num || !raw.isFinite) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be a finite number',
      );
    }
    final value = raw.toDouble();
    if (minimum != null && value < minimum ||
        maximum != null && value > maximum) {
      final range = maximum == null
          ? 'at least $minimum'
          : minimum == null
          ? 'at most $maximum'
          : 'between $minimum and $maximum';
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be $range',
      );
    }
    return value;
  }

  DateTime _sessionScienceRowTimestamp(
    Map<String, dynamic> json,
    String endpoint,
    int rowIndex,
  ) {
    final milliseconds = _sessionScienceRowInt(
      json,
      'timestamp',
      endpoint,
      rowIndex,
      minimum: 0,
    );
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  String? _sessionScienceRowNullableString(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex,
  ) {
    if (!json.containsKey(field) || json[field] == null) return null;
    final raw = json[field];
    if (raw is! String || raw.trim().isEmpty) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be a non-empty string or null',
      );
    }
    return raw;
  }

  PsfFieldTileRow _psfFieldTileFromJson(
    Map<String, dynamic> json,
    String endpoint,
    int rowIndex,
  ) {
    return PsfFieldTileRow(
      id: _sessionScienceRowInt(json, 'id', endpoint, rowIndex, minimum: 1),
      capturedImageId: _sessionScienceRowNullableId(
        json,
        'capturedImageId',
        endpoint,
        rowIndex,
      ),
      sessionId: _sessionScienceRowNullableId(
        json,
        'sessionId',
        endpoint,
        rowIndex,
      ),
      tileRow: _sessionScienceRowInt(
        json,
        'tileRow',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      tileCol: _sessionScienceRowInt(
        json,
        'tileCol',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      starCount: _sessionScienceRowInt(
        json,
        'starCount',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      medianFwhm: _sessionScienceRowDouble(
        json,
        'medianFwhm',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      medianHfr: _sessionScienceRowDouble(
        json,
        'medianHfr',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      medianEccentricity: _sessionScienceRowDouble(
        json,
        'medianEccentricity',
        endpoint,
        rowIndex,
        minimum: 0,
        maximum: 1,
      ),
      roundness: _sessionScienceRowDouble(
        json,
        'roundness',
        endpoint,
        rowIndex,
        minimum: 0,
        maximum: 1,
      ),
      timestamp: _sessionScienceRowTimestamp(json, endpoint, rowIndex),
    );
  }

  AstrometryResidualVectorRow _residualVectorFromJson(
    Map<String, dynamic> json,
    String endpoint,
    int rowIndex,
  ) {
    return AstrometryResidualVectorRow(
      id: _sessionScienceRowInt(json, 'id', endpoint, rowIndex, minimum: 1),
      capturedImageId: _sessionScienceRowNullableId(
        json,
        'capturedImageId',
        endpoint,
        rowIndex,
      ),
      sessionId: _sessionScienceRowNullableId(
        json,
        'sessionId',
        endpoint,
        rowIndex,
      ),
      x: _sessionScienceRowDouble(json, 'x', endpoint, rowIndex, minimum: 0),
      y: _sessionScienceRowDouble(json, 'y', endpoint, rowIndex, minimum: 0),
      dxArcsec: _sessionScienceRowDouble(json, 'dxArcsec', endpoint, rowIndex),
      dyArcsec: _sessionScienceRowDouble(json, 'dyArcsec', endpoint, rowIndex),
      magnitudeArcsec: _sessionScienceRowDouble(
        json,
        'magnitudeArcsec',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      recommendationCode: _sessionScienceRowNullableString(
        json,
        'recommendationCode',
        endpoint,
        rowIndex,
      ),
      timestamp: _sessionScienceRowTimestamp(json, endpoint, rowIndex),
    );
  }
}
