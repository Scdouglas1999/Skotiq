// Growth / best-night / re-reference all group folded subs by *observing
// night*, not by UTC calendar day.
//
// The distinction is not cosmetic. Grouping by UTC day is wrong twice over:
//
//   * West of Greenwich every night is labelled a day late — 21:00 EDT is
//     01:00 UTC the following day, so a session whose header reads
//     "2026-07-25 21:00" was charted as "Jul 26".
//   * East of Greenwich (all of Europe and Asia) the 00:00 UTC boundary falls
//     in the MIDDLE of the observing night, so every single night is split into
//     two points and its frame count, integration time and mean weight are
//     halved. "Best night" then reports the better HALF of a night.
//
// The noon-to-noon local rule asserted here is the same one
// TargetProgressService._nightStart and the forecast planner already use.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Epoch seconds for a LOCAL wall-clock instant, which is how an observer
/// describes when they were at the telescope.
int _localEpochSeconds(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
]) {
  return DateTime(year, month, day, hour, minute).millisecondsSinceEpoch ~/
      1000;
}

DateTime _nightOfLocal(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
]) {
  return SmartProjectService.observingNightOf(
    _localEpochSeconds(year, month, day, hour, minute),
  );
}

void main() {
  group('SmartProjectService.observingNightOf', () {
    test('a run that crosses local midnight stays ONE night', () {
      // A continuous session: last frame before midnight, first frame after.
      final before = _nightOfLocal(2026, 7, 29, 23, 40);
      final after = _nightOfLocal(2026, 7, 30, 0, 20);

      expect(
        after,
        before,
        reason:
            'A 23:40 frame and a 00:20 frame from the same continuous run must '
            'land on the same observing night, not two.',
      );
      expect(before, DateTime(2026, 7, 29));
    });

    test('an evening capture is labelled with its own local date', () {
      // The user's session header says "2026-07-25 21:00"; the growth chart
      // must agree instead of showing the next day.
      expect(_nightOfLocal(2026, 7, 25, 21, 0), DateTime(2026, 7, 25));
    });

    test('an after-midnight capture belongs to the night that started', () {
      // 03:00 is deep in the night that began the previous evening.
      expect(_nightOfLocal(2026, 7, 30, 3, 0), DateTime(2026, 7, 29));
      expect(_nightOfLocal(2026, 7, 30, 11, 59), DateTime(2026, 7, 29));
    });

    test('local noon is the boundary', () {
      expect(_nightOfLocal(2026, 7, 30, 11, 59), DateTime(2026, 7, 29));
      expect(_nightOfLocal(2026, 7, 30, 12, 0), DateTime(2026, 7, 30));
    });

    test('the returned key is date-only and local', () {
      final night = _nightOfLocal(2026, 7, 29, 22, 17);
      expect(night.hour, 0);
      expect(night.minute, 0);
      expect(night.second, 0);
      expect(
        night.isUtc,
        isFalse,
        reason:
            'The chart axis and the best-night badge format y/m/d straight off '
            'this value, so it has to carry the observer local date.',
      );
    });

    test('three observing sessions group into three nights', () {
      // The reproduced project: two evening sessions and one that straddles
      // midnight. The panel reported "24 frames across 4 nights".
      final captures = <int>[
        // Night A — 10 frames from 21:00.
        for (var i = 0; i < 10; i++) _localEpochSeconds(2026, 7, 25, 21, i * 5),
        // Night B — 6 frames from 21:00.
        for (var i = 0; i < 6; i++) _localEpochSeconds(2026, 7, 27, 21, i * 5),
        // Night C — one continuous 50-minute run across local midnight.
        for (var i = 0; i < 4; i++) _localEpochSeconds(2026, 7, 29, 23, 40 + i),
        for (var i = 0; i < 4; i++) _localEpochSeconds(2026, 7, 30, 0, 10 + i),
      ];

      final nights =
          captures.map(SmartProjectService.observingNightOf).toSet().toList()
            ..sort();

      expect(nights.length, 3, reason: 'Three sessions, three nights.');
      expect(nights, [
        DateTime(2026, 7, 25),
        DateTime(2026, 7, 27),
        DateTime(2026, 7, 29),
      ]);

      // And the split night keeps all 8 of its frames on one point.
      final perNight = <DateTime, int>{};
      for (final c in captures) {
        final n = SmartProjectService.observingNightOf(c);
        perNight[n] = (perNight[n] ?? 0) + 1;
      }
      expect(perNight[DateTime(2026, 7, 29)], 8);
      expect(perNight[DateTime(2026, 7, 25)], 10);
      expect(perNight[DateTime(2026, 7, 27)], 6);
    });
  });
}
