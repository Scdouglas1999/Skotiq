// The phone's imaging session (wake lock and the ongoing "Imaging"
// notification) follows the run as the phone sees it now, not the transition
// it happened to see: a phone restarted, relinked or opened on a run started
// elsewhere takes the session up too.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_mobile/services/mobile_sequence_hooks.dart';

void main() {
  test('a run under way takes the session up, whatever came before', () {
    for (final exec in [
      SequenceExecutionState.running,
      SequenceExecutionState.paused,
      SequenceExecutionState.recovering,
    ]) {
      expect(
        imagingSessionChange(held: false, exec: exec),
        ImagingSessionChange.start,
        reason: exec.name,
      );
      expect(
        imagingSessionChange(held: true, exec: exec),
        ImagingSessionChange.keep,
        reason: exec.name,
      );
    }
  });

  test('a stop that has not settled keeps the session', () {
    for (final exec in [
      SequenceExecutionState.stopping,
      SequenceExecutionState.finalizing,
      SequenceExecutionState.stopFailed,
      SequenceExecutionState.cleanupFailed,
    ]) {
      expect(
        imagingSessionChange(held: true, exec: exec),
        ImagingSessionChange.keep,
        reason: exec.name,
      );
      expect(
        imagingSessionChange(held: false, exec: exec),
        ImagingSessionChange.keep,
        reason: '${exec.name} starts nothing',
      );
    }
  });

  test('a finished run says so; a stopped or failed one releases quietly', () {
    expect(
      imagingSessionChange(held: true, exec: SequenceExecutionState.completed),
      ImagingSessionChange.finish,
    );
    expect(
      imagingSessionChange(held: true, exec: SequenceExecutionState.idle),
      ImagingSessionChange.end,
    );
    expect(
      imagingSessionChange(held: true, exec: SequenceExecutionState.failed),
      ImagingSessionChange.end,
    );
    expect(
      imagingSessionChange(held: false, exec: SequenceExecutionState.completed),
      ImagingSessionChange.keep,
      reason: 'no session, no completion notice',
    );
  });
}
