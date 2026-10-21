// RunStatsLedger: the seal that keeps a late incremental write from landing
// after the run's final stats JSON.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_executor/run_stats_ledger.dart';

class _MockRunsDao extends Mock implements SequenceRunsDao {}

void main() {
  late _MockRunsDao dao;
  late SequenceRunStats? live;
  late int publishCount;
  late RunStatsLedger ledger;

  setUp(() {
    dao = _MockRunsDao();
    live = SequenceRunStats();
    publishCount = 0;
    ledger = RunStatsLedger(
      readStats: () => live,
      publishStats: (stats) {
        publishCount++;
        live = stats;
      },
      readRunId: () => 7,
      runsDao: () => dao,
      logger: LoggingService.new,
    );
  });

  test('an update publishes a fresh copy and writes the run row', () async {
    when(() => dao.updateStats(7, any())).thenAnswer((_) async {});
    final before = live;
    ledger.update((stats) => stats.recordWarning('w'));
    expect(publishCount, 1);
    expect(identical(live, before), isFalse);
    expect(live!.warningMessages, ['w']);
    verify(() => dao.updateStats(7, any())).called(1);
  });

  test('persist: false records in memory only', () {
    ledger.update((stats) => stats.recordWarning('w'), persist: false);
    expect(live!.warningMessages, ['w']);
    verifyNever(() => dao.updateStats(any(), any()));
  });

  test(
    'sealing drains the writes in flight and blocks every later one',
    () async {
      final gate = Completer<void>();
      when(() => dao.updateStats(7, any())).thenAnswer((_) => gate.future);
      ledger.update((stats) => stats.recordWarning('before'));

      var drained = false;
      final drain = ledger.sealAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse, reason: 'the pending write has not settled');
      expect(ledger.isSealed, isTrue);

      ledger.update((stats) => stats.recordWarning('after'));
      expect(live!.warningMessages, ['before'], reason: 'sealed');
      verify(() => dao.updateStats(7, any())).called(1);

      gate.complete();
      await drain;
      expect(drained, isTrue);
    },
  );

  test('a failed write neither escapes nor blocks the drain', () async {
    when(
      () => dao.updateStats(7, any()),
    ).thenAnswer((_) => Future<void>.error(StateError('disk full')));
    ledger.update((stats) => stats.recordWarning('w'));
    await ledger.sealAndDrain();
  });

  test('reopen lifts the seal for the next run', () async {
    await ledger.sealAndDrain();
    ledger.reopen();
    expect(ledger.isSealed, isFalse);
    ledger.update((stats) => stats.recordWarning('next run'), persist: false);
    expect(live!.warningMessages, ['next run']);
  });

  test('with no live run nothing happens', () {
    live = null;
    ledger.update((stats) => stats.recordWarning('w'));
    expect(publishCount, 0);
    verifyNever(() => dao.updateStats(any(), any()));
  });
}
