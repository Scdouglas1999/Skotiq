// Remote log retrieval and tail endpoints.
//
// Exposes the on-disk + in-memory log surface over the headless API so a
// mobile operator on a Pi/embedded host can diagnose from across the LAN
// instead of SSHing into the box.
//
// Endpoints (all under /api/logs):
//
//   GET  /api/logs                       — JSON list of available log
//                                          files (name, size, mtime,
//                                          isCurrent).
//   GET  /api/logs/recent                — JSON list of the last N
//                                          entries from the
//                                          LoggingService ring buffer.
//                                          Honors limit + minSeverity
//                                          query params.
//   GET  /api/logs/files/{name}/download — Stream a specific log file
//                                          as attachment. Supports
//                                          HTTP Range (RFC 7233) so a
//                                          flaky mobile network can
//                                          resume a multi-MB log
//                                          download.
//   GET  /api/logs/tail                  — Server-Sent Events stream
//                                          tailing the live log feed.
//                                          Initial replay from the
//                                          ring buffer, then live
//                                          subscription to
//                                          LoggingService.logEntryStream.
//   POST /api/logs/clear                 — Delete every non-current
//                                          log file. Admin scope,
//                                          audit-logged.
//   POST /api/logs/test-entry            — Write a synthetic log
//                                          entry. Used by the mobile
//                                          "test notification" feature
//                                          to verify the SSE plumbing
//                                          end-to-end. Admin scope,
//                                          audit-logged.
//
// Filename safety: `download` rejects anything that contains a path
// separator, contains `..`, or does not match the daily-rolling Rust
// tracing appender's output pattern (validated via
// `LoggingService.isSkotiqLogFileName`, which anchors the regex
// `^skotiq\.log(?:\.\d{4}-\d{2}-\d{2})?$`). We additionally resolve
// the requested path and verify its parent is exactly the configured
// log directory so a symlink-into-logs trick cannot escape.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// P1-14 — Headless API handlers for log retrieval and tail.
///
/// Stateless: every request resolves the [LoggingService] from the
/// provider container so a hot-reload of the service is picked up
/// automatically. The SSE handler is the only handler that opens a
/// long-lived subscription; that subscription is bound to the request
/// stream lifecycle (cancelled on client disconnect).
class LogHandlers {
  final ProviderContainer container;

  /// Default page size for `GET /api/logs/recent` when the client does
  /// not supply `?limit=`. 200 ≈ a couple of screens on a phone log
  /// viewer; large enough to be useful, small enough to keep the
  /// payload under a typical LTE TCP window.
  static const int _defaultRecentLimit = 200;

  /// Hard upper bound on `?limit=` for `GET /api/logs/recent`.
  /// Matches the LoggingService ring buffer capacity so requesting
  /// more is pointless; we clamp rather than 400 because the operator
  /// generally wants "as much as available".
  static const int _maxRecentLimit = 1000;

  /// Default page size for SSE `?since=` replay. Matches the recent
  /// endpoint default so a phone reconnecting after a brief drop sees
  /// a consistent view regardless of which call it made first.
  static const int _defaultTailReplayLimit = 200;

  /// Heartbeat cadence on the SSE stream. 30 s is the standard
  /// "should-be-fine-everywhere" choice — long enough that the per-
  /// client byte rate is negligible, short enough that an idle proxy
  /// timeout (commonly 60 s on cellular gateways) cannot drop the
  /// connection between heartbeats.
  static const Duration _sseHeartbeatInterval = Duration(seconds: 30);

  LogHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  /// Retention window advertised by `GET /api/logs`. The Rust tracing
  /// appender (`tracing_appender::rolling::daily(...)`) does not
  /// auto-prune; deletion is operator-driven via [LoggingService.clearLogs].
  /// We expose this number so the mobile UI can render an accurate
  /// "logs are kept until you clear them" hint.
  ///
  /// 0 here means "no automatic retention". When/if the appender gains
  /// a max-files knob this becomes the configured cap.
  static const int _retentionDays = 0;

