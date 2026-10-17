import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';

/// The twilight crossing finder.
///
/// Comparing only the search window's endpoint altitudes returns null whenever
/// the window holds zero or two crossings of matching endpoint sign — e.g.
/// high-latitude summer sites where sunset slips past local midnight. The
/// finder brackets the first crossing in the requested direction with a coarse
/// scan, so these tests brute-force the truth with a fine scan and require
/// agreement.
void main() {
  const sunRiseSetAltitude = -0.8333;

  /// Brute-force: first descending (or rising) crossing of [targetAlt]
  /// in [start, end), scanning at 1-minute resolution.
  ///
  /// [targetAlt] is a GEOMETRIC sun-centre altitude (the -0.8333 deg rise/set
  /// limb already contains the -34' refraction allowance), so the scan reads
  /// geometric altitude. Scanning the refracted altitude against it would
  /// count refraction twice and make this oracle agree with the very bug it
  /// exists to catch.
  DateTime? bruteForceCrossing({
    required DateTime start,
    required DateTime end,
    required double targetAlt,
    required double lat,
    required double lon,
    required bool rising,
  }) {
    var t = start;
    var prev =
        AstronomyCalculations.sunAltitude(
          dt: t,
          latitudeDeg: lat,
          longitudeDeg: lon,
          apparent: false,
        ) -
        targetAlt;
    while (t.isBefore(end)) {
      final next = t.add(const Duration(minutes: 1));
      final cur =
          AstronomyCalculations.sunAltitude(
            dt: next,
            latitudeDeg: lat,
            longitudeDeg: lon,
            apparent: false,
          ) -
          targetAlt;
      if (rising ? (prev < 0 && cur >= 0) : (prev > 0 && cur <= 0)) {
        return next;
      }
      t = next;
      prev = cur;
    }
    return null;
  }

  // Latitudes from equatorial to polar, longitudes spread across the globe so
  // the test exercises sites whose solar midnight is far from the machine's
  // civil midnight.
  final sites = <(double, double, String)>[
    (0.0, 0.0, 'equator/Greenwich'),
    (64.15, -21.95, 'Reykjavik'),
    (69.65, 18.96, 'Tromso'),
    (-33.92, 18.42, 'Cape Town'),
    (61.22, -149.90, 'Anchorage'),
    (35.68, 139.69, 'Tokyo'),
  ];
  final dates = <DateTime>[
    DateTime(2026, 6, 21),
    DateTime(2026, 12, 21),
    DateTime(2026, 3, 20),
  ];

  group('calculateTwilightTimes window coverage', () {
    for (final (lat, lon, name) in sites) {
      for (final date in dates) {
        test('$name ${date.toIso8601String().substring(0, 10)}', () {
          final twilight = AstronomyCalculations.calculateTwilightTimes(
            date: date,
            latitudeDeg: lat,
            longitudeDeg: lon,
          );

          // Mirror the implementation's anchor: the site's solar noon
          // expressed in machine civil time.
          final machineNoon = DateTime(date.year, date.month, date.day, 12);
          final tzOffsetHours = machineNoon.timeZoneOffset.inMinutes / 60.0;
          final noon = machineNoon.add(
            Duration(minutes: ((tzOffsetHours - lon / 15.0) * 60).round()),
          );
          final expectedSunset = bruteForceCrossing(
            start: noon,
            end: noon.add(const Duration(hours: 24)),
            targetAlt: sunRiseSetAltitude,
            lat: lat,
            lon: lon,
            rising: false,
          );
          final expectedSunrise = bruteForceCrossing(
            start: noon.add(const Duration(hours: 12)),
            end: noon.add(const Duration(hours: 30)),
            targetAlt: sunRiseSetAltitude,
            lat: lat,
            lon: lon,
            rising: true,
          );

          if (expectedSunset == null) {
            expect(
              twilight.sunset,
              isNull,
              reason:
                  'no sunset exists (polar day/night) but one was '
                  'reported',
            );
          } else {
            expect(
              twilight.sunset,
              isNotNull,
              reason:
                  'sunset exists at '
                  '${expectedSunset.toIso8601String()} but the finder '
                  'returned null — window/bracketing regression',
            );
            expect(
              twilight.sunset!.difference(expectedSunset).inMinutes.abs(),
              lessThanOrEqualTo(2),
            );
          }

          if (expectedSunrise == null) {
            expect(
              twilight.sunrise,
              isNull,
              reason:
                  'no sunrise exists (polar day/night) but one was '
                  'reported',
            );
          } else {
            expect(
              twilight.sunrise,
              isNotNull,
              reason:
                  'sunrise exists at '
                  '${expectedSunrise.toIso8601String()} but the finder '
                  'returned null — window/bracketing regression',
            );
            expect(
              twilight.sunrise!.difference(expectedSunrise).inMinutes.abs(),
              lessThanOrEqualTo(2),
            );
          }

          // Dusk/dawn ordering sanity whenever both exist: astronomical
          // dusk must come after sunset, dawn before sunrise.
          if (twilight.sunset != null && twilight.astronomicalDusk != null) {
            expect(
              twilight.astronomicalDusk!.isAfter(twilight.sunset!),
              isTrue,
            );
          }
          if (twilight.sunrise != null && twilight.astronomicalDawn != null) {
            expect(
              twilight.astronomicalDawn!.isBefore(twilight.sunrise!),
              isTrue,
            );
          }
        });
      }
    }
  });
}
