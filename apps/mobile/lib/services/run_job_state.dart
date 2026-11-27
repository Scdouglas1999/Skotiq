import 'package:skotiq_core/models.dart';

/// The run's state in the words the phone's Live Activity and the watch
/// complication read (`ContentState.jobState` on the Swift side). Inside a
/// running run the step's name hints at focusing, centering or guiding;
/// anything else that runs is exposing.
String runJobState(
  SequenceExecutionState exec, {
  required SequenceProgress progress,
}) {
  switch (exec) {
    case SequenceExecutionState.idle:
      return 'idle';
    case SequenceExecutionState.running:
      if (progress.currentNodeName case final name?) {
        final node = name.toLowerCase();
        if (node.contains('autofocus') || node.contains('focus')) {
          return 'focusing';
        }
        if (node.contains('center')) return 'centering';
        if (node.contains('guid')) return 'guiding';
      }
      return 'exposing';
    case SequenceExecutionState.paused:
      return 'paused';
    case SequenceExecutionState.recovering:
      return 'recovering';
    case SequenceExecutionState.stopping:
      return 'stopping';
    case SequenceExecutionState.completed:
      return 'completed';
    case SequenceExecutionState.failed:
      return 'failed';
    case SequenceExecutionState.stopFailed:
    case SequenceExecutionState.cleanupFailed:
    case SequenceExecutionState.finalizing:
      // The stop, the finalization or its cleanup is still pending: the run
      // has not settled, so it reads as stopping.
      return 'stopping';
  }
}
