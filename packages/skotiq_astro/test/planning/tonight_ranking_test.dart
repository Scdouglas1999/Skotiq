// Covers darkness-window filtering and catalog-aware target ranking.

import 'package:test/test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import '../support/scripted_night_scorer.dart';

void main() {
  const latitude = 40.0;
  const longitude = -105.0;
  final nightDate = DateTime(2026, 8, 2);
  // No horizon set: the minimum altitude in every direction.
  final floor = AltitudeFloorSamples.flat(30);

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

  // Equal night scores for every target, so the catalog fit decides.
  final scorer = ScriptedNightScorer();

  test('rise/transit/set are reported against the 30° floor', () async {
    final darkMid = window.start.add(
      Duration(seconds: window.duration.inSeconds ~/ 2),
    );
    final ranked = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [raThatTransitsAt(darkMid)],
      decDeg: [20.0],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
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

  test('a target the scorer leaves out is not listed', () async {
    final ranked = await rankTonightTargets(
      scorer: ScriptedNightScorer(byIndex: {0: null}).call,
      raDeg: [10, 20],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
    );
    expect(ranked.map((entry) => entry.index), [1]);
  });

  test('the scorer is asked about the darkness window, its Moon in the '
      'catalog frame and the floor', () async {
    final asked = ScriptedNightScorer();
    await rankTonightTargets(
      scorer: asked.call,
      raDeg: [10],
      decDeg: [20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
    );
    final request = asked.requests.single;
    expect(request.nightStart, window.start);
    expect(request.nightEnd, window.end);
    final (moonRaOfDate, moonDecOfDate, _) = AstronomyCalculations.moonPosition(
      darkMid,
    );
    final moonJ2000 = AstronomyCalculations.precessFromDateToJ2000(
      raDeg: moonRaOfDate,
      decDeg: moonDecOfDate,
      dt: darkMid,
    );
    expect(request.moon, moonJ2000);
    expect(request.floor, same(floor));
    expect(request.targets.single.coordinates.raDegrees, closeTo(10, 1e-9));
  });

  test('a night with no darkness asks the scorer nothing', () async {
    final asked = ScriptedNightScorer();
    final ranked = await rankTonightTargets(
      scorer: asked.call,
      raDeg: [10],
      decDeg: [20],
      // Midsummer near the pole: the sun never sets.
      latitudeDeg: 78,
      longitudeDeg: 15,
      nightDate: DateTime(2026, 6, 21),
      floor: floor,
    );
    expect(ranked, isEmpty);
    expect(asked.requests, isEmpty);
  });

  test('catalog magnitude breaks neutral geometry ties', () async {
    final ra = raThatTransitsAt(darkMid);
    final ranked = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
      magnitudes: [8, 15],
    );
    expect(ranked.map((entry) => entry.index).take(2), [0, 1]);
  });

  test('catalog type breaks neutral geometry ties', () async {
    final ra = raThatTransitsAt(darkMid);
    final ranked = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
      objectTypes: [DsoType.galaxy.index, DsoType.star.index],
    );
    expect(ranked.map((entry) => entry.index).take(2), [0, 1]);
  });

  test('target size is scored against the active field of view', () async {
    final ra = raThatTransitsAt(darkMid);
    final narrow = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
      sizesArcMin: [2, 200],
      fovWidthDeg: 0.57,
      fovHeightDeg: 0.57,
    );
    final wide = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
      sizesArcMin: [2, 200],
      fovWidthDeg: 5.7,
      fovHeightDeg: 5.7,
    );
    expect(narrow.first.index, 0);
    expect(wide.first.index, 1);
  });

  test('missing catalog metadata is neutral and deterministic', () async {
    final ra = raThatTransitsAt(darkMid);
    final withNoMetadata = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
    );
    final explicitNulls = await rankTonightTargets(
      scorer: scorer.call,
      raDeg: [ra, ra],
      decDeg: [20, 20],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
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
    test('prefers astronomical night', () async {
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

    test('midnight sun has no window at all', () async {
      expect(darknessWindowOf(const TwilightTimes()), isNull);
    });
  });

  // 30% of the key is a catalog-fit term the night score does not have: the
  // list can put a row with FEWER usable dark hours and a LOWER night score
  // above the row under it, so the words shown to the operator say so.
  group('the ranking key and the words shown for it agree', () {
    test('catalog fit can outrank a clearly better night score', () async {
      // A (index 0): the better night, but faint. B (index 1): a poorer night
      // with fewer usable hours, but bright.
      final ranked = await rankTonightTargets(
        scorer: ScriptedNightScorer(
          byIndex: {0: (total: 90, hours: 8), 1: (total: 70, hours: 3)},
        ).call,
        raDeg: [raThatTransitsAt(darkMid), raThatTransitsAt(darkMid)],
        decDeg: [40.0, 0.0],
        magnitudes: [14.5, 5.0],
        latitudeDeg: latitude,
        longitudeDeg: longitude,
        nightDate: nightDate,
        floor: floor,
      );
      expect(ranked, hasLength(2));
      // The panel puts the bright one first, and shows it with fewer usable
      // hours than the row below it.
      expect(ranked.first.index, 1);
      expect(
        ranked.first.hoursInDarkness,
        lessThan(ranked.last.hoursInDarkness),
      );
    });

    test(
      'the tooltip states that rule instead of claiming planner parity',
      () async {
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
      },
    );
  });
}
