// Verifies the opt-in "Remove untracked targets" cleanup predicate used by the
// Analytics → Projects panel. A target is "untracked" — and therefore eligible
// for deletion — ONLY when it has:
//   * no integration goal      (goalIntegrationSecs <= 0)
//   * is not a favorite        (isFavorite == false)
//   * no captured subs         (capturedSubs == 0)
//   * no integration time      (totalIntegrationSecs == 0)
//   * no referencing session   (id NOT IN imaging_sessions.targetId)
//
// Every other target — favorites, goal-tracked, captured, or session-referenced
// — must survive the cleanup. countUntrackedTargets() must match the number
// actually deleted.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';

void main() {
  late SkotiqDatabase db;
  late TargetsDao targets;
  late SessionsDao sessions;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    targets = db.targetsDao;
    sessions = db.sessionsDao;
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTarget({
    required String name,
    bool isFavorite = false,
    double goalIntegrationSecs = 0.0,
    int capturedSubs = 0,
    double totalIntegrationSecs = 0.0,
  }) {
    return targets.createTarget(
      TargetsCompanion.insert(
        name: name,
        ra: 5.59,
        dec: -5.39,
        isFavorite: Value(isFavorite),
        goalIntegrationSecs: Value(goalIntegrationSecs),
        capturedSubs: Value(capturedSubs),
        totalIntegrationSecs: Value(totalIntegrationSecs),
      ),
    );
  }

  test('deletes only phantom/untracked targets and keeps the rest', () async {
    // Phantom rows — exactly what Framing used to auto-create.
    final phantom1 = await insertTarget(name: 'Phantom A');
    final phantom2 = await insertTarget(name: 'Phantom B');

    // Protected: favorite.
    final favorite = await insertTarget(name: 'Favorite', isFavorite: true);
    // Protected: has an integration goal.
    final goal = await insertTarget(name: 'Goal', goalIntegrationSecs: 3600.0);
    // Protected: has captured subs.
    final captured = await insertTarget(name: 'Captured', capturedSubs: 12);
    // Protected: has accumulated integration time.
    final integrated = await insertTarget(
      name: 'Integrated',
      totalIntegrationSecs: 1800.0,
    );
    // Protected: referenced by an imaging session (even with no other data).
    final sessioned = await insertTarget(name: 'Sessioned');
    await sessions.createSession(
      ImagingSessionsCompanion.insert(
        startTime: DateTime(2026, 5, 31, 21),
        targetId: Value(sessioned),
      ),
    );

    expect(
      await targets.countUntrackedTargets(),
      2,
      reason: 'only the two phantom rows are untracked',
    );

    final deleted = await targets.deleteUntrackedTargets();
    expect(deleted, 2, reason: 'deletes exactly the untracked phantom rows');

    final remaining = (await targets.getAllTargets()).map((t) => t.id).toSet();
    expect(remaining, {favorite, goal, captured, integrated, sessioned});
    expect(remaining, isNot(contains(phantom1)));
    expect(remaining, isNot(contains(phantom2)));

    // Second run is a no-op now that nothing is untracked.
    expect(await targets.countUntrackedTargets(), 0);
    expect(await targets.deleteUntrackedTargets(), 0);
  });

  test('count matches delete across mixed data', () async {
    await insertTarget(name: 'P1');
    await insertTarget(name: 'P2');
    await insertTarget(name: 'P3');
    await insertTarget(name: 'Fav', isFavorite: true);

    final count = await targets.countUntrackedTargets();
    final deleted = await targets.deleteUntrackedTargets();
    expect(count, deleted);
    expect(count, 3);
  });
}
