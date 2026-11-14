// The error payload carries notes, step problems, pauses and faults. The
// Tonight log titled a preflight advisory "Sequencer error" although the run
// went on normally (qa-pair QP-14), and raised the critical banner for it.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _sequencerError(
  SequencerErrorKind kind, {
  EventSeverity? severity,
}) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity:
      severity ??
      (kind == SequencerErrorKind.advisory ||
              kind == SequencerErrorKind.stepProblem
          ? EventSeverity.warning
          : EventSeverity.error),
  category: EventCategory.sequencer,
  payload: EventPayload.sequencer(
    SequencerEvent.error(message: 'what happened', kind: kind),
  ),
);

void main() {
  test('each kind of sequencer error is titled for what it means', () {
    expect(
      {
        for (final kind in SequencerErrorKind.values)
          kind: skotiqEventDisplayTitle(_sequencerError(kind)),
      },
      {
        SequencerErrorKind.advisory: 'Sequencer notice',
        SequencerErrorKind.stepProblem: 'Step problem, run continues',
        SequencerErrorKind.runHeld: 'Run paused',
        SequencerErrorKind.stepFailed: 'Sequencer error',
        SequencerErrorKind.standalone: 'Operation error',
        SequencerErrorKind.cancelled: 'Sequence stopped',
      },
    );
  });

  test('a note and a problem the run carried on through are never critical, '
      'whatever severity they arrive at', () {
    for (final kind in [
      SequencerErrorKind.advisory,
      SequencerErrorKind.stepProblem,
    ]) {
      expect(isCriticalEvent(_sequencerError(kind)), isFalse);
      expect(
        isCriticalEvent(_sequencerError(kind, severity: EventSeverity.error)),
        isFalse,
      );
    }
  });

  test('a failed step, a pause for the operator and a hand-started '
      'operation that failed are critical', () {
    for (final kind in [
      SequencerErrorKind.stepFailed,
      SequencerErrorKind.runHeld,
      SequencerErrorKind.standalone,
    ]) {
      expect(isCriticalEvent(_sequencerError(kind)), isTrue);
    }
  });

  // Every stop ends the run this way; it is an alarm for nobody.
  test('a stopped run\'s cancellation is not critical', () {
    expect(
      isCriticalEvent(_sequencerError(SequencerErrorKind.cancelled)),
      isFalse,
    );
  });

  test('progress a hand-started operation publishes at info is not '
      'critical', () {
    expect(
      isCriticalEvent(
        _sequencerError(
          SequencerErrorKind.standalone,
          severity: EventSeverity.info,
        ),
      ),
      isFalse,
    );
  });
}
