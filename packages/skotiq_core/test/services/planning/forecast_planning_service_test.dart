// Tests for ForecastPlanningService — the pure, I/O-free multi-night scorer.
//
// The service consumes already-fetched hourly cloud data (a RadarFetchResult of
// synthetic RadarFrames, constructed directly — no HTTP) plus a decoupled list
// of ProjectTargetCandidates, and emits a WeekForecast. These tests cover the
// fail-closed contract (error feed, partial horizon), the polar no-darkness
// path, target-up scoring, and bestNight selection.
//
// To stay timezone-robust the fixtures derive each night's dark window from
// SkyCalculations.computeTwilight at test time and place cloud frames relative
// to the computed dusk/dawn, rather than hardcoding UTC offsets that would
// shift with the runner's local zone.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/weather/radar_frame.dart';
import 'package:skotiq_core/src/services/planning/forecast_planning_service.dart';
import 'package:skotiq_core/src/services/scheduler/sky_calculations.dart';
import 'package:skotiq_core/src/services/weather/radar_provider.dart';

void main() {
  // Mid-latitude site with long winter nights, so the dark window is several
  // hours and easy to fill with hourly frames.
  const lat = 40.0;

  // A fixed local-noon anchor; the service buckets nights noon-to-noon.
  final nowLocal = DateTime(2026, 1, 15, 12);

  // Longitude chosen so the synthetic site's SOLAR time matches the test
  // runner's local clock (15° of longitude per hour of UTC offset). The
  // service interprets `nowLocal` in runner-local time, so a hardcoded
  // longitude only lines up in time zones near it — with lon -105 these
  // tests passed on UTC-5 machines but failed on UTC CI runners, where the
  // night's dark window straddled the noon-to-noon bucket boundary and the
  // night was dropped. Deriving lon from the runner's offset keeps local
  // noon ≈ solar noon in every zone.
  final lon = nowLocal.timeZoneOffset.inMinutes / 4.0;

  /// The astronomical dark window for the night anchored at [noonLocal].
  ({DateTime dusk, DateTime dawn}) darkWindow(DateTime noonLocal) {
    final tw = SkyCalculations.computeTwilight(
      noonLocal: noonLocal,
      latitudeDegrees: lat,
      longitudeDegrees: lon,
      kind: TwilightKind.astronomical,
    );
    return (dusk: tw.eveningEnd!.toUtc(), dawn: tw.morningStart!.toUtc());
  }

  /// Builds hourly cloud frames at a fixed [opacity] covering
  /// `[from - pad, to + pad]` at top-of-hour, so every dark-hour sample finds a
  /// frame within the service's 90-minute tolerance.
  List<RadarFrame> hourlyFrames({
    required DateTime from,
    required DateTime to,
    required double opacity,
    Duration pad = const Duration(hours: 3),
  }) {
    final frames = <RadarFrame>[];
    final start = from.subtract(pad);
    final end = to.add(pad);
    var t = DateTime.utc(start.year, start.month, start.day, start.hour);
    while (!t.isAfter(end)) {
      frames.add(
        RadarFrame(
          timestamp: t,
          tileUrlTemplate: '',
          north: lat + 0.5,
          south: lat - 0.5,
          east: lon + 0.5,
          west: lon - 0.5,
          opacity: opacity,
        ),
      );
      t = t.add(const Duration(hours: 1));
    }
    return frames;
  }

  // A circumpolar / high-dec target that is always well above 30° at lat 40:
  // dec ~ +70° → min altitude = lat - (90 - dec) = 40 - 20 = 20° at lower
  // culmination, but we set minAltitude 30 and it transits near 90 - |lat-dec|
  // = 60°+, so it clears 30° for the entire night.
  const alwaysUp = ProjectTargetCandidate(
    targetId: 1,
    name: 'Polaris-ish',
    raHours: 6.0,
    decDegrees: 75.0,
    minAltitudeDeg: 30.0,
  );

  // A deep-southern target that never rises above 30° at lat 40
  // (dec -60° → max altitude = 90 - |lat - dec| = 90 - 100 → never up).
  const neverUp = ProjectTargetCandidate(
    targetId: 2,
    name: 'Deep South',
    raHours: 12.0,
    decDegrees: -60.0,
    minAltitudeDeg: 30.0,
  );

  ForecastPlanningService service() =>
      ForecastPlanningService(latitudeDegrees: lat, longitudeDegrees: lon);

  group('construction', () {
    test('rejects a cloud threshold outside [0,1]', () {
      expect(
        () => ForecastPlanningService(
          latitudeDegrees: lat,
          longitudeDegrees: lon,
          cloudClearThreshold: 1.5,
        ),
        throwsArgumentError,
      );
      expect(
        () => ForecastPlanningService(
          latitudeDegrees: lat,
          longitudeDegrees: lon,
          cloudClearThreshold: -0.1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive nights count', () {
      expect(
        () => service().buildWeek(
          cloudResult: RadarFetchResult.success(
            hourlyFrames(
              from: nowLocal.toUtc(),
              to: nowLocal.add(const Duration(days: 8)).toUtc(),
              opacity: 0.0,
            ),
          ),
          targets: const [alwaysUp],
          nowLocal: nowLocal,
          nights: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('fail-closed', () {
    test('error cloud result → unavailable week, no nights, no bestNight', () {
      final week = service().buildWeek(
        cloudResult: RadarFetchResult.error('network down'),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
      );
      expect(week.available, isFalse);
      expect(week.unavailableReason, contains('network down'));
      expect(week.nights, isEmpty);
      expect(week.bestNight, isNull);
    });

    test(
      'empty-frames success → unavailable week (never fabricates clear)',
      () {
        final week = service().buildWeek(
          cloudResult: RadarFetchResult.success(const []),
          targets: const [alwaysUp],
          nowLocal: nowLocal,
        );
        expect(week.available, isFalse);
        expect(week.unavailableReason, contains('no forecast frames'));
        expect(week.bestNight, isNull);
      },
    );
  });

  group('per-night scoring', () {
    test('clear night with a target up scores high (clear fraction ~1)', () {
      final win = darkWindow(nowLocal);
      final frames = hourlyFrames(from: win.dusk, to: win.dawn, opacity: 0.0);

      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
        nights: 1,
      );

      expect(week.nights, hasLength(1));
      final night = week.nights.single;
      expect(night.forecastAvailable, isTrue);
      expect(night.darkHours, greaterThan(8.0));
      // Every dark hour is clear (opacity 0 <= 0.35 threshold).
      expect(night.clearDarkHours, closeTo(night.darkHours.floorToDouble(), 1));
      expect(night.meanCloudCoverDuringDark, closeTo(0.0, 1e-9));
      // Target is up the whole night.
      expect(night.bestTargets, hasLength(1));
      expect(night.bestTargets.single.targetId, alwaysUp.targetId);
      expect(night.bestTargets.single.upDarkHours, greaterThan(8.0));
      expect(night.bestTargets.single.maxAltitudeDeg, greaterThan(30.0));
      // Clear fraction with a target up → score near 1.
      expect(night.score, greaterThan(0.9));
    });

    test('fully clouded night scores ~0 even with a target up', () {
      final win = darkWindow(nowLocal);
      final frames = hourlyFrames(from: win.dusk, to: win.dawn, opacity: 1.0);

      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
        nights: 1,
      );

      final night = week.nights.single;
      expect(night.forecastAvailable, isTrue);
      expect(night.darkHours, greaterThan(8.0));
      expect(night.clearDarkHours, closeTo(0.0, 1e-9));
      expect(night.meanCloudCoverDuringDark, closeTo(1.0, 1e-9));
      // Target is still up, but no clear hours → score 0.
      expect(night.bestTargets, isNotEmpty);
      expect(night.score, closeTo(0.0, 1e-9));
    });

    test(
      'clear night with NO target up has empty bestTargets and scores 0',
      () {
        final win = darkWindow(nowLocal);
        final frames = hourlyFrames(from: win.dusk, to: win.dawn, opacity: 0.0);

        final week = service().buildWeek(
          cloudResult: RadarFetchResult.success(frames),
          targets: const [neverUp],
          nowLocal: nowLocal,
          nights: 1,
        );

        final night = week.nights.single;
        expect(night.forecastAvailable, isTrue);
        expect(night.clearDarkHours, greaterThan(8.0)); // genuinely clear
        expect(night.bestTargets, isEmpty); // nothing to point at
        // Composite score gates on a target being up → 0 despite clear sky.
        expect(night.score, closeTo(0.0, 1e-9));
      },
    );

    test(
      'threshold boundary: opacity exactly at threshold counts as clear',
      () {
        final win = darkWindow(nowLocal);
        // opacity == threshold (0.35) must be treated as clear (<=).
        final frames = hourlyFrames(
          from: win.dusk,
          to: win.dawn,
          opacity: 0.35,
        );

        final week = service().buildWeek(
          cloudResult: RadarFetchResult.success(frames),
          targets: const [alwaysUp],
          nowLocal: nowLocal,
          nights: 1,
        );
        final night = week.nights.single;
        expect(night.clearDarkHours, greaterThan(8.0));
        expect(night.score, greaterThan(0.9));
      },
    );

    test('a target just over threshold opacity is NOT clear', () {
      final win = darkWindow(nowLocal);
      final frames = hourlyFrames(
        from: win.dusk,
        to: win.dawn,
        opacity: 0.3501,
      );
      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
        nights: 1,
      );
      final night = week.nights.single;
      expect(night.clearDarkHours, closeTo(0.0, 1e-9));
      expect(night.score, closeTo(0.0, 1e-9));
    });
  });

  group('polar / no-darkness', () {
    test('polar summer date → darkHours 0, available (not unavailable)', () {
      // Svalbard-ish, lat 78 N, midsummer: sun never reaches -18°.
      final polarService = ForecastPlanningService(
        latitudeDegrees: 78.0,
        longitudeDegrees: 15.0,
      );
      final polarNoon = DateTime(2026, 6, 21, 12);
      // Frames are irrelevant (no dark hours to sample) but must be non-empty
      // to pass the fail-closed gate.
      final frames = hourlyFrames(
        from: polarNoon.toUtc(),
        to: polarNoon.add(const Duration(days: 1)).toUtc(),
        opacity: 0.0,
      );

      final week = polarService.buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: polarNoon,
        nights: 1,
      );

      final night = week.nights.single;
      expect(
        night.forecastAvailable,
        isTrue,
        reason: 'no darkness is honest, not a forecast failure',
      );
      expect(night.darkHours, 0.0);
      expect(night.clearDarkHours, 0.0);
      expect(night.bestTargets, isEmpty);
      expect(night.score, 0.0);
      // The week is still "available" overall; the night just scores 0.
      expect(week.available, isTrue);
      expect(
        week.bestNight,
        isNull,
        reason: 'a night with no darkness at all is not a "best night"',
      );
    });
  });

  group('partial horizon (fail-closed per-night)', () {
    test('forecast shorter than the lookahead → early nights available, later '
        'nights unavailable', () {
      // Cover only the first two nights' dark windows with frames; nights
      // beyond the horizon must be unavailable, not silently clear.
      final win0 = darkWindow(nowLocal);
      final win1 = darkWindow(nowLocal.add(const Duration(days: 1)));
      final frames = [
        ...hourlyFrames(from: win0.dusk, to: win0.dawn, opacity: 0.0),
        ...hourlyFrames(from: win1.dusk, to: win1.dawn, opacity: 0.0),
      ];

      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
        nights: 7,
      );

      expect(week.available, isTrue);
      expect(week.nights, hasLength(7));
      // Nights are sorted ascending by date.
      for (var i = 1; i < week.nights.length; i++) {
        expect(
          week.nights[i].nightDateLocal.isAfter(
            week.nights[i - 1].nightDateLocal,
          ),
          isTrue,
        );
      }
      // First two covered → available & high score.
      expect(week.nights[0].forecastAvailable, isTrue);
      expect(week.nights[0].score, greaterThan(0.9));
      expect(week.nights[1].forecastAvailable, isTrue);
      expect(week.nights[1].score, greaterThan(0.9));
      // Later nights have no cloud frame within tolerance → unavailable.
      for (var i = 2; i < week.nights.length; i++) {
        expect(
          week.nights[i].forecastAvailable,
          isFalse,
          reason: 'night $i is beyond the fetched horizon',
        );
        expect(week.nights[i].unavailableReason, contains('horizon'));
        expect(week.nights[i].score, 0.0);
      }
    });
  });

  group('bestNight selection', () {
    test('returns the highest-scoring available night', () {
      // Night 0 clear, night 1 fully clouded, night 2 partly clear (~half).
      final win0 = darkWindow(nowLocal);
      final win1 = darkWindow(nowLocal.add(const Duration(days: 1)));
      final win2 = darkWindow(nowLocal.add(const Duration(days: 2)));

      // Night 2: first half of dark hours clear, second half clouded.
      final mid2 = win2.dusk.add(
        Duration(seconds: win2.dawn.difference(win2.dusk).inSeconds ~/ 2),
      );
      final night2Clear = hourlyFrames(
        from: win2.dusk,
        to: mid2,
        opacity: 0.0,
        pad: Duration.zero,
      );
      final night2Cloud = hourlyFrames(
        from: mid2.add(const Duration(hours: 1)),
        to: win2.dawn,
        opacity: 1.0,
        pad: Duration.zero,
      );

      final frames = [
        ...hourlyFrames(from: win0.dusk, to: win0.dawn, opacity: 0.0),
        ...hourlyFrames(from: win1.dusk, to: win1.dawn, opacity: 1.0),
        ...night2Clear,
        ...night2Cloud,
      ];

      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
        nights: 3,
      );

      final best = week.bestNight;
      expect(best, isNotNull);
      // Night 0 (fully clear) must win over the clouded and half-clear nights.
      expect(best!.nightDateLocal, week.nights[0].nightDateLocal);
      expect(best.score, greaterThan(week.nights[1].score));
      expect(best.score, greaterThan(week.nights[2].score));
      // Sanity: clouded night scores ~0, half-clear scores in between.
      expect(week.nights[1].score, closeTo(0.0, 1e-9));
      expect(week.nights[2].score, greaterThan(0.0));
      expect(week.nights[2].score, lessThan(best.score));
    });
  });

  group('bestTargets ranking', () {
    test('ranks targets by up-time descending and caps at five', () {
      final win = darkWindow(nowLocal);
      final frames = hourlyFrames(from: win.dusk, to: win.dawn, opacity: 0.0);

      // Seven always-up targets at varying declinations; all clear 30° all
      // night, so up-hours tie and the tie-break is peak altitude (higher dec
      // closer to lat 40 transits higher). We only assert the cap and that
      // the highest-culminating ones survive.
      final targets = <ProjectTargetCandidate>[
        for (var i = 0; i < 7; i++)
          ProjectTargetCandidate(
            targetId: 10 + i,
            name: 'T$i',
            raHours: 6.0,
            decDegrees: 50.0 + i * 2.0, // 50..62
            minAltitudeDeg: 20.0,
          ),
      ];

      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: targets,
        nowLocal: nowLocal,
        nights: 1,
      );
      final best = week.nights.single.bestTargets;
      expect(best.length, 5, reason: 'top-N cap');
      // Descending by up-hours (then peak altitude). Verify monotonic order.
      for (var i = 1; i < best.length; i++) {
        final prev = best[i - 1];
        final cur = best[i];
        final ordered =
            prev.upDarkHours > cur.upDarkHours ||
            (prev.upDarkHours == cur.upDarkHours &&
                prev.maxAltitudeDeg >= cur.maxAltitudeDeg);
        expect(
          ordered,
          isTrue,
          reason: 'targets must be ranked desc by up-time then altitude',
        );
      }
    });
  });

  group('altitude correctness (cross-check against scheduler formula)', () {
    test('alwaysUp peak altitude matches the standard alt formula', () {
      final win = darkWindow(nowLocal);
      final frames = hourlyFrames(from: win.dusk, to: win.dawn, opacity: 0.0);
      final week = service().buildWeek(
        cloudResult: RadarFetchResult.success(frames),
        targets: const [alwaysUp],
        nowLocal: nowLocal,
        nights: 1,
      );
      final reported = week.nights.single.bestTargets.single.maxAltitudeDeg;

      // Independently compute the max altitude across the same top-of-hour
      // samples using the textbook formula + the shared LST machinery.
      var expected = double.negativeInfinity;
      var t = DateTime.utc(
        win.dusk.year,
        win.dusk.month,
        win.dusk.day,
        win.dusk.hour,
      );
      if (t.isBefore(win.dusk)) t = t.add(const Duration(hours: 1));
      while (t.isBefore(win.dawn)) {
        final alt = _refAltDeg(
          raHours: alwaysUp.raHours,
          decDegrees: alwaysUp.decDegrees,
          timeUtc: t,
          latDeg: lat,
          lonDeg: lon,
        );
        if (alt > expected) expected = alt;
        t = t.add(const Duration(hours: 1));
      }
      expect(reported, closeTo(expected, 1e-6));
    });
  });
}

/// Reference altitude (deg) using the same spherical formula and IAU GMST the
/// service uses — an independent reimplementation for cross-checking.
double _refAltDeg({
  required double raHours,
  required double decDegrees,
  required DateTime timeUtc,
  required double latDeg,
  required double lonDeg,
}) {
  final jd = SkyCalculations.julianDate(timeUtc);
  final t = (jd - 2451545.0) / 36525.0;
  var gmstDeg =
      280.46061837 +
      360.98564736629 * (jd - 2451545.0) +
      0.000387933 * t * t -
      t * t * t / 38710000.0;
  gmstDeg %= 360.0;
  if (gmstDeg < 0) gmstDeg += 360.0;
  var lstDeg = (gmstDeg + lonDeg) % 360.0;
  if (lstDeg < 0) lstDeg += 360.0;
  final lstHours = lstDeg / 15.0;
  final haRad = (lstHours - raHours) * 15.0 * math.pi / 180.0;
  final decRad = decDegrees * math.pi / 180.0;
  final latRad = latDeg * math.pi / 180.0;
  final sinAlt =
      math.sin(decRad) * math.sin(latRad) +
      math.cos(decRad) * math.cos(latRad) * math.cos(haRad);
  return math.asin(sinAlt.clamp(-1.0, 1.0)) * 180.0 / math.pi;
}
