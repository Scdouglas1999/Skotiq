import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/night_report.dart';
import '../../providers/database_provider.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'night_reports_dao.g.dart';

/// Reads and writes for `night_reports`: the persisted Night Doctor verdict
/// for each session (and/or target) the Smart Morning Report pipeline
/// produces.
///
/// The `findings_json` column round-trips through
/// [NightReport.decodeFindings] / [NightReport.encodeFindings], so a corrupt
/// blob degrades to an empty findings list rather than crashing a read.
@DriftAccessor(include: {'../schema/post_session.drift'})
class NightReportsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$NightReportsDaoMixin {
  NightReportsDao(super.db);

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
    return into(nightReports).insert(
      NightReportsCompanion.insert(
        sessionId: Value(sessionId),
        targetId: Value(targetId),
        score: Value(score),
        headline: Value(headline),
        findingsJson: Value(NightReport.encodeFindings(findings)),
        createdAt: toEpochSeconds(createdAt ?? DateTime.now().toUtc()),
      ),
    );
  }

  /// Fetch a report by id, or null when absent.
  Future<NightReport?> getById(int id) async {
    final row = await (select(
      nightReports,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapReport(row);
  }

  /// All reports for a given session, newest first.
  Future<List<NightReport>> getForSession(int sessionId) async {
    final rows = await _newestFirst((r) => r.sessionId.equals(sessionId)).get();
    return rows.map(_mapReport).toList();
  }

  /// All reports for a given target, newest first.
  Future<List<NightReport>> getForTarget(int targetId) async {
    final rows = await _newestFirst((r) => r.targetId.equals(targetId)).get();
    return rows.map(_mapReport).toList();
  }

  /// The most recent report for a session, or null when none exists.
  Future<NightReport?> latestForSession(int sessionId) async {
    final row = await (_newestFirst(
      (r) => r.sessionId.equals(sessionId),
    )..limit(1)).getSingleOrNull();
    return row == null ? null : _mapReport(row);
  }

  /// Delete a report by id.
  Future<int> deleteReport(int id) =>
      (delete(nightReports)..where((r) => r.id.equals(id))).go();

  SimpleSelectStatement<NightReports, NightReportRow> _newestFirst(
    Expression<bool> Function(NightReports r) filter,
  ) {
    return select(nightReports)
      ..where(filter)
      ..orderBy([
        (r) => OrderingTerm.desc(r.createdAt),
        (r) => OrderingTerm.desc(r.id),
      ]);
  }

  NightReport _mapReport(NightReportRow row) {
    return NightReport(
      sessionId: row.sessionId,
      targetId: row.targetId,
      score: row.score,
      headline: row.headline,
      findings: NightReport.decodeFindings(row.findingsJson),
      createdAt: fromEpochSeconds(row.createdAt),
    );
  }
}

/// Riverpod provider for [NightReportsDao].
final nightReportsDaoProvider = Provider<NightReportsDao>((ref) {
  return NightReportsDao(ref.watch(databaseProvider));
});
