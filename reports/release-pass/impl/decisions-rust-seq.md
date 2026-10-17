# Batch rust-seq — owner decisions 4 and 10

Branch `audit/end-to-end-campaign`, worktree `wf_9953116a-7f8-3`. Not committed.

Files touched (3):
- `native/skotiq_native/sequencer/src/instructions.rs`
- `native/skotiq_native/sequencer/src/executor/mod.rs`
- `native/skotiq_native/sequencer/src/triggers.rs`

## Decision 4 — Unpark only when the mount reports parked

`execute_unpark` (instructions.rs) issued `mount_unpark` unconditionally. The
autopilot prefixes every dispatched sequence with an `Unpark` node, so a mount
already tracking a target receives a release-the-axes command mid-run.

Now it reads `mount_is_parked` first:
- `Ok(false)` → logged no-op, `Success` with message `"Mount already unparked"`;
  `mount_unpark` is never called.
- `Ok(true)` → unchanged behaviour (`"Mount unparked"` / `"Unpark failed: …"`).
- `Err(_)` → warn and unpark anyway. Fail-safe direction: an unpark on an
  already-unparked mount is milder than skipping an unpark on a parked one, and
  this preserves the pre-decision behaviour for drivers that do not expose
  `AtPark`.

The park path directly above already polls `mount_is_parked` and warns-and-
continues on a read error, so this reads like its neighbour.

Tests (new, `instructions::tests`, in the file's existing scripted-ops style —
added `mount_unpark_calls` counter and `with_mount_is_parked_error` to
`ScriptedDomeRotatorOps`):
- `unpark_is_a_logged_no_op_when_the_mount_is_not_parked` — 0 unpark calls.
  Would have failed before the change on both the call count and the message.
- `unpark_runs_when_the_mount_reports_parked`
- `unpark_still_runs_when_the_parked_state_cannot_be_read`

## Decision 10 — interval-autofocus TRIGGER failure policy

Failure path found at `executor/mod.rs` `RecoveryAction::Autofocus` arm (the
inline trigger-monitor closure). Old behaviour: reset the HFR baseline, then
latch `is_paused_for_triggers`, set `ExecutorState::Paused`, emit a
`StateChanged(Paused)` + an `Error` reading "sequence paused for intervention".
On an unattended rig that spent the rest of a clear night parked on a missed
curve fit.

Three changes:

1. **Continue, do not pause.** The pause latch, the state write and the
   `StateChanged` emit are gone. The run carries on at the pre-autofocus
   position.

2. **The restore was already correct and is now reported.**
   `execute_autofocus` (instructions.rs:4021, :4495) captures the pre-sweep
   position before computing the sweep and calls `restore_autofocus_origin` on
   every `Failure`/`Cancelled` result, stamping `autofocus_origin_restored` into
   `result.data`. So nothing "applies the failed position" today — the delta was
   only that the outcome was invisible. The trigger arm now reads the focuser
   before and after and threads both into the record. The marker is read as a
   tri-state: `Some(true)` restored, `Some(false)` the return move failed,
   `None` the run never moved the focuser (e.g. admission rejected because
   another autofocus held the equipment). Only an explicit `false` produces the
   "could NOT be returned" warning — reading `None` as a failed restore would
   cry wolf on a run whose focuser never moved.

3. **Cadence anchor moves on a failed attempt.** New
   `TriggerState::mark_autofocus_attempted` (triggers.rs) sets
   `last_autofocus_frame = completed_exposures` and drops the stale-focus latch,
   without claiming an autofocus succeeded (unlike `mark_autofocus_performed`,
   which also resets the HFR baseline semantics the caller handles separately).
   Without this, continuing is worse than pausing: `AutofocusInterval` carries
   `with_cooldown(0)` by design, so `frames_since_af >= every_n_frames` stays
   true and a failing sweep re-fires after *every* subsequent exposure. Retry is
   now one full cadence later.

Decision row: `DecisionCategory::SystemEvent`, summary
`"Autofocus failed — continuing with last-good focus"` (pinned as
`pub const AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY`, reachable from the bridge via
`pub use executor::*` so the INFO push can key off it rather than string-match),
details `{trigger_id, trigger_name, reason, focuser_position_before,
focuser_position_after, pre_autofocus_position_restored}`, stamped with
`active_run_id_for_decisions` the same way the neighbouring `TriggerFired` row
is. Sent on `decision_tx_for_lifecycle`; the operator notice still goes out as
`ExecutorEvent::Error` (the only text-carrying variant, and the precedent used
by the "no focuser configured, continuing" arm right below).

Per-node scope: untouched. `AutofocusInstruction` →
`execute_autofocus_for_node` is a different call path; the only `failure_action`
config in this crate is `FlipFailureAction` (meridian flip), also untouched.

Testable seam: the record-building was extracted to
`autofocus_trigger_continuation()` next to the existing
`classify_dither_result()` helper, for the reason that file already documents —
the trigger-monitor closure cannot be invoked as a unit.

Tests (new):
- `executor::tests::a_failed_autofocus_trigger_records_the_focus_the_run_kept`
- `executor::tests::a_failed_position_restore_is_called_out_not_smoothed_over`
- `executor::tests::an_autofocus_that_never_moved_the_focuser_does_not_warn_about_restore`
- `triggers::tests::a_failed_autofocus_attempt_defers_the_next_interval_by_a_full_cadence`
  — asserts no re-fire on each of the next 9 frames, re-fire on the 10th.

