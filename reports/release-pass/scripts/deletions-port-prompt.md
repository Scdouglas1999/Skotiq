# Deletions-port agent prompt (prepared 2026-08-14; launch after batch 4 returns)

You are the PORT agent for the deletions batch of the Skotiq owner-decisions wave,
working DIRECTLY ON THE MAIN TREE at /home/scdouglas/Documents/Skotiq2 (branch
audit/end-to-end-campaign; the tree carries many unrelated uncommitted changes from six
already-merged batches — leave them alone; do NOT commit, stash, or checkout).
MANDATORY: one graphify query before grepping/reading source.

The batch implemented owner decisions 5+6 (delete the Dart fallback device stack; delete
the unreachable device backend, the SKOTIQ_COMPANION_UI dashboard, the unreachable
device-service methods and the sequential profile-connect path) against a STALE base
(59dec49c7). The campaign since restructured many of its target files (C3 splits, the
FRB regeneration). Re-land its work semantically:

- SPEC: the frozen worktree .claude/worktrees/wf_9953116a-7f8-4 (READ ONLY) — its
  `git -C <wt> diff` is the intent; its impl log (reports/release-pass/impl/, if
  written) is the narrative; its final `status --porcelain` is the file list.
- The D (deleted) files: pre-verified — every deletion path exists at HEAD verbatim
  (snapshot: session scratchpad deletions-list.txt, but USE THE BATCH'S FINAL LIST).
  `git rm` them, plus their part-of/import references.
- The M files: re-land each edit's SEMANTICS at HEAD, not its hunks. Known drift
  hot-spots: bridge_stub/sequencer_operations.dart, imaging_service.dart,
  centering_service.dart (all heavily rewritten since the stale base), and
  device_capabilities.rs which NO LONGER EXISTS — its content moved to
  bridge/src/device_capabilities/; find where the batch's 743-line deletion now lives.
- CAUTION: phd2_models.dart / .freezed.dart / .g.dart were ALREADY modified on the
  main tree by the merged ui-small batch. Reconcile the deletions batch's edits INTO
  the current file state; never overwrite. If freezed regeneration is needed, run
  build_runner in skotiq_core.
- The bridge_stub fail-closed policy comment must state the truth: Rust is the only
  device path.
- After landing: `dart analyze` clean in every touched package; the touched packages'
  test suites pass (skotiq_bridge, skotiq_core, skotiq_app, apps/mobile);
  `cargo build -p skotiq_bridge` clean if any Rust was touched. List every deleted
  file + line count in a PORTED section of the impl log. Report honestly.

## Hunk triage (pre-computed from the 77-change snapshot)

- 23 modified files are PURE DELETIONS (no added lines): re-land by deleting the same
  symbols at HEAD — mechanical.
- 10 files add ≤5 lines: near-mechanical.
- 12 substantive rewrites, in descending effort: bridge_stub/guiding_operations.dart
  (+78/-427), device_manager/ops/{dome,switch,cover,rotator}.rs, bridge_stub/
  connection_operations.dart, phd2_models.dart+.freezed (THE ui-small OVERLAP — merge,
  don't overwrite; regen freezed after), bridge_stub.dart, connection.rs, and two test
  rewrites (predictive_af_service_test, centering_service_test.mocks — regenerate mocks
  rather than hand-porting if the repo uses build_runner mocks).
Start with the pure deletions, verify compile, then the twelve.
