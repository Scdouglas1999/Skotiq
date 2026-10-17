// Covers darkness-window filtering and catalog-aware target ranking.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  const latitude = 40.0;
  const longitude = -105.0;
  final nightDate = DateTime(2026, 8, 2);

  final twilight = AstronomyCalculations.calculateTwilightTimes(
    date: nightDate,
    latitudeDeg: latitude,
    longitudeDeg: longitude,
  );
  final window = darknessWindowOf(twilight)!;
  final darkMid = window.start.add(
    Duration(seconds: window.duration.inSeconds ~/ 2),
  );

  /// RA (degrees) of an object that culminates at [instant] from this site.
  /// Transit happens when the local sidereal time equals the object's RA.
  double raThatTransitsAt(DateTime instant) =>
      AstronomyCalculations.localSiderealTime(instant, longitude) * 15.0;

  test('a target that only culminates in daylight cannot head the list', () {
    // Mid-morning: the sun is well up in August at 40N.
    final daylight = DateTime(
      nightDate.year,
      nightDate.month,
      nightDate.day,
      10,
    );
    final darkMid = window.start.add(
      Duration(seconds: window.duration.inSeconds ~/ 2),
    );

    // Index 0: transits at 10:00 with dec == latitude, i.e. straight through
    // the zenith — the shape a transit-altitude sort maximises (~90°).
    // Index 1: transits in the middle of the dark window, and lower (~70°).
    final ranked = rankTonightTargets(
      raDeg: [raThatTransitsAt(daylight), raThatTransitsAt(darkMid)],
      decDeg: [40.0, 20.0],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
    );

    expect(ranked, isNotEmpty);
    expect(
      ranked.first.index,
      1,
      reason:
          'the target usable during darkness must outrank the zenith '
          'object that culminates at 10:00',
    );
    // A transit-altitude sort genuinely disagrees here, so this is not a
    // no-op assertion.
    expect(ranked.first.visibility.transitAltitude, lessThan(85));
  });

  test('every ranked target has usable time inside the darkness window', () {
    final daylight = DateTime(
      nightDate.year,
      nightDate.month,
      nightDate.day,
      13,
    );
    final ranked = rankTonightTargets(
      raDeg: [
        for (var hourOffset = 0; hourOffset < 24; hourOffset++)
          (raThatTransitsAt(daylight) + hourOffset * 15.0) % 360.0,
      ],
      decDeg: [for (var i = 0; i < 24; i++) 35.0],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
    );

    expect(ranked, isNotEmpty);
    for (final entry in ranked) {
      expect(
        entry.hoursInDarkness,
        greaterThan(0),
        reason: 'index ${entry.index} was recommended with no dark time',
      );
      expect(entry.peakTime, isNotNull);
      expect(entry.peakTime!.isBefore(window.start), isFalse);
      expect(entry.peakTime!.isAfter(window.end), isFalse);
    }

    // Ranked list is ordered by dark hours' worth of score, so the first entry
    // must not be beaten on usable time by the last.
    expect(
      ranked.first.hoursInDarkness,
      greaterThanOrEqualTo(ranked.last.hoursInDarkness),
    );
  });

  test('an object that never clears the floor at all is dropped', () {
    // Deep south from 40N: never rises.
    final ranked = rankTonightTargets(
      raDeg: [0.0],
      decDeg: [-80.0],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
    );

    expect(ranked, isEmpty);
  });

  test('rise/transit/set are reported against the 30° floor', () {
    final darkMid = window.start.add(
      Duration(seconds: window.duration.inSeconds ~/ 2),
    );
    final ranked = rankTonightTargets(
      raDeg: [raThatTransitsAt(darkMid)],
      decDeg: [20.0],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
    );

    final v = ranked.single.visibility;
    expect(v.riseTime, isNotNull);
    expect(v.setTime, isNotNull);
    // Above 30° for a dec=+20 object at 40N is ~9.4h, comfortably short of the
    // ~13h it spends above the horizon — proof the floor was applied.
    final hoursUp = v.setTime!.difference(v.riseTime!).inMinutes / 60.0;
    expect(hoursUp, lessThan(11));
    expect(hoursUp, greaterThan(7));
  });

  test('catalog magnitude breaks neutral geometry ties', () {
    final ra = raThatTransitsAt(darkMid);
    final ranked = rankTonightTargets(
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      magnitudes: [8, 15],
    );
    expect(ranked.map((entry) => entry.index).take(2), [0, 1]);
  });

  test('catalog type breaks neutral geometry ties', () {
    final ra = raThatTransitsAt(darkMid);
    final ranked = rankTonightTargets(
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      objectTypes: [DsoType.galaxy.index, DsoType.star.index],
    );
    expect(ranked.map((entry) => entry.index).take(2), [0, 1]);
  });

  test('target size is scored against the active field of view', () {
    final ra = raThatTransitsAt(darkMid);
    final narrow = rankTonightTargets(
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      sizesArcMin: [2, 200],
      fovWidthDeg: 0.57,
      fovHeightDeg: 0.57,
    );
    final wide = rankTonightTargets(
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      sizesArcMin: [2, 200],
      fovWidthDeg: 5.7,
      fovHeightDeg: 5.7,
    );
    expect(narrow.first.index, 0);
    expect(wide.first.index, 1);
  });

  test('missing catalog metadata is neutral and deterministic', () {
    final ra = raThatTransitsAt(darkMid);
    final withNoMetadata = rankTonightTargets(
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
    );
    final explicitNulls = rankTonightTargets(
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      magnitudes: [null, null],
      sizesArcMin: [null, null],
      objectTypes: [null, null],
    );
    expect(
      explicitNulls.map((entry) => entry.index),
      withNoMetadata.map((entry) => entry.index),
    );
    expect(
      explicitNulls.map((entry) => entry.score),
      withNoMetadata.map((entry) => entry.score),
    );
  });

  group('darknessWindowOf', () {
    test('prefers astronomical night', () {
      final w = darknessWindowOf(
        TwilightTimes(
          sunset: DateTime(2026, 8, 2, 20),
          nauticalDusk: DateTime(2026, 8, 2, 21),
          astronomicalDusk: DateTime(2026, 8, 2, 22),
          astronomicalDawn: DateTime(2026, 8, 3, 4),
          nauticalDawn: DateTime(2026, 8, 3, 5),
          sunrise: DateTime(2026, 8, 3, 6),
        ),
      )!;
      expect(w.start, DateTime(2026, 8, 2, 22));
      expect(w.end, DateTime(2026, 8, 3, 4));
      expect(w.isAstronomical, isTrue);
      expect(w.hours, closeTo(6, 1e-9));
    });

    test(
      'falls back one band at a time where there is no astronomical night',
      () {
        final w = darknessWindowOf(
          TwilightTimes(
            sunset: DateTime(2026, 6, 21, 22),
            nauticalDusk: DateTime(2026, 6, 21, 23, 30),
            nauticalDawn: DateTime(2026, 6, 22, 2, 30),
            sunrise: DateTime(2026, 6, 22, 4),
          ),
        )!;
        expect(w.start, DateTime(2026, 6, 21, 23, 30));
        expect(w.isAstronomical, isFalse);
      },
    );

    test('midnight sun has no window at all', () {
      expect(darknessWindowOf(const TwilightTimes()), isNull);
    });
  });

  // A tooltip saying the panel ranks on "the same score the planner uses" is
  // false while 30% of the key is a catalog-fit term TargetScoringService has
  // never heard of: the list then puts a row with FEWER usable dark hours and a
  // LOWER planner score above the row under it, on a card whose own headline
  // number is those hours. The blend stays; the words shown to the operator
  // match it.
  group('the ranking key and the words shown for it agree', () {
    test('catalog fit can outrank a clearly better night score', () {
      // A (index 0): transits mid-darkness at dec == latitude, but faint.
      // B (index 1): near the edge of the window and low, but bright.
      final raA = raThatTransitsAt(darkMid);
      final raB = raThatTransitsAt(
        window.start.add(const Duration(minutes: 20)),
      );

      final ranked = rankTonightTargets(
        raDeg: [raA, raB],
        decDeg: [40.0, 0.0],
        magnitudes: [14.5, 5.0],
        latitudeDeg: latitude,
        longitudeDeg: longitude,
        nightDate: nightDate,
      );
      expect(ranked, hasLength(2));

      // The planner's own scorer prefers the OTHER one...
      final mid = window.start.add(
        Duration(seconds: window.duration.inSeconds ~/ 2),
      );
      final (moonRaOfDate, moonDecOfDate, _) =
          AstronomyCalculations.moonPosition(mid);
      final (moonRa, moonDec) = AstronomyCalculations.precessFromDateToJ2000(
        raDeg: moonRaOfDate,
        decDeg: moonDecOfDate,
        dt: mid,
      );
      final scorer = TargetScoringService(
        latitude: latitude,
        longitude: longitude,
        observationTime: mid,
        moonPosition: (moonRa, moonDec),
        moonIllumination: AstronomyCalculations.moonIllumination(mid),
        twilight: twilight,
      );
      double nightScore(double raDeg, double decDeg) => scorer
          .scoreTargetForNight(
            target: DeepSkyObject(
              id: 'x',
              name: 'x',
              coordinates: CelestialCoordinate.fromDegrees(
                raDegrees: raDeg,
                decDegrees: decDeg,
              ),
              type: DsoType.other,
            ),
            nightStart: window.start,
            nightEnd: window.end,
            minAltitude: kTonightMinAltitudeDeg,
          )
          .totalScore;

      expect(
        nightScore(raA, 40.0),
        greaterThan(nightScore(raB, 0.0)),
        reason: 'the planner prefers the well-placed faint one',
      );
      // ...and the panel still puts the bright one first, and even shows it
      // with fewer usable hours than the row below it.
      expect(ranked.first.index, 1);
      expect(
        ranked.first.hoursInDarkness,
        lessThan(ranked.last.hoursInDarkness),
      );
    });

    test('the tooltip states that rule instead of claiming planner parity', () {
      expect(kTonightCatalogFitWeight, greaterThan(0));
      // The disclosed split has to be the split the code actually applies.
      expect(
        kTonightRankingTooltip,
        contains('${(kTonightConditionsWeight * 100).round()}%'),
      );
      expect(
        kTonightRankingTooltip,
        contains('${(kTonightCatalogFitWeight * 100).round()}%'),
      );
      expect(kTonightRankingTooltip.toLowerCase(), contains('brightness'));
      expect(kTonightRankingTooltip.toLowerCase(), contains('field of view'));
      // The claim that started this: the key is NOT the planner's score.
      expect(
        kTonightRankingTooltip.toLowerCase(),
        isNot(contains('same score the planner')),
      );
    });
  });
}