## Verdicts

- `cargo test -p skotiq_sequencer`: **PASS** — 701 lib + 5 + 4 + 12
  integration, 0 failed (1 doc-test ignored, pre-existing).
- `cargo clippy -p skotiq_sequencer --all-targets`: clean.
- `cargo fmt --all -- --check`: clean.

## Owed / not covered by this batch

- The "push INFO" half of decision 10 is Dart/bridge side — the Rust decision
  row and the `AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY` constant are the hooks it
  needs; nothing in this crate publishes pushes.
- No test drives the trigger-monitor closure end to end (the closure is not
  unit-invokable — same limitation `scenario_sim_tests.rs` documents for the
  ParkAndAbort path). The *policy* is proven at the extracted seam and at the
  trigger-state seam; that the closure no longer latches PAUSED is proven only
  by the diff and the compiler, not by a running executor. Worth one live-rig
  or GUI-drive confirmation that a forced AF failure leaves the run `running`.

---

## PORTED — re-landed on the post-split tree (2026-08-14)

The batch above was written against `59dec49c7`, where the sequencer was still
two monoliths. The campaign has since split `instructions.rs` into
`instructions/*.rs` + `instructions/tests/*.rs` and `triggers.rs` into
`triggers/`, and moved the trigger-monitor closure out of `executor/mod.rs` into
`executor/start.rs`. Re-landed on the main tree with the same semantics; nothing
in the batch was dropped.

New homes (7 files touched, 1 added):
- `execute_unpark` pre-check → `instructions/park.rs` (verbatim).
- Unpark tests → new `instructions/tests/park.rs` (`mod park;` registered in
  `instructions/tests/mod.rs`), following the C3 split's one-cluster-per-file
  convention. The `ScriptedDomeRotatorOps` harness now lives in
  `instructions/tests/mod.rs`; `mount_unpark_calls`, `mount_is_parked_error`
  and `with_mount_is_parked_error` were added there verbatim.
- `TriggerState::mark_autofocus_attempted` → `triggers/state.rs`, beside
  `mark_autofocus_performed` / `clear_autofocus_invalidation` (verbatim).
- Its cadence test → `triggers/tests/mod.rs`, next to
  `test_autofocus_interval_trigger` (verbatim).
- `AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY`, `AutofocusTriggerContinuation` and
  `autofocus_trigger_continuation()` → `executor/mod.rs`, still beside
  `classify_dither_result()` (verbatim). Still reachable from the bridge via
  `pub use executor::*` in `lib.rs`.
- The three continuation tests → `executor/tests/mod.rs` (verbatim), which is
  where `mod tests` moved.
- The `RecoveryAction::Autofocus` failure path → `executor/start.rs`.

Three deliberate adaptations, all forced by code that landed after the batch's
base:

1. The arm no longer destructures `(Some(_), Some(focuser_id))`; HEAD matches on
   `autofocus_trigger_skip_reason(camera_id, focuser_id)` and the focuser id is
   not bound. Rather than re-derive it twice, the two position reads go through
   a new `read_focuser_position(&device_ops, focuser_id)` helper in
   `executor/trigger_context.rs` (where the other small trigger helpers live).
   `None` for "no focuser" collapses into the same `None` the batch produced for
   "the driver would not answer" — both mean the row cannot name a position, and
   the skip-reason match has already proved a focuser is configured on this path.

2. HEAD reached the pause in question through two earlier exits that did not
   exist at the batch's base: `AutofocusOutcome::KeepImaging` (soft but inside
   tolerance → continue) and `AutofocusFailureAction::AbortAndPark` (end the run
   and safe the rig). Both are left intact — the batch's policy replaces only
   the final catch-all arm, which was the one that latched PAUSED. AbortAndPark
   remains the operator's way to ask for the harder answer, and the arm's
   comment now says so.

3. `ts.mark_autofocus_attempted()` went into the same `reset_baseline_hfr()`
   block the batch put it in — which at HEAD is shared by all three failure
   exits rather than reached only by the pause arm. This is the faithful
   placement and the correct one: `KeepImaging` also continues the run, so it
   needs the cadence anchor moved for exactly the same reason (no time cooldown
   on `AutofocusInterval`), and `AbortAndPark` terminates, so the mark cannot
   matter there. The `tracing::warn!` in that block was reworded to describe
   what it now does on every path it can run on, instead of the batch's
   continuation-specific wording, which would have been false on the abort path.

Verdicts on the main tree:
- `cargo test -p skotiq_sequencer`: **PASS** — 800 lib + 6 + 4 + 12
  integration, 0 failed (1 doc-test ignored, pre-existing). The four new tests
  pass; `instructions::tests::park::*` are 3 of them.
- `cargo clippy -p skotiq_sequencer --all-targets`: clean (the only
  warnings in the workspace are pre-existing doc-indent ones in
  `skotiq_imaging`, untouched here).
- `cargo fmt -p skotiq_sequencer -- --check`: clean.

Still owed, unchanged from the batch: the Dart/bridge INFO push, and a live
confirmation that a forced trigger-AF failure leaves the run `running` — no test
drives the trigger-monitor closure end to end.
