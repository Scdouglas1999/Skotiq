import 'dart:convert';

import 'package:skotiq_app/services/run_control/run_control.dart';
import 'package:skotiq_core/models.dart' show SequenceExecutionState;

/// Where a run stands, as the browser pages decide their run controls from
/// it.
enum RunPhase {
  /// No run, or a state word no row names.
  idle,
  running,
  paused,
  recovering,

  /// The run is stopping or the app is finishing its records.
  stopping,

  /// The stop or its cleanup failed; Stop is offered again.
  stopRetry,

  /// The wire says the run is over.
  ended,
}

/// A run control a browser page can show.
enum PageControl { start, pause, resume, skip, stop }

/// A browser page the host serves run controls to.
enum RunPage { dashboard, runWatch }

/// The run-state words the browser pages show, the run controls each phase
/// allows, and the script that serves both as `js/run-state.js` to the
/// dashboard and run-watch.
///
/// The words are the native executor's (`ExecutorState::as_wire`, the app's
/// `NativeRunState`) and the app's `SequenceExecutionState` names that
/// run-watch reads from `progress.state`, plus words older pages also read.
/// A key is the word lowercased with `_` and spaces removed.
abstract final class RunStateScript {
  static const rows = <String, ({RunPhase phase, String badge})>{
    'idle': (phase: RunPhase.idle, badge: 'badge-idle'),
    'running': (phase: RunPhase.running, badge: 'badge-running'),
    'executing': (phase: RunPhase.running, badge: 'badge-running'),
    'paused': (phase: RunPhase.paused, badge: 'badge-paused'),
    'recovering': (phase: RunPhase.recovering, badge: 'badge-recovering'),
    'stopping': (phase: RunPhase.stopping, badge: 'badge-idle'),
    'finalizing': (phase: RunPhase.stopping, badge: 'badge-idle'),
    'stopfailed': (phase: RunPhase.stopRetry, badge: 'badge-idle'),
    'cleanupfailed': (phase: RunPhase.stopRetry, badge: 'badge-idle'),
    'cancelled': (phase: RunPhase.ended, badge: 'badge-idle'),
    'stopped': (phase: RunPhase.ended, badge: 'badge-idle'),
    'completed': (phase: RunPhase.ended, badge: 'badge-completed'),
    'done': (phase: RunPhase.ended, badge: 'badge-completed'),
    'failed': (phase: RunPhase.ended, badge: 'badge-error'),
    'error': (phase: RunPhase.ended, badge: 'badge-error'),
  };

  /// What the label reads for a paused run whose step (an exposure, a slew,
  /// a focuser move) is still finishing, which the host reports as
  /// `pausedIdle: false`.
  static const pausingLabel = 'pausing: step finishing';

  /// The controls the app offers in [phase] (`runTransportFor`), with a
  /// manual action holding the run when [held]. A phase offers a control
  /// only when every app state in it does: Stop is not offered while
  /// `stopping`, because `finalizing` shares the phase.
  static Set<PageControl> appControls(RunPhase phase, {required bool held}) {
    final states = [
      for (final state in SequenceExecutionState.values)
        if (rows[_key(state.name)]?.phase == phase) state,
    ];
    if (states.isEmpty) return const {};
    return states
        .map((state) => appControlsFor(state, held: held))
        .reduce((a, b) => a.intersection(b));
  }

  /// The controls the app offers for a run the executor reports as [state].
  /// No run is under way when [state] is idle or ended, so only Start is
  /// asked, without the app's plan and camera checks.
  static Set<PageControl> appControlsFor(
    SequenceExecutionState state, {
    required bool held,
  }) {
    final transport = runTransportFor(
      phase:
          liveRunPhaseOf(state, heldByAction: held) ?? NightRunPhase.finished,
      execution: state,
      gates: const {RunGate.actionHold},
      heldByAction: held,
    );
    bool on(RunControl? control) => control != null && control.enabled;
    final toggles = on(transport.pauseResume);
    return {
      if (on(transport.start)) PageControl.start,
      if (toggles && !transport.resumes) PageControl.pause,
      if (toggles && transport.resumes) PageControl.resume,
      if (on(transport.skip)) PageControl.skip,
      if (on(transport.stop)) PageControl.stop,
    };
  }

