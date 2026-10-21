/// Keeps every Darkroom pass's [PassLog]: live in memory while it runs, on
/// disk as a record once it reports anything, so a finished pass reads back
/// exactly as it was drawn while it ran.
///
/// Native reports arrive as `IntegrationTelemetry` events on the backend's
/// event stream; Dart services add theirs through [PassReporter]. Records go
/// to `<base>/passes/<run>.json`, with the run's preview PNGs in
/// `<base>/passes/<run>/`. When a pass ends, its seconds per stage are kept in
/// `<base>/passes/rates.json` to estimate the next pass before it has
/// measured anything.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/backend/event_types.dart';
import 'pass_log.dart';
import 'pass_timeline.dart';

/// One pass on disk, for a list.
class PassRecordSummary {
  const PassRecordSummary({
    required this.runId,
    required this.path,
    required this.startedAt,
    required this.ended,
    this.target,
    this.sessionId,
    this.failure,
  });

  final String runId;
  final String path;
  final DateTime startedAt;
  final bool ended;
  final String? target;
  final int? sessionId;
  final String? failure;
}

class DarkroomPassRecorder implements PassReporter {
  DarkroomPassRecorder({
    required Stream<SkotiqEvent> events,
    required Future<String> Function() baseDirectory,
    DateTime Function()? clock,
    Duration saveDelay = const Duration(seconds: 2),
  }) : _baseDirectory = baseDirectory,
       _clock = clock ?? DateTime.now,
       _saveDelay = saveDelay {
    _subscription = events.listen(_onEvent);
  }

  /// Follow [events] instead of the stream given at construction, for a
  /// backend that was replaced while the app runs.
  void listenTo(Stream<SkotiqEvent> events) {
    unawaited(_subscription.cancel());
    _subscription = events.listen(_onEvent);
  }

  final Future<String> Function() _baseDirectory;
  final DateTime Function() _clock;
  final Duration _saveDelay;
  late StreamSubscription<SkotiqEvent> _subscription;

  final Map<String, PassLog> _logs = <String, PassLog>{};
  final Map<int, String> _sessionRuns = <int, String>{};
  final Map<String, Timer> _pendingSaves = <String, Timer>{};
  final StreamController<String> _changes =
      StreamController<String>.broadcast();
  Map<String, double>? _rates;

  /// The run id of each report as it lands.
  Stream<String> get changes => _changes.stream;

  /// The live (in-memory) log of [runId], or null.
  PassLog? live(String runId) => _logs[runId];

  /// The run ids of passes that have not reported their end.
  List<String> get running => <String>[
    for (final e in _logs.entries)
      if (!e.value.ended) e.key,
  ];

  void _onEvent(SkotiqEvent event) {
    if (event.category != EventCategory.imaging ||
        event.eventType != 'IntegrationTelemetry') {
      return;
    }
    final runId = event.data['run_id'];
    final kind = event.data['kind'];
    if (runId is! String || runId.isEmpty || kind is! String) return;
    final detail = event.data['detail'];
    _append(
      runId,
      PassLogEntry(
        t: event.timestamp,
        kind: kind,
        detail: detail is Map ? Map<String, dynamic>.from(detail) : const {},
      ),
    );
  }

  void _append(String runId, PassLogEntry entry) {
    if (_changes.isClosed) return;
    final log = _logs.putIfAbsent(runId, () => PassLog(runId: runId));
    log.entries.add(entry);
    if (entry.kind == PassKinds.passPlanned) {
      final session = (entry.detail['sessionId'] as num?)?.toInt();
      if (session != null) _sessionRuns[session] = runId;
    }
    _changes.add(runId);
    if (entry.kind == PassKinds.passEnded) {
      unawaited(_save(runId, finished: true));
    } else {
      _pendingSaves[runId] ??= Timer(_saveDelay, () => unawaited(_save(runId)));
    }
  }

  @override
  void report(String runId, String kind, [Map<String, dynamic>? detail]) {
    _append(
      runId,
      PassLogEntry(
        t: _clock().millisecondsSinceEpoch,
        kind: kind,
        detail: detail ?? const <String, dynamic>{},
      ),
    );
  }

