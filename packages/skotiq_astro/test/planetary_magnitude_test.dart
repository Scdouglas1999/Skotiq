import 'dart:math' as math;

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  group('Planetary magnitude', () {
    test(
      'Venus apparent magnitude stays physically bright across its full orbit',
      () {
        // Sample Venus across an entire synodic period (~584 days). Venus
        // always sits between ~-3.5 and -4.9; the previous (geoLon - earthLon)
        // bug erroneously pushed Venus fainter than +0.5 near superior conjunction.
        final start = DateTime.utc(2026, 1, 1);
        for (var day = 0; day < 600; day += 30) {
          final dt = start.add(Duration(days: day));
          final planets = PlanetaryPositions.getAllPlanetPositions(dt);
          final venus = planets.firstWhere((p) => p.name == 'Venus');
          expect(venus.magnitude.isFinite, isTrue);
          expect(
            venus.magnitude,
            inInclusiveRange(-5.0, -3.2),
            reason: 'Venus magnitude at $dt was ${venus.magnitude}',
          );
        }
      },
    );

    test('Meeus Example 41.a: Venus on 1992 December 20', () {
      // Meeus, Astronomical Algorithms, the Venus example for 1992 Dec 20.0 TD.
      // Published distances: r = 0.724604 AU, Δ = 0.910947 AU, i = 72.96°.
      // Muller's formula is what the book rounds to -3.8. The expressions the
      // Astronomical Almanac has used since 1984, which Meeus prints in the
      // same section and which this code implements, evaluate to -4.217 for
      // those same distances.
      const r = 0.724604;
      const delta = 0.910947;
      const phaseDeg = 72.96;
      final muller =
          -4.00 +
          5 * math.log(r * delta) / math.ln10 +
          0.01322 * phaseDeg +
          0.0000004247 * phaseDeg * phaseDeg * phaseDeg;
      expect((muller * 10).round() / 10, -3.8);

      final almanac =
          -4.40 +
          5 * math.log(r * delta) / math.ln10 +
          0.0009 * phaseDeg +
          0.000239 * phaseDeg * phaseDeg -
          0.00000065 * phaseDeg * phaseDeg * phaseDeg;
      expect(almanac, closeTo(-4.217, 0.001));

      final planets = PlanetaryPositions.getAllPlanetPositions(
        DateTime.utc(1992, 12, 20),
      );
      final venus = planets.firstWhere((p) => p.name == 'Venus');
      expect(
        venus.magnitude,
        closeTo(almanac, 0.01),
        reason:
            '1992 Dec 20 Venus should match the Almanac formula on Meeus '
            'example distances ($almanac); got ${venus.magnitude}',
      );
    });
  });
}
