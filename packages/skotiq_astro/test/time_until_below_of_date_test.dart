// Target coordinates are J2000 and must be placed in the sky of the requested
// instant: skipping precession moves altitude by ~0.3 degrees and transit by
// over a minute.
//
// Reference values: astropy 8.0.2, ICRS -> AltAz with no refraction, M42 at
// RA 5.5878 h, Dec -5.3897 deg, site 40 N 75 W, 2026-10-22.

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

const _ra = 5.5878;
const _dec = -5.3897;
const _lat = 40.0;
const _lon = -75.0;

void main() {
  test('altitude and azimuth match astropy for a J2000 target', () {
    const reference = <int, (double, double)>{
      0: (-32.487, 67.078),
      6: (32.483, 132.767),
      9: (44.218, 189.273),
      13: (13.886, 250.532),
    };
    for (final MapEntry(key: hour, value: (alt, az)) in reference.entries) {
      final (gotAlt, gotAz) = AstronomyCalculations.objectAltAz(
        raDeg: _ra * 15.0,
        decDeg: _dec,
        dt: DateTime.utc(2026, 10, 22, hour),
        latitudeDeg: _lat,
        longitudeDeg: _lon,
      );
      expect(gotAlt, closeTo(alt, 0.02), reason: 'altitude at ${hour}Z');
      expect(gotAz, closeTo(az, 0.02), reason: 'azimuth at ${hour}Z');
    }
  });

  test('transit time matches astropy (08:33:25 UTC)', () {
    final transit = AstronomyCalculations.transitOnUtcDate(
      raDeg: _ra * 15.0,
      decDeg: _dec,
      date: DateTime.utc(2026, 10, 22),
      longitudeDeg: _lon,
    );
    final expected = DateTime.utc(2026, 10, 22, 8, 33, 25);
    expect(transit.difference(expected).inSeconds.abs(), lessThan(15));
  });

  test('time to set matches astropy (14:14:20 UTC)', () {
    final now = DateTime.utc(2026, 10, 22, 12);
    final toSet = AstronomyCalculations.timeUntilBelow(
      raDeg: _ra * 15.0,
      decDeg: _dec,
      now: now,
      latitudeDeg: _lat,
      longitudeDeg: _lon,
    );
    final expected = DateTime.utc(2026, 10, 22, 14, 14, 20);
    expect(now.add(toSet!).difference(expected).inSeconds.abs(), lessThan(15));
  });
}
