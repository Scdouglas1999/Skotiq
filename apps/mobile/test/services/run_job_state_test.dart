// The Live Activity and the watch complication read the run's state in one
// set of words; both Swift targets branch on exactly these.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_mobile/services/run_job_state.dart';

void main() {
  test('every run state has its word', () {
    const idle = SequenceProgress();
    final words = {
      for (final s in SequenceExecutionState.values)
        s.name: runJobState(s, progress: idle),
    };
    expect(words, {
      'idle': 'idle',
      'running': 'exposing',
      'paused': 'paused',
      'recovering': 'recovering',
      'stopping': 'stopping',
      'finalizing': 'stopping',
      'stopFailed': 'stopping',
      'cleanupFailed': 'stopping',
      'completed': 'completed',
      'failed': 'failed',
    });
  });

  group('a running step is read by what it reports, not its name', () {
    String word(String node, InstructionProgressDetail? reading) => runJobState(
      SequenceExecutionState.running,
      progress: SequenceProgress(
        currentNodeId: 'step',
        currentNodeName: node,
        nodeProgressStructuredDetail: {'step': ?reading},
      ),
    );

    test('an exposure step named for focusing is exposing', () {
      expect(
        word(
          'Ha focus field',
          const ExposureInstructionProgressDetail(
            frame: 3,
            total: 20,
            durationSecs: 300,
          ),
        ),
        'exposing',
      );
    });

    test('a refocus reading leaves the step to its name', () {
      expect(
        word(
          'Lights',
          const AutofocusInstructionProgressDetail(step: 9, totalSteps: 9),
        ),
        'exposing',
      );
      expect(
        word(
          'Autofocus',
          const AutofocusInstructionProgressDetail(step: 4, totalSteps: 9),
        ),
        'focusing',
      );
    });

    test('a centering step under any name is centering', () {
      expect(
        word(
          'M31',
          const CenterInstructionProgressDetail(attempt: 1, maxAttempts: 5),
        ),
        'centering',
      );
    });
  });

  test('a running step names what it does', () {
    String word(String node) => runJobState(
      SequenceExecutionState.running,
      progress: SequenceProgress(currentNodeName: node),
    );
    expect(word('Autofocus'), 'focusing');
    expect(word('Center target'), 'centering');
    expect(word('Start guiding'), 'guiding');
    expect(word('Lights'), 'exposing');
  });
}
