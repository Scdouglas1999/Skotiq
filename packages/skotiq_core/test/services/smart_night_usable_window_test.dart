import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_astro/skotiq_astro.dart'
    show AstronomyCalculations, TargetVisibilityInfo;

class _MockLoggingService extends Mock implements LoggingService {}

/// The window a target is planned into is the longest stretch it stands above
/// the site's altitude floor inside the dark window, worked out from where the
/// target is in the sky. What a suggestion says about rise and set (one
/// noon-to-noon day, chosen by whoever scored it) does not decide it.
/// No horizon set and a 30 degree minimum altitude.
const _minimum30 = AltitudeFloor(horizon: null, minimumDeg: 30);

const _siteLatitude = 40.0;
const _siteLongitude = -75.0;

void main() {
  const profile = EquipmentProfileModel(
    id: 1,
    name: 'ASI2600MM + RedCat 71',
    focalLength: 350,
    aperture: 71,
    focalRatio: 4.9,
    cameraName: 'ZWO ASI2600MM Pro',
    telescopeName: 'WO RedCat 71',
    mountName: 'ZWO AM5',
    defaultGain: 100,
    defaultOffset: 50,
    filterNames: ['L'],
  );

  const settings = SmartNightSettings(subExposureFloorSecs: 1);

  late SmartNightService service;

  setUp(() {
    service = SmartNightService(
      suggestionService: TargetSuggestionService(
        loggingService: _MockLoggingService(),
      ),
      logging: _MockLoggingService(),
      floor: _minimum30,
    );
  });

  TargetSuggestion suggestionWith({
    required DateTime? rise,
    required DateTime? set,
    double peakAltitude = 84,
    double hoursAboveMinAlt = 5.3,
    double raHours = 17.285,
    double decDegrees = 43.136,
  }) {
    return TargetSuggestion(
      targetId: 92,
      targetName: 'M92',
      raHours: raHours,
      decDegrees: decDegrees,
      totalScore: 77,
      objectType: 'Globular Cluster',
      visibility: TargetVisibilityInfo(
        currentAltitude: 50,
        currentAzimuth: 180,
        airmass: 1.2,
        moonDistance: 90,
        peakAltitude: peakAltitude,
        hoursAboveMinAlt: hoursAboveMinAlt,
        riseTime: rise,
        setTime: set,
      ),
    );
  }

  TargetHeaderNode headerOf(SingleTargetSequenceResult result) =>
      result.sequence.nodes.values.whereType<TargetHeaderNode>().single;

  // 22:01 to 04:11 local at the site, in UTC so the test reads the same sky
  // on any machine.
  final darkStart = DateTime.utc(2026, 8, 2, 2, 1);
  final darkEnd = DateTime.utc(2026, 8, 2, 8, 11);

  /// Every stretch inside the dark window that a target stands above
  /// [floor], minute by minute from the ephemeris.
  List<(DateTime, DateTime)> stretchesAbove(
    AltitudeFloor floor,
    double raHours,
    double decDegrees,
  ) {
    final stretches = <(DateTime, DateTime)>[];
    DateTime? open;
    for (
      var t = darkStart;
      !t.isAfter(darkEnd);
      t = t.add(const Duration(minutes: 1))
    ) {
      final (alt, az) = AstronomyCalculations.objectAltAz(
        raDeg: raHours * 15,
        decDeg: decDegrees,
        dt: t,
        latitudeDeg: _siteLatitude,
        longitudeDeg: _siteLongitude,
      );
      final above = alt >= floor.atAzimuth(az);
      if (above) {
        open ??= t;
      } else if (open != null) {
        stretches.add((open, t));
        open = null;
      }
    }
    if (open != null) stretches.add((open, darkEnd));
    return stretches;
  }

  SingleTargetSequenceResult build(
    SmartNightService service,
    double raHours,
    double decDegrees, {
    DateTime? rise,
    DateTime? set,
  }) => service.buildSingleTargetSequence(
    profile: profile,
    suggestion: suggestionWith(
      rise: rise,
      set: set,
      raHours: raHours,
      decDegrees: decDegrees,
    ),
    windowStart: darkStart,
    windowEnd: darkEnd,
    latitudeDeg: _siteLatitude,
    longitudeDeg: _siteLongitude,
    availableFilters: profile.filterNames,
    settings: settings,
  );

  SmartNightService serviceWith(AltitudeFloor floor) => SmartNightService(
    suggestionService: TargetSuggestionService(
      loggingService: _MockLoggingService(),
    ),
    logging: _MockLoggingService(),
    floor: floor,
  );

  group('usable target window', () {
    test('a target above the floor all night gets the whole dark window, '
        'whatever day the suggestion\'s rise and set belong to', () {
      // Five degrees from the pole: 35 to 45 degrees up all night from 40 N.
      expect(stretchesAbove(_minimum30, 17.285, 85), [(darkStart, darkEnd)]);
      for (final (rise, set) in [
        (null, null),
        // The following day's crossings, as a scorer anchored on the night's
        // midpoint reports them.
        (DateTime.utc(2026, 8, 2, 16, 1), DateTime.utc(2026, 8, 3, 9, 41)),
        // The previous day's.
        (DateTime.utc(2026, 7, 31, 16, 5), DateTime.utc(2026, 8, 1, 9, 45)),
      ]) {
        final result = build(service, 17.285, 85, rise: rise, set: set);
        expect(result.plannedTarget.windowStart, darkStart);
        expect(headerOf(result).startAfter, darkStart);
        // Its integration budget, not the sky, ends the plan.
        expect(
          result.plannedTarget.windowEnd.isAfter(
            darkStart.add(const Duration(hours: 1)),
          ),
          isTrue,
        );
      }
    });

    test('the window ends when the target drops below the floor', () {
      // Arcturus is in the west and sinking through 30 degrees.
      final truth = stretchesAbove(_minimum30, 14.26, 19.18).single;
      expect(truth.$1, darkStart);
      expect(truth.$2.isBefore(darkEnd), isTrue);

      final result = build(service, 14.26, 19.18);
      expect(result.plannedTarget.windowStart, darkStart);
      // The plan stops a few seconds short of the crossing.
      expect(
        truth.$2.difference(result.plannedTarget.windowEnd).abs(),
        lessThan(const Duration(minutes: 1)),
      );
      expect(headerOf(result).endBefore, result.plannedTarget.windowEnd);
    });

    test('the window starts when the target clears the floor', () {
      // The Pleiades rise through 30 degrees before dawn.
      final truth = stretchesAbove(_minimum30, 3.79, 24.1).single;
      expect(truth.$1.isAfter(darkStart), isTrue);
      expect(truth.$2, darkEnd);

      final result = build(service, 3.79, 24.1);
      expect(result.plannedTarget.windowStart, truth.$1);
      expect(headerOf(result).startAfter, truth.$1);
    });

    test('takes the longest stretch when the horizon hides the target for a '
        'while', () {
      // A chimney 80 degrees tall and 6 degrees wide where M92 stands an
      // hour and a half into the night; open sky elsewhere.
      final (_, chimney) = AstronomyCalculations.objectAltAz(
        raDeg: 17.285 * 15,
        decDeg: 43.136,
        dt: darkStart.add(const Duration(minutes: 90)),
        latitudeDeg: _siteLatitude,
        longitudeDeg: _siteLongitude,
      );
      final floor = AltitudeFloor(
        horizon: SiteHorizonProfile.fromSamples([
          (azimuth: 0, altitude: 0),
          (azimuth: chimney - 3.1, altitude: 0),
          (azimuth: chimney - 3, altitude: 80),
          (azimuth: chimney + 3, altitude: 80),
          (azimuth: chimney + 3.1, altitude: 0),
          (azimuth: 359, altitude: 0),
        ]),
        minimumDeg: 30,
      );
      final truth = stretchesAbove(floor, 17.285, 43.136);
      expect(truth.length, 2, reason: 'before the chimney and after it');
      final longest = truth.reduce(
        (a, b) => b.$2.difference(b.$1) > a.$2.difference(a.$1) ? b : a,
      );
      expect(longest, truth.last);

      final result = build(serviceWith(floor), 17.285, 43.136);
      expect(result.plannedTarget.windowStart, longest.$1);
      expect(
        longest.$2.difference(result.plannedTarget.windowEnd).abs(),
        lessThan(const Duration(minutes: 1)),
      );
    });

    test('refuses a target that never clears the floor', () {
      // Declination -45 culminates 5 degrees up from 40 N.
      expect(stretchesAbove(_minimum30, 18, -45), isEmpty);
      expect(
        () => build(service, 18, -45),
        throwsA(isA<SmartNightBuildException>()),
      );
    });
  });
}
