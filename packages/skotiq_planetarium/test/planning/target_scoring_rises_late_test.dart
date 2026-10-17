// The "rises late" warning must describe the night the operator is planning.
//
// Live finding: the Night Outlook hero card carried "⚠ Rises late at 11:54"
// for a target that was already above 80° when astronomical darkness began and
// stayed up all night. The warning was gated on `visibility.riseTime`, which
// comes from a separate noon-to-noon solve of the GEOMETRIC horizon crossing.
// When a target's rise falls just before local noon, the first crossing inside
// that window is the NEXT morning's — an instant in broad daylight, hours
// after the night has ended — and every test of "is that after nightStart?"
// says yes.
//
// The night sampler already knows the honest answer: the first 15-minute
// sample that clears the configured minimum altitude over the local skyline.
//
// Right ascensions are SEARCHED rather than hard-coded because
// `calculateObjectVisibility` anchors its window on local noon, so which sky
// satisfies each premise depends on the machine's timezone.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _Fixture implements CelestialObject {
  @override
  final String id;
  @override
  final String name;
  @override
  final CelestialCoordinate coordinates;

  const _Fixture({
    required this.id,
    required this.name,
    required this.coordinates,
  });

  @override
  double? get magnitude => null;
}

void main() {
  // The reported site and night: 40 N, 75 W, astronomical dark on 2026-08-01.
  const lat = 40.0;
  const lon = -75.0;
  const dec = 45.0;
  final nightStart = DateTime(2026, 8, 1, 22, 1);
  final nightEnd = DateTime(2026, 8, 2, 4, 0);

  TargetScore score(double ra, {required double minAltitude}) =>
      TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
      ).scoreTargetForNight(
        target: _Fixture(
          id: 'ra$ra',
          name: 'ra$ra',
          coordinates: CelestialCoordinate(ra: ra, dec: dec),
        ),
        nightStart: nightStart,
        nightEnd: nightEnd,
        minAltitude: minAltitude,
      );

  DateTime? solvedRise(double ra) =>
      AstronomyCalculations.calculateObjectVisibility(
        raDeg: ra * 15.0,
        decDeg: dec,
        date: AstronomyCalculations.nightDateOf(nightStart),
        latitudeDeg: lat,
        longitudeDeg: lon,
      ).riseTime;

  double altitudeAt(double ra, DateTime when) =>
      AstronomyCalculations.objectAltAz(
        raDeg: ra * 15.0,
        decDeg: dec,
        dt: when,
        latitudeDeg: lat,
        longitudeDeg: lon,
      ).$1;

  Iterable<TargetWarning> risesLate(TargetScore s) =>
      s.warnings.where((w) => w.type == WarningType.notYetRisen);

  test(
    'a target already high when darkness falls is never warned that it rises '
    'late',
    () {
      // The highest target this site can offer at dusk.
      double? subject;
      var best = -90.0;
      for (var ra = 0.0; ra < 24.0; ra += 0.25) {
        final altAtDusk = altitudeAt(ra, nightStart);
        if (altAtDusk <= best) continue;
        best = altAtDusk;
        subject = ra;
      }
      expect(subject, isNotNull);
      expect(
        best,
        greaterThan(60.0),
        reason: 'premise check: the target is high, not marginal, at dusk',
      );

      // The solve itself must no longer be able to state the defect premise.
      // It used to: a target already up when the noon-to-noon window opened
      // got the NEXT day's rise, hours after this night had ended, and every
      // "is that after nightStart?" gate said yes. Rise now belongs to the
      // pass the target is IN, so it precedes the darkness it is up for.
      final rise = solvedRise(subject!)!;
      expect(
        rise.isBefore(nightStart),
        isTrue,
        reason: 'a target 60+ deg up at dusk rose before dusk, not after dawn',
      );

      final result = score(subject, minAltitude: 30);
      expect(
        result.visibility.hoursAboveMinAlt,
        greaterThanOrEqualTo(4.0),
        reason: 'premise check: the target is usable for most of the night',
      );
      expect(risesLate(result), isEmpty);
    },
  );

  test(
    'a target that only clears the minimum in the last third of the night is '
    'still warned, with the time it actually becomes usable',
    () {
      // The inverse guard: this target clears the GEOMETRIC horizon early but
      // does not reach the site minimum until the last third of the night. A
      // gate on rise time alone stays silent; the operator must still be told,
      // and told when it becomes USABLE.
      const minAltitude = 15.0;
      final threshold = nightStart.add(
        Duration(
          milliseconds: (nightEnd.difference(nightStart).inMilliseconds * 0.66)
              .round(),
        ),
      );

      double? subject;
      for (var ra = 0.0; ra < 24.0 && subject == null; ra += 0.25) {
        if (altitudeAt(ra, nightStart) >= minAltitude) continue;
        final rise = solvedRise(ra);
        if (rise == null || rise.isAfter(threshold)) continue;
        if (score(ra, minAltitude: minAltitude).visibility.hoursAboveMinAlt !=
            2.0) {
          continue;
        }
        subject = ra;
      }
      expect(
        subject,
        isNotNull,
        reason: 'no sky reproduces the late-riser premise at this site/night',
      );

      final warning = risesLate(
        score(subject!, minAltitude: minAltitude),
      ).single;
      expect(warning.message, startsWith('Usable only from '));
      expect(
        warning.message,
        isNot(contains(_hhmm(solvedRise(subject)!))),
        reason:
            'the time printed is when the target clears the minimum, not '
            'when it crossed the geometric horizon',
      );
    },
  );
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';
