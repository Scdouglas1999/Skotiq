import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  group('Batch 4 astronomy correctness regressions', () {
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

    test(
      'precession/nutation at celestial poles (+90/-90 deg) stays finite and round-trips',
      () {
        final dt = DateTime.utc(2026, 11, 21, 0, 0, 0);
        for (final poleDec in [90.0, -90.0, 89.999, -89.999]) {
          final (raDate, decDate) = AstronomyCalculations.precessFromJ2000ToDate(
            raDeg: 45.0,
            decDeg: poleDec,
            dt: dt,
          );
          expect(raDate.isFinite, isTrue);
          expect(decDate.isFinite, isTrue);
          expect(decDate, inInclusiveRange(-90.0, 90.0));

          final (raBack, decBack) = AstronomyCalculations.precessFromDateToJ2000(
            raDeg: raDate,
            decDeg: decDate,
            dt: dt,
          );
          expect(raBack.isFinite, isTrue);
          expect(decBack.isFinite, isTrue);
          expect(decBack, closeTo(poleDec, 1e-4));
        }
      },
    );
  });
}
