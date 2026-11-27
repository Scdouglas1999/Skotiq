// The ongoing "Imaging" notification says, in one line, what the run is doing
// now and how many frames it has, never the step's status paragraph.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/night_actions/night_action_api.dart'
    show ManualActionId;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_mobile/services/foreground_service.dart';

void main() {
  SequenceProgress at(
    String node, {
    InstructionProgressDetail? reading,
    String? filter,
    int done = 0,
    int total = 75,
    String? message,
  }) => SequenceProgress(
    currentNodeId: 'step',
    currentNodeName: node,
    nodeProgressStructuredDetail: {'step': ?reading},
    currentFilter: filter,
    completedExposures: done,
    totalExposures: total,
    message: message,
  );

  const running = SequenceExecutionState.running;

  test('the line names the step type once, then the count', () {
    expect(
      ongoingRunText(
        running,
        at('Initial autofocus', done: 0, message: 'Progress: 0/75 exposures'),
      ),
      'Autofocus · 0/75 exposures',
    );
    expect(
      ongoingRunText(
        running,
        at(
          'M74',
          reading: const CenterInstructionProgressDetail(
            attempt: 1,
            maxAttempts: 5,
          ),
        ),
      ),
      'Centering · 0/75 exposures',
    );
    expect(
      ongoingRunText(running, at('Start guiding', done: 3)),
      'Guiding · 3/75 exposures (4%)',
    );
    expect(
      ongoingRunText(
        running,
        at(
          'Smart Exposure',
          filter: 'L',
          done: 12,
          reading: const SmartExposureInstructionProgressDetail(
            currentFilter: 'L',
            planIndex: 0,
            totalPlans: 1,
            frameInPlan: 13,
            totalFrames: 75,
          ),
        ),
      ),
      'Exposing L · 12/75 exposures (16%)',
    );
  });

  test('a step of no known type is named, not called an exposure', () {
    expect(
      ongoingRunText(running, at('Cool camera to -10°C')),
      'Cool camera to -10°C · 0/75 exposures',
    );
  });

  test('a paused or recovering run says so, whatever its step', () {
    expect(
      ongoingRunText(
        SequenceExecutionState.paused,
        at('Initial autofocus', done: 5, message: 'Guide Star Lost ...'),
      ),
      'Paused · 5/75 exposures (7%)',
    );
    expect(
      ongoingRunText(SequenceExecutionState.recovering, at('Smart Exposure')),
      'Recovering · 0/75 exposures',
    );
  });

  test('a Smart Exposure step names its filter and counts its frames', () {
    expect(
      ongoingRunText(
        running,
        at(
          'Smart Exposure: Ha+OIII+SII',
          filter: 'SII',
          done: 8,
          total: 0,
          reading: const ExposureAdjustedProgressDetail(
            adaptedSecs: 20,
            nominalSecs: 20,
            reasonWire: 'disabled',
            unchanged: true,
          ),
        ),
      ),
      'Exposing SII · 8 exposures',
    );
  });

  test('a run a manual action holds says what holds it', () {
    expect(
      ongoingRunText(
        SequenceExecutionState.paused,
        at('Smart Exposure', done: 5),
        heldFor: ongoingHoldText(held: true, action: ManualActionId.autofocus),
      ),
      'Paused for autofocus · 5/75 exposures (7%)',
    );
    expect(
      ongoingHoldText(held: true, action: null),
      'Paused for a manual action',
    );
    expect(ongoingHoldText(held: false, action: ManualActionId.center), isNull);
  });
}
