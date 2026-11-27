// The web pages read the run state from the script the host serves as
// `js/run-state.js`; their node tests load a committed copy. This keeps that
// copy equal to what the host serves. Regenerate with:
//
//     SKOTIQ_REGENERATE=1 flutter test test/headless_api/run_state_script_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/run_state_script.dart';
import 'package:skotiq_core/models.dart'
    show NativeRunState, SequenceExecutionState;

String _key(String word) => word.toLowerCase().replaceAll(RegExp(r'[_\s]'), '');

void main() {
  test('the node tests load the run state the host serves', () {
    final fixture = File('web_dashboard/test/fixtures/run-state.js');
    final served = RunStateScript.javaScript();
    if (Platform.environment['SKOTIQ_REGENERATE'] == '1') {
      fixture.writeAsStringSync(served);
    }
    expect(
      fixture.readAsStringSync(),
      served,
      reason: 'run with SKOTIQ_REGENERATE=1 to refresh the fixture',
    );
  });

  test('every state word a host reports has a row', () {
    final words = [
      for (final state in NativeRunState.values)
        if (state != NativeRunState.unknown) state.name,
      for (final state in SequenceExecutionState.values) state.name,
    ];
    for (final word in words) {
      expect(RunStateScript.rows, contains(_key(word)), reason: word);
    }
  });

  test('each page offers the app\'s run controls, apart from these', () {
    final differences = <String>[];
    for (final page in RunPage.values) {
      for (final state in SequenceExecutionState.values) {
        for (final held in [false, true]) {
          final phase = RunStateScript.rows[_key(state.name)]!.phase;
          final offered = RunStateScript.pageControls(page, phase, held: held);
          final app = RunStateScript.appControlsFor(state, held: held);
          final who = '${page.name} ${state.name}${held ? ' held' : ''}';
          for (final c in offered.difference(app)) {
            differences.add('$who: +${c.name}');
          }
          for (final c in app.difference(offered)) {
            differences.add('$who: -${c.name}');
          }
        }
      }
    }
    expect(differences, [
      // Stop shares the phase with finalizing, which has nothing to stop.
      'dashboard stopping: -stop',
      'dashboard stopping held: -stop',
      'runWatch stopping: -stop',
      'runWatch stopping held: -stop',
      // RunStateScript.pageAlso.
      'runWatch recovering: +pause',
      'runWatch recovering: +skip',
      'runWatch recovering held: +pause',
      'runWatch recovering held: +skip',
    ]);
  });

  test('a row agrees with the app on whether the run is over', () {
    for (final state in NativeRunState.values) {
      if (state == NativeRunState.unknown) continue;
      final phase = RunStateScript.rows[_key(state.name)]!.phase;
      final over = phase == RunPhase.ended || phase == RunPhase.idle;
      expect(over, state.isTerminal, reason: state.name);
    }
  });
}
