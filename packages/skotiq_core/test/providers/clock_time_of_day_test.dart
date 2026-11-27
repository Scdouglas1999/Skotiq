import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  // 2026-11-26 03:30 UTC: 22:30 the evening before at UTC-05:00.
  final now = DateTime.utc(2026, 11, 26, 3, 30);
  const site = FixedOffsetClock(
    utcOffset: Duration(hours: -5),
    label: 'UTC-05:00',
  );

  test('a time of day later tonight on the site clock is tonight', () {
    final next = site.nextTimeOfDay(23, 15, now: now);
    expect(next.isAtSameMomentAs(DateTime.utc(2026, 11, 26, 4, 15)), isTrue);
    expect(next.isUtc, isFalse);
  });

  test('a time of day already past on the site clock is tomorrow', () {
    expect(
      site
          .nextTimeOfDay(21, 0, now: now)
          .isAtSameMomentAs(DateTime.utc(2026, 11, 27, 2, 0)),
      isTrue,
    );
  });

  test('the site clock shows an instant in its own zone', () {
    expect(site.timeOfDay(DateTime.utc(2026, 11, 26, 4, 15)), '23:15');
  });

  test('the system clock keeps this machine\'s zone', () {
    expect(
      const SystemClock().nextTimeOfDay(23, 15, now: now),
      nextLocalTimeOfDay(now, 23, 15),
    );
    final local = DateTime(2026, 11, 26, 22, 5);
    expect(const SystemClock().timeOfDay(local), '22:05');
  });
}
