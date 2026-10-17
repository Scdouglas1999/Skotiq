part of '../network_backend.dart';

mixin _NetworkBackendRemoteLogOperations on _NetworkBackendTransport {
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
    final body = await _get('logs/recent', query);
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
        developer.log(
          '[NetworkBackend] fetchRecentServerLogs: dropped malformed entry: $e',
          name: 'NetworkBackend',
          level: 900,
        );
      }
    }
    return out;
  }

  /// GET /api/logs — list the host's on-disk log files (name, size,
  /// mtime, isCurrent) so a paired device can pick one to download.
  Future<List<RemoteLogFileInfo>> listServerLogFiles() async {
    final body = await _get('logs');
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
      'logs/files/${Uri.encodeComponent(fileName)}/download',
      localPath,
      onProgress: onProgress,
    );
  }

  /// POST /api/logs/clear — delete all non-current log files on the
  /// server. Returns when the server acknowledges; the response body is
  /// the per-file status map which the desktop log viewer surfaces but
  /// the mobile log tab does not currently need.
  Future<void> clearServerLogs() async {
    await _post('logs/clear');
  }

  /// Open a tail subscription against `GET /api/logs/tail` (SSE). The
  /// returned stream emits one [LogEntry] per server-side log event. The
  /// stream auto-reconnects with exponential backoff on transport errors
  /// (up to a 30 s ceiling) and closes only when the consumer cancels
  /// its subscription.
  ///
  /// Why a custom HttpClient instead of [http.Client]: package:http
  /// buffers the entire response body before returning, which is the
  /// opposite of what an SSE stream needs. dart:io's HttpClient hands
  /// back a streaming response we can chunk-decode in real time.
  Stream<LogEntry> tailServerLogs({String? severityMin}) {
    final controller = StreamController<LogEntry>();
    HttpClient? client;
    HttpClientResponse? response;
    StreamSubscription<String>? sub;
    var closed = false;
    var reconnectAttempts = 0;
    Timer? reconnectTimer;
    String? lastEventId;
    late Future<void> Function() connect;

    void scheduleReconnect() {
      if (closed) return;
      sub?.cancel();
      sub = null;
      try {
        response = null;
        client?.close(force: true);
      } catch (_) {
        // close() can throw on already-disposed clients; ignore.
      }
      client = null;
      reconnectAttempts += 1;
      // Cap exponential backoff at 30 s so a long server outage doesn't
      // push the next attempt out by minutes.
      final delaySeconds = (1 << (reconnectAttempts - 1)).clamp(1, 30);
      reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
        if (!closed) unawaited(connect());
      });
    }

    connect = () async {
      if (closed) return;
      reconnectTimer?.cancel();
      reconnectTimer = null;
      final query = <String, String>{};
      if (severityMin != null && severityMin.isNotEmpty) {
        query['severity'] = severityMin;
      }
      final uri = _apiUri('logs/tail', query);
      try {
        client = HttpClient();
        final req = await client!.getUrl(uri);
        req.headers.set('accept', 'text/event-stream');
        req.headers.set('cache-control', 'no-cache');
        // Mirror _addAuthHeaders manually because the dart:io HttpClient
        // doesn't share the package:http header pipeline.
        req.headers.set(
          RemoteApiCompatibility.apiVersionHeader,
          RemoteApiCompatibility.clientApiVersion.format(),
        );
        req.headers.set(
          NetworkBackend._requestIdHeader,
          _nextRequestId('logs/tail'),
        );
        if (authToken != null && authToken!.isNotEmpty) {
          req.headers.set('Authorization', 'Bearer $authToken');
        }
        if (lastEventId != null) {
          req.headers.set('last-event-id', lastEventId!);
        }
        response = await req.close();
        if (response!.statusCode != 200) {
          throw dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.connection,
            message: 'GET /api/logs/tail returned HTTP ${response!.statusCode}',
          );
        }
        reconnectAttempts = 0;
        final buffer = StringBuffer();
        sub = response!
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (closed) return;
                if (line.isEmpty) {
                  _processSseFrame(buffer.toString(), controller, (id) {
                    lastEventId = id;
                  });
                  buffer.clear();
                  return;
                }
                // Comments (`: keep-alive`) are ignored by the SSE spec.
                if (line.startsWith(':')) return;
                buffer.writeln(line);
              },
              onError: (Object e, _) {
                if (closed) return;
                developer.log(
                  '[NetworkBackend] /api/logs/tail stream error: $e',
                  name: 'NetworkBackend',
                  level: 900,
                );
                scheduleReconnect();
              },
              onDone: () {
                if (closed) return;
                developer.log(
                  '[NetworkBackend] /api/logs/tail stream closed by server',
                  name: 'NetworkBackend',
                  level: 700,
                );
                scheduleReconnect();
              },
              cancelOnError: true,
            );
      } catch (e) {
        if (closed) return;
        developer.log(
          '[NetworkBackend] /api/logs/tail connect failed: $e',
          name: 'NetworkBackend',
          level: 900,
        );
        scheduleReconnect();
      }
    };

    controller.onListen = () => unawaited(connect());
    controller.onCancel = () async {
      closed = true;
      reconnectTimer?.cancel();
      reconnectTimer = null;
      await sub?.cancel();
      sub = null;
      try {
        client?.close(force: true);
      } catch (_) {
        // ignore — already disposed
      }
      client = null;
    };

    return controller.stream;
  }

  /// Parse one accumulated SSE frame (text lines from the same `id`/
  /// `event`/`data` block) and surface a [LogEntry] if it contains a
  /// `data:` payload with a valid log entry. Updates `onId` with the
  /// frame's `id:` value so reconnects can pass `Last-Event-ID`.
  void _processSseFrame(
    String raw,
    StreamController<LogEntry> controller,
    void Function(String id) onId,
  ) {
    if (raw.isEmpty) return;
    String? event;
    String? id;
    final data = StringBuffer();
    for (final line in raw.split('\n')) {
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final field = line.substring(0, colon);
      var value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
          break;
        case 'id':
          id = value;
          break;
        case 'data':
          if (data.isNotEmpty) data.write('\n');
          data.write(value);
          break;
        case 'retry':
          // We honour the server's reconnect retry hint by NOT overriding
          // our exponential backoff with it — the server's 5 s suggestion
          // is fine as a floor but our backoff already starts at 1 s and
          // climbs from there, which is safer under sustained failure.
          break;
      }
    }
    if (id != null) onId(id);
    // The server emits `event: replay-done` as a marker (no log entry);
    // skip it without surfacing.
    if (event == 'replay-done') return;
    final dataStr = data.toString();
    if (dataStr.isEmpty) return;
    try {
      final decoded = jsonDecode(dataStr);
      if (decoded is! Map) return;
      final entry = LogEntry.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v as Object?)),
      );
      if (!controller.isClosed) controller.add(entry);
    } on FormatException catch (e) {
      developer.log(
        '[NetworkBackend] /api/logs/tail: dropped malformed entry: $e',
        name: 'NetworkBackend',
        level: 900,
      );
    } catch (e) {
      developer.log(
        '[NetworkBackend] /api/logs/tail: decode error: $e',
        name: 'NetworkBackend',
        level: 900,
      );
    }
  }
}
