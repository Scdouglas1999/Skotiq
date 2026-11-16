part of '../network_backend.dart';

/// The log entries and log files of a linked imaging host.
mixin HostLogs on NetworkBackendTransport {
  /// POST /api/logs/clear — delete all non-current log files on the
  /// server. Returns when the server acknowledges; the response body is
  /// the per-file status map which the desktop log viewer surfaces but
  /// the mobile log tab does not currently need.
  Future<void> clearServerLogs() async {
    await _post(LogApi.clear);
  }

  /// GET `/api/logs/files/<name>/download` — stream one full log file to
  /// [localPath]. [fileName] must be a name returned by
  /// [listServerLogFiles]; the server rejects anything that is not a
  /// skotiq log file name.
  Future<void> downloadServerLogFile(
    String fileName,
    String localPath, {
    void Function(double)? onProgress,
  }) {
    if (fileName.trim().isEmpty) {
      throw ArgumentError.value(fileName, 'fileName', 'must not be empty');
    }
    return _downloadToFile(
      LogApi.downloadFile,
      localPath,
      path: {'filename': fileName},
      onProgress: onProgress,
    );
  }

  /// GET /api/logs/recent — the host's most recent log entries. A missing or
  /// malformed payload throws instead of degrading to an empty list.
  Future<List<LogEntry>> fetchRecentServerLogs({
    int limit = 200,
    String? severityMin,
    String? categoryFilter,
  }) async {
    final query = <String, dynamic>{'limit': limit.toString()};
    if (severityMin != null && severityMin.isNotEmpty) {
      query['minSeverity'] = severityMin;
    }
    // The server doesn't yet expose a categoryFilter; we forward it as a
    // `source` substring filter when supplied so the existing handler
    // honours it. Documented here so a future server-side categoryFilter
    // can replace the source mapping without changing the call site.
    if (categoryFilter != null && categoryFilter.isNotEmpty) {
      query['source'] = categoryFilter;
    }
    final body = await _get(LogApi.recent, query: query);
    final entriesRaw = body['entries'];
    if (entriesRaw is! List) {
      // Malformed payload — surface loudly. A silent empty list would
      // make a broken server look like a quiet one.
      throw const dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message:
            'GET /api/logs/recent: missing or non-list `entries` field in '
            'response body',
      );
    }
    final out = <LogEntry>[];
    for (final raw in entriesRaw) {
      if (raw is! Map) continue;
      try {
        out.add(
          LogEntry.fromJson(
            raw.map((k, v) => MapEntry(k.toString(), v as Object?)),
          ),
        );
      } on FormatException catch (e) {
        // One bad entry must not torpedo the whole list. We log and
        // skip; the UI gets the remaining entries.
        Log.warning(
          '[NetworkBackend] fetchRecentServerLogs: dropped malformed entry: $e',
          source: 'NetworkBackend',
        );
      }
    }
    return out;
  }

  /// GET /api/logs — list the host's on-disk log files (name, size,
  /// mtime, isCurrent) so a paired device can pick one to download.
  Future<List<RemoteLogFileInfo>> listServerLogFiles() async {
    final body = await _get(LogApi.listFiles);
    final filesRaw = body['files'];
    if (filesRaw is! List) {
      // Malformed payload — surface loudly, matching fetchRecentServerLogs.
      throw const dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message:
            'GET /api/logs: missing or non-list `files` field in response '
            'body',
      );
    }
    return [
      for (final raw in filesRaw)
        if (raw is Map) RemoteLogFileInfo.fromJson(raw.cast<String, dynamic>()),
    ];
  }
}
