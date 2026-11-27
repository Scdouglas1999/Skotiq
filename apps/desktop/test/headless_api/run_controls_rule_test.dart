// The app's run-control rule (`runTransportFor`) for every state the
// executor reports, with and without a manual action holding the run: the
// rule the browser pages' run controls are checked against.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/run_control/run_control.dart';
import 'package:skotiq_core/models.dart' show SequenceExecutionState;

/// The night phase the app shows for [state] (`nightRunPhaseProvider`); an
/// ended or idle run reads as finished.
NightRunPhase _appPhase(SequenceExecutionState state, {required bool held}) =>
    switch (state) {
      SequenceExecutionState.running ||
      SequenceExecutionState.recovering => NightRunPhase.running,
      SequenceExecutionState.paused =>
        held ? NightRunPhase.pausedForAction : NightRunPhase.pausedByUser,
      SequenceExecutionState.stopping ||
      SequenceExecutionState.finalizing ||
      SequenceExecutionState.stopFailed ||
      SequenceExecutionState.cleanupFailed => NightRunPhase.stopping,
      SequenceExecutionState.idle ||
      SequenceExecutionState.completed ||
      SequenceExecutionState.failed => NightRunPhase.finished,
    };

/// The controls the app enables in [state], as a list of names.
List<String> appControls(SequenceExecutionState state, {required bool held}) {
  final t = runTransportFor(
    phase: _appPhase(state, held: held),
    execution: state,
    gates: const {RunGate.actionHold},
  );
  bool on(RunControl? c) => c?.enabled ?? false;
  return [
    if (on(t.start)) 'start',
    if (on(t.pauseResume) && !t.resumes) 'pause',
    if (on(t.pauseResume) && t.resumes) 'resume',
    if (on(t.skip)) 'skip',
    if (on(t.stop)) 'stop',
  ];
}

void main() {
  test('the app offers these run controls in each state', () {
    final seen = {
      for (final state in SequenceExecutionState.values) ...{
        state.name: appControls(state, held: false),
        '${state.name}, held': appControls(state, held: true),
      },
    };
    expect(seen, {
      'idle': ['start'],
      'idle, held': ['start'],
      'running': ['pause', 'skip', 'stop'],
      'running, held': ['pause', 'skip', 'stop'],
      'paused': ['resume', 'skip', 'stop'],
      'paused, held': ['stop'],
      'stopping': ['stop'],
      'stopping, held': ['stop'],
      'recovering': ['stop'],
      'recovering, held': ['stop'],
      'completed': ['start'],
      'completed, held': ['start'],
      'failed': ['start'],
      'failed, held': ['start'],
      'stopFailed': ['stop'],
      'stopFailed, held': ['stop'],
      'cleanupFailed': ['stop'],
      'cleanupFailed, held': ['stop'],
      'finalizing': <String>[],
      'finalizing, held': <String>[],
    });
  });
}
