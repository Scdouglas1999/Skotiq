import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;

import '../utils/skotiq_data_directory.dart';

/// Log level for filtering
enum LogLevel { debug, info, warning, error, critical }

/// A log entry
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? source;
  final Map<String, Object?> fields;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.source,
    Map<String, Object?>? fields,
  }) : fields = Map.unmodifiable(fields ?? const {});

  @override
  String toString() {
    final levelStr = level.name.toUpperCase().padRight(8);
    final sourceStr = source != null ? '[$source] ' : '';
    final fieldsStr = fields.isEmpty ? '' : ' ${jsonEncode(_jsonSafe(fields))}';
    return '${timestamp.toIso8601String()} $levelStr $sourceStr$message$fieldsStr';
  }

  /// Stable wire schema for the headless API. Used by both
  /// `GET /api/logs/recent` (JSON list) and `GET /api/logs/tail`
  /// (Server-Sent Events `data:` lines). Optional fields are omitted
  /// when empty to keep mobile payloads tight.
  ///
  /// `severity` mirrors the LogLevel name so remote clients can filter
  /// without an integer table. `timestamp` is UTC ISO-8601 with `Z`
  /// suffix; clients localise client-side.
  Map<String, Object?> toJson() {
    final safeFields = _jsonSafe(fields);
    return {
      'timestamp': timestamp.toUtc().toIso8601String(),
      'severity': level.name,
      if (source != null) 'source': source,
      'message': message,
      if (fields.isNotEmpty) 'fields': safeFields,
    };
  }

  /// Inverse of [toJson] used by the mobile log tail client when
  /// consuming `/api/logs/recent` and `/api/logs/tail`. Unknown severity
  /// values fall back to [LogLevel.info] because the alternative — throwing
  /// — would tear down the entire tail stream on a single bad entry, which
  /// is exactly the silent-fallback failure mode we guard against
  /// for state-bearing data but is the right call here because a log
  /// entry's severity is a display hint, not a control input.
  ///
  /// Throws [FormatException] if `timestamp` is missing or unparseable
  /// (since dropping the timestamp would silently misorder entries) and
  /// if `message` is missing (since a log entry with no message is
  /// meaningless and almost certainly indicates a wire-protocol bug).
  static LogEntry fromJson(Map<String, Object?> json) {
    final tsRaw = json['timestamp'];
    if (tsRaw is! String || tsRaw.isEmpty) {
      throw const FormatException('LogEntry.fromJson: missing timestamp');
    }
    final timestamp = DateTime.tryParse(tsRaw);
    if (timestamp == null) {
      throw FormatException(
        'LogEntry.fromJson: unparseable timestamp "$tsRaw"',
      );
    }

    final messageRaw = json['message'];
    if (messageRaw is! String) {
      throw const FormatException('LogEntry.fromJson: missing message');
    }

    final severityRaw = json['severity'];
    final level = severityRaw is String
        ? (LoggingService.parseLogLevel(severityRaw) ?? LogLevel.info)
        : LogLevel.info;

    final sourceRaw = json['source'];
    final source = sourceRaw is String && sourceRaw.isNotEmpty
        ? sourceRaw
        : null;

    final fieldsRaw = json['fields'];
    final fields = fieldsRaw is Map
        ? fieldsRaw.map<String, Object?>(
            (k, v) => MapEntry(k.toString(), v as Object?),
          )
        : const <String, Object?>{};

    return LogEntry(
      timestamp: timestamp,
      level: level,
      message: messageRaw,
      source: source,
      fields: fields,
    );
  }

  static Object? _jsonSafe(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Iterable) {
      return value.map(_jsonSafe).toList(growable: false);
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _jsonSafe(entry.value),
      };
    }
    return value.toString();
  }
}

/// Base name of the rolling file this service writes its own entries to.
///
/// **Why a second file rather than the one the Rust bridge already rolls.**
/// `apiInitWithLogging(logDirectory:)` hands the log directory to
/// `tracing_appender::rolling::daily(..., "skotiq.log")`, which keeps its
/// own buffered handle open on `skotiq.log.YYYY-MM-DD` for the life of the
/// process. A second writer appending its own buffered lines into that same
/// file interleaves partial lines with the tracing writer's, and neither side
/// can be made to hold the other's lock. So the Dart entries get a sibling with
/// the same directory and the same daily rotation, and every reader of the log
/// directory — [getLogFiles], [getLogFileInfos], [exportLogs], [clearLogs] and
/// the headless download endpoint through [isSkotiqLogFileName] — takes
/// both names.
const String dartLogFileBaseName = 'skotiq-dart.log';

