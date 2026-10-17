// A bright moon must cost something, and it must be said out loud.
//
// `_scoreMoonDistance` returned a flat 100 for any separation past
// `30 + 70*illumination`, so a FULL moon at 101° scored 100 while a NEW moon at
// the same separation scored 95.6 — the moon factor literally rewarded the worse
// night. And `_moonProximityWarnings` only fired below 45°, so on a full-moon
// night with wide separations nothing warned at all: Plan Tonight described a
// 100%-illuminated sky exactly the way it describes a new-moon sky.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _Fixture implements CelestialObject {
  @override
  final String id;
  @override
  final String name;
  @override
  final CelestialCoordinate coordinates;

  const _Fixture({
    required this.id,
    required this.name,
    required this.coordinates,
  });

  @override
  double? get magnitude => null;
}

void main() {
  // NGC6015-like: high in the north, and far from a moon parked to the south.
  const target = _Fixture(
    id: 'ngc6015',
    name: 'NGC6015',
    coordinates: CelestialCoordinate(ra: 15.86, dec: 62.31),
  );
  const moonFarAway = (60.0, -20.0);
  final observationTime = DateTime.utc(2026, 7, 30, 2, 0);

  TargetScore scoreAt(double illumination) {
    final service = TargetScoringService(
      latitude: 40.0,
      longitude: -75.0,
      observationTime: observationTime,
      moonPosition: moonFarAway,
      moonIllumination: illumination,
    );
    return service.scoreTarget(target);
  }

  test(
    'a full moon cannot score as well as a new moon at equal separation',
    () {
      final newMoon = scoreAt(2);
      final fullMoon = scoreAt(100);

      // Same geometry, so the separation is identical…
      expect(
        fullMoon.visibility.moonDistance,
        closeTo(newMoon.visibility.moonDistance, 0.001),
      );
      expect(fullMoon.visibility.moonDistance, greaterThan(45));
      // …and the only difference is how much moonlight there is.
      expect(
        fullMoon.moonDistanceScore,
        lessThan(newMoon.moonDistanceScore),
        reason: 'a 100%-illuminated sky must not out-score a dark one',
      );
      expect(fullMoon.moonDistanceScore, lessThan(100));
    },
  );

  test('the moon sub-score falls monotonically as the moon brightens', () {
    final scores = [
      for (final i in [2.0, 30.0, 60.0, 100.0]) scoreAt(i),
    ].map((score) => score.moonDistanceScore).toList();

    for (var i = 1; i < scores.length; i++) {
      expect(
        scores[i],
        lessThanOrEqualTo(scores[i - 1]),
        reason: 'moon scores $scores should not rise with illumination',
      );
    }
  });

  test('a bright moon warns even when the target is far from it', () {
    final warnings = scoreAt(
      100,
    ).warnings.where((w) => w.type == WarningType.moonProximity).toList();

    expect(
      warnings,
      hasLength(1),
      reason: 'nothing warned on a full-moon night with wide separation',
    );
    expect(warnings.single.message, contains('100%'));
    expect(warnings.single.suggestion, contains('arrowband'));
  });

  test('a new moon night still warns about nothing', () {
    expect(
      scoreAt(2).warnings.where((w) => w.type == WarningType.moonProximity),
      isEmpty,
    );
  });
}
