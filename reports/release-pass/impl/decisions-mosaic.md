# Owner decision 7 — mosaic panel resume is real (batch: mosaic)

Decision (RELEASE-PASS-2026-08-11, "Owner decisions (made 2026-08-14)"):
**WIRE THE REAL SINK — `SessionWizardCheckpointSink` into production.** Panel resume is
supposed to be real in 6.x. **ON-RIG VALIDATION IS OWED (owner accepted).**

## What was actually broken

`crate::mosaic::run_mosaic_wizard` — the production entry, reached from
`MosaicInstruction` → `execute_mosaic` — constructed a `NullCheckpointSink`
unconditionally. Every per-panel save went to `/dev/null`, every load returned `None`, and
the module docs plus the `resume_round_trips_through_session_sink_on_disk` test described
`SessionWizardCheckpointSink` as "the production sink" while nothing in production ever
built one. The test was true about the sink and false about production.

A second, quieter half of the same defect: the executor's streaming-checkpoint task (30 s
cadence) builds a fresh `SessionCheckpoint` each tick and only carried `budget_states` and
`smart_exposure_states` forward from disk. `wizard_states` and `scheduler_states` were
dropped, so even a correctly-written mosaic slot would have been erased within 30 seconds.
The public writer (`executor/checkpoint.rs`) already carries all four forward and documents
why; the streaming task did not.

## Changes

* `sequencer/src/node/context.rs` — new `ExecutionContext.checkpoint_manager:
  Option<Arc<CheckpointManager>>` (the same Arc the executor holds, so the wizard sink and
  the streaming task share one manager + info cache). Defaults to `None` in
  `ExecutionContext::new`, which means "no session, persist nothing".
* `sequencer/src/executor/mod.rs` — a third Arc clone (`context_checkpoint_manager`)
  installed onto the run's `ExecutionContext` at `start()`; and the streaming-checkpoint
  task now carries `wizard_states` + `scheduler_states` forward from the on-disk
  checkpoint, mirroring the public writer.
* `sequencer/src/mosaic/mod.rs` — `run_mosaic_wizard` takes
  `checkpoint_manager: Option<&CheckpointManager>` and wraps it in
  `SessionWizardCheckpointSink`; `NullCheckpointSink` remains only as the no-session
  fallback.
* `sequencer/src/instructions.rs` — `execute_mosaic` passes the manager through.
* `sequencer/src/node/instructions/mosaic.rs` — the node reads
  `context.checkpoint_manager` and hands it down.
* Docs aligned: the mosaic module header no longer claims the wizard "is already wired…
  without further work" (it now describes the live wiring and records that on-rig
  validation is owed); the node header points at the two production tests;
  `packages/skotiq_core/lib/src/services/mosaic_service.dart` now says the
  `wizard_states["mosaic"]` slot is unused *under the static-expansion path* rather than
  "dormant", and notes the Rust `Mosaic` node persists for real.

## Tests (failing-test-first)

New, and both verified to FAIL against the pre-fix wiring — I temporarily restored the
null-sink line and re-ran to confirm, then reverted:

* `mosaic::resume_tests::production_entry_resumes_through_the_session_sink` — seeds
  `wizard_states["mosaic"].completed_steps = 4` on disk, opens a fresh
  `CheckpointManager` (an app restart), calls the PRODUCTION entry `run_mosaic_wizard`,
  and asserts the reported panels are `[5,6,7,8,9]` and the slot is cleared on disk.
  Pre-fix: `left: [1,…,9]`, `right: [5,…,9]`.
* `node::instructions::mosaic::tests::node_persists_panel_progress_through_the_session_sink`
  — the same round trip driven through `MosaicInstruction::execute` with the manager on
  `ExecutionContext`, asserting from the node's `ProgressDetail::Mosaic` payloads that it
  resumes at panel 5, and that the slot is cleared afterwards. Pre-fix: reported panels
  `[0,0,1,1,2,2,…]`.
* `mosaic::resume_tests::production_entry_without_a_manager_persists_nothing` — the other
  half: no manager ⇒ all nine panels run and the on-disk slot is left untouched at 4.

Verdicts (all run in this worktree):

* `cargo test -p skotiq_sequencer --lib mosaic` — 12 passed, 0 failed.
* `cargo test -p skotiq_sequencer --lib checkpoint` — 24 passed, 0 failed.
* `cargo test -p skotiq_sequencer --lib` (full crate) — **697 passed, 0 failed**.
* `cargo check --workspace --all-targets` — clean.
* `cargo clippy -p skotiq_sequencer --lib --all-targets` — clean (the one warning it
  raised, "items after a test module", is fixed).
* `cargo fmt --all -- --check` — clean.
* Dart: the only Dart edit is a doc comment in `mosaic_service.dart`. `dart analyze` in
  this worktree reports unresolved-package errors for that file (`package:uuid`,
  `package:skotiq_planetarium`) because the worktree has no `.dart_tool` — environmental,
  not from this change. Honest caveat: the Dart analyzer was not run against a bootstrapped
  worktree.

