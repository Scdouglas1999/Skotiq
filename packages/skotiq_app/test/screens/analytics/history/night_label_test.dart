// A run after midnight belongs to the night that began the evening before, so
// the night's label names both dates.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/history/history_tab.dart';

void main() {
  final now = DateTime(2026, 11, 15);

  test('the night header names the evening and the morning', () {
    expect(
      observingNightLabel(DateTime(2026, 11, 3), now: now),
      'Night of Nov 3 to 4',
    );
    expect(
      observingNightLabel(DateTime(2026, 10, 31), now: now),
      'Night of Oct 31 to Nov 1',
    );
  });

  test('a night of another year says which', () {
    expect(
      observingNightLabel(DateTime(2025, 12, 31), now: now),
      'Night of Dec 31 to Jan 1, 2025',
    );
  });

  test('the morning is the next calendar day on the night the clocks change',
      () {
    // In zones that leave daylight time on 2026-11-01, 24 hours after that
    // midnight is still November 1.
    expect(
      observingNightLabel(DateTime(2026, 11, 1), now: now),
      'Night of Nov 1 to 2',
    );
  });
}
