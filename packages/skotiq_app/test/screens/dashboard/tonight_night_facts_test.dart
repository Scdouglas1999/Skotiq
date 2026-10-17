// Tonight's night facts, and the unit trap in the moon's illumination.
//
// `MoonTimes.illumination` is ALREADY a percentage — `skotiq_planetarium`
// computes `(1 + cos(phaseAngle)) / 2 * 100` — and the first cut of the hero
// treated it as a 0–1 fraction and scaled it again, so a 2.38 % crescent
// printed as "Moon 238%, sets 22:10" on the live rig. These tests pin the unit
// at the one place the number is formatted, so the bug cannot come back by
// being reintroduced in a second caller.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_night.dart';

TonightNight _night({
  double? illuminationPercent,
  DateTime? now,
  DateTime? moonSet,
}) {
  final base = DateTime(2026, 9, 9, 19, 12);
  return TonightNight(
    sunset: base,
    astroDark: DateTime(2026, 9, 9, 20, 54),
    astroDawn: DateTime(2026, 9, 10, 4, 51),
    sunrise: DateTime(2026, 9, 10, 6, 33),
    now: now ?? DateTime(2026, 9, 9, 22, 41),
    moonSet: moonSet,
    moonIlluminationPercent: illuminationPercent,
  );
}

void main() {
  group('moon illumination is a percentage, not a fraction', () {
    test('a 2.38% crescent rounds to 2, never 238', () {
      final night = _night(illuminationPercent: 2.38);
      expect(night.moonIlluminationRounded, 2);
      expect(
        night.moonIlluminationRounded!,
        inInclusiveRange(0, 100),
        reason: 'an illuminated fraction of the disc cannot exceed 100%',
      );
    });

    test('a full moon is 100, not 10000', () {
      expect(_night(illuminationPercent: 100).moonIlluminationRounded, 100);
    });

    test('a new moon is 0', () {
      expect(_night(illuminationPercent: 0).moonIlluminationRounded, 0);
    });

    test('no moon data renders as null, so the UI can show an em dash', () {
      expect(_night().moonIlluminationRounded, isNull);
    });

    test('every value the provider can produce stays in range', () {
      // The provider's own range is [0, 100]; sweep it so a future scaling
      // change trips here rather than on the rig.
      for (var percent = 0.0; percent <= 100.0; percent += 0.5) {
        expect(
          _night(illuminationPercent: percent).moonIlluminationRounded,
          inInclusiveRange(0, 100),
          reason: '$percent% must not leave the 0–100 range',
        );
      }
    });
  });

  group('night facts', () {
    test('untilDark counts down before dark and is null once dark', () {
      final before = _night(now: DateTime(2026, 9, 9, 19, 30));
      expect(before.untilDark, const Duration(hours: 1, minutes: 24));
      expect(before.isDark, isFalse);

      final after = _night(now: DateTime(2026, 9, 9, 23, 0));
      expect(after.untilDark, isNull);
      expect(after.isDark, isTrue);
    });

    test('darkDuration is astro dark to astro dawn', () {
      expect(_night().darkDuration, const Duration(hours: 7, minutes: 57));
    });

    test('tonightClock pads to HH:MM', () {
      expect(tonightClock(DateTime(2026, 9, 9, 4, 5)), '04:05');
      expect(tonightClock(DateTime(2026, 9, 9, 22, 41)), '22:41');
    });

    test(
        'tonightDuration drops the hour when there is none, and rejects '
        'negatives so a stale estimate cannot print "-1 h"', () {
      expect(tonightDuration(const Duration(minutes: 54)), '54 m');
      expect(
          tonightDuration(const Duration(hours: 2, minutes: 54)), '2 h 54 m');
      expect(tonightDuration(const Duration(minutes: -5)), isNull);
      expect(tonightDuration(null), isNull);
    });
  });
}
