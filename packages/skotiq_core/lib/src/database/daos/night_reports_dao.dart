import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/night_report.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v42 `night_reports` table — the persisted Night
/// Doctor verdict for each session (and/or target) the Smart Morning Report
/// pipeline produces.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createNightReportsTable]) rather than a drift `Table`
/// class, so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customUpdate` APIs — mirroring
/// [IntegratedMastersDao]. It is deliberately NOT a `@DriftAccessor`.
///
/// SQLite errors propagate; reads map nullable columns to the model's nullable
/// fields. The `findings_json` column round-trips through
/// [NightReport.decodeFindings] / [NightReport.encodeFindings], so a corrupt
/// blob degrades to an empty findings list rather than crashing a read.
class NightReportsDao {
  NightReportsDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, session_id, target_id, score, headline, findings_json, created_at';

  /// Insert a new report row and return its id. [createdAt] defaults to "now"
  /// (UTC seconds) when omitted. [findings] is serialized to the
  /// `findings_json` column.
  Future<int> insertReport({
    int? sessionId,
    int? targetId,
    required int score,
    required String headline,
    List<NightFinding> findings = const [],
    DateTime? createdAt,
  }) {
    final now = DateTime.now().toUtc();
    return _db.customInsert(
      'INSERT INTO night_reports('
      'session_id, target_id, score, headline, findings_json, created_at'
      ') VALUES (?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(sessionId),
        Variable<int>(targetId),
        Variable<int>(score),
        Variable<String>(headline),
        Variable<String>(NightReport.encodeFindings(findings)),
        Variable<int>(_toEpochSeconds(createdAt ?? now)),
      ],
    );
  }

  /// Fetch a report by id, or null when absent.
  Future<NightReport?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM night_reports WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _mapReport(rows.first);
  }

  /// All reports for a given session, newest first.
  Future<List<NightReport>> getForSession(int sessionId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM night_reports '
          'WHERE session_id = ? ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(sessionId)],
        )
        .get();
    return rows.map(_mapReport).toList();
  }

  /// All reports for a given target, newest first.
  Future<List<NightReport>> getForTarget(int targetId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM night_reports '
          'WHERE target_id = ? ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(targetId)],
        )
        .get();
    return rows.map(_mapReport).toList();
  }

  /// The most recent report for a session, or null when none exists.
  Future<NightReport?> latestForSession(int sessionId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM night_reports '
          'WHERE session_id = ? ORDER BY created_at DESC, id DESC LIMIT 1',
          variables: [Variable<int>(sessionId)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _mapReport(rows.first);
  }

  /// Delete a report by id.
  Future<int> deleteReport(int id) {
    return _db.customUpdate(
      'DELETE FROM night_reports WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

  NightReport _mapReport(QueryRow row) {
    return NightReport(
      sessionId: row.readNullable<int>('session_id'),
      targetId: row.readNullable<int>('target_id'),
      score: row.read<int>('score'),
      headline: row.read<String>('headline'),
      findings: NightReport.decodeFindings(
        row.readNullable<String>('findings_json'),
      ),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [NightReportsDao].
final nightReportsDaoProvider = Provider<NightReportsDao>((ref) {
  return NightReportsDao(ref.watch(databaseProvider));
});
