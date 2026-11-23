'use strict';

// The run state a page shows, served by the host from RunStateScript
// (apps/desktop/lib/headless_api/run_state_script.dart). Do not copy it.
const RUN_STATE = (() => {
  const rows = Object.freeze({
    idle: Object.freeze({ phase: "idle", badge: "badge-idle" }),
    running: Object.freeze({ phase: "running", badge: "badge-running" }),
    executing: Object.freeze({ phase: "running", badge: "badge-running" }),
    paused: Object.freeze({ phase: "paused", badge: "badge-paused" }),
    recovering: Object.freeze({ phase: "recovering", badge: "badge-recovering" }),
    stopping: Object.freeze({ phase: "stopping", badge: "badge-idle" }),
    finalizing: Object.freeze({ phase: "stopping", badge: "badge-idle" }),
    stopfailed: Object.freeze({ phase: "stopRetry", badge: "badge-idle" }),
    cleanupfailed: Object.freeze({ phase: "stopRetry", badge: "badge-idle" }),
    cancelled: Object.freeze({ phase: "ended", badge: "badge-idle" }),
    stopped: Object.freeze({ phase: "ended", badge: "badge-idle" }),
    completed: Object.freeze({ phase: "ended", badge: "badge-completed" }),
    done: Object.freeze({ phase: "ended", badge: "badge-completed" }),
    failed: Object.freeze({ phase: "ended", badge: "badge-error" }),
    error: Object.freeze({ phase: "ended", badge: "badge-error" }),
  });
  const unnamed = Object.freeze({ phase: 'idle', badge: 'badge-idle' });
  return Object.freeze({
    /// The badge label and class for the run state [word], and the
    /// phase a page decides its run controls from. [pausedIdle] is the
    /// host's `pausedIdle`; only `false` changes the label.
    view(word, pausedIdle) {
      const key = String(word).toLowerCase().replace(/[_\s]/g, '');
      const row = Object.prototype.hasOwnProperty.call(rows, key)
        ? rows[key] : unnamed;
      const pausing = row.phase === 'paused' && pausedIdle === false;
      return Object.freeze({
        label: pausing ? "pausing: step finishing" : String(word),
        badge: row.badge,
        phase: row.phase,
      });
    },
  });
})();
