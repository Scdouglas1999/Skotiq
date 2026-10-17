# E-fix batch `autopilot-night`

Scope: `packages/skotiq_core/lib/src/services/scheduler/**`,
`packages/skotiq_core/lib/src/providers/sequence/**`.
Every item below has a failing-test-first pin; the refutation items encode the
refuter's own counter-input. No GUI harness, no bundle rebuild, no FRB regen, no
git writes.

## The one defect under all six items

`SchedulerStatus.currentTargetId` records **the last target dispatched**, not
"the run I own". Only a natural completion reaches the engine's trigger stream
(`scheduler_provider.dart` maps `SequencerEvent_Completed` and nothing else), so
after a failure / abort / operator Stop the field stays pinned and hysteresis
reports `isSwitch == false` forever. D-fix hardened `stop()` and
`_handleNoEligibleTarget` against that stale state; the **dispatch** path and the
**dawn park** still trusted it. Both are closed here by asking the executor,
through `SchedulerRunOwnership`, two questions instead of one.

New contract member: `SchedulerRunOwnership.hasActiveRun` — "is ANY run in
flight". `ownsRun == false` has two meanings that call for opposite actions:

| ownsRun | hasActiveRun | meaning | action |
|---|---|---|---|
| true | true | the autopilot's own run | dispatch nothing, dawn parks |
| false | false | our run ended, rig is FREE | clear target ⇒ re-dispatch; dawn parks |
| false | true | operator took the rig back | keep hysteresis; dawn does NOT park |

## WE-SEQ-N1 (P1) — one failed run ended the unattended night

* Fix: `SchedulerEngine._reconcileDispatchedRun(reason)`, called at the top of
  every running evaluation (`evaluation.dart`), clears `currentTargetId` when the
  dispatched run is no longer ours **and** the rig is free.
* Distinguishing log line (the two-implementations guard):
  `SchedulerEngine` / `Scheduler reconcile (<reason>): dispatched run <id> has
  ended and the rig is free — clearing current target <name>` (and the
  complementary `… but another run is active — keeping hysteresis …`). A live log
  now answers "did the re-arm run, and which branch did it take?".
* Pin: `test/services/scheduler/scheduler_run_ended_redispatch_test.dart`
  — proven failing first with the call disabled: `Expected: <2> Actual: <1>`
  dispatches; plus the regression pin that a manual run is never dispatched over.

## WE-SEQ-N5 (P2) — the generated plan could not start from a parked mount

* Fix: `buildSequenceForCandidate` emits `Unpark Mount` as the target's FIRST
  child (`Unpark → Slew → Center → Expose`). Unconditional: unparking an
  unparked mount is a no-op, while a live is-parked read taken minutes before the
  slew is not a guarantee.
* Pin: same file — asserts the child ORDER, not just presence.

## Wave-E refutation of SEQ-12 — the dawn park is the third teardown

`parkForEndOfNight()` routes to `SafeRigService.safeTheRig(park: true)`, which
**pauses the running sequence first**. Firing it without an ownership check ends
the operator's exposure mid-frame — the exact reasoning SEQ-12 used to gate the
other two paths.

* Fix (`_handleNoEligibleTarget`): park unless somebody ELSE's run is live.
  An idle rig at dawn is still parked (it may be tracking into the ground); a
  rig running the operator's own plan is not. The declined tick publishes an
  operator-facing line — "Dawn has arrived but the autopilot is not parking: the
  run on the rig is not the one it started." — and logs at WARNING.
* Pin: the refuter's state (takeover, clock advanced to local noon):
  `Expected: <0> Actual: <1>` park calls, proven failing first.

## WE-SEQ-N3 (P3) — the armed-autopilot warning went silent after one dispatch

