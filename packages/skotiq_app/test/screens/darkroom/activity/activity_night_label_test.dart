import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/activity/activity_panel.dart';

// The night a time belongs to reads as the calendar days it spans, also on
// the night the clocks fall back (run under TZ=America/New_York, the night of
// 2026-11-01 is 25 hours long).
void main() {
  test('night label', () {
    expect(nightLabel(DateTime(2026, 10, 24, 22)), 'Oct 24 to 25');
    expect(nightLabel(DateTime(2026, 10, 25, 3)), 'Oct 24 to 25');
    expect(nightLabel(DateTime(2026, 10, 31, 23)), 'Oct 31 to Nov 1');
    expect(nightLabel(DateTime(2026, 11, 1, 22)), 'Nov 1 to 2');
  });
}
