import 'package:skotiq_core/models.dart';

/// The run's state in the words the phone's Live Activity and the watch
/// complication read (`ContentState.jobState` on the Swift side). Inside a
/// running run, a step's last centering or exposure reading says what it
/// does; otherwise its name does.
String runJobState(
  SequenceExecutionState exec, {
  required SequenceProgress progress,
}) {
  switch (exec) {
    case SequenceExecutionState.idle:
      return 'idle';
    case SequenceExecutionState.running:
      return _runningStepWord(progress);
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

String _runningStepWord(SequenceProgress progress) =>
    switch (runningStepKind(progress)) {
      RunningStepKind.centering => 'centering',
      RunningStepKind.focusing => 'focusing',
      RunningStepKind.guiding => 'guiding',
      RunningStepKind.exposing || RunningStepKind.other => 'exposing',
    };

/// What the running step does, as far as the phone can tell.
enum RunningStepKind { exposing, centering, focusing, guiding, other }

/// Reads the running step: its last centering or exposure reading says what
/// it does; otherwise its name does.
RunningStepKind runningStepKind(SequenceProgress progress) {
  final reading = progress.nodeProgressStructuredDetail[progress.currentNodeId];
  switch (reading) {
    case CenterInstructionProgressDetail():
      return RunningStepKind.centering;
    case ExposureInstructionProgressDetail() ||
        SmartExposureInstructionProgressDetail() ||
        ExposureAdjustedProgressDetail():
      return RunningStepKind.exposing;
    default:
      break;
  }
  // An autofocus reading does not decide: an exposure step keeps the reading
  // of a refocus it ran until its next frame is recorded, and an autofocus
  // reports one only once it has measured a point.
  if (progress.currentNodeName case final name?) {
    final node = name.toLowerCase();
    if (node.contains('autofocus') || node.contains('focus')) {
      return RunningStepKind.focusing;
    }
    if (node.contains('center')) return RunningStepKind.centering;
    if (node.contains('guid')) return RunningStepKind.guiding;
  }
  return RunningStepKind.other;
}
