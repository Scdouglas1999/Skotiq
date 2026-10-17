/// Frame-Failure Forensics: Dart-side persistence + event
/// aggregation service.
///
/// The Rust sequencer classifies each rejection (via
/// `skotiq_sequencer::quality::analyze_rejection`) and attaches the
/// verdict + evidence + environment snapshot to the
/// `SequencerEvent::FrameRejected` payload. This service:
///
/// 1. Listens to those events (via [recordRejection]).
/// 2. Persists a row to the `frame_forensics` table (schema v32).
/// 3. Re-emits the typed [FrameForensicsRecord] on a broadcast stream
///    consumed by the Run Dashboard's Forensics panel and Frame Detail
///    dialog.
///
/// The service is deliberately read/write-coupled to the database so a
/// crash mid-run never loses the verdict; the broadcast stream is
/// strictly observational.

library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/database.dart';
import '../models/forensics/frame_forensics.dart';

class ForensicsService {
  ForensicsService(this._db);

  final SkotiqDatabase _db;
  static const _uuid = Uuid();
  final StreamController<FrameForensicsRecord> _broadcast =
      StreamController<FrameForensicsRecord>.broadcast();

  /// Stream of every record this service has persisted since startup.
  /// Subscribers (the dashboard panel) attach late but only see future
  /// events — the panel's initial render uses [loadRecentForSession] or
  /// [loadForSequenceRun] to backfill from the database.
  Stream<FrameForensicsRecord> get stream => _broadcast.stream;

  /// Persist one forensic record. Returns the persisted record (including
  /// the freshly minted UUID + createdAt).
  ///
  /// `causeLabel` is the Rust-side wire-stable snake_case label
  /// (`LikelyCause.label`); pass `null` when the classifier did not
  /// run.
  Future<FrameForensicsRecord> recordRejection({
    int? capturedImageId,
    String? sessionId,
    int? sequenceRunId,
    String? nodeId,
    required int frameIndex,
    required int totalFrames,
    required String rejectPath,
    required String reason,
    String? causeLabel,
    List<String> evidence = const <String>[],
    ForensicEnvironment environment = const ForensicEnvironment(),
    double? hfr,
    double? eccentricity,
    int? starCount,
  }) async {
    final id = _uuid.v4();
    final cause = LikelyCauseExt.fromLabel(causeLabel) ?? LikelyCause.unknown;
    final now = DateTime.now().toUtc();
    final evidenceJson = jsonEncode(evidence);
    final environmentJson = jsonEncode(environment.toJson());

    await _db.customStatement(
      'INSERT INTO frame_forensics ('
      'id, captured_image_id, session_id, sequence_run_id, node_id, '
      'frame_index, total_frames, reject_path, reason, likely_cause, '
      'evidence_json, environment_json, hfr, eccentricity, star_count, '
      'created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        capturedImageId,
        sessionId,
        sequenceRunId,
        nodeId,
        frameIndex,
        totalFrames,
        rejectPath,
        reason,
        cause.label,
        evidenceJson,
        environmentJson,
        hfr,
        eccentricity,
        starCount,
        now.millisecondsSinceEpoch ~/ 1000,
      ],
    );

    final record = FrameForensicsRecord(
      id: id,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      sequenceRunId: sequenceRunId,
      nodeId: nodeId,
      frameIndex: frameIndex,
      totalFrames: totalFrames,
      rejectPath: rejectPath,
      reason: reason,
      likelyCause: cause,
      evidence: List<String>.unmodifiable(evidence),
      environment: environment,
      hfr: hfr,
      eccentricity: eccentricity,
      starCount: starCount,
      createdAt: now,
    );
    if (!_broadcast.isClosed) {
      _broadcast.add(record);
    }
    return record;
  }

  /// Fetch the most recent N records for a given session. Returns
  /// newest-first.
  Future<List<FrameForensicsRecord>> loadRecentForSession(
    String sessionId, {
    int limit = 50,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM frame_forensics WHERE session_id = ? '
          'ORDER BY created_at DESC LIMIT ?',
          variables: [Variable<String>(sessionId), Variable<int>(limit)],
        )
        .get();
    return rows.map((r) => FrameForensicsRecord.fromRow(r.data)).toList();
  }

  /// Fetch every record for a given `sequence_runs.id`. Used by the
  /// post-session report.
  Future<List<FrameForensicsRecord>> loadForSequenceRun(
    int sequenceRunId,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM frame_forensics WHERE sequence_run_id = ? '
          'ORDER BY created_at ASC',
          variables: [Variable<int>(sequenceRunId)],
        )
        .get();
    return rows.map((r) => FrameForensicsRecord.fromRow(r.data)).toList();
  }

  /// Fetch the newest forensic record tied to a captured image id.
  /// Used by Replay Debug rows to jump straight from a FrameRejected
  /// decision to the Frame Detail dialog.
  Future<FrameForensicsRecord?> loadForCapturedImage(
    int capturedImageId,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM frame_forensics WHERE captured_image_id = ? '
          'ORDER BY created_at DESC LIMIT 1',
          variables: [Variable<int>(capturedImageId)],
        )
        .get();
    if (rows.isEmpty) return null;
    return FrameForensicsRecord.fromRow(rows.first.data);
  }

  /// Filter records by classified cause (used by the "Show me all
  /// CloudPassage rejections" link).
  Future<List<FrameForensicsRecord>> loadByCause(
    LikelyCause cause, {
    int? sequenceRunId,
    int limit = 200,
  }) async {
    final filter = StringBuffer('likely_cause = ?');
    final vars = <Variable<Object>>[Variable<String>(cause.label)];
    if (sequenceRunId != null) {
      filter.write(' AND sequence_run_id = ?');
      vars.add(Variable<int>(sequenceRunId));
    }
    vars.add(Variable<int>(limit));
    final rows = await _db
        .customSelect(
          'SELECT * FROM frame_forensics WHERE $filter '
          'ORDER BY created_at DESC LIMIT ?',
          variables: vars,
        )
        .get();
    return rows.map((r) => FrameForensicsRecord.fromRow(r.data)).toList();
  }

  /// Build a summary for the given records grouped by cause.
  static ForensicSummary summarize(Iterable<FrameForensicsRecord> records) {
    final counts = <LikelyCause, int>{};
    DateTime? first;
    DateTime? last;
    var total = 0;
    for (final r in records) {
      total++;
      counts.update(r.likelyCause, (v) => v + 1, ifAbsent: () => 1);
      if (first == null || r.createdAt.isBefore(first)) first = r.createdAt;
      if (last == null || r.createdAt.isAfter(last)) last = r.createdAt;
    }
    return ForensicSummary(
      countsByCause: counts,
      total: total,
      firstAt: first,
      lastAt: last,
    );
  }

  /// Synchronously build a summary for a single sequence run by going to
  /// the database.
  Future<ForensicSummary> summarizeForSequenceRun(int sequenceRunId) async {
    final records = await loadForSequenceRun(sequenceRunId);
    return summarize(records);
  }

  Future<void> dispose() async {
    if (!_broadcast.isClosed) {
      await _broadcast.close();
    }
  }
}