Root cause was NOT the rule: `CurrentSequenceNotifier.createSequence` ("New
Sequence") never handed the editor slot back, so `activePlanOwnerProvider` still
said `autopilot` for a plan the operator built, and `AutopilotArmedRule`'s
correct self-exemption applied to the wrong plan.

* Fix: `_reclaimManualOwnership()` — one helper now used by `loadSequence`,
  `createSequence` and `clearSequence`.
* Distinguishing log line: the rule logs `AutopilotArmedRule: suppressed for
  "<plan>" — the editor slot is owned by the autopilot`. "Suppressed" in a log
  for an operator-built plan is the fingerprint of this bug returning.
* Pin: `test/providers/sequence/autopilot_ownership_handback_test.dart` — three
  assertions failed first (owner after New Sequence / after Clear / the warning
  itself), and the scheduler's own dispatch is still exempt.

## WE-SEQ-N6 (P2) — the same Stop recorded Failed + CRITICAL

Empirically narrowed with the harness, not by reading:

* A `SequenceFailed` arriving **while** the stop is in flight is already handled
  (test 1 passes at HEAD) — that hypothesis was wrong.
* A `SequenceFailed` arriving **after** the stop's finalization completed opened a
  SECOND finalization and republished the verdict as `failed`
  (`Expected: 'paused-stopped' Actual: 'failed'`). That is the live symptom: a
  stop-cancelled Slew emits BOTH the `Stopped` state change and the node tree's
  own failure, and whichever landed second won; a stop during an exposure emits
  only `Stopped`, which is why the hand-started run was recorded honestly.
* Fix: `SequenceExecutor._settledRunStatus` — a run's verdict is claimed once;
  a terminal arriving after the drive finished is logged and ignored. Reset by
  `_resetFinalizationForNewRun()`. Deliberately state-based, not string-based:
  the Wave-E refuter already showed what substring-matching "cancelled" costs.
* Log line uses the shared `kStopClassificationLogTag` so this producer joins the
  other stop-classification sites: `[stop-classification] sequence_executor:
  late "failed" terminal ignored — this run already settled as "paused-stopped"`.
* Pin: `test/providers/sequence/operator_stop_outcome_test.dart`, including the
  counter-pin that a genuine `SequenceFailed` with no stop in flight is still a
  failure.

## Wave-E refutation of SEQ-13 — undo/redo never re-synced the catalog

The builder→catalog re-point sync hung off `updateNode` only, so Ctrl+Z reached
the same two-copies divergence — with the STALE copy now the one the operator
never confirmed.

* Fix: `_syncTargetsAfterSnapshotSwap(before, after)` in `tree_editing.dart`,
  called by `undo()` and `redo()`; per-node guard means an undone rename or
  priority edit writes nothing.
* Pin: `test/providers/sequence/target_repoint_undo_sync_test.dart` with the
  refuter's exact input (M42-TEST 5.5885 h/−5.39° → 21.42 h/−35.0°, then undo)
  against a real in-memory `SkotiqDatabase`: failed first with
  `Expected: 5.5885 Actual: 21.42`.

## Verification

* `flutter test test/services/scheduler/ test/providers/sequence/` +
  the four scheduler provider suites — **731 passed** (later re-run: 713 + 6 in
  the two files re-formatted).
* `apps/desktop test/headless_api/scheduler_handlers_test.dart` — 11 passed
  (the Unpark node changes the generated plan; the headless contract is unaffected).
* `dart analyze` over both scope directories — no issues from this batch.
* `dart format --set-exit-if-changed` over every file this batch touched — clean.

## Notes for the orchestrator

* **Concurrent-agent hazard observed.** Mid-batch the working tree briefly showed
  every tracked E-fix change reverted, with `git stash` in the reflog
  (`stash@{0}: WIP on audit/end-to-end-campaign`) and, later, all changes back and
  **staged**. Nothing of this batch was lost, but `stash@{1}` and `stash@{0}` both
  still exist and the index is now non-empty — worth checking before the commit.
* `packages/skotiq_app` suites could not be trusted while this ran: sibling
  batches were mid-edit in `planetarium/widgets/redesign/command_bar.dart` (a
  syntax error) and `time_control_panel.dart` (missing method), which fails the
  whole package's compilation. The 6 `test/screens/planner/captures_*` failures
  seen are from those edits, not from this batch — none of its files are in that
  package. Re-run after the wave settles.
* `sequence_executor/event_operations.dart` and the notification classifier were
  left alone deliberately: the sibling stop-classification batch owns them, and
  this batch reuses their `kStopClassificationLogTag` rather than inventing a
  second vocabulary.
