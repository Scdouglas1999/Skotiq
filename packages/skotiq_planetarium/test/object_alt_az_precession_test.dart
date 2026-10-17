// The alt/az the app states for a catalog object is computed for the sky of the
// requested instant, not for the sky of J2000.
//
// At 40.00N / 105.00W, Vega at 2026-08-03 20:49:14 UTC reads Alt 6.2 / Az 43.0
// straight out of the unrotated J2000 catalog position; precessing to the
// equinox of date first gives 6.14 / 42.90. The hour angle is measured from the
// equinox of DATE, so skipping precession is not a rounding error — a quarter
// century past J2000 the equinox has moved ~22 arcmin, and the 1/cos(altitude)
// amplification pushes the azimuth error to 1.4 deg for a near-zenith target
// (Pollux: 214.0 unprecessed against 212.7 true).
//
// AstronomyCalculations.precessFromJ2000ToDate is the rotation every catalog
// position passes through.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The reference site.
const _lat = 40.0;
const _lon = -105.0;

/// Vega (alpha Lyrae), J2000.
const _vegaRaDeg = 279.234735;
const _vegaDecDeg = 38.783689;

/// Pollux (beta Geminorum), J2000 — the case where the azimuth error was worst.
const _polluxRaDeg = 116.328958;
const _polluxDecDeg = 28.026183;

void main() {
  test(
    'objectAltAz precesses J2000 catalog coordinates to the epoch of date',
    () {
      final dt = DateTime.utc(2026, 8, 3, 20, 49, 14);

      final (alt, az) = AstronomyCalculations.objectAltAz(
        raDeg: _vegaRaDeg,
        decDeg: _vegaDecDeg,
        dt: dt,
        latitudeDeg: _lat,
        longitudeDeg: _lon,
      );

      // Ground truth for the equinox of date (rigorous IAU 1976 + nutation).
      expect(alt, closeTo(6.145, 0.02));
      expect(az, closeTo(42.90, 0.03));

      // And explicitly NOT the unprecessed J2000 answer the app used to state.
      final lst = AstronomyCalculations.localSiderealTime(dt, _lon);
      final (rawAlt, rawAz) = AstronomyCalculations.equatorialToHorizontal(
        raDeg: _vegaRaDeg,
        decDeg: _vegaDecDeg,
        latitudeDeg: _lat,
        lstHours: lst,
      );
      expect(rawAlt, closeTo(6.244, 0.02));
      expect(rawAz, closeTo(43.05, 0.03));
      expect((alt - rawAlt).abs(), greaterThan(0.05));
      expect((az - rawAz).abs(), greaterThan(0.05));
    },
  );

  test('the azimuth error a near-zenith target used to carry is gone', () {
    final dt = DateTime.utc(2026, 8, 3, 18, 39, 17);

    final (alt, az) = AstronomyCalculations.objectAltAz(
      raDeg: _polluxRaDeg,
      decDeg: _polluxDecDeg,
      dt: dt,
      latitudeDeg: _lat,
      longitudeDeg: _lon,
    );

    final lst = AstronomyCalculations.localSiderealTime(dt, _lon);
    final (_, rawAz) = AstronomyCalculations.equatorialToHorizontal(
      raDeg: _polluxRaDeg,
      decDeg: _polluxDecDeg,
      latitudeDeg: _lat,
      lstHours: lst,
    );

    // Near the zenith the same 22-arcmin equinox shift is amplified into more
    // than a degree of azimuth, which is enough to mis-call an obstruction
    // check or a meridian flip.
    expect(
      alt,
      greaterThan(70),
      reason: 'the amplification needs a high target',
    );
    expect((az - rawAz).abs(), greaterThan(1.0));
    // Ground truth from an independent IAU-1976 precession + GMST computation.
    expect(az, closeTo(218.771, 0.05));
    expect(rawAz, closeTo(220.093, 0.05));
  });

  test('objectAltAz agrees with an explicit precess-then-transform', () {
    final dt = DateTime.utc(2026, 12, 21, 3, 0, 0);
    final (raDate, decDate) = AstronomyCalculations.precessFromJ2000ToDate(
      raDeg: _vegaRaDeg,
      decDeg: _vegaDecDeg,
      dt: dt,
    );
    final expected = AstronomyCalculations.equatorialToHorizontal(
      raDeg: raDate,
      decDeg: decDate,
      latitudeDeg: _lat,
      lstHours: AstronomyCalculations.localSiderealTime(dt, _lon),
    );

    final actual = AstronomyCalculations.objectAltAz(
      raDeg: _vegaRaDeg,
      decDeg: _vegaDecDeg,
      dt: dt,
      latitudeDeg: _lat,
      longitudeDeg: _lon,
    );

    expect(actual.$1, closeTo(expected.$1, 1e-9));
    expect(actual.$2, closeTo(expected.$2, 1e-9));
  });
}
