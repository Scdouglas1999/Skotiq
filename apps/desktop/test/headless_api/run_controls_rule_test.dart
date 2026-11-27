// The app's run-control rule (`runTransportFor`, as RunStateScript asks it)
// for every state the executor reports, with and without a manual action
// holding the run: the rule the browser pages' run controls are built from.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/run_state_script.dart';
import 'package:skotiq_core/models.dart' show SequenceExecutionState;

/// The controls the app enables in [state], as a list of names.
List<String> appControls(SequenceExecutionState state, {required bool held}) =>
    [
      for (final control in RunStateScript.appControlsFor(state, held: held))
        control.name,
    ];

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
