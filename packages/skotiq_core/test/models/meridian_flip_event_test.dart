import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  // The file `flip_events_match_the_app` in meridian_events.rs serializes the
  // native flip events against.
  final events =
      jsonDecode(
            File('test/fixtures/meridian_flip_events.json').readAsStringSync(),
          )
          as List<dynamic>;

  test('reads every flip event the native executor sends', () {
    expect(events.map(MeridianFlipEvent.fromWire).toList(), [
      const MeridianFlipStarting(targetName: 'M31'),
      const MeridianFlipStepStarted(
        step: FlipStep.pausingGuider,
        stepIndex: 0,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.enablingTracking,
        stepIndex: 1,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.slewingToTarget,
        stepIndex: 2,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.verifyingPierSide,
        stepIndex: 3,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.confirmingTracking,
        stepIndex: 4,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.plateSolvingAndCentering,
        stepIndex: 5,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.refocusing,
        stepIndex: 6,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.resumingGuider,
        stepIndex: 7,
        totalSteps: 9,
      ),
      const MeridianFlipStepStarted(
        step: FlipStep.settling,
        stepIndex: 8,
        totalSteps: 9,
      ),
      const MeridianFlipStepCompleted(step: FlipStep.settling),
      const MeridianFlipStepFailed(
        step: FlipStep.slewingToTarget,
        error: 'slew timed out',
      ),
      const MeridianFlipProgress(percent: 40),
      const MeridianFlipRetryScheduled(
        attempt: 1,
        maxAttempts: 3,
        delaySecs: 60,
      ),
      const MeridianFlipCompleted(durationSecs: 185),
      const MeridianFlipFailed(
        error: 'pier side did not change',
        actionTaken: 'parked',
      ),
      const MeridianFlipAborted(reason: 'run stopped'),
    ]);
  });

  test('a step this build has no name for still reads as a step', () {
    expect(
      MeridianFlipEvent.fromWire({
        'StepStarted': {'step': 'Levitating', 'step_index': 0},
      }),
      const MeridianFlipStepStarted(stepIndex: 0),
    );
    expect(MeridianFlipEvent.fromWire({'Teleported': {}}), isNull);
    expect(MeridianFlipEvent.fromWire('Completed'), isNull);
  });
}
