/// A run the operator stops WHILE IT IS RUNNING must not be reported as
/// "paused-stopped" — a raw state-machine token, and a false claim about what
/// happened. The token means "stopped, checkpoint kept", which is about
/// resumability, not about a pause.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/run_status_presentation.dart';

void main() {
  test('the resumable stop reads as a stop, not as a pause', () {
    expect(runStatusLabel('paused-stopped'), 'Stopped (resumable)');
    expect(runStatusLabel('paused-stopped'), isNot(contains('paused')));
  });

  test('every status the executor durably writes has product English', () {
    const durable = {
      'completed': 'Completed',
      'failed': 'Failed',
      'aborted': 'Aborted',
      'stopped': 'Stopped',
      'paused-stopped': 'Stopped (resumable)',
      'interrupted': 'Interrupted',
      'running': 'Running',
      'paused': 'Paused',
    };
    durable.forEach((status, label) {
      expect(runStatusLabel(status), label);
    });
  });

  test('an unmapped status degrades to something readable', () {
    expect(runStatusLabel('half_way-there'), 'Half way there');
    expect(runStatusLabel(''), 'Unknown');
  });

  // A substring test on "cancelled" inside `isRunCancellationNotice` drops a
  // REAL fault whose text contains that word when Stop is pressed, leaving the
  // Session Report with no Errors section at all. These four inputs are each
  // shaped like a message the stack really emits.
  group('a stop drops the notice and NOTHING else', () {
    const realFaults = <String>[
      'Temperature compensation cancelled',
      'Cancelled: Target',
      'focuser move was canceled by the driver',
      'slew canceled by the mount (limit switch)',
    ];

    test('real faults survive an operator stop', () {
      final kept = runErrorMessagesFor('paused-stopped', [
        'Sequence cancelled',
        ...realFaults,
      ]);
      expect(kept, realFaults);
    });

    test('the notice itself is dropped, in either spelling', () {
      expect(
        runErrorMessagesFor('paused-stopped', const [
          'Sequence cancelled',
          'Sequence canceled',
          'Stopped by request',
        ]),
        isEmpty,
      );
    });

    test('a run that failed on its own keeps every message', () {
      const messages = ['Sequence cancelled', 'Camera disconnected'];
      expect(runErrorMessagesFor('failed', messages), messages);
    });
  });
}