  // GET /api/logs — listing

  /// `GET /api/logs` — JSON listing of available log files.
  ///
  /// Response shape:
  /// ```json
  /// {
  ///   "files": [{"name": "...", "sizeBytes": 1234,
  ///              "modifiedAt": "2026-05-24T19:00:00Z",
  ///              "isCurrent": false}, ...],
  ///   "totalBytes": 12345,
  ///   "retentionDays": 0
  /// }
  /// ```
  Future<Response> handleListFiles(Request request) async {
    _logger.info('[API] GET /api/logs', source: 'LogHandlers');
    final infos = await _logger.getLogFileInfos();
    final total = infos.fold<int>(0, (sum, info) => sum + info.sizeBytes);
    return jsonOk({
      'files': infos.map((info) => info.toJson()).toList(growable: false),
      'totalBytes': total,
      'retentionDays': _retentionDays,
    });
  }

  // GET /api/logs/recent — ring-buffer slice

  /// `GET /api/logs/recent?limit=N&minSeverity=warning`
  ///
  /// Returns the last `limit` entries from the in-memory ring buffer,
  /// optionally filtered to entries at or above `minSeverity`.
  /// Defaults: `limit=200`, no severity filter (i.e. all entries).
  ///
  /// 400 on:
  ///   - `limit` not parseable as a positive integer.
  ///   - `minSeverity` is not one of debug/info/warning/error/critical.
  Future<Response> handleRecent(Request request) async {
    _logger.info('[API] GET /api/logs/recent', source: 'LogHandlers');
    final params = request.url.queryParameters;

    int limit = _defaultRecentLimit;
    final limitStr = params['limit'];
    if (limitStr != null && limitStr.isNotEmpty) {
      final parsed = int.tryParse(limitStr);
      if (parsed == null || parsed <= 0) {
        throw BadRequestError(
          field: 'limit',
          expected: 'positive integer',
          message: 'limit must be a positive integer',
        );
      }
      limit = parsed > _maxRecentLimit ? _maxRecentLimit : parsed;
    }

    LogLevel? minSeverity;
    final sevStr = params['minSeverity'];
    if (sevStr != null && sevStr.isNotEmpty) {
      minSeverity = LoggingService.parseLogLevel(sevStr);
      if (minSeverity == null) {
        throw BadRequestError(
          field: 'minSeverity',
          expected: 'one of: ${LogLevel.values.map((l) => l.name).join(', ')}',
          message: '$sevStr is not a valid severity name',
        );
      }
    }

    final all = _logger.getRecentLogs(minLevel: minSeverity);
    final start = all.length > limit ? all.length - limit : 0;
    final slice = all.sublist(start);

    return jsonOk({
      'entries': slice.map((e) => e.toJson()).toList(growable: false),
      'count': slice.length,
      'totalBuffered': all.length,
      if (minSeverity != null) 'minSeverity': minSeverity.name,
    });
  }

  // GET /api/logs/files/{filename}/download — single-file stream

