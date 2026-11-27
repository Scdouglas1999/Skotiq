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
  const pages = Object.freeze({
    dashboard: Object.freeze({
      idle: Object.freeze({ free: ["start"], held: ["start"] }),
      running: Object.freeze({ free: ["pause","skip","stop"], held: ["pause","stop"] }),
      paused: Object.freeze({ free: ["resume","skip","stop"], held: ["stop"] }),
      recovering: Object.freeze({ free: ["stop"], held: ["stop"] }),
      stopping: Object.freeze({ free: [], held: [] }),
      stopRetry: Object.freeze({ free: ["stop"], held: ["stop"] }),
      ended: Object.freeze({ free: ["start"], held: ["start"] }),
    }),
    runWatch: Object.freeze({
      idle: Object.freeze({ free: ["start"], held: ["start"] }),
      running: Object.freeze({ free: ["pause","skip","stop"], held: ["pause","stop"] }),
      paused: Object.freeze({ free: ["resume","skip","stop"], held: ["stop"] }),
      recovering: Object.freeze({ free: ["pause","skip","stop"], held: ["pause","stop"] }),
      stopping: Object.freeze({ free: [], held: [] }),
      stopRetry: Object.freeze({ free: ["stop"], held: ["stop"] }),
      ended: Object.freeze({ free: ["start"], held: ["start"] }),
    }),
  });
  const rowOf = (word) => {
    const key = String(word).toLowerCase().replace(/[_\s]/g, '');
    return Object.prototype.hasOwnProperty.call(rows, key)
      ? rows[key] : unnamed;
  };
  return Object.freeze({
    /// The badge label and class for the run state [word], and the
    /// phase the run is in. [pausedIdle] is the
    /// host's `pausedIdle`; only `false` changes the label.
    view(word, pausedIdle) {
      const row = rowOf(word);
      const pausing = row.phase === 'paused' && pausedIdle === false;
      return Object.freeze({
        label: pausing ? "pausing: step finishing" : String(word),
        badge: row.badge,
        phase: row.phase,
      });
    },
    /// Which run controls [page] (`dashboard`, `runWatch`) enables
    /// for the run state [word]. [heldByAction] is the host's
    /// `heldByAction`: a manual action holds the run.
    controls(page, word, heldByAction) {
      const allowed = pages[page][rowOf(word).phase]
        [heldByAction === true ? 'held' : 'free'];
      return Object.freeze({
        start: allowed.includes("start"),
        pause: allowed.includes("pause"),
        resume: allowed.includes("resume"),
        skip: allowed.includes("skip"),
        stop: allowed.includes("stop"),
      });
    },
  });
})();