  /// Controls a page offers beyond the app's rule. Run-watch keeps Pause and
  /// Skip while the run is recovering: the executor keeps an operator's
  /// pause through the recovery ladder, and the app refuses both there.
  static const pageAlso = <RunPage, Map<RunPhase, Set<PageControl>>>{
    RunPage.runWatch: {
      RunPhase.recovering: {PageControl.pause, PageControl.skip},
    },
  };

  /// The controls [page] offers in [phase]. Only a manual action's own
  /// release skips a run the action holds, on every page.
  static Set<PageControl> pageControls(
    RunPage page,
    RunPhase phase, {
    required bool held,
  }) =>
      {...appControls(phase, held: held), ...?pageAlso[page]?[phase]}
        ..removeAll({if (held) PageControl.skip});

  static String _key(String word) =>
      word.toLowerCase().replaceAll(RegExp(r'[_\s]'), '');

  /// The table as a browser script: `RUN_STATE.view(word, pausedIdle)` and
  /// `RUN_STATE.controls(page, word, heldByAction)`.
  static String javaScript() {
    final entries = [
      for (final MapEntry(:key, :value) in rows.entries)
        '    $key: Object.freeze({ phase: ${jsonEncode(value.phase.name)}, '
            'badge: ${jsonEncode(value.badge)} }),',
    ].join('\n');
    String names(Set<PageControl> controls) => jsonEncode([
      for (final control in PageControl.values)
        if (controls.contains(control)) control.name,
    ]);
    final controls = [
      for (final page in RunPage.values) ...[
        '    ${page.name}: Object.freeze({',
        for (final phase in RunPhase.values)
          '      ${phase.name}: Object.freeze({ '
              'free: ${names(pageControls(page, phase, held: false))}, '
              'held: ${names(pageControls(page, phase, held: true))} }),',
        '    }),',
      ],
    ].join('\n');
    final flags = [
      for (final control in PageControl.values)
        '        ${control.name}: allowed.includes(${jsonEncode(control.name)}),',
    ].join('\n');
    return "'use strict';\n\n"
        '// The run state a page shows, served by the host from RunStateScript\n'
        '// (apps/desktop/lib/headless_api/run_state_script.dart). Do not copy it.\n'
        'const RUN_STATE = (() => {\n'
        '  const rows = Object.freeze({\n$entries\n  });\n'
        "  const unnamed = Object.freeze({ phase: 'idle', badge: 'badge-idle' });\n"
        '  const pages = Object.freeze({\n$controls\n  });\n'
        '  const rowOf = (word) => {\n'
        "    const key = String(word).toLowerCase().replace(/[_\\s]/g, '');\n"
        '    return Object.prototype.hasOwnProperty.call(rows, key)\n'
        '      ? rows[key] : unnamed;\n'
        '  };\n'
        '  return Object.freeze({\n'
        '    /// The badge label and class for the run state [word], and the\n'
        '    /// phase the run is in. [pausedIdle] is the\n'
        '    /// host\'s `pausedIdle`; only `false` changes the label.\n'
        '    view(word, pausedIdle) {\n'
        '      const row = rowOf(word);\n'
        "      const pausing = row.phase === 'paused' && pausedIdle === false;\n"
        '      return Object.freeze({\n'
        '        label: pausing ? ${jsonEncode(pausingLabel)} : String(word),\n'
        '        badge: row.badge,\n'
        '        phase: row.phase,\n'
        '      });\n'
        '    },\n'
        '    /// Which run controls [page] (`dashboard`, `runWatch`) enables\n'
        '    /// for the run state [word]. [heldByAction] is the host\'s\n'
        '    /// `heldByAction`: a manual action holds the run.\n'
        '    controls(page, word, heldByAction) {\n'
        '      const allowed = pages[page][rowOf(word).phase]\n'
        "        [heldByAction === true ? 'held' : 'free'];\n"
        '      return Object.freeze({\n'
        '$flags\n'
        '      });\n'
        '    },\n'
        '  });\n'
        '})();\n';
  }
}
