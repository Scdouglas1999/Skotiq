// Unit tests for the pure countdown logic behind the Night Timeline header.
//
// computeNightCountdown is the single most important piece of branching in the
// briefing — it phrases the "most relevant fact" depending on where `now` sits
// within the night — so it is extracted as a pure function and tested directly
// without a widget tree.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/night_timeline.dart';
import 'package:skotiq_core/skotiq_core.dart' show FixedOffsetClock;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  // A representative night: sunset 18:00, astro dusk 19:30, astro dawn 04:30,
  // sunrise 06:00 (the following day for dawn/sunrise/dusk crossing midnight).
  final base = DateTime(2026, 1, 15);
  TwilightTimes night() => TwilightTimes(
        sunset: base.add(const Duration(hours: 18)),
        civilDusk: base.add(const Duration(hours: 18, minutes: 30)),
        nauticalDusk: base.add(const Duration(hours: 19)),
        astronomicalDusk: base.add(const Duration(hours: 19, minutes: 30)),
        astronomicalDawn: base.add(const Duration(hours: 28, minutes: 30)),
        nauticalDawn: base.add(const Duration(hours: 29)),
        civilDawn: base.add(const Duration(hours: 29, minutes: 30)),
        sunrise: base.add(const Duration(hours: 30)),
      );

  group('computeNightCountdown', () {
    test('before astro dusk → counts down to astro dark', () {
      final now = base.add(const Duration(hours: 19)); // 30 min before dusk
      final c = computeNightCountdown(twilight: night(), now: now);
      expect(c.headlineLabelKey, 'dbAstroDarkIn');
      expect(c.headlineValue, '0h 30m');
      expect(c.isDark, isFalse);
      // 19:30 → 04:30 = 9h window.
      expect(c.windowLabel, '9h 0m');
    });

    test('inside the dark window → counts down remaining dark', () {
      final now = base.add(const Duration(hours: 22)); // 22:00
      final c = computeNightCountdown(twilight: night(), now: now);
      expect(c.headlineLabelKey, 'dbDarkForAnother');
      expect(c.headlineValue, '6h 30m'); // until 04:30
      expect(c.isDark, isTrue);
    });

    test('after astro dawn but before sunrise → counts down to sunrise', () {
      final now = base.add(const Duration(hours: 29)); // 05:00, dawn passed
      final c = computeNightCountdown(twilight: night(), now: now);
      expect(c.headlineLabelKey, 'dbSunriseIn');
      expect(c.headlineValue, '1h 0m');
      expect(c.isDark, isFalse);
    });

    test('daytime (after sunrise) → shows next sunset clock time', () {
      final now = base.add(const Duration(hours: 31)); // 07:00, sun up
      final c = computeNightCountdown(twilight: night(), now: now);
      expect(c.headlineLabelKey, 'dbSunsetAt');
      expect(c.headlineValue, '18:00');
      expect(c.isDark, isFalse);
    });

    // The status bar and the Dashboard header chip render Settings → Location
    // → Timezone. A clock face on the same screen that stayed host-local would
    // put two zones side by side — "03:44 now" over "Sunset at 18:00" — which
    // is worse than the uniformly host-local screen this replaced.
    test('the sunset clock face follows the chosen site timezone', () {
      final now = base.add(const Duration(hours: 31)); // 07:00, sun up
      final hostOffset = now.timeZoneOffset;
      final c = computeNightCountdown(
        twilight: night(),
        now: now,
        clock: FixedOffsetClock(
          utcOffset: hostOffset + const Duration(hours: 5),
          label: 'site',
        ),
      );
      expect(c.headlineLabelKey, 'dbSunsetAt');
      expect(
        c.headlineValue,
        '23:00',
        reason: 'sunset is 18:00 host-local, so five hours ahead is 23:00',
      );
    });

    test('degrades gracefully when astro twilight is undefined', () {
      // High-latitude summer: sun never reaches −18°, so dusk/dawn are null but
      // we still have a sunset/sunrise span.
      final twilight = TwilightTimes(
        sunset: base.add(const Duration(hours: 22)),
        sunrise: base.add(const Duration(hours: 27)),
      );
      final now = base.add(const Duration(hours: 23));
      final c = computeNightCountdown(twilight: twilight, now: now);
      // No imaging window since there's no astronomical darkness.
      expect(c.windowLabel, isNull);
      // Still offers a sensible sunrise countdown.
      expect(c.headlineLabelKey, 'dbSunriseIn');
      expect(c.headlineValue, '4h 0m');
    });
  });
}
