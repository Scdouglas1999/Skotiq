import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/history/night_entry.dart';
import 'package:skotiq_core/models.dart';

import 'history_fixtures.dart';

void main() {
  final evening = DateTime(2026, 11, 3, 20, 21, 22);

  group('pairNightEntries', () {
    test('a run joins the session it opened, and each is listed once', () {
      final entries = pairNightEntries(
        [
          session(1, name: 'M74 Plan', start: evening, status: 'failed'),
          session(2, name: 'Older night', start: DateTime(2025, 1, 4, 21)),
        ],
        [
          run(
            7,
            name: 'M74 Plan',
            start: evening,
            status: 'failed',
            stats: {'framesCaptured': 12},
          ),
        ],
      );

      expect(entries, hasLength(2));
      expect(entries.first.session!.id, 1);
      expect(entries.first.run!.id, 7);
      expect(entries.first.stats!.framesCaptured, 12);
      expect(entries.last.session!.id, 2);
      expect(entries.last.run, isNull);
    });

    test('a run with no session is a row of its own, newest first', () {
      final entries = pairNightEntries(
        [session(1, name: 'A', start: DateTime(2026, 11, 1, 21))],
        [run(3, name: 'Orphan', start: DateTime(2026, 11, 2, 21))],
      );

      expect(entries.map((e) => e.name), ['Orphan', 'A']);
      expect(entries.first.session, isNull);
    });

    test('a run record that cannot be read keeps its row', () {
      final broken = run(3, name: 'Run', start: evening);
      final entries = pairNightEntries(
        const [],
        [broken.copyWith(statsJson: '{not json')],
      );

      expect(entries.single.stats, isNull);
    });

    test('a session still open reads as running', () {
      final entry =
          NightEntry(session: session(1, start: evening, status: 'active'));
      expect(entry.ending, SequenceRunStatus.running);
    });
  });

  group('HistoryFilter', () {
    final now = DateTime(2026, 11, 15);
    final targets = {5: 'NGC 7814'};
    final failed = NightEntry(
      session: session(
        1,
        name: 'Rig run-through',
        start: evening,
        status: 'failed',
        targetId: 5,
        sequenceId: 23,
      ),
    );
    final paused = NightEntry(
      run: run(2, name: 'M74 Plan', start: evening, status: 'paused'),
      stats: parseRunStats(
        '{"targetBreakdown":{"M 74":{"L":{"captured":3}}}}',
      ),
    );
    final lastYear = NightEntry(
      session: session(3, name: 'Old', start: DateTime(2025, 11, 20, 22)),
    );

    bool matches(HistoryFilter filter, NightEntry entry) =>
        filter.matches(entry, targetNameById: targets, now: now);

    test('an empty filter lists everything', () {
      const filter = HistoryFilter();
      expect(filter.isEmpty, isTrue);
      expect([failed, paused, lastYear].every((e) => matches(filter, e)), true);
    });

    test('status matches the outcome; Running also finds a paused run', () {
      expect(
        matches(const HistoryFilter(status: SequenceRunStatus.failed), failed),
        isTrue,
      );
      expect(
        matches(const HistoryFilter(status: SequenceRunStatus.failed), paused),
        isFalse,
      );
      expect(
        matches(const HistoryFilter(status: SequenceRunStatus.running), paused),
        isTrue,
      );
    });

    test('target matches the session target or a target the run shot', () {
      expect(matches(const HistoryFilter(target: 'NGC 7814'), failed), isTrue);
      expect(matches(const HistoryFilter(target: 'M 74'), paused), isTrue);
      expect(matches(const HistoryFilter(target: 'M 74'), failed), isFalse);
      expect(matches(const HistoryFilter(untargeted: true), failed), isFalse);
      expect(matches(const HistoryFilter(untargeted: true), lastYear), isTrue);
    });

    test('search reads the name and the run targets', () {
      expect(matches(const HistoryFilter(query: 'run-through'), failed), true);
      expect(matches(const HistoryFilter(query: 'm 74'), paused), isTrue);
      expect(matches(const HistoryFilter(query: 'm 74'), failed), isFalse);
    });

    test('period and sequence narrow the list', () {
      const thisYear = HistoryFilter(period: HistoryPeriod.thisYear);
      expect(matches(thisYear, failed), isTrue);
      expect(matches(thisYear, lastYear), isFalse);
      expect(matches(const HistoryFilter(sequenceId: 23), failed), isTrue);
      expect(matches(const HistoryFilter(sequenceId: 23), paused), isFalse);
    });

    test('quick captures stay only while nothing they lack is asked for', () {
      expect(const HistoryFilter().admitsQuickCaptures, isTrue);
      expect(
        const HistoryFilter(period: HistoryPeriod.thisMonth)
            .admitsQuickCaptures,
        isTrue,
      );
      expect(const HistoryFilter(query: 'm').admitsQuickCaptures, isFalse);
      expect(
        const HistoryFilter(status: SequenceRunStatus.failed)
            .admitsQuickCaptures,
        isFalse,
      );
    });
  });

  group('groupByNight', () {
    test('a run after midnight belongs to the night that began the evening '
        'before, and quick captures join the night they were taken', () {
      final nights = groupByNight(
        [
          NightEntry(session: session(1, start: DateTime(2026, 11, 3, 20, 21))),
          NightEntry(session: session(2, start: DateTime(2026, 11, 4, 2, 5))),
          NightEntry(session: session(3, start: DateTime(2026, 11, 1, 22))),
        ],
        standaloneLights: [
          frame(1, at: DateTime(2026, 11, 1, 21, 30)),
          frame(2, at: DateTime(2026, 10, 20, 23), exposure: 30),
        ],
      );

      expect(nights.map((n) => n.night.day), [3, 1, 20]);
      expect(nights[0].entries, hasLength(2));
      expect(nights[0].quickCaptures, isNull);
      expect(nights[1].quickCaptures!.lights, hasLength(1));
      expect(nights[2].entries, isEmpty);
      expect(nights[2].quickCaptures!.integrationSecs, 30);
    });
  });

  group('HistoryTotals', () {
    final at = DateTime(2026, 7, 14);

    test('integration and quality count accepted lights; temperature and '
        'exposures count every frame', () {
      final totals = HistoryTotals.of(
        images: [
          frame(1, at: at, exposure: 45, temperature: -10, hfr: 2, rms: 0.8),
          frame(
            2,
            at: at,
            accepted: false,
            exposure: 120,
            temperature: -5,
            hfr: 10,
            rms: 4,
          ),
          frame(3, at: at, type: 'flat', exposure: 2, temperature: 0),
        ],
        sessions: [
          session(1, start: at, autofocus: 2),
          session(2, start: at, autofocus: 3),
        ],
        runs: [
          run(1, name: 'a', start: at, stats: {'meridianFlips': 2}),
          run(2, name: 'b', start: at, stats: {'meridianFlips': 1}),
        ],
      );

      expect(totals.exposures, 3);
      expect(totals.acceptedIntegrationSecs, 45);
      expect(totals.meanSensorTemp, -5);
      expect(totals.meanHfr, 2);
      expect(totals.meanGuidingRms, 0.8);
      expect(totals.autofocusRuns, 5);
      expect(totals.meridianFlips, 3);
    });

    test('counts that have not loaded are unknown, not zero', () {
      final totals =
          HistoryTotals.of(images: const [], sessions: null, runs: null);

      expect(totals.autofocusRuns, isNull);
      expect(totals.meridianFlips, isNull);
      expect(totals.meanHfr, isNull);
    });
  });
}
