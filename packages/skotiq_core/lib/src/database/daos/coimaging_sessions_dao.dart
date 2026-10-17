import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/database_provider.dart';
import '../database.dart';
import '../tables/coimaging_sessions.dart';

part 'coimaging_sessions_dao.g.dart';

/// Data access for [CoImagingSessions] — live co-imaging session membership.
///
/// One membership row per `(hubKey, sessionId)`. Writers funnel through
/// [_upsert], which keys on the unique `(hubKey, sessionId)` index and only
/// overwrites the fields a given concern owns — so a progress update (frames /
/// integration) does not clobber the assigned framing offset and vice versa,
/// mirroring [ConstellationContributionsDao]'s discipline.
@DriftAccessor(tables: [CoImagingSessions])
class CoImagingSessionsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$CoImagingSessionsDaoMixin {
  CoImagingSessionsDao(super.db);

  /// The membership row for [sessionId] at [hubKey], or null when not joined.
  Future<CoImagingSessionRow?> getSession(String hubKey, String sessionId) {
    return _byKey(hubKey, sessionId).getSingleOrNull();
  }

  /// Every membership row at [hubKey] (rehydrates the co-imaging view for a hub
  /// without a live round-trip).
  Future<List<CoImagingSessionRow>> getAllForHub(String hubKey) {
    return (select(
      coImagingSessions,
    )..where((s) => s.hubKey.equals(hubKey))).get();
  }

  /// Every session this rig still considers itself an active participant of,
  /// across all hubs (newest-joined first).
  Future<List<CoImagingSessionRow>> getActiveSessions() {
    return (select(coImagingSessions)
          ..where((s) => s.active.equals(true))
          ..orderBy([(s) => OrderingTerm.desc(s.joinedAt)]))
        .get();
  }

  /// Record (or refresh) this rig's membership after a successful JOIN. The
  /// hub-assigned framing offset slot + the membership token land here; progress
  /// tallies are left untouched (use [updateProgress]).
  Future<void> upsertMembership(
    String hubKey,
    String sessionId, {
    String? targetName,
    double? targetRaDeg,
    double? targetDecDeg,
    String? role,
    String? claimToken,
    int? framingOffsetIndex,
    double? framingOffsetRaArcsec,
    double? framingOffsetDecArcsec,
    bool? active,
  }) {
    return _upsert(
      hubKey,
      sessionId,
      CoImagingSessionsCompanion(
        targetName: targetName == null
            ? const Value.absent()
            : Value(targetName),
        targetRaDeg: targetRaDeg == null
            ? const Value.absent()
            : Value(targetRaDeg),
        targetDecDeg: targetDecDeg == null
            ? const Value.absent()
            : Value(targetDecDeg),
        role: role == null ? const Value.absent() : Value(role),
        claimToken: claimToken == null
            ? const Value.absent()
            : Value(claimToken),
        framingOffsetIndex: framingOffsetIndex == null
            ? const Value.absent()
            : Value(framingOffsetIndex),
        framingOffsetRaArcsec: framingOffsetRaArcsec == null
            ? const Value.absent()
            : Value(framingOffsetRaArcsec),
        framingOffsetDecArcsec: framingOffsetDecArcsec == null
            ? const Value.absent()
            : Value(framingOffsetDecArcsec),
        active: active == null ? const Value.absent() : Value(active),
      ),
    );
  }

  /// Advance this rig's cumulative contribution tallies for the session. The
  /// membership identity / framing offset are untouched.
  Future<void> updateProgress(
    String hubKey,
    String sessionId, {
    required int contributedFrames,
    required double contributedIntegrationSeconds,
  }) {
    return _upsert(
      hubKey,
      sessionId,
      CoImagingSessionsCompanion(
        contributedFrames: Value(contributedFrames),
        contributedIntegrationSeconds: Value(contributedIntegrationSeconds),
      ),
    );
  }

  /// Mark the membership inactive (rig left, or the hub reported the session
  /// closed). Kept as a row so attribution + history survive.
  Future<void> markInactive(String hubKey, String sessionId) {
    return _upsert(
      hubKey,
      sessionId,
      const CoImagingSessionsCompanion(active: Value(false)),
    );
  }

  /// Delete the membership row for [sessionId] at [hubKey].
  Future<int> deleteSession(String hubKey, String sessionId) {
    return (delete(coImagingSessions)..where(
          (s) => s.hubKey.equals(hubKey) & s.sessionId.equals(sessionId),
        ))
        .go();
  }

  SimpleSelectStatement<$CoImagingSessionsTable, CoImagingSessionRow> _byKey(
    String hubKey,
    String sessionId,
  ) {
    return select(coImagingSessions)
      ..where((s) => s.hubKey.equals(hubKey) & s.sessionId.equals(sessionId))
      ..limit(1);
  }

  /// Keyed update-or-insert that touches only the fields present in [patch],
  /// always refreshing [CoImagingSessions.updatedAt].
  Future<void> _upsert(
    String hubKey,
    String sessionId,
    CoImagingSessionsCompanion patch,
  ) {
    return transaction(() async {
      final existing = await _byKey(hubKey, sessionId).getSingleOrNull();
      final stamped = patch.copyWith(updatedAt: Value(DateTime.now()));
      if (existing != null) {
        await (update(
          coImagingSessions,
        )..where((s) => s.id.equals(existing.id))).write(stamped);
        return;
      }
      await into(coImagingSessions).insert(
        stamped.copyWith(hubKey: Value(hubKey), sessionId: Value(sessionId)),
      );
    });
  }
}

/// Riverpod provider for [CoImagingSessionsDao].
final coImagingSessionsDaoProvider = Provider<CoImagingSessionsDao>((ref) {
  return CoImagingSessionsDao(ref.watch(databaseProvider));
});
