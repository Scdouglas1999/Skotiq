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
