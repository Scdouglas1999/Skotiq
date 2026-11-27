// A step held for a meridian flip reads "Waiting for the flip" until the
// flip is over; the flip's outcome ends the hold on every surface, not the
// step's next reading.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show FlipOutcome, SequencerEvent;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  const flipHold = FlipHoldProgressDetail(
    exposureSecs: 120,
    firesInSecs: 70,
    hourAngleHours: 0.06,
    thresholdMin: 5,
  );
  const reading = ExposureInstructionProgressDetail(
    frame: 3,
    total: 10,
    durationSecs: 120,
  );

  for (final outcome in FlipOutcome.values) {
    test('a flip that reports $outcome ends the hold', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final run = container.read(runRecordProvider.notifier)
        ..updateNodeStructuredProgress('m74-l', 30, reading)
        ..updateNodeStructuredProgress('m74-l', 30, flipHold)
        ..updateNodeStructuredProgress('m74-ha', 0, flipHold);

      foldRunEvent(
        run,
        SequencerEvent.meridianFlipOutcome(
          outcome: outcome,
          targetName: 'M74',
          newPierSide: 'west',
          durationSecs: 90,
          attempts: 1,
          failedSteps: const [],
        ),
      );

      final progress = container.read(sequenceProgressProvider);
      expect(
        progress.nodeLatestReport['m74-l'],
        isNot(isA<FlipHoldProgressDetail>()),
      );
      expect(progress.nodeLatestReport['m74-ha'], isNull);
      expect(
        progress.nodeProgressStructuredDetail['m74-l'],
        reading,
        reason: 'the step keeps its last reading',
      );
    });
  }
}
