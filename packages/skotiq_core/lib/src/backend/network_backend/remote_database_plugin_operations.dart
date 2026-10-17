part of '../network_backend.dart';

mixin _NetworkBackendRemoteDatabasePluginOperations
    on _NetworkBackendTransport {
  /// GET /api/sequence-runs?sequenceId=&limit=&offset=
  Future<RemotePage<RemoteSequenceRun>> fetchSequenceRuns({
    int? sequenceId,
    int limit = 200,
    int offset = 0,
  }) async {
    if (sequenceId != null && sequenceId <= 0) {
      throw ArgumentError.value(sequenceId, 'sequenceId', 'must be positive');
    }
    _validateReplayPageRequest(limit: limit, offset: offset);
    final response = await _get('sequence-runs', {
      if (sequenceId != null) 'sequenceId': sequenceId.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(response, RemoteSequenceRun.fromJson);
  }

  /// GET /api/notes-journal?equipmentProfileId=&limit=&offset=
  Future<RemotePage<RemoteNotesJournalEntry>> fetchNotesJournal({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _get('notes-journal', {
      if (equipmentProfileId != null)
        'equipmentProfileId': equipmentProfileId.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(response, RemoteNotesJournalEntry.fromJson);
  }

  /// POST /api/notes-journal
  Future<int> createObservationLog({
    required DateTime timestamp,
    required String objectName,
    required double ra,
    required double dec,
    String? objectType,
    String? catalogId,
    double? altitude,
    double? azimuth,
    String? notes,
    int? rating,
    int? equipmentProfileId,
    String? seeingConditions,
    String? transparency,
    String? locationName,
    double? latitude,
    double? longitude,
  }) async {
    // A create is not idempotent: retrying after an ambiguous timeout could
    // insert the same observation twice. Let the caller retry deliberately.
    final response = await _post(
      'notes-journal',
      {
        'timestamp': timestamp.toIso8601String(),
        'objectName': objectName,
        'ra': ra,
        'dec': dec,
        if (objectType != null) 'objectType': objectType,
        if (catalogId != null) 'catalogId': catalogId,
        if (altitude != null) 'altitude': altitude,
        if (azimuth != null) 'azimuth': azimuth,
        if (notes != null) 'notes': notes,
        if (rating != null) 'rating': rating,
        if (equipmentProfileId != null)
          'equipmentProfileId': equipmentProfileId,
        if (seeingConditions != null) 'seeingConditions': seeingConditions,
        if (transparency != null) 'transparency': transparency,
        if (locationName != null) 'locationName': locationName,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      },
      null,
      1,
    );
    final id = response['id'];
    if (id is! num) {
      throw StateError('Malformed observation-log response: missing id');
    }
    return id.toInt();
  }

  /// DELETE `/api/notes-journal/<id>`.
  Future<void> deleteObservationLog(int id) => _delete('notes-journal/$id');

  /// DELETE /api/notes-journal
  Future<void> deleteAllObservationLogs() => _delete('notes-journal');

  /// GET /api/db/notes?targetId=&runId=
  ///
  /// The operator's per-target / per-run journal notes (the `notes_journal`
  /// table). Distinct from [fetchNotesJournal], which despite its name serves
  /// the `observation_logs` table. With no filter it returns every note;
  /// [targetId] / [runId] scope it for the family providers.
  Future<RemotePage<RemoteJournalNote>> fetchJournalNotes({
    String? targetId,
    int? runId,
  }) async {
    final response = await _get('db/notes', {
      if (targetId != null && targetId.isNotEmpty) 'targetId': targetId,
      if (runId != null) 'runId': runId.toString(),
    });
    return RemotePage.fromJson(response, RemoteJournalNote.fromJson);
  }

  /// POST /api/db/notes
  Future<RemoteJournalNote> createJournalNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  }) async {
    // Creating a note is not idempotent because the host assigns its UUID.
    // Avoid duplicating it after an ambiguous timeout.
    final response = await _post(
      'db/notes',
      {
        'targetId': targetId,
        if (sequenceRunId != null) 'sequenceRunId': sequenceRunId,
        'body': body,
        if (title != null) 'title': title,
        'tags': tags,
        'attachments': attachments,
        if (sentiment != null) 'sentiment': sentiment,
      },
      null,
      1,
    );
    return _journalNoteFromMutationResponse(response);
  }

  /// PUT `/api/db/notes/<id>`
  Future<RemoteJournalNote> updateJournalNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  }) async {
    final response = await _put('db/notes/${Uri.encodeComponent(id)}', {
      if (body != null) 'body': body,
      if (title != null) 'title': title,
      if (tags != null) 'tags': tags,
      if (attachments != null) 'attachments': attachments,
      if (sentiment != null) 'sentiment': sentiment,
      'clearTitle': clearTitle,
      'clearSentiment': clearSentiment,
    });
    return _journalNoteFromMutationResponse(response);
  }

  /// DELETE `/api/db/notes/<id>`
  Future<void> deleteJournalNote(String id) =>
      _delete('db/notes/${Uri.encodeComponent(id)}');

  RemoteJournalNote _journalNoteFromMutationResponse(
    Map<String, dynamic> response,
  ) {
    final raw = response['note'];
    if (raw is! Map) {
      throw StateError('Malformed journal-note response: missing note');
    }
    return RemoteJournalNote.fromJson(raw.cast<String, dynamic>());
  }

  /// GET /api/guide-rms-history?sinceMs=&untilMs=&limit=&offset=
  Future<RemotePage<RemoteGuideRmsHistoryEntry>> fetchGuideRmsHistory({
    String? mountId,
    int? sinceMs,
    int? untilMs,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _get('guide-rms-history', {
      if (mountId != null && mountId.trim().isNotEmpty)
        'mountId': mountId.trim(),
      if (sinceMs != null) 'sinceMs': sinceMs.toString(),
      if (untilMs != null) 'untilMs': untilMs.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(response, RemoteGuideRmsHistoryEntry.fromJson);
  }

  /// GET /api/polar-alignment-history?equipmentProfileId=&limit=&offset=
  Future<RemotePage<RemotePolarAlignmentHistoryEntry>>
  fetchPolarAlignmentHistory({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _get('polar-alignment-history', {
      if (equipmentProfileId != null)
        'equipmentProfileId': equipmentProfileId.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(
      response,
      RemotePolarAlignmentHistoryEntry.fromJson,
    );
  }

  /// GET /api/db/dark-library?gainMin=&gainMax=&temperatureC=&exposureSecs=&limit=&offset=
  ///
  /// Returns the raw `dark_library` Drift rows. The pre-existing
  /// `listDarks()` method projects the same table through the
  /// `RemoteDarkLibraryEntry` wire model used by the calibration UI, but
  /// elides several columns (master frame path, master count) that the
  /// Read surface intentionally exposes. Hence the separate
  /// [RemoteDbDarkLibraryRow] wire type — different consumers, different
  /// shapes, no risk of one breaking the other.
  Future<RemotePage<RemoteDbDarkLibraryRow>> fetchDarkLibrary({
    int? gainMin,
    int? gainMax,
    double? temperatureC,
    double? exposureSecs,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _get('db/dark-library', {
      if (gainMin != null) 'gainMin': gainMin.toString(),
      if (gainMax != null) 'gainMax': gainMax.toString(),
      if (temperatureC != null) 'temperatureC': temperatureC.toString(),
      if (exposureSecs != null) 'exposureSecs': exposureSecs.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(response, RemoteDbDarkLibraryRow.fromJson);
  }

  /// GET /api/db/flat-history?filterName=&panelKey=&limit=&offset=
  ///
  /// Distinct from the calibration UI's `listFlats()` for the same reason
  /// the dark-library variant is — see the comment on [fetchDarkLibrary].
  Future<RemotePage<RemoteDbFlatHistoryRow>> fetchFlatHistory({
    String? filterName,
    int? panelKey,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _get('db/flat-history', {
      if (filterName != null && filterName.isNotEmpty) 'filterName': filterName,
      if (panelKey != null) 'panelKey': panelKey.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(response, RemoteDbFlatHistoryRow.fromJson);
  }

  // Replay scrubber — per-run endpoints.
  Future<RemoteSequenceRunDetail> fetchSequenceRunById(int runId) async {
    _validateReplayRunId(runId);
    final response = await _get('sequence-runs/$runId');
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

  /// Fetch the exact current and prior completed sequence snapshots needed by
  /// the run-history diff action. The host only includes these potentially
  /// large documents when explicitly requested.
  Future<RemoteSequenceRunDiffContext> fetchSequenceRunDiffContext(
    int runId,
  ) async {
    _validateReplayRunId(runId);
    final response = await _get('sequence-runs/$runId', {
      'includeDiffContext': 'true',
    });
    final raw = response['diffContext'];
    if (raw is! Map) {
      throw StateError(
        'Malformed /sequence-runs/$runId diff response: '
        'missing diffContext object',
      );
    }
    final parsed = RemoteSequenceRunDiffContext.fromJson(
      raw.cast<String, dynamic>(),
    );
    if (parsed.runId != runId) {
      throw FormatException(
        'GET /api/sequence-runs/$runId returned diff context for run '
        '${parsed.runId}',
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
    _validateReplayRunId(runId);
    _validateReplayPageRequest(limit: limit, offset: offset);
    if (sinceMs != null && sinceMs <= 0) {
      throw ArgumentError.value(sinceMs, 'sinceMs', 'must be positive');
    }
    if (untilMs != null && untilMs <= 0) {
      throw ArgumentError.value(untilMs, 'untilMs', 'must be positive');
    }
    if (sinceMs != null && untilMs != null && sinceMs > untilMs) {
      throw ArgumentError('sinceMs must not be after untilMs');
    }
    final response = await _get('sequence-runs/$runId/events', {
      if (sinceMs != null) 'since': sinceMs.toString(),
      if (untilMs != null) 'until': untilMs.toString(),
      if (severityMin != null && severityMin.isNotEmpty)
        'severityMin': severityMin,
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemoteReplayEventsPage.fromJson(response);
  }

  Future<RemotePage<RemoteReplayFrame>> fetchSequenceRunFrames(
    int runId, {
    int limit = 200,
    int offset = 0,
  }) async {
    _validateReplayRunId(runId);
    _validateReplayPageRequest(limit: limit, offset: offset);
    final response = await _get('sequence-runs/$runId/frames', {
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return RemotePage.fromJson(response, RemoteReplayFrame.fromJson);
  }

  void _validateReplayRunId(int runId) {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
  }

  void _validateReplayPageRequest({required int limit, required int offset}) {
    if (limit <= 0 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 1000');
    }
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must not be negative');
    }
  }

  // Plugin management. Methods live on NetworkBackend because the
  // FfiBackend manages plugins directly via PluginHost; the network path
  // is the only one that needs HTTP wiring.

  /// GET /api/plugins
  Future<List<RemotePluginManifest>> listPlugins() async {
    final response = await _get('plugins');
    return _rowsFromJson(response['items'], RemotePluginManifest.fromJson);
  }

  /// POST /api/plugins/upload.
  ///
  /// Current Dart AOT hosts return 501 because uploaded code cannot be loaded
  /// safely at runtime. This method remains for wire compatibility and will
  /// surface that HTTP failure rather than manufacturing an installed state.
  Future<RemotePluginManifest> uploadPlugin(
    List<int> bytes, {
    required String filename,
  }) async {
    final response = await _postRaw(
      'plugins/upload',
      {'filename': filename},
      Uint8List.fromList(bytes),
      contentType: 'application/octet-stream',
    );
    final manifest = response['manifest'];
    if (manifest is! Map) {
      throw StateError(
        'Malformed /plugins/upload response: missing manifest field',
      );
    }
    return RemotePluginManifest.fromJson(manifest.cast<String, dynamic>());
  }

  /// POST /api/plugins/{id}/enable
  Future<RemotePluginManifest> enablePlugin(String pluginId) async {
    final response = await _post('plugins/$pluginId/enable');
    final manifest = response['manifest'];
    if (manifest is! Map) {
      throw StateError(
        'Malformed /plugins/enable response: missing manifest field',
      );
    }
    return RemotePluginManifest.fromJson(manifest.cast<String, dynamic>());
  }

  /// POST /api/plugins/{id}/disable
  Future<RemotePluginManifest> disablePlugin(String pluginId) async {
    final response = await _post('plugins/$pluginId/disable');
    final manifest = response['manifest'];
    if (manifest is! Map) {
      throw StateError(
        'Malformed /plugins/disable response: missing manifest field',
      );
    }
    return RemotePluginManifest.fromJson(manifest.cast<String, dynamic>());
  }

  /// DELETE /api/plugins/{id}
  Future<void> uninstallPlugin(String pluginId) async {
    await _delete('plugins/$pluginId');
  }

  // Log tail: client surface for the headless server's
  // remote-log endpoints. Lets the mobile log tab show ENTRIES emitted on
  // the host (not just SkotiqEvents) when the backend is networked.
  //
  // Wire shapes mirror `apps/desktop/lib/headless_api/handlers/log_handlers.dart`:
  //   GET  /api/logs/recent       — JSON { entries: [...], count, totalBuffered }
  //   GET  /api/logs/tail         — SSE  `id: <iso>\nevent: log\ndata: <json>\n\n`
  //   POST /api/logs/clear        — JSON { /* server-defined; we discard */ }
  //
  // We deliberately keep these methods OUT of [SkotiqBackend]'s
  // abstract surface because the local FFI backend has no equivalent
  // remote-log concept (it consumes the LoggingService directly). UI
  // callers do an `is NetworkBackend` check before invoking these.

  /// Fetch the last `limit` entries from the server's in-memory ring
  /// buffer, optionally filtered by severity and source substring.
  /// Throws on transport errors (let the UI display the failure rather
}
