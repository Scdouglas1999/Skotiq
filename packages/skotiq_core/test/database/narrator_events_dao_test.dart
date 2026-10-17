import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/daos/narrator_events_dao.dart';

/// Exercises the v48 `narrator_events` table end-to-end through
/// [NarratorEventsDao]: persistence, the durable dedupe guard, and the
/// pinned-first / newest-first feed ordering the providers rely on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late NarratorEventsDao dao;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = NarratorEventsDao(db);
    // Seed the imaging_sessions rows the events reference (FKs are enforced).
    for (final id in [1, 2, 3, 5, 7]) {
      await db
          .into(db.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              id: Value(id),
              startTime: DateTime.utc(2026, 6, 11, 21),
            ),
          );
    }
  });

  tearDown(() async {
    await db.close();
  });

  NarratorEventsCompanion event({
    required String eventType,
    required String category,
    required String severity,
    required String headline,
    required String dedupeKey,
    int? sessionId,
    bool pinned = false,
    DateTime? timestamp,
    String? evidenceJson,
  }) {
    return NarratorEventsCompanion.insert(
      sessionId: Value(sessionId),
      eventType: eventType,
      category: category,
      severity: severity,
      headline: headline,
      dedupeKey: dedupeKey,
      pinned: Value(pinned),
      timestamp: timestamp == null ? const Value.absent() : Value(timestamp),
      evidenceJson: Value(evidenceJson),
    );
  }

  test(
    'schema bump created the narrator_events table (insert succeeds)',
    () async {
      final id = await dao.insertEvent(
        event(
          eventType: 'milestone.limiting_mag',
          category: 'milestone',
          severity: 'success',
          headline: 'Reaching mag 19.2',
          dedupeKey: 'milestone.limiting_mag.first',
          sessionId: 7,
        ),
      );
      expect(id, greaterThan(0));
    },
  );

  test('hasDedupeKey is session-scoped', () async {
    await dao.insertEvent(
      event(
        eventType: 'conditions.excellent',
        category: 'conditions',
        severity: 'success',
        headline: 'Great window',
        dedupeKey: 'conditions.excellent',
        sessionId: 1,
      ),
    );
    expect(await dao.hasDedupeKey(1, 'conditions.excellent'), isTrue);
    expect(await dao.hasDedupeKey(2, 'conditions.excellent'), isFalse);
    expect(await dao.hasDedupeKey(null, 'conditions.excellent'), isFalse);
  });

  test('feed is pinned-first, then newest-first', () async {
    final base = DateTime.utc(2026, 6, 11, 22);
    await dao.insertEvent(
      event(
        eventType: 'a',
        category: 'quality',
        severity: 'info',
        headline: 'old unpinned',
        dedupeKey: 'a',
        sessionId: 3,
        timestamp: base,
      ),
    );
    await dao.insertEvent(
      event(
        eventType: 'b',
        category: 'quality',
        severity: 'info',
        headline: 'new unpinned',
        dedupeKey: 'b',
        sessionId: 3,
        timestamp: base.add(const Duration(minutes: 10)),
      ),
    );
    await dao.insertEvent(
      event(
        eventType: 'c',
        category: 'discovery',
        severity: 'celebrate',
        headline: 'pinned discovery',
        dedupeKey: 'c',
        sessionId: 3,
        pinned: true,
        timestamp: base.add(const Duration(minutes: 5)),
      ),
    );

    final feed = await dao.getFeedForSession(3);
    expect(feed.map((r) => r.headline).toList(), [
      'pinned discovery', // pinned bubbles to top
      'new unpinned', // then newest-first
      'old unpinned',
    ]);
  });

  test(
    'recent feed is scoped to the most-recent session, pinned-first',
    () async {
      final base = DateTime.utc(2026, 6, 11, 22);
      // Last week's session (1) with a pinned discovery.
      await dao.insertEvent(
        event(
          eventType: 'discovery.moving_object',
          category: 'discovery',
          severity: 'celebrate',
          headline: 'last week pinned discovery',
          dedupeKey: 'old-pinned',
          sessionId: 1,
          pinned: true,
          timestamp: base.subtract(const Duration(days: 7)),
        ),
      );
      // Tonight's session (3): a plain event (newer than last week's pinned).
      await dao.insertEvent(
        event(
          eventType: 'quality.clipping',
          category: 'quality',
          severity: 'warning',
          headline: 'tonight unpinned',
          dedupeKey: 'tonight-1',
          sessionId: 3,
          timestamp: base,
        ),
      );
      await dao.insertEvent(
        event(
          eventType: 'discovery.period_found',
          category: 'discovery',
          severity: 'celebrate',
          headline: 'tonight pinned',
          dedupeKey: 'tonight-2',
          sessionId: 3,
          pinned: true,
          timestamp: base.add(const Duration(minutes: 1)),
        ),
      );

      final feed = await dao.watchRecentFeed().first;
      // Only tonight's session, pinned-first; last week's pinned discovery must
      // NOT bubble in.
      expect(feed.map((r) => r.headline).toList(), [
        'tonight pinned',
        'tonight unpinned',
      ]);
      expect(await dao.mostRecentEventSessionId(), 3);
    },
  );

  test('provider mapper decodes evidence and enums from a row', () async {
    final evidence = NarratorEvidence.delta(from: 18.6, to: 19.2, unit: 'mag');
    await dao.insertEvent(
      event(
        eventType: 'milestone.limiting_mag',
        category: 'milestone',
        severity: 'success',
        headline: 'Depth record',
        dedupeKey: 'depth-1',
        sessionId: 5,
        evidenceJson: evidence.toJsonString(),
      ),
    );
    final rows = await dao.getFeedForSession(5);
    final mapped = narratorEventFromRow(rows.single);
    expect(mapped.category, NarratorCategory.milestone);
    expect(mapped.severity, NarratorSeverity.success);
    expect(mapped.evidence, isNotNull);
    expect(mapped.evidence!.kind, NarratorEvidenceKind.delta);
    expect(mapped.evidence!.to, 19.2);
  });
}
