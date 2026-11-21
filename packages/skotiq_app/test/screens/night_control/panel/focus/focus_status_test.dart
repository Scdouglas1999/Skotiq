import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_panel_vm.dart';

void main() {
  test('a cancelled autofocus is cancelled, not a failure and not idle', () {
    expect(
      nightAutofocusStatus(
        isRunning: false,
        hasError: false,
        hasResult: false,
        status: 'Autofocus cancelled',
      ),
      NightAutofocusStatus.cancelled,
    );
    expect(
      nightAutofocusStatus(
        isRunning: false,
        hasError: true,
        hasResult: false,
        status: 'Failed: no stars',
      ),
      NightAutofocusStatus.failed,
    );
    expect(
      nightAutofocusStatus(
        isRunning: false,
        hasError: false,
        hasResult: false,
        status: '',
      ),
      NightAutofocusStatus.idle,
    );
  });
}
