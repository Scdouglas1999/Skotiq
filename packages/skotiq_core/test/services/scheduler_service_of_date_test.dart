// SchedulerService takes J2000 target coordinates and must place them in the
// sky of the requested instant, or Tonight's altitude, hour angle and transit
// disagree with Framing's and the Planner's (which precess) by ~0.3 degrees and
// over a minute of transit time.
//
// Reference values: astropy 8.0.2, ICRS -> AltAz with no refraction, M42 at
// RA 5.5878 h, Dec -5.3897 deg, site 40 N 75 W, 2026-10-22.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/scheduler_service.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations;

const _ra = 5.5878;
const _dec = -5.3897;
const _lat = 40.0;
const _lon = -75.0;

void main() {
  late ProviderContainer container;
  late SchedulerService scheduler;

  setUp(() {
    container = ProviderContainer();
    scheduler = container.read(schedulerServiceProvider);
  });
  tearDown(() => container.dispose());

  test('altitude and azimuth match astropy for a J2000 target', () {
    const reference = <int, (double, double)>{
      0: (-32.487, 67.078),
      6: (32.483, 132.767),
      9: (44.218, 189.273),
      13: (13.886, 250.532),
    };
    for (final MapEntry(key: hour, value: (alt, az)) in reference.entries) {
      final (gotAlt, gotAz) = scheduler.calculateAltAz(
        raHours: _ra,
        decDegrees: _dec,
        time: DateTime.utc(2026, 10, 22, hour),
        latitudeDegrees: _lat,
        longitudeDegrees: _lon,
      );
      expect(gotAlt, closeTo(alt, 0.02), reason: 'altitude at ${hour}Z');
      expect(gotAz, closeTo(az, 0.02), reason: 'azimuth at ${hour}Z');
    }
  });

  test('agrees with the Framing altitude (AstronomyCalculations)', () {
    for (var hour = 0; hour < 24; hour += 3) {
      final time = DateTime.utc(2026, 10, 22, hour);
      final (alt, az) = scheduler.calculateAltAz(
        raHours: _ra,
        decDegrees: _dec,
        time: time,
        latitudeDegrees: _lat,
        longitudeDegrees: _lon,
      );
      final (framingAlt, framingAz) = AstronomyCalculations.objectAltAz(
        raDeg: _ra * 15,
        decDeg: _dec,
        dt: time,
        latitudeDeg: _lat,
        longitudeDeg: _lon,
      );
      expect(alt, closeTo(framingAlt, 0.01));
      expect(az, closeTo(framingAz, 0.01));
    }
  });

  test('transit time matches astropy (08:33:25 UTC)', () {
    final transit = scheduler.calculateTransitTime(
      raHours: _ra,
      decDegrees: _dec,
      date: DateTime.utc(2026, 10, 22),
      longitudeDegrees: _lon,
    );
    final expected = DateTime.utc(2026, 10, 22, 8, 33, 25);
    expect(transit.difference(expected).inSeconds.abs(), lessThan(15));
  });

  test('time to set matches astropy (14:14:20 UTC)', () {
    final now = DateTime.utc(2026, 10, 22, 12);
    final toSet = scheduler.nextSetTime(
      raHours: _ra,
      decDegrees: _dec,
      now: now,
      latitudeDegrees: _lat,
      longitudeDegrees: _lon,
    );
    final expected = DateTime.utc(2026, 10, 22, 14, 14, 20);
    expect(now.add(toSet!).difference(expected).inSeconds.abs(), lessThan(15));
  });
}