  /// `GET /api/logs/files/{filename}/download`
  ///
  /// Streams a specific log file as attachment with RFC 7233 Range
  /// support. The filename MUST match
  /// `LoggingService.isSkotiqLogFileName`; anything else returns 403.
  ///
  /// Why 403 (not 404) for an invalid filename: 404 would let an
  /// attacker probe the directory by file name. 403 indicates that
  /// the *request* is forbidden regardless of whether the path exists.
  /// Once the filename passes validation we use 404 for the legitimate
  /// "we have no file by that name" case.
  Future<Response> handleDownloadFile(Request request, String filename) async {
    _logger.info(
      '[API] GET /api/logs/files/$filename/download',
      source: 'LogHandlers',
    );

    // Defence in depth: reject anything that looks remotely path-like
    // BEFORE running the LoggingService regex. The regex itself is
    // anchored and would reject these, but having the explicit reasons
    // recorded helps audit-log triage.
    if (filename.isEmpty ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.contains('..') ||
        filename.contains(' ')) {
      _logger.warning(
        '[API] /api/logs/files: rejected suspicious filename "$filename"',
        source: 'LogHandlers',
      );
      return jsonForbidden({
        'error': 'forbidden_filename',
        'message': 'Filename contains path separators or escape sequences',
      });
    }

    if (!LoggingService.isSkotiqLogFileName(filename)) {
      _logger.warning(
        '[API] /api/logs/files: filename "$filename" does not match log naming policy',
        source: 'LogHandlers',
      );
      return jsonForbidden({
        'error': 'forbidden_filename',
        'message': 'Filename must match skotiq.log[.YYYY-MM-DD] naming policy',
      });
    }

    final logDir = _logger.logDirectory;
    if (logDir == null) {
      // The logging service has not yet initialised — usually a test
      // harness without an app-data dir. Reported as 404 because the
      // request is well-formed; there just isn't a log file to serve.
      return jsonNotFound({
        'error': 'log_directory_unavailable',
        'message': 'Log directory has not been initialised',
      });
    }

    final candidate = File('$logDir${Platform.pathSeparator}$filename');

    // Symlink-escape guard: resolve the path and assert its parent is
    // the configured log directory. We use the realpath comparison
    // because a symlink in the logs dir pointing at /etc/passwd would
    // pass the leaf regex but resolve outside.
    String resolvedPath;
    try {
      resolvedPath = candidate.resolveSymbolicLinksSync();
    } on FileSystemException {
      // File does not exist on disk (or we can't read it) — 404.
      return jsonNotFound({
        'error': 'log_file_not_found',
        'message': 'No log file by that name',
      });
    }

    final resolvedDir = Directory(logDir).absolute.resolveSymbolicLinksSync();
    // Compare canonicalised paths. The parent of resolvedPath MUST equal
    // resolvedDir; we cannot just `startsWith` because that would let
    // `/var/log_evil/...` pass when `/var/log/` is allowed.
    final resolvedParent = File(resolvedPath).parent.absolute.path;
    if (resolvedParent != resolvedDir) {
      _logger.warning(
        '[API] /api/logs/files: rejected request — resolved path "$resolvedPath" '
        'escapes log directory "$resolvedDir"',
        source: 'LogHandlers',
      );
      return jsonForbidden({
        'error': 'forbidden_path',
        'message': 'Resolved path escapes log directory',
      });
    }

    final file = File(resolvedPath);
    if (!await file.exists()) {
      return jsonNotFound({
        'error': 'log_file_not_found',
        'message': 'No log file by that name',
      });
    }

    final int fileLength;
    final DateTime mtime;
    try {
      fileLength = await file.length();
      mtime = await file.lastModified();
    } on PathAccessException catch (e) {
      _logger.warning(
        '[API] /api/logs/files: permission denied for $filename: $e',
        source: 'LogHandlers',
      );
      return jsonForbidden({
        'error': 'permission_denied',
        'message': 'Cannot read log file',
      });
    } on FileSystemException catch (e) {
      _logger.error(
        '[API] /api/logs/files: failed to stat $filename: $e',
        source: 'LogHandlers',
      );
      return jsonInternalServerError({
        'error': 'stat_failed',
        'message': 'Failed to read log file metadata',
      });
    }

    final etag = '"$filename-${mtime.millisecondsSinceEpoch}-$fileLength"';
    final rangeHeader = request.headers['range'];
    final ifRange = request.headers['if-range'];
    final ifRangeMatches = ifRange == null || ifRange == etag;
    final shouldHonourRange = rangeHeader != null && ifRangeMatches;

    if (!shouldHonourRange) {
      return attachmentResponse(
        file.openRead(),
        fileName: filename,
        contentType: 'text/plain; charset=utf-8',
        contentLength: fileLength,
        headers: {
          'accept-ranges': 'bytes',
          'etag': etag,
          'last-modified': HttpDate.format(mtime),
        },
      );
    }

    final int rangeStart;
    final int rangeEnd;
    try {
      final parsed = parseRangeHeader(rangeHeader, fileLength);
      rangeStart = parsed.start;
      rangeEnd = parsed.end;
    } on FormatException catch (e) {
      _logger.info(
        '[API] /api/logs/files: invalid range "$rangeHeader" for $filename: ${e.message}',
        source: 'LogHandlers',
      );
      return rangeNotSatisfiableResponse(fileLength, reason: e.message);
    }

    final body = file.openRead(rangeStart, rangeEnd + 1);
    return partialContentResponse(
      body,
      start: rangeStart,
      end: rangeEnd,
      totalLength: fileLength,
      contentType: 'text/plain; charset=utf-8',
      fileName: filename,
      headers: {'etag': etag, 'last-modified': HttpDate.format(mtime)},
    );
  }