  @override
  void reportForSession(
    int sessionId,
    String kind, [
    Map<String, dynamic>? detail,
  ]) {
    var runId = _sessionRuns[sessionId];
    if (runId == null || (_logs[runId]?.ended ?? true)) {
      runId = 'darkroom-$sessionId-${_clock().millisecondsSinceEpoch}';
      report(runId, PassKinds.passPlanned, <String, dynamic>{
        'sessionId': sessionId,
        'lanes': const <Object>[],
      });
    }
    report(runId, kind, detail);
  }

  @override
  String? runningForSession(int sessionId) {
    final runId = _sessionRuns[sessionId];
    if (runId == null) return null;
    return (_logs[runId]?.ended ?? true) ? null : runId;
  }

  Future<Directory> _passesDirectory() async {
    final dir = Directory(p.join(await _baseDirectory(), 'passes'));
    await dir.create(recursive: true);
    return dir;
  }

  static String _fileStem(String runId) =>
      runId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  @override
  Future<String?> previewDir(String runId) async {
    try {
      final dir = Directory(
        p.join((await _passesDirectory()).path, _fileStem(runId)),
      );
      await dir.create(recursive: true);
      return dir.path;
    } on Object {
      return null;
    }
  }

  Future<void> _save(String runId, {bool finished = false}) async {
    _pendingSaves.remove(runId)?.cancel();
    final log = _logs[runId];
    if (log == null || log.entries.isEmpty) return;
    try {
      final dir = await _passesDirectory();
      final file = File(p.join(dir.path, '${_fileStem(runId)}.json'));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(log.toJson()), flush: true);
      await tmp.rename(file.path);
      if (finished) {
        final rates = PassTimeline.fromLog(log).stageRates();
        if (rates.isNotEmpty) {
          final merged = <String, double>{...await storedRates(), ...rates};
          _rates = merged;
          await File(
            p.join(dir.path, 'rates.json'),
          ).writeAsString(jsonEncode(merged), flush: true);
        }
      }
    } on Object {
      // A record that cannot be written never stops the pass it describes;
      // the live view keeps working from memory and the write is retried at
      // the next report.
    }
  }

  /// Seconds per stage from the last finished passes.
  Future<Map<String, double>> storedRates() async {
    final cached = _rates;
    if (cached != null) return cached;
    try {
      final file = File(p.join((await _passesDirectory()).path, 'rates.json'));
      if (!await file.exists()) return _rates = const <String, double>{};
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return _rates = const <String, double>{};
      return _rates = <String, double>{
        for (final e in raw.entries)
          if (e.value is num) '${e.key}': (e.value as num).toDouble(),
      };
    } on Object {
      return _rates = const <String, double>{};
    }
  }

  /// Every recorded pass, newest first. A running pass is listed from memory.
  Future<List<PassRecordSummary>> records() async {
    final out = <String, PassRecordSummary>{};
    try {
      final dir = await _passesDirectory();
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        if (p.basename(entity.path) == 'rates.json') continue;
        final log = await _read(entity.path);
        if (log == null) continue;
        out[log.runId] = _summary(log, entity.path);
      }
    } on Object {
      // Listed from memory only.
    }
    for (final log in _logs.values) {
      out[log.runId] = _summary(log, out[log.runId]?.path ?? '');
    }
    final list = out.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  PassRecordSummary _summary(PassLog log, String path) {
    final ended = log.entries
        .where((e) => e.kind == PassKinds.passEnded)
        .lastOrNull;
    return PassRecordSummary(
      runId: log.runId,
      path: path,
      startedAt: DateTime.fromMillisecondsSinceEpoch(log.startedAt ?? 0),
      ended: ended != null,
      target: log.target,
      sessionId: log.sessionId,
      failure: ended?.detail['ok'] == false
          ? '${ended?.detail['error']}'
          : null,
    );
  }

  /// The log of [runId]: live when it is in memory, else from its record.
  Future<PassLog?> load(String runId) async {
    final live = _logs[runId];
    if (live != null) return live;
    try {
      final dir = await _passesDirectory();
      return _read(p.join(dir.path, '${_fileStem(runId)}.json'));
    } on Object {
      return null;
    }
  }

  Future<PassLog?> _read(String path) async {
    try {
      return PassLog.fromJson(jsonDecode(await File(path).readAsString()));
    } on Object {
      return null;
    }
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    for (final runId in _pendingSaves.keys.toList()) {
      await _save(runId);
    }
    await _changes.close();
  }
}