/// Service for managing application logs
class LoggingService {
  /// Fallback handed to [resolveSkotiqDataDirectory] when the operator
  /// has not relocated this instance. Null means "use path_provider" — the
  /// resolver owns that default so there is exactly one place that names it.
  final Future<Directory> Function()? _applicationSupportDirectoryProvider;
  final Map<String, String>? _environment;
  final void Function({String? logDirectory}) _nativeInitWithLogging;
  final void Function() _nativeInit;
  final String? Function() _currentLogFileProvider;

  String? _logDirectory;
  bool _initialized = false;
  Future<void>? _initializationFuture;
  final List<LogEntry> _recentLogs = [];
  static const int _maxRecentLogs = 1000;

  /// Broadcast stream of new log entries. Wired into every public
  /// `log()` call so remote tail clients (the headless API
  /// `/api/logs/tail` SSE endpoint) can observe the live log feed without
  /// re-reading the on-disk file.
  ///
  /// Broadcast because the headless API serves several concurrent SSE clients
  /// (operator phone, dashboard tab, mobile companion), each listening
  /// independently.
  final StreamController<LogEntry> _logEntryController =
      StreamController<LogEntry>.broadcast();
  bool _disposed = false;

  /// Append handle on today's Dart log file, and the `YYYY-MM-DD` stamp it was
  /// opened for. The stamp is what rotates the file: a line whose day differs
  /// closes this handle and opens the next day's.
  RandomAccessFile? _fileHandle;
  String? _fileHandleDay;

  /// The day a file-write refusal has already been stated for, so a disk that
  /// stays full says so once per rotation instead of once per line. Writes are
  /// still attempted every line — a share that comes back must start recording
  /// again without a restart.
  String? _refusalStatedFor;

  /// True while a file-write refusal is being logged, so the refusal's own
  /// entry does not recurse back into the writer that just refused it.
  bool _statingRefusal = false;

  LoggingService({
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    Map<String, String>? environment,
    void Function({String? logDirectory})? nativeInitWithLogging,
    void Function()? nativeInit,
    String? Function()? currentLogFileProvider,
  }) : _applicationSupportDirectoryProvider =
           applicationSupportDirectoryProvider,
       _environment = environment,
       _nativeInitWithLogging =
           nativeInitWithLogging ?? bridge_api.apiInitWithLogging,
       _nativeInit = nativeInit ?? bridge_api.apiInit,
       _currentLogFileProvider =
           currentLogFileProvider ?? bridge_api.apiGetCurrentLogFile;

  /// Initialize logging with file output
  Future<void> initialize() async {
    await ensureInitialized();
  }

  /// Ensure initialization is started exactly once.
  Future<void> ensureInitialized() {
    return _initializationFuture ??= _initializeImpl();
  }

