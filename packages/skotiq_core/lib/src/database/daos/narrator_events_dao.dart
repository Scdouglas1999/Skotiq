import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/narrator_events.dart';

part 'narrator_events_dao.g.dart';

/// Data access for [NarratorEvents] — persistence + the DB-watch streams the
/// feed providers expose. Feeds are **pinned-first, then newest-first** so a
/// pinned discovery bubbles to the top of every surface while everything else
/// reads as a reverse-chronological story of the night.
@DriftAccessor(tables: [NarratorEvents])
class NarratorEventsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$NarratorEventsDaoMixin {
  NarratorEventsDao(super.db);

  /// Insert an accepted event. The engine has already enforced dedupe +
  /// cooldown, so callers do not need to check for duplicates here.
  Future<int> insertEvent(NarratorEventsCompanion event) {
    return into(narratorEvents).insert(event);
  }

  /// How far back a SESSIONLESS dedupe check looks.
  ///
  /// A session-scoped check needs no window: every night gets a fresh session
  /// id, so last night's keys cannot suppress tonight's. The sessionless bucket
  /// has no such boundary — `sessionId IS NULL` matches every hand-driven frame
  /// ever recorded — so without a window a static-key detector
  /// (`conditions.excellent`, `conditions.sky_darkness.darker`,
  /// `milestone.calibration_locked`, `milestone.limiting_mag.first`) fires once
  /// per install and is silent on every later night. One observing night is the
  /// natural boundary, and 12 hours covers the longest of them while still
  /// separating consecutive nights.
  static const Duration sessionlessDedupeWindow = Duration(hours: 12);

  /// Whether an event with [dedupeKey] already exists for [sessionId] (null =
  /// sessionless). Lets the service survive a restart without re-emitting an
  /// event the engine's in-memory dedupe set has forgotten.
  Future<bool> hasDedupeKey(int? sessionId, String dedupeKey) async {
    final query = selectOnly(narratorEvents)
      ..addColumns([narratorEvents.id])
      ..where(narratorEvents.dedupeKey.equals(dedupeKey))
      ..limit(1);
    if (sessionId == null) {
      query.where(
        narratorEvents.sessionId.isNull() &
            narratorEvents.timestamp.isBiggerOrEqualValue(
              DateTime.now().subtract(sessionlessDedupeWindow),
            ),
      );
    } else {
      query.where(narratorEvents.sessionId.equals(sessionId));
    }
    final row = await query.getSingleOrNull();
    return row != null;
  }

  /// All dedupe keys already persisted for [sessionId] (null = sessionless).
  /// Used to seed the engine's dedupe set on (re)attach.
  ///
  /// The sessionless case is bounded by [sessionlessDedupeWindow] for the same
  /// reason [hasDedupeKey] is: seeding the engine with every key this install
  /// has ever emitted sessionlessly would silence those detectors permanently.
  Future<Set<String>> dedupeKeysForSession(int? sessionId) async {
    final query = selectOnly(narratorEvents)
      ..addColumns([narratorEvents.dedupeKey]);
    if (sessionId == null) {
      query.where(
        narratorEvents.sessionId.isNull() &
            narratorEvents.timestamp.isBiggerOrEqualValue(
              DateTime.now().subtract(sessionlessDedupeWindow),
            ),
      );
    } else {
      query.where(narratorEvents.sessionId.equals(sessionId));
    }
    final rows = await query.get();
    return rows.map((r) => r.read(narratorEvents.dedupeKey)!).toSet();
  }

  /// Pinned-first, newest-first feed for a single session.
  Stream<List<NarratorEventRow>> watchFeedForSession(int sessionId) {
    return (select(narratorEvents)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.pinned),
            (t) => OrderingTerm.desc(t.timestamp),
          ]))
        .watch();
  }

  Future<List<NarratorEventRow>> getFeedForSession(int sessionId) {
    return (select(narratorEvents)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.pinned),
            (t) => OrderingTerm.desc(t.timestamp),
          ]))
        .get();
  }

  /// Pinned-first, newest-first recent feed scoped to the **single most recent
  /// session that has events** (by latest event timestamp). Scoping prevents a
  /// pinned discovery from a prior night bubbling above tonight's events in the
  /// idle cockpit tile, which has no session selector of its own. Capped to
  /// [limit]. Yields empty until at least one event exists.
  Stream<List<NarratorEventRow>> watchRecentFeed({int limit = 50}) {
    // Scope to the session of the most-recent event via a scalar subquery,
    // using `IS` so the sessionless bucket (NULL) matches itself rather than
    // SQL's never-true `= NULL`. Pinned-first / newest-first within that scope.
    return customSelect(
      'SELECT * FROM narrator_events '
      'WHERE session_id IS ('
      '  SELECT session_id FROM narrator_events '
      '  ORDER BY timestamp DESC LIMIT 1'
      ') '
      'ORDER BY pinned DESC, timestamp DESC '
      'LIMIT ?',
      variables: [Variable.withInt(limit)],
      readsFrom: {narratorEvents},
    ).watch().map(
      (rows) => rows
          .map((row) => narratorEvents.map(row.data))
          .toList(growable: false),
    );
  }

  /// The session id of the most-recent event (null = sessionless bucket, or no
  /// events). Exposed so [recentNarratorFeedProvider] consumers / tests can
  /// reason about which session the recent feed is scoped to.
  Future<int?> mostRecentEventSessionId() async {
    final row =
        await (select(narratorEvents)
              ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
              ..limit(1))
            .getSingleOrNull();
    return row?.sessionId;
  }

  Future<List<NarratorEventRow>> getRecentFeed({int limit = 50}) {
    return (select(narratorEvents)
          ..orderBy([
            (t) => OrderingTerm.desc(t.pinned),
            (t) => OrderingTerm.desc(t.timestamp),
          ])
          ..limit(limit))
        .get();
  }
}