## Owed

**ON-RIG VALIDATION IS OWED (owner accepted.)** Everything above is proven down to real
disk I/O in unit tests, but no mosaic has been killed and resumed against hardware. Two
things specifically want a rig (or at least a live sim run):

1. A `Mosaic` node is not emitted by today's Dart UI — the canonical path is still
   static N×M `TargetHeader` expansion, whose resume comes from `node_statuses`. The
   wizard slot only carries a run that contains a Rust `Mosaic` node.
2. The executor's `start()` path was not exercised end-to-end here: the seam
   `self.checkpoint_manager` → `ExecutionContext.checkpoint_manager` is a one-line
   assignment covered only by compilation, not by a running-executor test. The streaming
   carry-forward of `wizard_states`/`scheduler_states` likewise wants a real 30 s+ run to
   observe.

Not committed — changes left in the worktree per the wave instructions.

---

## PORTED to HEAD (audit/end-to-end-campaign, 2026-08-14)

The batch above was implemented in the frozen worktree `wf_9953116a-7f8-5` against the
pre-campaign base `59dec49c7`, where the sequencer monoliths still existed. Re-landed on the
current tree with identical semantics. Every hunk moved; no logic was changed.

### Where each hunk went

| Spec file (stale base) | New home at HEAD |
| --- | --- |
| `sequencer/src/executor/mod.rs` (all three hunks) | `sequencer/src/executor/start.rs` — the C3 split moved `SequenceExecutor::start` and the 30 s streaming-checkpoint task out of `mod.rs`. Anchors: `completion_checkpoint_manager` (~L483), `context.is_paused = is_paused_clone` (~L627), `checkpoint_mgr.save(&checkpoint)` (~L2066). |
| `sequencer/src/instructions.rs` (`execute_mosaic`) | `sequencer/src/instructions/mosaic.rs` — the monolith is now a module dir; `execute_mosaic` was moved there verbatim by C3. |
| `sequencer/src/mosaic/mod.rs` | unchanged path; the pre-image at HEAD matched the spec's pre-image byte for byte. |
| `sequencer/src/node/context.rs` | unchanged path. |
| `sequencer/src/node/instructions/mosaic.rs` | unchanged path; the spec diff already targeted the split node file. |
| `packages/skotiq_core/lib/src/services/mosaic_service.dart` | unchanged path. |

### Deliberate deviations

* `run_mosaic_wizard(..., Some(&recorder), None)` in
  `production_entry_without_a_manager_persists_nothing` collapses onto one line under the
  current `cargo fmt`; the spec's four-line form was pre-`fmt`. Semantics identical.
* Nothing else differs. The `SessionWizardCheckpointSink` selection, the
  `wizard_states`/`scheduler_states` carry-forward, the `ExecutionContext` field and its
  `None` default, and all three tests are the spec's text.

### Verdicts (run on this tree, not the worktree)

* `cargo test -p skotiq_sequencer` — **825 passed, 0 failed, 1 ignored** across all
  targets (lib 803, decision_smoke 6, dual_rig_loop 4, interpolation_smoke 12; the 1 ignored
  is the pre-existing hanging plate-solve test from commit `6429c854b`, unrelated).
* `cargo test -p skotiq_sequencer --lib mosaic` — 12 passed, 0 failed (the 9 pre-existing
  `resume_tests` plus the 3 new ones).
* **Failing-first re-proved on this tree.** I temporarily neutered the sink selection
  (`.filter(|_| false)` on the `session_sink`) and re-ran: `production_entry_resumes_through_the_session_sink`
  and `node_persists_panel_progress_through_the_session_sink` both **FAILED**; the other 10
  passed. Then reverted and re-ran green. `production_entry_without_a_manager_persists_nothing`
  passes either way by design — it is the negative half, not a regression detector.
* `cargo check --workspace --all-targets` — clean. (No caller of `execute_mosaic` or
  `run_mosaic_wizard` exists outside `sequencer/src`, so the two signature changes are
  crate-local.)
* `cargo clippy -p skotiq_sequencer --all-targets` — no warnings attributable to this
  crate; the 3 `doc list item overindented` warnings emitted during that run belong to
  `skotiq_imaging` and pre-date this batch.
* `cargo fmt -p skotiq_sequencer -- --check` — clean.
* `dart analyze lib/src/services/mosaic_service.dart` (from `packages/skotiq_core`, a
  bootstrapped tree this time) — **No issues found**, which closes the honest caveat the
  frozen worktree had to leave open.

### Still owed, unchanged by the port

**ON-RIG VALIDATION IS OWED (owner accepted).** Both items in the "Owed" section above stand
verbatim: today's Dart UI still emits static N×M `TargetHeader` expansion rather than a Rust
`Mosaic` node, and the `self.checkpoint_manager` → `ExecutionContext.checkpoint_manager` seam
in `executor/start.rs` plus the 30 s streaming carry-forward are covered by compilation and
by the public writer's precedent, not by a running-executor test.
