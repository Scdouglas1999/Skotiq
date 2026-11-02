// History groups a run after midnight with the night that began the evening
// before. The header named only that evening's date, so Sunday-morning runs
// sat under "Saturday, Oct 31, 2026" (qa-night N19); it names both now.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/tabs/history_tab.dart';

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
}
