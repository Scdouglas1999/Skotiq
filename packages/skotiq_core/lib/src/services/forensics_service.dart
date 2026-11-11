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

import 'package:drift/drift.dart' show Value;
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

    await _db.frameForensicsDao.insertRecord(
      FrameForensicsCompanion.insert(
        id: id,
        capturedImageId: Value(capturedImageId),
        sessionId: Value(sessionId),
        sequenceRunId: Value(sequenceRunId),
        nodeId: Value(nodeId),
        frameIndex: frameIndex,
        totalFrames: totalFrames,
        rejectPath: rejectPath,
        reason: reason,
        likelyCause: Value(cause.label),
        evidenceJson: Value(evidenceJson),
        environmentJson: Value(environmentJson),
        hfr: Value(hfr),
        eccentricity: Value(eccentricity),
        starCount: Value(starCount),
        createdAt: now.millisecondsSinceEpoch ~/ 1000,
      ),
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
    final rows = await _db.frameForensicsDao.recentForSession(sessionId, limit);
    return rows.map(_toRecord).toList();
  }

  /// Fetch every record for a given `sequence_runs.id`. Used by the
  /// post-session report.
  Future<List<FrameForensicsRecord>> loadForSequenceRun(
    int sequenceRunId,
  ) async {
    final rows = await _db.frameForensicsDao.forSequenceRun(sequenceRunId);
    return rows.map(_toRecord).toList();
  }

  /// Fetch the newest forensic record tied to a captured image id.
  /// Used by Replay Debug rows to jump straight from a FrameRejected
  /// decision to the Frame Detail dialog.
  Future<FrameForensicsRecord?> loadForCapturedImage(
    int capturedImageId,
  ) async {
    final row = await _db.frameForensicsDao.newestForCapturedImage(
      capturedImageId,
    );
    return row == null ? null : _toRecord(row);
  }

  /// Filter records by classified cause (used by the "Show me all
  /// CloudPassage rejections" link).
  Future<List<FrameForensicsRecord>> loadByCause(
    LikelyCause cause, {
    int? sequenceRunId,
    int limit = 200,
  }) async {
    final rows = await _db.frameForensicsDao.byCause(
      cause.label,
      sequenceRunId: sequenceRunId,
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  static FrameForensicsRecord _toRecord(FrameForensicsRow row) =>
      FrameForensicsRecord.fromRow({
        'id': row.id,
        'captured_image_id': row.capturedImageId,
        'session_id': row.sessionId,
        'sequence_run_id': row.sequenceRunId,
        'node_id': row.nodeId,
        'frame_index': row.frameIndex,
        'total_frames': row.totalFrames,
        'reject_path': row.rejectPath,
        'reason': row.reason,
        'likely_cause': row.likelyCause,
        'evidence_json': row.evidenceJson,
        'environment_json': row.environmentJson,
        'hfr': row.hfr,
        'eccentricity': row.eccentricity,
        'star_count': row.starCount,
        'created_at': row.createdAt,
      });

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

  Future<void> dispose() async {
    if (!_broadcast.isClosed) {
      await _broadcast.close();
    }
  }
}
