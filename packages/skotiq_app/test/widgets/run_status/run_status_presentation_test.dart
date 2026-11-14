/// A run the operator stops WHILE IT IS RUNNING must not be reported as
/// "paused-stopped" — a raw state-machine token, and a false claim about what
/// happened. The token means "stopped, checkpoint kept", which is about
/// resumability, not about a pause.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/run_status/run_status_presentation.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  test('the resumable stop reads as a stop, not as a pause', () {
    expect(runStatusLabel(SequenceRunStatus.stoppedResumable),
        'Stopped (resumable)');
    expect(runStatusLabel(SequenceRunStatus.stoppedResumable),
        isNot(contains('paused')));
  });

  test('every stored token reads as its status label', () {
    for (final status in SequenceRunStatus.values) {
      expect(runStatusTokenLabel(status.token), runStatusLabel(status));
    }
    expect(runStatusTokenLabel('paused-stopped'), 'Stopped (resumable)');
  });

  test('a token that is not a run status degrades to something readable', () {
    expect(runStatusTokenLabel('half_way-there'), 'Half way there');
    expect(runStatusTokenLabel('active'), 'Active');
    expect(runStatusTokenLabel(''), 'Unknown');
  });

  test('a session a run ended reads and is toned as that run ending', () {
    for (final status in SessionStatus.values) {
      final run = status.runEnding;
      if (run == null) continue;
      expect(sessionStatusLabel(status.token), runStatusLabel(run));
      expect(sessionStatusTone(status.token), runStatusTone(run));
    }
    expect(sessionStatusLabel('active'), 'Active');
    expect(sessionStatusLabel('error'), 'Error');
    expect(sessionStatusTone('error'), ChipTone.error);
    expect(sessionStatusLabel('half_way'), 'Half way');
    expect(sessionStatusTone('half_way'), ChipTone.neutral);
  });

  test('every finished run status names the session status it leaves', () {
    for (final run in SequenceRunStatus.values.where((s) => !s.isLive)) {
      expect(SessionStatus.endedBy(run).runEnding, run);
    }
  });

  test('a paused run is live; an interrupted one is not', () {
    expect(SequenceRunStatus.paused.isLive, isTrue);
    expect(SequenceRunStatus.running.isLive, isTrue);
    expect(SequenceRunStatus.interrupted.isLive, isFalse);
    expect(
      SequenceRunStatus.values.where((s) => s.stoppedByOperator),
      [SequenceRunStatus.stopped, SequenceRunStatus.stoppedResumable],
    );
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
      final kept = runErrorMessagesFor(SequenceRunStatus.stoppedResumable, [
        'Sequence cancelled',
        ...realFaults,
      ]);
      expect(kept, realFaults);
    });

    test('the notice itself is dropped, in either spelling', () {
      expect(
        runErrorMessagesFor(SequenceRunStatus.stoppedResumable, const [
          'Sequence cancelled',
          'Sequence canceled',
          'Stopped by request',
        ]),
        isEmpty,
      );
    });

    test('a run that failed on its own keeps every message', () {
      const messages = ['Sequence cancelled', 'Camera disconnected'];
      expect(runErrorMessagesFor(SequenceRunStatus.failed, messages), messages);
    });
  });
}
