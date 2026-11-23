import 'dart:convert';

/// Where a run stands, as the browser pages decide their run controls from
/// it. Each page offers its own set of controls.
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

/// The run-state words the browser pages show, and the script that serves
/// them as `js/run-state.js` to both the dashboard and run-watch.
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

  /// The table as a browser script: `RUN_STATE.view(word, pausedIdle)`.
  static String javaScript() {
    final entries = [
      for (final MapEntry(:key, :value) in rows.entries)
        '    $key: Object.freeze({ phase: ${jsonEncode(value.phase.name)}, '
            'badge: ${jsonEncode(value.badge)} }),',
    ].join('\n');
    return "'use strict';\n\n"
        '// The run state a page shows, served by the host from RunStateScript\n'
        '// (apps/desktop/lib/headless_api/run_state_script.dart). Do not copy it.\n'
        'const RUN_STATE = (() => {\n'
        '  const rows = Object.freeze({\n$entries\n  });\n'
        "  const unnamed = Object.freeze({ phase: 'idle', badge: 'badge-idle' });\n"
        '  return Object.freeze({\n'
        '    /// The badge label and class for the run state [word], and the\n'
        '    /// phase a page decides its run controls from. [pausedIdle] is the\n'
        '    /// host\'s `pausedIdle`; only `false` changes the label.\n'
        '    view(word, pausedIdle) {\n'
        "      const key = String(word).toLowerCase().replace(/[_\\s]/g, '');\n"
        '      const row = Object.prototype.hasOwnProperty.call(rows, key)\n'
        '        ? rows[key] : unnamed;\n'
        "      const pausing = row.phase === 'paused' && pausedIdle === false;\n"
        '      return Object.freeze({\n'
        '        label: pausing ? ${jsonEncode(pausingLabel)} : String(word),\n'
        '        badge: row.badge,\n'
        '        phase: row.phase,\n'
        '      });\n'
        '    },\n'
        '  });\n'
        '})();\n';
  }
}
