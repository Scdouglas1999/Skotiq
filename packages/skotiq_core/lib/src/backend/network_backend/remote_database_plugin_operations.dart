part of '../network_backend.dart';

mixin _NetworkBackendRemoteDatabasePluginOperations on NetworkBackendTransport {
  /// GET /api/notes-journal?equipmentProfileId=&limit=&offset=
  Future<RemotePage<RemoteNotesJournalEntry>> fetchNotesJournal({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  }) async {
    final response = await _get(
      DbReadApi.listNotesJournal,
      query: {
        if (equipmentProfileId != null)
          'equipmentProfileId': equipmentProfileId.toString(),
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
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
      DbReadApi.createObservationLog,
      body: {
        'timestamp': timestamp.toWireTime(),
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
      maxAttempts: 1,
    );
    final id = response['id'];
    if (id is! num) {
      throw StateError('Malformed observation-log response: missing id');
    }
    return id.toInt();
  }

  /// DELETE `/api/notes-journal/<id>`.
  Future<void> deleteObservationLog(int id) =>
      _delete(DbReadApi.deleteObservationLog, path: {'id': id});

  /// DELETE /api/notes-journal
  Future<void> deleteAllObservationLogs() =>
      _delete(DbReadApi.deleteAllObservationLogs);

  // Plugin management. Methods live on NetworkBackend because the
  // FfiBackend manages plugins directly via PluginHost; the network path
  // is the only one that needs HTTP wiring.

  /// GET /api/plugins
  Future<List<RemotePluginManifest>> listPlugins() async {
    final response = await _get(PluginApi.listPlugins);
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
      PluginApi.uploadPlugin,
      query: {'filename': filename},
      bytes: Uint8List.fromList(bytes),
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
    final response = await _post(
      PluginApi.enablePlugin,
      path: {'pluginId': pluginId},
    );
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
    final response = await _post(
      PluginApi.disablePlugin,
      path: {'pluginId': pluginId},
    );
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
    await _delete(PluginApi.uninstallPlugin, path: {'pluginId': pluginId});
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
  // callers reach these through `backend.remoteHost?.logs`.

  /// Fetch the last `limit` entries from the server's in-memory ring
  /// buffer, optionally filtered by severity and source substring.
  /// Throws on transport errors (let the UI display the failure rather
}

extension _NetworkBackendRemoteDatabasePluginOperationsHelpers
    on NetworkBackendTransport {
  JournalNote _journalNoteFromMutationResponse(Map<String, dynamic> response) {
    final raw = response['note'];
    if (raw is! Map) {
      throw StateError('Malformed journal-note response: missing note');
    }
    return JournalNote.fromJson(raw.cast<String, dynamic>());
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
}
