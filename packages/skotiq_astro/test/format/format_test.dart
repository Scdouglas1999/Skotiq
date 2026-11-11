import 'package:skotiq_astro/format.dart';
import 'package:test/test.dart';

void main() {
  group('ClockFormat', () {
    final t = DateTime(2026, 11, 3, 4, 5, 6, 7);
    test('prints the fields it is given', () {
      expect(ClockFormat.hm(t), '04:05');
      expect(ClockFormat.hms(t), '04:05:06');
      expect(ClockFormat.hmsMillis(t), '04:05:06.007');
      expect(ClockFormat.date(t), '2026-11-03');
      expect(ClockFormat.dateHm(t), '2026-11-03 04:05');
      expect(ClockFormat.dateHms(t), '2026-11-03 04:05:06');
      expect(ClockFormat.monthDay(t), 'Nov 3');
      expect(ClockFormat.monthDayYear(t), 'Nov 3, 2026');
      expect(ClockFormat.monthDayHm(t), 'Nov 3 04:05');
      expect(ClockFormat.monthDayYearHm(t), 'Nov 3, 2026 04:05');
    });

    test('never converts zones', () {
      final utc = DateTime.utc(2026, 1, 1, 23, 59);
      expect(ClockFormat.hm(utc), '23:59');
    });

    test('same-day times drop the date', () {
      expect(ClockFormat.hmOrMonthDayHm(t, DateTime(2026, 11, 3, 23)), '04:05');
      expect(
        ClockFormat.hmOrMonthDayHm(t, DateTime(2026, 11, 4)),
        'Nov 3 04:05',
      );
    });

    test('hours of day fold and truncate', () {
      expect(ClockFormat.hoursOfDay(5.5), '05:30');
      expect(ClockFormat.hoursOfDay(23.9999), '23:59');
      expect(ClockFormat.hoursOfDay(24.25), '00:15');
      expect(ClockFormat.hoursOfDay(-0.5), '23:30');
      expect(ClockFormat.minutesOfDay(7 * 60 + 5), '07:05');
    });

    test('stopwatch', () {
      expect(ClockFormat.stopwatch(const Duration(seconds: 7)), '0:07');
      expect(
        ClockFormat.stopwatch(const Duration(minutes: 12, seconds: 7)),
        '12:07',
      );
      expect(
        ClockFormat.stopwatch(const Duration(hours: 1, minutes: 2, seconds: 7)),
        '1:02:07',
      );
      expect(ClockFormat.stopwatch(const Duration(seconds: -3)), '0:00');
      expect(
        ClockFormat.stopwatchPadded(const Duration(minutes: 12, seconds: 7)),
        '00:12:07',
      );
    });
  });

  group('RelativeTime', () {
    final now = DateTime(2026, 11, 10, 12);
    String ago(Duration d, [RelativeTimeStyle s = RelativeTimeStyle.compact]) =>
        RelativeTime.ago(now.subtract(d), now: now, style: s);

    test('compact', () {
      expect(ago(const Duration(seconds: 5)), 'just now');
      expect(ago(const Duration(seconds: 59)), 'just now');
      expect(ago(const Duration(minutes: 1)), '1m ago');
      expect(ago(const Duration(minutes: 59)), '59m ago');
      expect(ago(const Duration(hours: 3)), '3h ago');
      expect(ago(const Duration(days: 2)), '2d ago');
      expect(ago(const Duration(days: 45)), '1mo ago');
      expect(ago(const Duration(days: 800)), '2y ago');
    });

    test('a future time is just now, never negative', () {
      expect(ago(const Duration(minutes: -5)), 'just now');
    });

    test('words', () {
      const w = RelativeTimeStyle.words;
      expect(ago(const Duration(minutes: 1), w), '1 minute ago');
      expect(ago(const Duration(minutes: 5), w), '5 minutes ago');
      expect(ago(const Duration(hours: 1), w), '1 hour ago');
      expect(ago(const Duration(days: 3), w), '3 days ago');
      expect(ago(const Duration(days: 70), w), '2 months ago');
      expect(ago(const Duration(days: 365), w), '1 year ago');
    });

    test('age', () {
      expect(RelativeTime.age(const Duration(seconds: -1)), '0s');
      expect(RelativeTime.age(const Duration(seconds: 45)), '45s');
      expect(RelativeTime.age(const Duration(minutes: 5)), '5m');
      expect(RelativeTime.age(const Duration(hours: 30)), '1d');
    });
  });

  group('ByteFormat.size', () {
    test('keeps about three significant digits', () {
      expect(ByteFormat.size(0), '0 B');
      expect(ByteFormat.size(-4), '0 B');
      expect(ByteFormat.size(512), '512 B');
      expect(ByteFormat.size(1536), '1.5 KB');
      expect(ByteFormat.size(150 * 1024), '150 KB');
      expect(ByteFormat.size((38.4 * 1024 * 1024).round()), '38.4 MB');
      expect(ByteFormat.size(256 * 1024 * 1024 * 1024), '256 GB');
      expect(
        ByteFormat.size((1.8 * 1024 * 1024 * 1024 * 1024).round()),
        '1.8 TB',
      );
    });

    test('never prints 1024 of a unit', () {
      expect(ByteFormat.size(1024 * 1024 - 1), '1.0 MB');
      expect(ByteFormat.size(1024), '1.0 KB');
    });
  });

  group('AngleFormat', () {
    test('degrees', () {
      expect(AngleFormat.degrees(45.123), '45.1°');
      expect(AngleFormat.degrees(270, decimals: 0), '270°');
    });

    test('arcsec picks the unit', () {
      expect(AngleFormat.arcsec(4.21), '4.2"');
      expect(AngleFormat.arcsec(240.4), '240"');
      expect(AngleFormat.arcsec(4680), '1.3°');
    });

    test('adaptive picks the unit', () {
      expect(AngleFormat.adaptive(2.5), '2.50°');
      expect(AngleFormat.adaptive(0.205), "12.3'");
      expect(AngleFormat.adaptive(0.0125), '45.0"');
    });

    test('site coordinates name the hemisphere', () {
      expect(AngleFormat.latitude(40.1234), '40.1234° N');
      expect(AngleFormat.latitude(-33.87, decimals: 2), '33.87° S');
      expect(AngleFormat.longitude(-74.006), '74.0060° W');
      expect(AngleFormat.longitude(2.35), '2.3500° E');
    });

    test('compass', () {
      expect(AngleFormat.compass(0), 'N');
      expect(AngleFormat.compass(22.5), 'NNE');
      expect(AngleFormat.compass(348.75), 'N');
      expect(AngleFormat.compass(348.74), 'NNW');
      expect(AngleFormat.compass(225), 'SW');
      expect(AngleFormat.compass(22.4, points: 8), 'N');
      expect(AngleFormat.compass(22.5, points: 8), 'NE');
      expect(AngleFormat.compass(-90, points: 8), 'W');
    });
  });

  group('QuantityFormat', () {
    test('trimmed', () {
      expect(QuantityFormat.trimmed(30), '30');
      expect(QuantityFormat.trimmed(2.5), '2.5');
      expect(QuantityFormat.trimmed(2.04), '2');
      expect(QuantityFormat.trimmed(0.25, maxDecimals: 2), '0.25');
      expect(QuantityFormat.trimmed(-0.01), '0');
      expect(QuantityFormat.trimmed(100, maxDecimals: 0), '100');
    });

    test('grouped and compact counts', () {
      expect(QuantityFormat.grouped(999), '999');
      expect(QuantityFormat.grouped(12345), '12,345');
      expect(QuantityFormat.grouped(-1234567), '-1,234,567');
      expect(QuantityFormat.compactCount(950), '950');
      expect(QuantityFormat.compactCount(1234), '1.2k');
      expect(QuantityFormat.compactCount(3400000), '3.4M');
    });

    test('percent', () {
      expect(QuantityFormat.percent(75), '75%');
      expect(QuantityFormat.percent(12.5), '12.5%');
      expect(QuantityFormat.fraction(0.125), '12.5%');
    });
  });
}
