// Which night "tonight" is at a site: the one in progress, or the coming one
// once its dark has ended, cut on the site's own solar day.

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  // A remote site about 15 hours ahead of US Eastern time: its night falls in
  // the Eastern small hours and its dawn in the Eastern afternoon.
  const lat = 40.0;
  const lon = 155.66;

  TwilightTimes nightAt(DateTime now) => AstronomyCalculations.nightAt(
    now: now,
    latitudeDeg: lat,
    longitudeDeg: lon,
  );

  test('after the dark ends, tonight is the coming night', () {
    // 21:15 UTC: the site's astronomical dawn (about 18:45 UTC) has passed.
    final now = DateTime.utc(2026, 11, 11, 21, 15);
    final night = nightAt(now);
    expect(night.sunset!.isAfter(now), isTrue);
    expect(night.sunset!.difference(now), lessThan(const Duration(hours: 12)));
    expect(night.astronomicalDawn!.isAfter(night.astronomicalDusk!), isTrue);
  });

  test('during the dark, tonight is the night in progress', () {
    // 12:00 UTC is about 22:30 at the site.
    final now = DateTime.utc(2026, 11, 11, 12);
    final night = nightAt(now);
    expect(night.astronomicalDusk!.isBefore(now), isTrue);
    expect(night.astronomicalDawn!.isAfter(now), isTrue);
  });

  test('in the morning twilight the night is over', () {
    final dark = nightAt(DateTime.utc(2026, 11, 11, 12));
    final justAfterDawn = dark.astronomicalDawn!.add(
      const Duration(minutes: 1),
    );
    final next = nightAt(justAfterDawn);
    expect(next.sunset!.isAfter(justAfterDawn), isTrue);
    expect(
      next.astronomicalDusk!.difference(dark.astronomicalDusk!).inHours,
      inInclusiveRange(23, 25),
    );
  });

  test('events come back in the zone of now', () {
    expect(nightAt(DateTime.utc(2026, 11, 11, 21)).sunset!.isUtc, isTrue);
    expect(nightAt(DateTime(2026, 11, 11, 16)).sunset!.isUtc, isFalse);
  });
}
