// Library dates name calendar days, not 24-hour windows. intl's jm() puts a
// narrow no-break space (U+202F) before AM/PM.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/tabs/sequence_library_tab.dart';

void main() {
  final morning = DateTime(2026, 10, 21, 8, 51);

  test('last night at 10:37 PM is Yesterday, not Today', () {
    expect(
      sequenceCardDateLabel(DateTime(2026, 10, 20, 22, 37), morning),
      'Yesterday 10:37\u202fPM',
    );
  });

  test('earlier the same day is Today', () {
    expect(
      sequenceCardDateLabel(DateTime(2026, 10, 21, 0, 5), morning),
      'Today 12:05\u202fAM',
    );
  });

  test('older dates count calendar days', () {
    expect(
      sequenceCardDateLabel(DateTime(2026, 10, 18, 23, 59), morning),
      '3 days ago',
    );
  });
}