  Future<void> _initializeImpl() async {
    if (_initialized) return;

    try {
      // Anchor logs on this process's data root, not on the platform
      // application-support folder. The support folder is shared by every
      // Skotiq on the machine, so a headless daemon started beside the GUI
      // with SKOTIQ_DATA_DIR pointed at its own tree still opened the GUI's
      // rolling log file and the two interleaved into it.
      final appDir = await resolveSkotiqDataDirectory(
        environment: _environment,
        applicationSupportDirectoryProvider:
            _applicationSupportDirectoryProvider,
      );
      _logDirectory = '${appDir.path}${Platform.pathSeparator}logs';

      // Create logs directory
      final logsDir = Directory(_logDirectory!);
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }

      // Initialize native logging with file output
      _nativeInitWithLogging(logDirectory: _logDirectory);

      _initialized = true;
      log(
        LogLevel.info,
        'Logging service initialized',
        source: 'LoggingService',
      );
      log(
        LogLevel.info,
        'Log directory: $_logDirectory',
        source: 'LoggingService',
      );
    } catch (e) {
      // Fall back to console-only logging
      try {
        _nativeInit();
      } catch (bridgeError) {
        // Why: the LoggingService runs in test harnesses where the Rust
        // bridge is not loaded — `_nativeInit` then throws because the FFI
        // entry point is unbound. We MUST NOT throw here because this is
        // the logger's own bootstrap; doing so would prevent any logging
        // from working at all. Use dart:developer (not `log(...)`) to
        // avoid recursion into the still-uninitialized service.
        developer.log(
          'Native logger init failed (likely a test without FFI): $bridgeError',
          name: 'LoggingService',
          level: 900,
        );
      }
      _initialized = true;
      log(
        LogLevel.warning,
        'File logging unavailable: $e',
        source: 'LoggingService',
      );
    }
  }

  /// Get the log directory path
  String? get logDirectory => _logDirectory;

  /// Get the current log file path
  String? get currentLogFile => _initialized ? _currentLogFileProvider() : null;

  /// Path of today's Dart log file — the one [log] appends to — or null before
  /// the data root has been resolved.
  ///
  /// Derived from the same UTC day stamp the writer rotates on, so it names the
  /// file that will be written next even before the first entry has opened it.
  String? get currentDartLogFile {
    final directory = _logDirectory;
    if (directory == null) return null;
    final day = _dayStamp(DateTime.now());
    return '$directory${Platform.pathSeparator}$dartLogFileBaseName.$day';
  }

  /// Broadcast stream of new [LogEntry] values. Emits AFTER the
  /// entry has been appended to [_recentLogs] and forwarded to the native
  /// logger, so subscribers see entries in the same order [getRecentLogs]
  /// would.
  ///
  /// Subscribers MUST tolerate dropped events when the controller is
  /// closed (via [dispose]); the stream will simply complete with
  /// `onDone`. Errors in subscriber callbacks do not affect log emission
  /// — the stream uses the default broadcast behaviour where each
  /// subscriber's onData runs in its own microtask.
  Stream<LogEntry> get logEntryStream => _logEntryController.stream;

  /// Log a message
  void log(
    LogLevel level,
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) {
    if (!_initialized) {
      unawaited(ensureInitialized());
    }

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      source: source,
      fields: fields,
    );

    // Keep recent logs in memory
    _recentLogs.add(entry);
    if (_recentLogs.length > _maxRecentLogs) {
      _recentLogs.removeAt(0);
    }

    // And on disk. The ring above holds 1000 entries, which one busy sequence
    // fills in a couple of minutes — so before this, a delivery failure at 04:00
    // was gone by the time the operator woke up, and the only log file on the
    // machine carried Rust tracing and nothing else. Written before the stream
    // fan-out and dart:developer for the same reason the fan-out precedes
    // dart:developer: the durable record is the one that must not be lost to a
    // subscriber's or the VM service's behaviour.
    _appendToFile(entry);

    // Fan out to any /api/logs/tail subscribers BEFORE forwarding
    // to dart:developer. Order matters because a subscriber that fails
    // would otherwise prevent the structured logger from getting the
    // entry; the controller add cannot synchronously throw a subscriber
    // error (broadcast subscribers run their callbacks in microtasks).
    // We guard against `isClosed` for the post-dispose() race where a
    // late log call arrives after the host has torn down the service.
    if (!_logEntryController.isClosed) {
      _logEntryController.add(entry);
    }

    // Forward to dart:developer with appropriate severity levels.
    // Level mapping: debug=300, info=500, warning=900, error=1000, critical=1200
    final int devLevel;
    switch (level) {
      case LogLevel.debug:
        devLevel = 300;
      case LogLevel.info:
        devLevel = 500;
      case LogLevel.warning:
        devLevel = 900;
      case LogLevel.error:
        devLevel = 1000;
      case LogLevel.critical:
        devLevel = 1200;
    }
    developer.log(
      entry.toString(),
      name: source ?? 'Skotiq',
      level: devLevel,
    );
  }

  /// Append one entry to today's Dart log file, rotating on the day stamp.
  ///
  /// Synchronous and unbuffered by design: `writeStringSync` on an append
  /// handle is one `write(2)`, so a line is on disk before the call returns and
  /// a process that is killed at 04:00 still leaves the line that says why. A
  /// buffered [IOSink] would lose exactly the tail a morning-after diagnosis
  /// needs.
  ///
  /// Never throws. A refused write is a fact about the disk, and raising it out
  /// of `log()` would take down whatever was merely trying to report something.
  /// It is stated once per rotation through the ring — which the Log Viewer and
  /// [exportLogs] both read — and the next line tries the disk again.
  void _appendToFile(LogEntry entry) {
    final directory = _logDirectory;
    // Before initialization resolves the data root there is no directory to
    // write into. Those entries are in the ring, and the two lines
    // [_initializeImpl] logs after resolving it are the first on disk.
    if (directory == null) return;
    // After [dispose] the handle is closed on purpose; reopening it for a late
    // entry would leak a descriptor for the rest of the process. The entry is
    // still in the ring, which is where [exportLogs] reads it — the same trade
    // the closed [_logEntryController] makes for a late subscriber.
    if (_disposed) return;

    final day = _dayStamp(entry.timestamp);
    try {
      var handle = _fileHandle;
      if (handle == null || _fileHandleDay != day) {
        handle?.closeSync();
        _fileHandle = null;
        _fileHandleDay = null;
        handle = File(
          '$directory${Platform.pathSeparator}$dartLogFileBaseName.$day',
        ).openSync(mode: FileMode.writeOnlyAppend);
        _fileHandle = handle;
        _fileHandleDay = day;
      }
      handle.writeStringSync('$entry\n');
      _refusalStatedFor = null;
    } catch (e) {
      _fileHandle = null;
      _fileHandleDay = null;
      if (_statingRefusal || _refusalStatedFor == day) return;
      _refusalStatedFor = day;
      _statingRefusal = true;
      try {
        log(
          LogLevel.error,
          'The Dart log file $dartLogFileBaseName.$day in $directory could not '
          'be written: $e. Dart log entries reach the in-app Log Viewer and the '
          'log export from memory, but nothing on disk carries them until this '
          'clears.',
          source: 'LoggingService',
        );
      } finally {
        _statingRefusal = false;
      }
    }
  }

  /// The `YYYY-MM-DD` stamp that names one day's file.
  ///
  /// UTC, because the Rust appender rolls on UTC and a reader holding both
  /// files open must not find them cut on two different midnights.
  static String _dayStamp(DateTime when) {
    final utc = when.toUtc();
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    return '${utc.year}-$month-$day';
  }

  /// Convenience methods
  void debug(String message, {String? source, Map<String, Object?>? fields}) =>
      log(LogLevel.debug, message, source: source, fields: fields);
  void info(String message, {String? source, Map<String, Object?>? fields}) =>
      log(LogLevel.info, message, source: source, fields: fields);
  void warning(
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) => log(LogLevel.warning, message, source: source, fields: fields);
  void error(String message, {String? source, Map<String, Object?>? fields}) =>
      log(LogLevel.error, message, source: source, fields: fields);
  void critical(
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) => log(LogLevel.critical, message, source: source, fields: fields);

  /// Get recent logs from memory
  List<LogEntry> getRecentLogs({LogLevel? minLevel}) {
    if (minLevel == null) return List.from(_recentLogs);
    return _recentLogs.where((e) => e.level.index >= minLevel.index).toList();
  }

  /// Get all available log files.
  ///
  /// [maxAge] bounds the result to files modified within that window. The
  /// native appender is a daily roller with no retention cap, so an install
  /// that has been running for months accumulates every day's file; a caller
  /// that promises "recent logs" must say how recent.
  Future<List<String>> getLogFiles({Duration? maxAge}) async {
    await ensureInitialized();
    if (_logDirectory == null) return [];

    try {
      final dir = Directory(_logDirectory!);
      if (!await dir.exists()) return [];

      final cutoff = maxAge == null ? null : DateTime.now().subtract(maxAge);
      final files = <String>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!_isSkotiqLogFile(entity.path)) continue;
        if (cutoff != null) {
          final modified = await entity.lastModified();
          if (modified.isBefore(cutoff)) continue;
        }
        files.add(entity.path);
      }

      files.sort(); // Chronological order
      return files;
    } catch (e) {
      // Why: log-directory enumeration can fail (read-only filesystem,
      // permission denied, sandboxed mobile path not yet created). Callers
      // (export UI, log viewer) treat `[]` as "no logs to show" which is
      // the correct degraded UX. Logged via dart:developer (not this
      // service) to avoid recursion when the failure IS the logger itself.
      developer.log(
        'getLogFiles failed: $e',
        name: 'LoggingService',
        level: 1000,
      );
      return [];
    }
  }

  static String _humanAge(Duration d) {
    if (d.inHours % 24 == 0 && d.inDays >= 1) {
      return d.inDays == 1 ? '24 hours' : '${d.inDays} days';
    }
    return '${d.inHours} hours';
  }

  /// Read a specific log file
  Future<String> readLogFile(String path) async {
    try {
      final file = File(path);
      return await file.readAsString();
    } catch (e) {
      return 'Error reading log file: $e';
    }
  }

  /// Export logs to a single file, returning the path written.
  ///
  /// [maxAge] bounds which rotated files are included. Callers that describe
  /// the result to the user as "recent log files" MUST pass one: the native
  /// appender rolls daily with no retention cap, so an unbounded export ships
  /// every day the install has ever run — every capture path, target name and
  /// host name in that history — to whoever receives the bundle.
  Future<String> exportLogs(String outputPath, {Duration? maxAge}) async {
    await ensureInitialized();
    try {
      final output = StringBuffer();
      output.writeln('=== Skotiq Log Export ===');
      output.writeln('Exported: ${DateTime.now().toIso8601String()}');
      output.writeln('Platform: ${Platform.operatingSystem}');
      output.writeln(
        maxAge == null
            ? 'Span: all retained log files'
            : 'Span: log files modified in the last ${_humanAge(maxAge)}',
      );
      output.writeln('');

      final logFiles = await getLogFiles(maxAge: maxAge);

      for (final logFile in logFiles) {
        output.writeln('\n=== $logFile ===\n');
        try {
          final content = await readLogFile(logFile);
          output.writeln(content);
        } catch (e) {
          output.writeln('Error reading file: $e');
        }
      }

      // The files above now carry the Dart entries too, but only from the
      // moment this process resolved its data root — the entries logged before
      // that exist nowhere but the ring. Append it so the export is a superset
      // of both, and so an install whose disk refused the Dart file still
      // exports what the in-app Log Viewer shows.
      output.writeln('\n=== In-memory Dart log entries ===\n');
      for (final entry in getRecentLogs()) {
        output.writeln(entry.toString());
      }

      // Write to output file
      final file = File(outputPath);
      await file.writeAsString(output.toString());

      log(
        LogLevel.info,
        'Logs exported to: $outputPath',
        source: 'LoggingService',
      );
      return outputPath;
    } catch (e) {
      throw Exception('Failed to export logs: $e');
    }
  }

  /// Get total size of all log files
  Future<int> getLogSizeBytes() async {
    await ensureInitialized();
    if (_logDirectory == null) return 0;

    try {
      final dir = Directory(_logDirectory!);
      if (!await dir.exists()) return 0;

      int totalSize = 0;
      await for (final entity in dir.list()) {
        if (entity is File && _isSkotiqLogFile(entity.path)) {
          final stat = await entity.stat();
          totalSize += stat.size;
        }
      }
      return totalSize;
    } catch (e) {
      // Why: log-directory stat can fail on read-only filesystems or when
      // a log file is rotated mid-iteration. Returning 0 degrades the
      // "log size" badge to "unknown"; the alternative — throwing —
      // would break a purely informational UI. Logged via dart:developer
      // (not this service) to avoid recursion.
      developer.log(
        'getLogSizeBytes failed: $e',
        name: 'LoggingService',
        level: 1000,
      );
      return 0;
    }
  }

  /// Clear all log files. Returns the list of deleted file paths and the
  /// total bytes freed. Neither of the two currently-open files is deleted —
  /// the native logger's, because removing it would yank the file handle out
  /// from under the tracing appender, and this service's own
  /// [dartLogFileBaseName] file, for the same reason: the append handle would
  /// keep writing into an unlinked inode nobody can read.
  ///
  /// Why a structured return rather than throwing on per-file failure:
  /// the headless POST /api/logs/clear endpoint reports per-file
  /// success/failure to the operator; surfacing the partial-progress
  /// result is more useful than a binary success bit.
  Future<ClearLogsResult> clearLogs() async {
    await ensureInitialized();
    if (_logDirectory == null) {
      return const ClearLogsResult(deletedFiles: [], freedBytes: 0, errors: []);
    }

    final deleted = <String>[];
    final errors = <String>[];
    int freedBytes = 0;

    try {
      final dir = Directory(_logDirectory!);
      if (!await dir.exists()) {
        return const ClearLogsResult(
          deletedFiles: [],
          freedBytes: 0,
          errors: [],
        );
      }

      final currentLog = currentLogFile;
      final currentDartLog = currentDartLogFile;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!_isSkotiqLogFile(entity.path)) continue;
        if (currentLog != null && entity.path == currentLog) continue;
        if (currentDartLog != null && entity.path == currentDartLog) continue;

        try {
          final size = await entity.length();
          await entity.delete();
          deleted.add(entity.path);
          freedBytes += size;
        } catch (e) {
          // Why: a single permission-denied / sharing-violation must not
          // abort the whole sweep. Record the failure and continue;
          // operators can re-issue the clear after fixing perms.
          errors.add('${entity.path}: $e');
        }
      }

      log(
        LogLevel.info,
        'Old log files cleared',
        source: 'LoggingService',
        fields: {
          'deletedCount': deleted.length,
          'freedBytes': freedBytes,
          if (errors.isNotEmpty) 'errorCount': errors.length,
        },
      );
    } catch (e) {
      log(LogLevel.error, 'Failed to clear logs: $e', source: 'LoggingService');
      errors.add('directory iteration: $e');
    }

    return ClearLogsResult(
      deletedFiles: List.unmodifiable(deleted),
      freedBytes: freedBytes,
      errors: List.unmodifiable(errors),
    );
  }

  /// Whether [path]'s leaf filename matches one of the two daily-rolling
  /// files this install writes — the Rust tracing appender's
  /// `skotiq.log[.YYYY-MM-DD]` and this service's own
  /// `skotiq-dart.log.YYYY-MM-DD` — so the public file-download
  /// endpoint cannot be coerced into returning arbitrary files in the
  /// logs directory.
  bool _isSkotiqLogFile(String path) {
    final leaf = path.split(Platform.pathSeparator).last;
    return isSkotiqLogFileName(leaf);
  }

  /// Whether [name] (a bare filename, no path) is a Skotiq
  /// rolling-log file. Exposed for the headless API which needs to
  /// validate caller-supplied filenames on `GET /api/logs/files/{name}/
  /// download`.
  static bool isSkotiqLogFileName(String name) {
    return _logFileNameRegex.hasMatch(name);
  }

  /// Matches either rolling file in the log directory: the Rust
  /// `tracing_appender::rolling::daily(..., "skotiq.log")` output — the
  /// bare `skotiq.log` handle name or a rotated
  /// `skotiq.log.YYYY-MM-DD` — and this service's own
  /// `skotiq-dart.log.YYYY-MM-DD` sibling (see [dartLogFileBaseName] for
  /// why the Dart entries need their own file). Anchored to defeat
  /// path-traversal probes (`..\\skotiq.log` would not match because
  /// the regex is anchored AND the caller pre-strips path separators —
  /// see [_validateLogFilename] in the handler).
  /// The Dart arm requires the day stamp: unlike the tracing appender, which
  /// also answers to the bare handle name, this service only ever creates
  /// `skotiq-dart.log.YYYY-MM-DD`, so a bare `skotiq-dart.log` in the
  /// directory is somebody else's file.
  static final RegExp _logFileNameRegex = RegExp(
    r'^skotiq(?:\.log(?:\.\d{4}-\d{2}-\d{2})?'
    r'|-dart\.log\.\d{4}-\d{2}-\d{2})$',
  );

  /// Return file-system metadata for every Skotiq log file
  /// on disk. The headless `/api/logs` listing renders the result
  /// directly; the GUI log viewer uses the same shape via
  /// [getLogFiles]/[readLogFile].
  ///
  /// Returns an empty list when the log directory has not been
  /// initialised or does not exist on disk yet.
  Future<List<LogFileInfo>> getLogFileInfos() async {
    await ensureInitialized();
    if (_logDirectory == null) return const [];

    try {
      final dir = Directory(_logDirectory!);
      if (!await dir.exists()) return const [];

      final infos = <LogFileInfo>[];
      final currentLog = currentLogFile;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!_isSkotiqLogFile(entity.path)) continue;

        try {
          final stat = await entity.stat();
          final name = entity.path.split(Platform.pathSeparator).last;
          infos.add(
            LogFileInfo(
              name: name,
              path: entity.path,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
              isCurrent: currentLog != null && entity.path == currentLog,
            ),
          );
        } catch (e) {
          // Mid-iteration rotation can break per-entry stat; skip the
          // affected entry and log via dart:developer (not this service)
          // to avoid recursion when the failure IS the logger itself.
          developer.log(
            'getLogFileInfos: stat failed for ${entity.path}: $e',
            name: 'LoggingService',
            level: 900,
          );
        }
      }

      infos.sort((a, b) => a.name.compareTo(b.name));
      return infos;
    } catch (e) {
      developer.log(
        'getLogFileInfos failed: $e',
        name: 'LoggingService',
        level: 1000,
      );
      return const [];
    }
  }

  /// Parse a severity name (case-insensitive) into a [LogLevel].
  /// Returns null for unknown names so callers can produce a structured
  /// 400 with the list of supported values rather than crashing.
  static LogLevel? parseLogLevel(String name) {
    final lower = name.trim().toLowerCase();
    for (final level in LogLevel.values) {
      if (level.name == lower) return level;
    }
    return null;
  }

  /// Close the broadcast stream and release pending resources.
  /// Idempotent; safe to call multiple times.
  ///
  /// Why explicit: the headless server holds long-lived SSE subscribers
  /// on `logEntryStream`. When the server unwinds in stop() they need to
  /// receive an `onDone` so their cleanup paths run (timer cancellation,
  /// socket close) rather than waiting forever on a dangling stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _fileHandle?.closeSync();
    } catch (e) {
      // The handle is being released on the way out; a close that refuses
      // changes nothing a caller can act on, and the lines already written are
      // already on disk (every write is unbuffered). Reported through
      // dart:developer rather than this service, whose stream is closing.
      developer.log(
        'Closing the Dart log file failed: $e',
        name: 'LoggingService',
        level: 900,
      );
    }
    _fileHandle = null;
    _fileHandleDay = null;
    if (!_logEntryController.isClosed) {
      await _logEntryController.close();
    }
  }
}

