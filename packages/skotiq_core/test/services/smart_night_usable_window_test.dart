import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations, TargetVisibilityInfo;

class _MockLoggingService extends Mock implements LoggingService {}

/// The Plan Tonight / "Image this target tonight" builder must not refuse every
/// non-circumpolar target with "no usable imaging window".
///
/// [TargetVisibilityInfo]'s rise/set describe ONE noon-to-noon day, chosen by
/// whatever date the scorer passed in — the night scorer passes the night
/// MIDPOINT, which for a night straddling midnight is the morning-after date.
/// The crossings that come back then belong to the following diurnal cycle, and
/// clipping tonight's dark window with them deletes the whole window. These
/// tests pin the crossing-to-interval mapping in both directions, and pin that
/// real clipping still happens.
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

  group('usable target window', () {
    test('builds when the scorer reported the NEXT cycle\'s crossings '
        '(the M92 "no usable imaging window" P0)', () {
      // Verbatim from the live failure: site 40.0N/-75.0W, dark window
      // 22:01:44 -> 04:11:18, and a visibility scored from the night
      // midpoint, so the rise it carries is the *following* midday.
      final windowStart = DateTime(2026, 8, 1, 22, 1, 44);
      final windowEnd = DateTime(2026, 8, 2, 4, 11, 18);

      final result = service.buildSingleTargetSequence(
        profile: profile,
        suggestion: suggestionWith(
          rise: DateTime(2026, 8, 2, 12, 1),
          set: DateTime(2026, 8, 3, 5, 41),
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: profile.filterNames,
        settings: settings,
      );

      expect(result.plannedTarget.windowStart, windowStart);
      expect(headerOf(result).startAfter, windowStart);
      // The night is 6h10m; the target is up for all of it.
      expect(
        result.plannedTarget.windowEnd.isAfter(
          windowStart.add(const Duration(hours: 1)),
        ),
        isTrue,
        reason: 'the whole dark window is usable for this target',
      );
    });

    test('builds when the scorer reported the PREVIOUS cycle\'s crossings', () {
      final windowStart = DateTime(2026, 8, 1, 22, 1, 44);
      final windowEnd = DateTime(2026, 8, 2, 4, 11, 18);

      final result = service.buildSingleTargetSequence(
        profile: profile,
        suggestion: suggestionWith(
          rise: DateTime(2026, 7, 31, 12, 5),
          set: DateTime(2026, 8, 1, 5, 45),
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: profile.filterNames,
        settings: settings,
      );

      expect(result.plannedTarget.windowStart, windowStart);
    });

    test('still clips the window at a set that falls inside it', () {
      final windowStart = DateTime(2026, 8, 1, 22, 1);
      final windowEnd = DateTime(2026, 8, 2, 4, 11);
      final set = DateTime(2026, 8, 1, 23);

      final result = service.buildSingleTargetSequence(
        profile: profile,
        suggestion: suggestionWith(
          rise: DateTime(2026, 8, 1, 14),
          set: set,
          peakAltitude: 60,
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: profile.filterNames,
        settings: settings,
      );

      expect(result.plannedTarget.windowStart, windowStart);
      expect(
        result.plannedTarget.windowEnd.isAfter(set),
        isFalse,
        reason: 'imaging must stop when the target sets',
      );
      expect(headerOf(result).endBefore!.isAfter(set), isFalse);
    });

    test('still clips the window at a rise that falls inside it', () {
      final windowStart = DateTime(2026, 8, 1, 22, 1);
      final windowEnd = DateTime(2026, 8, 2, 4, 11);
      final rise = DateTime(2026, 8, 2, 1);

      final result = service.buildSingleTargetSequence(
        profile: profile,
        suggestion: suggestionWith(
          rise: rise,
          set: DateTime(2026, 8, 2, 10),
          peakAltitude: 55,
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: profile.filterNames,
        settings: settings,
      );

      expect(result.plannedTarget.windowStart, rise);
      expect(headerOf(result).startAfter, rise);
    });

    test('takes the longer span when the target dips mid-window', () {
      // High declination, lower culmination inside the dark window: the target
      // is up at both ends and below the horizon in the middle, so there are
      // two disjoint usable spans. The builder returns one contiguous window,
      // so it must be the longer of the two (22:01 -> 23:30, not 03:30 ->
      // 04:11).
      final windowStart = DateTime(2026, 8, 1, 22, 1);
      final windowEnd = DateTime(2026, 8, 2, 4, 11);

      final result = service.buildSingleTargetSequence(
        profile: profile,
        suggestion: suggestionWith(
          rise: DateTime(2026, 8, 2, 3, 30),
          set: DateTime(2026, 8, 1, 23, 30),
          peakAltitude: 70,
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: profile.filterNames,
        settings: settings,
      );

      expect(result.plannedTarget.windowStart, windowStart);
      expect(
        result.plannedTarget.windowEnd.isAfter(DateTime(2026, 8, 1, 23, 30)),
        isFalse,
      );
    });

    test('rejects a target whose peak stays below the minimum altitude', () {
      expect(
        () => service.buildSingleTargetSequence(
          profile: profile,
          suggestion: suggestionWith(
            rise: DateTime(2026, 8, 1, 20),
            set: DateTime(2026, 8, 2, 6),
            peakAltitude: 12,
          ),
          windowStart: DateTime(2026, 8, 1, 22, 1),
          windowEnd: DateTime(2026, 8, 2, 4, 11),
          availableFilters: profile.filterNames,
          settings: settings,
        ),
        throwsA(isA<SmartNightBuildException>()),
      );
    });

    // End-to-end cover against real astronomy rather than hand-written
    // crossings: score the visibility exactly the way
    // TargetScoringService.scoreTargetForNight does (anchored on the night
    // MIDPOINT) and feed the result straight to the builder. Because the
    // midpoint of a midnight-straddling window always lands on the morning
    // date, the scored crossings belong to the next 24h day whatever wall
    // clock the host runs in — which is what made the interval unclippable.
    // Ground truth (peak altitude, minutes above the floor) is sampled from
    // the same ephemeris so the expectation holds in any timezone.
    test('M92 at 40N builds from a scorer-produced visibility', () {
      const raDeg = 259.28; // M92
      const decDeg = 43.136;
      const latitude = 40.0;
      const longitude = -75.0;
      const minAltitude = 30.0;

      final windowStart = DateTime(2026, 8, 1, 22, 1, 44);
      final windowEnd = DateTime(2026, 8, 2, 4, 11, 18);
      final nightMid = windowStart.add(
        Duration(seconds: windowEnd.difference(windowStart).inSeconds ~/ 2),
      );

      final scored = AstronomyCalculations.calculateObjectVisibility(
        raDeg: raDeg,
        decDeg: decDeg,
        date: nightMid,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );

      // Premise: the scored crossings sit a whole diurnal cycle away from the
      // interval they are about to be clipped against.
      expect(scored.riseTime, isNotNull);
      expect(scored.riseTime!.isAfter(windowEnd), isTrue);

      // Ground truth from the same ephemeris.
      var peakAlt = -90.0;
      DateTime? peakTime;
      var minutesAbove = 0;
      for (
        var t = windowStart;
        !t.isAfter(windowEnd);
        t = t.add(const Duration(minutes: 1))
      ) {
        final (alt, _) = AstronomyCalculations.objectAltAz(
          raDeg: raDeg,
          decDeg: decDeg,
          dt: t,
          latitudeDeg: latitude,
          longitudeDeg: longitude,
        );
        if (alt > peakAlt) {
          peakAlt = alt;
          peakTime = t;
        }
        if (alt >= minAltitude) minutesAbove++;
      }

      final suggestion = suggestionWith(
        rise: scored.riseTime,
        set: scored.setTime,
        peakAltitude: peakAlt,
        hoursAboveMinAlt: minutesAbove / 60,
      );

      if (peakAlt < minAltitude) {
        // Only reachable from a wall clock where this window is daytime at the
        // site; the builder is right to refuse.
        expect(
          () => service.buildSingleTargetSequence(
            profile: profile,
            suggestion: suggestion,
            windowStart: windowStart,
            windowEnd: windowEnd,
            availableFilters: profile.filterNames,
            settings: settings,
          ),
          throwsA(isA<SmartNightBuildException>()),
        );
        return;
      }

      final result = service.buildSingleTargetSequence(
        profile: profile,
        suggestion: suggestion,
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: profile.filterNames,
        settings: settings,
      );

      // The usable window must have opened by the moment the target is
      // highest — anything later means the crossings clipped real dark time
      // away again.
      expect(
        result.plannedTarget.windowStart.isAfter(peakTime!),
        isFalse,
        reason: 'imaging must have started by the target\'s peak',
      );
    });
  });
}
