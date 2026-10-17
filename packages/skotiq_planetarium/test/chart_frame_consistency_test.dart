// Everything on the sky chart shares ONE equinox.
//
// The star and DSO catalogues are J2000. The planetary theory (VSOP87D), the
// Sun and the Moon are theories of DATE, so output that reaches the chart
// unconverted draws the 2026 solar-system bodies ~22 arcmin (about two thirds
// of a Moon diameter) from the star background they are read against — Jupiter
// beside M44 with the wrong separation.
//
// Ground truth for the planet case is an independent Keplerian ephemeris, which
// the app's own truncated VSOP agrees with to ~0.4 arcmin at that instant — so
// a 3 arcmin tolerance is far inside the theory's error while the wrong frame
// is 22 arcmin away.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/astronomy/planetary_positions.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';

/// The audited instant.
final _instant = DateTime.utc(2026, 8, 2, 15, 12);

double _hmsToDeg(int h, int m, double s) => (h + m / 60 + s / 3600) * 15;
double _dmsToDeg(int d, int m, double s) => d + m / 60 + s / 3600;

/// Jupiter at [_instant], from the audit's independent ephemeris.
final _jupiterJ2000RaDeg = _hmsToDeg(8, 37, 58.3);
final _jupiterJ2000DecDeg = _dmsToDeg(18, 59, 31);
final _jupiterOfDateRaDeg = _hmsToDeg(8, 39, 29.5);
final _jupiterOfDateDecDeg = _dmsToDeg(18, 53, 50);

double _separationArcmin(
  double ra1Deg,
  double dec1Deg,
  double ra2Deg,
  double dec2Deg,
) =>
    AstronomyCalculations.angularSeparation(
      ra1Deg: ra1Deg,
      dec1Deg: dec1Deg,
      ra2Deg: ra2Deg,
      dec2Deg: dec2Deg,
    ) *
    60;

void main() {
  group('precession round trip', () {
    test('precessFromDateToJ2000 exactly inverts precessFromJ2000ToDate', () {
      for (final (ra, dec) in const [
        (0.0, 0.0),
        (83.822, -5.391), // M42
        (310.358, 45.28), // Deneb
        (45.0, -80.0),
        (359.9, 89.0),
      ]) {
        final ofDate = AstronomyCalculations.precessFromJ2000ToDate(
          raDeg: ra,
          decDeg: dec,
          dt: _instant,
        );
        final back = AstronomyCalculations.precessFromDateToJ2000(
          raDeg: ofDate.$1,
          decDeg: ofDate.$2,
          dt: _instant,
        );
        expect(_separationArcmin(back.$1, back.$2, ra, dec), lessThan(1e-6));
      }
    });
  });

  group('planets share the catalogue frame', () {
    test('Jupiter comes out in J2000, not the equinox of date', () {
      // Index 3 = Jupiter, via the same entry point the providers use.
      final planets = PlanetaryPositions.getAllPlanetPositions(_instant);
      final jupiter = planets.firstWhere((p) => p.name == 'Jupiter');
      final raDeg = jupiter.ra * 15;

      expect(
        _separationArcmin(
          raDeg,
          jupiter.dec,
          _jupiterJ2000RaDeg,
          _jupiterJ2000DecDeg,
        ),
        lessThan(3.0),
        reason: 'planets must be published in the J2000 catalogue frame',
      );
      expect(
        _separationArcmin(
          raDeg,
          jupiter.dec,
          _jupiterOfDateRaDeg,
          _jupiterOfDateDecDeg,
        ),
        greaterThan(15.0),
        reason: 'and must no longer be the equinox-of-date place',
      );
    });

    test('the two reference places really are ~22 arcmin apart', () {
      // Guards the test itself: if this shrank, the assertions above would stop
      // discriminating between the frames.
      expect(
        _separationArcmin(
          _jupiterJ2000RaDeg,
          _jupiterJ2000DecDeg,
          _jupiterOfDateRaDeg,
          _jupiterOfDateDecDeg,
        ),
        closeTo(22.0, 2.0),
      );
    });
  });

  group('Sun and Moon reach the chart in the catalogue frame', () {
    ProviderContainer pinnedAt(DateTime time) {
      final container = ProviderContainer();
      container.read(observationTimeProvider.notifier).setTime(time);
      return container;
    }

    test('sunPositionProvider is the J2000 place of the of-date Sun', () {
      final container = pinnedAt(_instant);
      addTearDown(container.dispose);

      // The provider quantises to the minute, and _instant is minute-aligned.
      final (ra, dec) = container.read(sunPositionProvider);
      final (ofDateRa, ofDateDec) = AstronomyCalculations.sunPosition(_instant);

      final forward = AstronomyCalculations.precessFromJ2000ToDate(
        raDeg: ra,
        decDeg: dec,
        dt: _instant,
      );
      expect(
        _separationArcmin(forward.$1, forward.$2, ofDateRa, ofDateDec),
        lessThan(1e-6),
        reason: 'the chart Sun must be exactly the of-date Sun, de-precessed',
      );
      expect(
        _separationArcmin(ra, dec, ofDateRa, ofDateDec),
        greaterThan(15.0),
        reason: 'and the conversion must not be a no-op',
      );
    });

    test('moonPositionProvider is the J2000 place of the of-date Moon', () {
      final container = pinnedAt(_instant);
      addTearDown(container.dispose);

      final (ra, dec, distance) = container.read(moonPositionProvider);
      final (ofDateRa, ofDateDec, ofDateDistance) =
          AstronomyCalculations.moonPosition(_instant);

      final forward = AstronomyCalculations.precessFromJ2000ToDate(
        raDeg: ra,
        decDeg: dec,
        dt: _instant,
      );
      expect(
        _separationArcmin(forward.$1, forward.$2, ofDateRa, ofDateDec),
        lessThan(1e-6),
      );
      expect(
        _separationArcmin(ra, dec, ofDateRa, ofDateDec),
        greaterThan(15.0),
      );
      // Distance is frame independent and must pass through untouched.
      expect(distance, ofDateDistance);
    });

    test('twilight and altitude keep their apparent (of-date) Sun', () {
      // sunAltitude/rise-set must NOT be dragged into J2000: an observer's
      // horizon is an of-date quantity. This pins that split.
      final container = pinnedAt(_instant);
      addTearDown(container.dispose);
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40.0, longitude: -105.0);

      final apparent = AstronomyCalculations.sunAltitude(
        dt: _instant,
        latitudeDeg: 40.0,
        longitudeDeg: -105.0,
      );
      expect(container.read(sunAltitudeProvider), closeTo(apparent, 1e-9));
    });
  });
}