/// File-system metadata for a Skotiq log file. Returned by
/// [LoggingService.getLogFileInfos] and shipped over the wire by the
/// `GET /api/logs` headless endpoint.
class LogFileInfo {
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;
  final bool isCurrent;

  const LogFileInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.isCurrent,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt.toUtc().toIso8601String(),
    'isCurrent': isCurrent,
  };
}

/// Result envelope for [LoggingService.clearLogs]. Reports the
/// deleted files, total freed bytes, and any per-file errors so the
/// headless `POST /api/logs/clear` endpoint can surface partial-success
/// instead of a binary outcome.
class ClearLogsResult {
  final List<String> deletedFiles;
  final int freedBytes;
  final List<String> errors;

  const ClearLogsResult({
    required this.deletedFiles,
    required this.freedBytes,
    required this.errors,
  });

  Map<String, Object?> toJson() => {
    'deletedFiles': deletedFiles,
    'freedBytes': freedBytes,
    if (errors.isNotEmpty) 'errors': errors,
  };
}

/// Provider for the logging service
final loggingServiceProvider = Provider<LoggingService>((ref) {
  final service = LoggingService();
  unawaited(service.ensureInitialized());
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Provider that initializes logging on first access
final loggingInitializerProvider = FutureProvider<LoggingService>((ref) async {
  final service = ref.watch(loggingServiceProvider);
  await service.initialize();
  return service;
});
