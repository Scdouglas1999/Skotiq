// `loadSequenceSummaries` documented itself as "a single grouped DAO query
// plus a batched run-history roll-up", but rolled the run history up one
// `runSummaryForSequence(row.id)` at a time inside a collection-`for` — a
// 40-sequence library cost 41 serialized round trips on the library screen.
//
// The roll-up is one grouped query. These tests pin the batched result against
// the per-sequence method, so a change to what the library reports (not just
// how fast) fails here.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase db;
  late SequencesDao sequencesDao;
  late SequenceRunsDao runsDao;
  late SequenceRepository repository;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    sequencesDao = SequencesDao(db);
    runsDao = SequenceRunsDao(db);
    repository = SequenceRepository(sequencesDao, runsDao: runsDao);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> newSequence(String name) => sequencesDao.createSequence(
    SequencesCompanion.insert(
      name: name,
      estimatedDurationMins: const Value(6),
    ),
  );

  Future<void> recordRun(int sequenceId, DateTime startedAt) async {
    final runId = await runsDao.startRun(
      sequenceId: sequenceId,
      sequenceName: 'run',
    );
    await db.customStatement(
      'UPDATE sequence_runs SET started_at = ? WHERE id = ?',
      [startedAt.millisecondsSinceEpoch ~/ 1000, runId],
    );
  }

  test('the batched roll-up agrees with the per-sequence roll-up', () async {
    final a = await newSequence('A');
    final b = await newSequence('B');
    final never = await newSequence('C');

    await recordRun(a, DateTime.utc(2026, 1, 1));
    await recordRun(a, DateTime.utc(2026, 3, 2));
    await recordRun(b, DateTime.utc(2026, 2, 5));

    final batched = await runsDao.runSummariesForSequences([a, b, never]);

    for (final id in [a, b, never]) {
      final single = await runsDao.runSummaryForSequence(id);
      expect(
        batched[id]?.runCount ?? 0,
        single.runCount,
        reason: 'run count for sequence $id',
      );
      expect(
        batched[id]?.lastRunAt,
        single.lastRunAt,
        reason: 'last run for sequence $id',
      );
    }
  });

  test('an empty id set costs no query and returns nothing', () async {
    expect(await runsDao.runSummariesForSequences(const []), isEmpty);
  });

  test('the library summaries carry the run roll-up per row', () async {
    final a = await newSequence('A');
    final b = await newSequence('B');
    await newSequence('C');

    await recordRun(a, DateTime.utc(2026, 1, 1));
    await recordRun(a, DateTime.utc(2026, 3, 2));
    await recordRun(b, DateTime.utc(2026, 2, 5));

    final summaries = {
      for (final s in await repository.loadSequenceSummaries()) s.name: s,
    };

    expect(summaries.keys, containsAll(['A', 'B', 'C']));
    expect(summaries['A']!.runCount, 2);
    // Drift hands back the instant in local time; compare instants.
    expect(summaries['A']!.lastRunAt!.toUtc(), DateTime.utc(2026, 3, 2));
    expect(summaries['B']!.runCount, 1);
    expect(summaries['B']!.lastRunAt!.toUtc(), DateTime.utc(2026, 2, 5));
    expect(summaries['C']!.runCount, 0);
    expect(summaries['C']!.lastRunAt, isNull);
  });
}
