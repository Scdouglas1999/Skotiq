// Behaviour tests for the v43 CampaignsDao (Phase B — durable multi-night
// campaigns). Covers the four provider methods from the brief —
// upsertDesired / recordAccepted / getForTarget / remaining — plus the
// acceptance-increments-the-count invariant that the SequenceExecutor hook
// relies on (accepted frames advance the counter; a non-positive delta does
// not).

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/campaigns_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  late SkotiqDatabase db;
  late CampaignsDao dao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = CampaignsDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTarget(String name) {
    return db.customInsert(
      'INSERT INTO targets (name, ra, dec) VALUES (?, ?, ?)',
      variables: [
        Variable.withString(name),
        Variable.withReal(5.6),
        Variable.withReal(-5.4),
      ],
    );
  }

  test('upsertDesired creates a campaign with zero accepted', () async {
    final t = await seedTarget('M42');
    final id = await dao.upsertDesired(
      targetId: t,
      filter: 'Ha',
      desiredCount: 60,
    );
    expect(id, greaterThan(0));

    final c = await dao.getForTargetFilter(t, 'Ha');
    expect(c, isNotNull);
    expect(c!.desiredCount, 60);
    expect(c.acceptedCount, 0);
    expect(c.remaining, 60);
    expect(c.lastCaptureAt, isNull);
  });

  test(
    'upsertDesired re-tune preserves accepted_count and last_date',
    () async {
      final t = await seedTarget('M42');
      await dao.upsertDesired(targetId: t, filter: 'Ha', desiredCount: 60);
      final at = DateTime.utc(2026, 6, 8, 4);
      await dao.recordAccepted(
        targetId: t,
        filter: 'Ha',
        delta: 10,
        capturedAt: at,
      );

      // Re-tune the goal mid-campaign.
      await dao.upsertDesired(targetId: t, filter: 'Ha', desiredCount: 90);

      final c = await dao.getForTargetFilter(t, 'Ha');
      expect(c!.desiredCount, 90);
      expect(
        c.acceptedCount,
        10,
        reason: 'accepted progress survives a re-tune',
      );
      expect(c.lastCaptureAt, at);
      expect(c.remaining, 80);
    },
  );

  test('recordAccepted increments the count and stamps last_date', () async {
    final t = await seedTarget('NGC 7000');
    await dao.upsertDesired(targetId: t, filter: 'OIII', desiredCount: 20);

    final at1 = DateTime.utc(2026, 6, 8, 2);
    await dao.recordAccepted(targetId: t, filter: 'OIII', capturedAt: at1);
    await dao.recordAccepted(targetId: t, filter: 'OIII', capturedAt: at1);
    final at2 = DateTime.utc(2026, 6, 9, 2);
    await dao.recordAccepted(
      targetId: t,
      filter: 'OIII',
      delta: 3,
      capturedAt: at2,
    );

    final c = await dao.getForTargetFilter(t, 'OIII');
    expect(c!.acceptedCount, 5);
    expect(c.lastCaptureAt, at2, reason: 'last_date tracks the latest credit');
    expect(c.remaining, 15);
  });

  test('recordAccepted auto-creates a campaign when none exists yet', () async {
    final t = await seedTarget('M31');
    // No upsertDesired first — the acceptance path may credit before a goal
    // is ever set; the credit must not be lost.
    final id = await dao.recordAccepted(targetId: t, filter: 'L', delta: 2);
    expect(id, isNotNull);

    final c = await dao.getForTargetFilter(t, 'L');
    expect(c!.acceptedCount, 2);
    expect(c.desiredCount, 0);
    // The row exists, so remaining() resolves it: 0 desired - 2 accepted
    // clamps to 0 (it only returns null when NO campaign row exists).
    expect(await dao.remaining(t, 'L'), 0);
    expect(c.remaining, 0);
  });

  test(
    'recordAccepted with non-positive delta is a no-op (rejected frames)',
    () async {
      final t = await seedTarget('M51');
      await dao.upsertDesired(targetId: t, filter: 'Ha', desiredCount: 10);

      final zero = await dao.recordAccepted(
        targetId: t,
        filter: 'Ha',
        delta: 0,
      );
      final neg = await dao.recordAccepted(
        targetId: t,
        filter: 'Ha',
        delta: -5,
      );
      expect(zero, isNull);
      expect(neg, isNull);

      final c = await dao.getForTargetFilter(t, 'Ha');
      expect(
        c!.acceptedCount,
        0,
        reason: 'rejected/no-op frames never advance',
      );
    },
  );

  test('filter matching is case-insensitive', () async {
    final t = await seedTarget('M81');
    await dao.upsertDesired(targetId: t, filter: 'Ha', desiredCount: 30);
    await dao.recordAccepted(targetId: t, filter: 'HA');
    await dao.recordAccepted(targetId: t, filter: 'ha');

    final rows = await dao.getForTarget(t);
    expect(rows, hasLength(1), reason: 'one logical campaign, case folded');
    expect(rows.single.acceptedCount, 2);
  });

  test('remaining() clamps to zero once the goal is met', () async {
    final t = await seedTarget('M13');
    await dao.upsertDesired(targetId: t, filter: 'L', desiredCount: 3);
    await dao.recordAccepted(targetId: t, filter: 'L', delta: 5);

    expect(await dao.remaining(t, 'L'), 0);
    final c = await dao.getForTargetFilter(t, 'L');
    expect(c!.isComplete, isTrue);
    expect(c.percentComplete, 1.0);
  });

  test('remaining() returns null for an unknown (target, filter)', () async {
    final t = await seedTarget('M27');
    expect(await dao.remaining(t, 'SII'), isNull);
  });

  test('getForTarget returns every filter campaign for the target', () async {
    final t = await seedTarget('M16');
    await dao.upsertDesired(targetId: t, filter: 'Ha', desiredCount: 40);
    await dao.upsertDesired(targetId: t, filter: 'OIII', desiredCount: 40);
    await dao.upsertDesired(targetId: t, filter: 'SII', desiredCount: 40);

    final rows = await dao.getForTarget(t);
    expect(rows.map((c) => c.filter).toList(), ['Ha', 'OIII', 'SII']);
  });

  test('deleting a target cascades its campaigns away', () async {
    final t = await seedTarget('M33');
    await dao.upsertDesired(targetId: t, filter: 'L', desiredCount: 10);
    expect(await dao.getForTarget(t), hasLength(1));

    await db.customStatement('DELETE FROM targets WHERE id = ?', [t]);
    expect(await dao.getForTarget(t), isEmpty);
  });
}
