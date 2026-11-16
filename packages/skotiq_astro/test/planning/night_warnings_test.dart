// What an operator is told about a target's night, from its night figures.

import 'package:skotiq_astro/format.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  final nightStart = DateTime.utc(2026, 1, 15, 23);
  final nightEnd = DateTime.utc(2026, 1, 16, 11);

  List<TargetWarning> warn({
    double peakAlt = 60,
    double bestAirmass = 1.2,
    double moonDist = 120,
    double moonIllumination = 0,
    double hoursAboveMin = 8,
    DateTime? firstObservableTime,
    DateTime? setTime,
  }) => nightWarnings(
    peakAlt: peakAlt,
    bestAirmass: bestAirmass,
    moonDist: moonDist,
    moonIllumination: moonIllumination,
    visibility: ObjectVisibility(setTime: setTime, transitAltitude: peakAlt),
    hoursAboveMin: hoursAboveMin,
    nightStart: nightStart,
    nightEnd: nightEnd,
    firstObservableTime: firstObservableTime ?? nightStart,
  );

  test('a well-placed target on a dark night warns about nothing', () {
    expect(warn(), isEmpty);
  });

  test('a bright moon warns even when the target is far from it', () {
    final moon = warn(
      moonIllumination: 100,
    ).where((w) => w.type == WarningType.moonProximity).toList();
    expect(moon, hasLength(1));
    expect(moon.single.message, contains('100%'));
    expect(moon.single.suggestion, contains('arrowband'));
  });

  test('a target usable only in the last third of the night is told when '
      'it becomes usable', () {
    final late = nightStart.add(const Duration(hours: 9));
    final warning = warn(
      firstObservableTime: late,
      hoursAboveMin: 3,
    ).singleWhere((w) => w.type == WarningType.notYetRisen);
    expect(warning.message, 'Usable only from ${ClockFormat.hm(late)}');
  });

  test('a target usable from dusk is not called a late riser', () {
    expect(warn().where((w) => w.type == WarningType.notYetRisen), isEmpty);
  });

  test('a low peak and a short window are both told', () {
    final types = warn(peakAlt: 12, hoursAboveMin: 1.5).map((w) => w.type);
    expect(
      types,
      containsAll([WarningType.lowAltitude, WarningType.settingSoon]),
    );
  });
}