  // GET /api/logs/tail — SSE stream

  /// `GET /api/logs/tail` — Server-Sent Events stream of new log entries.
  ///
  /// Query params:
  ///   - `since=<unix-ms>` — replay entries with `timestamp >= since`
  ///     before switching to live tail. Mutually exclusive with
  ///     `Last-Event-ID` (the standard SSE resume header); if both are
  ///     present, `Last-Event-ID` wins.
  ///   - `severity=<csv>` — comma-separated allow-list filter
  ///     (e.g. `warning,error,critical`).
  ///   - `source=<substring>` — substring match against the entry's
  ///     `source` field; case-insensitive.
  ///
  /// Headers:
  ///   - `Last-Event-ID` — ISO-8601 timestamp of the last event the
  ///     client received. Used by EventSource auto-reconnect.
  ///
  /// SSE frame: `id: <iso8601>\nevent: log\ndata: <json>\n\n`.
  /// Heartbeat: `:keep-alive\n\n` every 30 s.
  Response handleTail(Request request) {
    final params = request.url.queryParameters;

    // Parse severity allow-list. An empty/missing value means "no filter".
    final Set<LogLevel> severityFilter;
    final sevParam = params['severity'];
    if (sevParam == null || sevParam.trim().isEmpty) {
      severityFilter = const {};
    } else {
      final levels = <LogLevel>{};
      for (final token in sevParam.split(',')) {
        final trimmed = token.trim();
        if (trimmed.isEmpty) continue;
        final lvl = LoggingService.parseLogLevel(trimmed);
        if (lvl == null) {
          // Bad value; surface as 400. We use HandlerFailure-free
          // BadRequestError so the standard middleware translates it.
          throw BadRequestError(
            field: 'severity',
            expected:
                'csv of: ${LogLevel.values.map((l) => l.name).join(', ')}',
            message: '"$trimmed" is not a valid severity name',
          );
        }
        levels.add(lvl);
      }
      severityFilter = levels;
    }

    final sourceFilterRaw = params['source']?.trim();
    final String? sourceFilter =
        (sourceFilterRaw == null || sourceFilterRaw.isEmpty)
        ? null
        : sourceFilterRaw.toLowerCase();

    // Resume token resolution.
    //
    //   1. Last-Event-ID header (standard SSE resume).
    //   2. `?since=` query param (initial subscription with a known
    //      starting point).
    //   3. Default: replay the last [_defaultTailReplayLimit] entries.
    DateTime? sinceCutoff;
    final lastEventId = request.headers['last-event-id']?.trim();
    if (lastEventId != null && lastEventId.isNotEmpty) {
      sinceCutoff = DateTime.tryParse(lastEventId);
      if (sinceCutoff == null) {
        _logger.warning(
          '[API] /api/logs/tail: ignored malformed Last-Event-ID "$lastEventId"',
          source: 'LogHandlers',
        );
      }
    }
    if (sinceCutoff == null) {
      final sinceParam = params['since'];
      if (sinceParam != null && sinceParam.isNotEmpty) {
        final asInt = int.tryParse(sinceParam);
        if (asInt != null) {
          sinceCutoff = DateTime.fromMillisecondsSinceEpoch(asInt);
        } else {
          sinceCutoff = DateTime.tryParse(sinceParam);
        }
        if (sinceCutoff == null) {
          throw BadRequestError(
            field: 'since',
            expected: 'unix milliseconds or ISO-8601 timestamp',
            message: '"$sinceParam" is not a parseable timestamp',
          );
        }
      }
    }

    final logger = _logger;
    final controller = StreamController<List<int>>();

    bool matches(LogEntry entry) {
      if (severityFilter.isNotEmpty && !severityFilter.contains(entry.level)) {
        return false;
      }
      if (sourceFilter != null) {
        final src = entry.source?.toLowerCase();
        if (src == null || !src.contains(sourceFilter)) return false;
      }
      return true;
    }

    void write(String s) {
      if (controller.isClosed) return;
      controller.add(utf8.encode(s));
    }

    void writeEntry(LogEntry entry) {
      // SSE id uses the ISO-8601 timestamp because the LogEntry has no
      // numeric id; this lets EventSource resume cleanly via the
      // standard Last-Event-ID mechanism.
      final id = entry.timestamp.toUtc().toIso8601String();
      final payload = jsonEncode(entry.toJson());
      write('id: $id\nevent: log\ndata: $payload\n\n');
    }

    StreamSubscription<LogEntry>? sub;
    Timer? keepAlive;

    controller.onListen = () {
      logger.info(
        '[API] /api/logs/tail: client subscribed',
        source: 'LogHandlers',
      );
      // Conservative retry hint: 5 s on disconnect. Mirrors the
      // run-watch SSE handler so client behaviour is uniform.
      write('retry: 5000\n\n');

      // 1. Initial replay from the ring buffer.
      final recent = logger.getRecentLogs();
      const replayLimit = _defaultTailReplayLimit;
      final filtered = recent.where((entry) {
        if (sinceCutoff != null && !entry.timestamp.isAfter(sinceCutoff)) {
          return false;
        }
        return matches(entry);
      }).toList();
      final start = filtered.length > replayLimit
          ? filtered.length - replayLimit
          : 0;
      for (var i = start; i < filtered.length; i++) {
        writeEntry(filtered[i]);
      }
      // Signal end-of-replay so the client can transition its UI from
      // "loading history" to "live". A custom event name is used so
      // default `message` listeners don't see it; clients that care
      // listen with `addEventListener('replay-done', ...)`.
      write('event: replay-done\ndata: {}\n\n');

      // 2. Live subscription.
      sub = logger.logEntryStream.listen(
        (entry) {
          if (controller.isClosed) return;
          if (!matches(entry)) return;
          if (sinceCutoff != null && !entry.timestamp.isAfter(sinceCutoff)) {
            return;
          }
          try {
            writeEntry(entry);
          } catch (e) {
            // Why: a single bad entry must not kill the whole stream.
            // We surface via dart:io stderr indirectly through the
            // logger but without re-entering this very stream (which
            // would loop). Using dart:async to schedule the log on
            // the next microtask is sufficient because LoggingService
            // is reentrant.
            logger.warning(
              '/api/logs/tail: failed to encode entry: $e',
              source: 'LogHandlers',
            );
          }
        },
        onError: (Object e, _) {
          logger.warning(
            '/api/logs/tail: upstream stream error: $e',
            source: 'LogHandlers',
          );
        },
        onDone: () {
          // The logger has been disposed; close the SSE stream so the
          // client knows to stop reconnecting (EventSource will retry
          // on close anyway but the `: stream-closed` comment helps
          // operators reading raw curl output understand why).
          if (!controller.isClosed) {
            write(': stream-closed\n\n');
            controller.close();
          }
        },
      );

      // 3. Heartbeat. Why a comment (`: ...`) rather than a real event:
      // SSE comments are ignored by EventSource so the client filter
      // logic doesn't see them; cellular gateways still observe the
      // bytes and reset their idle timer.
      keepAlive = Timer.periodic(_sseHeartbeatInterval, (_) {
        if (controller.isClosed) return;
        write(': keep-alive\n\n');
      });
    };

    Future<void> cleanup() async {
      keepAlive?.cancel();
      keepAlive = null;
      await sub?.cancel();
      sub = null;
      logger.info(
        '[API] /api/logs/tail: client disconnected',
        source: 'LogHandlers',
      );
    }

    controller.onCancel = cleanup;

    return streamResponse(
      controller.stream,
      contentType: 'text/event-stream; charset=utf-8',
      headers: {
        'cache-control': 'no-cache, no-transform',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  // POST /api/logs/clear — delete non-current log files

  /// `POST /api/logs/clear` — delete all non-current log files.
  /// Admin-scope + audit-logged via the route_metadata table.
  Future<Response> handleClear(Request request) async {
    _logger.warning('[API] POST /api/logs/clear', source: 'LogHandlers');
    final result = await _logger.clearLogs();
    final status = result.errors.isEmpty ? 200 : 207; // 207 = partial success
    return jsonResponse(result.toJson(), statusCode: status);
  }

  // POST /api/logs/test-entry — synthetic log emission

  /// `POST /api/logs/test-entry` — writes a synthetic log entry at the
  /// requested severity. Admin-scope + audit-logged.
  ///
  /// Body: `{severity: 'error', message: 'Test', source: 'MobileTest',
  /// fields: {...}}`. `severity` defaults to `info`, `source` defaults
  /// to `LogHandlersTest`, and `fields` is optional.
  Future<Response> handleTestEntry(Request request) async {
    _logger.info('[API] POST /api/logs/test-entry', source: 'LogHandlers');
    final payload = await readJsonObject(request);

    final severityStr = optionalString(payload, 'severity') ?? 'info';
    final level = LoggingService.parseLogLevel(severityStr);
    if (level == null) {
      throw BadRequestError(
        field: 'severity',
        expected: 'one of: ${LogLevel.values.map((l) => l.name).join(', ')}',
        message: '"$severityStr" is not a valid severity name',
      );
    }

    final message = requireString(payload, 'message');
    final source = optionalString(payload, 'source') ?? 'LogHandlersTest';

    // `fields` is a free-form map. We accept any JSON value because
    // operators may want to test arbitrary structured payloads. Type
    // coercion happens inside LoggingService's _jsonSafe.
    Map<String, Object?>? fields;
    final rawFields = payload['fields'];
    if (rawFields is Map<String, dynamic>) {
      fields = Map<String, Object?>.from(rawFields);
    } else if (rawFields != null) {
      throw BadRequestError(
        field: 'fields',
        expected: 'object',
        message: 'fields, when present, must be a JSON object',
      );
    }

    final beforeCount = _logger.getRecentLogs().length;
    _logger.log(level, message, source: source, fields: fields);

    // Read the entry back from the ring buffer so the response
    // contains the *actual* recorded entry (including the server-side
    // timestamp). The buffer write is synchronous; the entry is the
    // most-recently appended one. We additionally assert the buffer
    // length grew to surface a silent failure if log() rejected the
    // entry for any reason.
    final logs = _logger.getRecentLogs();
    if (logs.length <= beforeCount) {
      // The buffer did not grow, so the service rejected the entry. Fail the
      // request: this endpoint exists to prove the log path works, and a 200
      // here would certify plumbing that is broken.
      throw HandlerFailure(
        code: 'log_emission_failed',
        message: 'LoggingService did not record the synthetic entry',
        statusCode: 500,
      );
    }
    final entry = logs.last;
    return jsonOk({'status': 'recorded', 'entry': entry.toJson()});
  }
}
