// A time of day picked for a sequence lands on that wall-clock time even when
// a daylight-saving change falls before it. Run under TZ=America/New_York to
// exercise the 1 November 2026 fall-back; in a zone without daylight saving
// the assertions still hold.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('a time later today stays today', () {
    final now = DateTime(2026, 10, 31, 20);
    expect(nextLocalTimeOfDay(now, 23, 30), DateTime(2026, 10, 31, 23, 30));
  });

  test('a time already past rolls to the next calendar day', () {
    final now = DateTime(2026, 10, 31, 20);
    final next = nextLocalTimeOfDay(now, 2, 0);
    expect(
      (next.year, next.month, next.day, next.hour, next.minute),
      (2026, 11, 1, 2, 0),
    );
  });

  test('rolling over the end of daylight time keeps the wall clock', () {
    // Before the change at 02:00 EDT; the picked 05:30 is after it.
    final now = DateTime(2026, 10, 31, 22);
    final next = nextLocalTimeOfDay(now, 5, 30);
    expect((next.day, next.hour, next.minute), (1, 5, 30));
  });

  test('rolling over the start of daylight time keeps the wall clock', () {
    final now = DateTime(2026, 3, 7, 22);
    final next = nextLocalTimeOfDay(now, 5, 30);
    expect((next.day, next.hour, next.minute), (8, 5, 30));
  });
}
