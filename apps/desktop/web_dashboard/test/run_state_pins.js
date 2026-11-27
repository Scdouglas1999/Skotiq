'use strict';

// What each page shows for every run state a host can report: the badge
// text and class, and which run controls are enabled. The dashboard reads
// GET /api/sequencer/status; run-watch reads the same block inside
// GET /api/run-watch/snapshot, where `progress.state` is the app's
// SequenceExecutionState name.
//
// `state` is the word in `sequencer.state` (and, on run-watch, also in
// `progress.state` unless `executor` names another). The first eight are the
// native executor's words (ExecutorState::as_wire); the rest are the app's
// SequenceExecutionState names and words older pages already handled.
// `heldByAction` is the host's flag that a manual action holds the run.

const CASES = [
  { name: 'idle', state: 'idle' },
  { name: 'running', state: 'running' },
  { name: 'paused', state: 'paused' },
  { name: 'paused, step finishing', state: 'paused', pausedIdle: false },
  { name: 'paused, step finished', state: 'paused', pausedIdle: true },
  { name: 'stopping', state: 'stopping' },
  { name: 'cancelled', state: 'cancelled' },
  { name: 'completed', state: 'completed' },
  { name: 'failed', state: 'failed' },
  { name: 'recovering', state: 'recovering' },
  { name: 'stopFailed', state: 'stopFailed' },
  { name: 'cleanupFailed', state: 'cleanupFailed' },
  { name: 'finalizing', state: 'finalizing' },
  { name: 'executing', state: 'executing' },
  { name: 'done', state: 'done' },
  { name: 'error', state: 'error' },
  { name: 'stopped', state: 'stopped' },
  { name: 'no state', state: null },
  { name: 'cancelled over an idle executor', state: 'cancelled', executor: 'idle' },
  { name: 'completed over a running executor', state: 'completed', executor: 'running' },
  { name: 'recovering executor over a running status', state: 'running', executor: 'recovering' },
  { name: 'paused, held by an action', state: 'paused', heldByAction: true },
  { name: 'running, held by an action', state: 'running', heldByAction: true },
  { name: 'recovering, held by an action', state: 'recovering', heldByAction: true },
];

/// One page's reading of a case as `[label, badge class, ...enabled controls]`.
function reading(label, badgeClass, controls) {
  return [label, badgeClass.replace(/^badge /, ''),
    ...Object.keys(controls).filter((k) => controls[k])];
}

module.exports = { CASES, reading };
