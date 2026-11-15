// A run after midnight belongs to the night that began the evening before, so
// the night's label names both dates.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/history/history_tab.dart';

void main() {
  test('the night header names the evening and the morning', () {
    expect(
      observingNightLabel(DateTime(2026, 10, 31)),
      'Night of Sat, Oct 31 to Sun, Nov 1, 2026',
    );
    expect(
      observingNightLabel(DateTime(2026, 12, 31)),
      'Night of Thu, Dec 31 to Fri, Jan 1, 2027',
    );
  });

  test('the morning is the next calendar day on the night the clocks change',
      () {
    // In zones that leave daylight time on 2026-11-01, 24 hours after that
    // midnight is still November 1.
    expect(
      observingNightLabel(DateTime(2026, 11, 1)),
      'Night of Sun, Nov 1 to Mon, Nov 2, 2026',
    );
  });
}
