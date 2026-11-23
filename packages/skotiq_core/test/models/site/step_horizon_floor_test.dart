// A step's own horizon (a scheduler target's customHorizon constraint) goes
// through the one floor rule with the site's horizon and minimum. Condition
// of the change: the combined floor is never below today's at any azimuth,
// where today a target had to clear both the site floor and the profile's
// own interpolation (HorizonProfile.minAltitudeAt), each on its own.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  final profiles = <String, List<HorizonSample>>{
    'one sample': [const HorizonSample(120, 25)],
    'two samples': [const HorizonSample(90, 10), const HorizonSample(270, 40)],
    'unsorted, many': [
      const HorizonSample(300, 12),
      const HorizonSample(45, 30),
      const HorizonSample(180, 5),
      const HorizonSample(10, 18),
      const HorizonSample(220, 35),
    ],
    'across the wrap': [
      const HorizonSample(350, 40),
      const HorizonSample(10, 5),
      const HorizonSample(180, 20),
    ],
    'duplicate azimuths': [
      const HorizonSample(90, 10),
      const HorizonSample(90, 30),
      const HorizonSample(180, 0),
      const HorizonSample(180, 22),
    ],
    'out of range azimuths': [
      const HorizonSample(-10, 15),
      const HorizonSample(370, 25),
      const HorizonSample(200, 8),
    ],
    'at 0 and 360': [
      const HorizonSample(0, 10),
      const HorizonSample(360, 30),
      const HorizonSample(180, 20),
    ],
    'negative altitudes': [
      const HorizonSample(0, -5),
      const HorizonSample(120, 12),
      const HorizonSample(240, -2),
    ],
  };
  final sites = <String, AltitudeFloor>{
    'no horizon, 0': const AltitudeFloor(horizon: null, minimumDeg: 0),
    'no horizon, 20': const AltitudeFloor(horizon: null, minimumDeg: 20),
    'site horizon': AltitudeFloor(
      horizon: SiteHorizonProfile.fromSamples([
        (azimuth: 0, altitude: 8),
        (azimuth: 100, altitude: 28),
        (azimuth: 250, altitude: 3),
      ]),
      minimumDeg: 15,
    ),
    'target minimum': const AltitudeFloor(
      horizon: null,
      minimumDeg: 10,
      targetMinimumDeg: 30,
    ),
  };

  test('the combined floor is never below today\'s at any azimuth', () {
    var checked = 0;
    for (final MapEntry(key: name, value: samples) in profiles.entries) {
      final step = HorizonProfile(name: name, samples: samples);
      for (final MapEntry(key: siteName, value: site) in sites.entries) {
        final combined = site.withTargetHorizon(step);
        for (var tenth = -3600; tenth <= 7200; tenth++) {
          final az = tenth / 10;
          final today = math.max(site.atAzimuth(az), step.minAltitudeAt(az));
          expect(
            combined.atAzimuth(az),
            greaterThanOrEqualTo(today - 1e-9),
            reason: '$name / $siteName at az $az',
          );
          checked++;
        }
      }
    }
    expect(checked, greaterThan(300000));
  });

  test('with no step horizon the floor is the site floor', () {
    for (final site in sites.values) {
      final same = site.withTargetHorizon(null);
      for (var az = 0.0; az < 360; az += 7.5) {
        expect(same.atAzimuth(az), site.atAzimuth(az));
      }
    }
  });
}
