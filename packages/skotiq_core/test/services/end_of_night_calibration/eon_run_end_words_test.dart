// reverify RV-09: the calibration status read "The calibration run ended
// paused-stopped before taking every frame" after a plain Stop.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/models/sequence/sequence_run_status.dart';

void main() {
  test('a run status reads as words', () {
    expect(eonRunEndWords(SequenceRunStatus.stoppedResumable), 'was stopped');
    expect(eonRunEndWords(SequenceRunStatus.stopped), 'was stopped');
    expect(eonRunEndWords(SequenceRunStatus.failed), 'failed');
  });

  test('a calibration refusal reads without "Bad state:"', () {
    expect(
      calibrationNeededText(
        StateError('Night of 2026-11-02 needs master flat.'),
      ),
      'Calibration needed: Night of 2026-11-02 needs master flat.',
    );
  });
}
