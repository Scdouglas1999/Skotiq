import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/guide_rms_history_dao.dart';

void main() {
  late SkotiqDatabase db;
  late GuideRmsHistoryDao dao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = db.guideRmsHistoryDao;
  });

  tearDown(() async {
    await db.close();
  });

  /// Build a companion with an explicit `recordedAt` so tests don't have to
  /// rely on insert order or `Future.delayed` to disambiguate same-second
  /// timestamps. Every other field gets a deterministic default.
  GuideRmsHistoryCompanion sample({
    required String mountId,
    required DateTime recordedAt,
    String sessionId = 'session-1',
    double rms = 0.5,
    int sampleCount = 100,
    double exposureSeconds = 2.0,
    int? targetId,
  }) {
    return GuideRmsHistoryCompanion.insert(
      sessionId: sessionId,
      mountId: mountId,
      totalRmsArcsec: rms,
      sampleCount: sampleCount,
      exposureSeconds: Value(exposureSeconds),
      recordedAt: recordedAt,
      targetId: targetId == null ? const Value.absent() : Value(targetId),
    );
  }

  test('insertSample returns an auto-incremented id', () async {
    final id1 = await dao.insertSample(
      sample(mountId: 'mount-1', recordedAt: DateTime(2026, 5, 17, 21)),
    );
    final id2 = await dao.insertSample(
      sample(mountId: 'mount-1', recordedAt: DateTime(2026, 5, 17, 22)),
    );

    expect(id1, greaterThan(0));
    expect(id2, greaterThan(id1));
  });

  test('recentForMount returns most-recent-first', () async {
    final t1 = DateTime(2026, 5, 17, 20);
    final t2 = DateTime(2026, 5, 17, 21);
    final t3 = DateTime(2026, 5, 17, 22);

    await dao.insertSample(sample(mountId: 'mount-1', recordedAt: t1));
    await dao.insertSample(sample(mountId: 'mount-1', recordedAt: t3));
    await dao.insertSample(sample(mountId: 'mount-1', recordedAt: t2));

    final samples = await dao.recentForMount('mount-1');
    expect(samples, hasLength(3));
    // DateTimeColumn round-trips through unix seconds, so we use
    // isAtSameMomentAs rather than equals to stay timezone-agnostic.
    expect(samples[0].recordedAt.isAtSameMomentAs(t3), isTrue);
    expect(samples[1].recordedAt.isAtSameMomentAs(t2), isTrue);
    expect(samples[2].recordedAt.isAtSameMomentAs(t1), isTrue);
  });

  test('recentForMount filters out other mounts', () async {
    final t = DateTime(2026, 5, 17, 21);
    await dao.insertSample(sample(mountId: 'mount-1', recordedAt: t));
    await dao.insertSample(
      sample(mountId: 'mount-2', recordedAt: t.add(const Duration(hours: 1))),
    );
    await dao.insertSample(
      sample(mountId: 'mount-1', recordedAt: t.add(const Duration(hours: 2))),
    );

    final mount1 = await dao.recentForMount('mount-1');
    expect(mount1, hasLength(2));
    expect(mount1.every((s) => s.mountId == 'mount-1'), isTrue);

    final mount2 = await dao.recentForMount('mount-2');
    expect(mount2, hasLength(1));
    expect(mount2.single.mountId, equals('mount-2'));
  });

  test('recentForMount respects the limit parameter', () async {
    // Insert 5 samples for mount-1 with increasing timestamps.
    for (var i = 0; i < 5; i++) {
      await dao.insertSample(
        sample(
          mountId: 'mount-1',
          recordedAt: DateTime(2026, 5, 17, 20 + i),
          rms: i.toDouble(),
        ),
      );
    }

    final limited = await dao.recentForMount('mount-1', limit: 3);
    expect(limited, hasLength(3));
    // We asked for the 3 most recent — RMS values 4, 3, 2 in DESC order.
    expect(
      limited.map((s) => s.totalRmsArcsec).toList(),
      equals([4.0, 3.0, 2.0]),
    );
  });

  test('deleteOlderThan removes only entries before the cutoff', () async {
    final old = DateTime(2026, 5, 10, 12);
    final cutoff = DateTime(2026, 5, 15, 12);
    final fresh = DateTime(2026, 5, 17, 12);

    final oldId = await dao.insertSample(
      sample(mountId: 'mount-1', recordedAt: old),
    );
    final freshId = await dao.insertSample(
      sample(mountId: 'mount-1', recordedAt: fresh),
    );

    await dao.deleteOlderThan(cutoff);

    final remaining = await dao.recentForMount('mount-1');
    expect(remaining, hasLength(1));
    expect(remaining.single.id, equals(freshId));
    // Confirm `oldId` is really gone, not just hidden by the query.
    expect(remaining.any((s) => s.id == oldId), isFalse);
  });

  test('recentForMount default limit returns 20 entries in DESC recordedAt '
      'order after inserting 25', () async {
    // End-to-end check: the planner asks for "recent history" without
    // overriding the limit, and we want exactly the 20 newest samples in
    // descending-time order.
    final baseline = DateTime(2026, 5, 17, 0);
    for (var i = 0; i < 25; i++) {
      await dao.insertSample(
        sample(
          mountId: 'mount-1',
          recordedAt: baseline.add(Duration(minutes: i)),
          rms: i.toDouble(),
        ),
      );
    }

    final recent = await dao.recentForMount('mount-1');
    expect(recent, hasLength(20));

    // Most recent is RMS 24, oldest in the slice is RMS 5.
    expect(recent.first.totalRmsArcsec, equals(24.0));
    expect(recent.last.totalRmsArcsec, equals(5.0));

    // Verify the entire slice is monotonically non-increasing on recordedAt.
    for (var i = 1; i < recent.length; i++) {
      expect(
        recent[i].recordedAt.isAfter(recent[i - 1].recordedAt),
        isFalse,
        reason:
            'recentForMount must return rows in DESC recordedAt order; '
            'row $i (${recent[i].recordedAt}) is after row ${i - 1} '
            '(${recent[i - 1].recordedAt}).',
      );
    }
  });

  test('the (mountId, recordedAt DESC) helper index is present', () async {
    // The DAO advertises recentForMount as O(log n) on the (mountId,
    // recordedAt) pair. The index is created in database.dart's
    // _createCustomIndexes(); if someone removes it the planner's hot
    // path silently degrades to a table scan. Pin the invariant here.
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'index' AND name = 'idx_guide_rms_mount_recent'",
        )
        .get();
    expect(rows, hasLength(1));
  });
}
