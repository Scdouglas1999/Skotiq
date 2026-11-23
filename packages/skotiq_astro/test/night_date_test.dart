import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  test('a night is its calendar day, whatever the zone of the DateTime', () {
    expect(
      NightDate.ofCalendarDay(DateTime.utc(2026, 3, 8, 23, 30)),
      NightDate.ofCalendarDay(DateTime(2026, 3, 8, 0, 15)),
    );
    expect(const NightDate(2026, 3, 8).toString(), '2026-03-08');
  });

  test('addDays crosses months and years', () {
    expect(
      const NightDate(2026, 12, 31).addDays(1),
      const NightDate(2027, 1, 1),
    );
    expect(
      const NightDate(2026, 3, 1).addDays(-1),
      const NightDate(2026, 2, 28),
    );
  });

  test('the night an instant belongs to opens before it', () {
    final instant = DateTime.utc(2026, 7, 26, 4);
    final night = AstronomyCalculations.nightDateOf(instant, longitudeDeg: -75);
    final opens = AstronomyCalculations.nightStartOf(night, longitudeDeg: -75);
    expect(night, const NightDate(2026, 7, 25));
    expect(opens.isBefore(instant), isTrue);
    expect(instant.difference(opens), lessThan(const Duration(hours: 24)));
  });
}
