# Decisions-wave merge runbook (2026-08-14)

The exact integration order for everything in flight, so the adjudication is mechanical.
Patches referenced live in the session scratchpad
(/tmp/claude-1000/-home-scdouglas-Documents-Skotiq2/224b7868-cbfc-40e1-8fb0-99c71d23f174/scratchpad/).

## Already ON the main tree (uncommitted, verified)

- ui-small (IMG-9): applied from worktree 7 (HEAD-based) + its two test files copied;
  suites 5/5 + 3/3 green; guiding dir 31/31 non-golden green.
- rust-seq + mosaic PORTS: landing directly on the tree via wf_1850e651-026 (serialized).
  Verify after: `cargo test -p skotiq_sequencer` + clippy + the mosaic/checkpoint
  filters; read the PORTED sections of impl logs.
- The parallel main-loop fixes: gitignore P0 (+3 staged profiles files), framing +
  imaging_handlers flake fixes, D19/completion dedupe, M-2/M-3/M-4, changelog, checklist.

## To merge when their workflows return

| batch | worktree | base | route |
|---|---|---|---|
| scheduler | 1 | b7e8f77f5 HEAD | `git -C .claude/worktrees/wf_9953116a-7f8-1 diff` → apply --check → apply; copy `??` files; run its named tests |
| pushes | 2 | b7e8f77f5 HEAD | same as scheduler |
| deletions | 4 | 59dec49c7 STALE | PORT-AGENT REQUIRED (pre-computed 2026-08-14): the batch is deep surgery — 26+ D files (all exist at HEAD verbatim, zero renames) PLUS ~45 M files, many with heavy HEAD drift (sequencer_operations +210/-622, imaging_service +144/-771, centering_service -941, and device_capabilities.rs which no longer exists at HEAD — the K-regen moved it into device_capabilities/). Serialize ONE port agent on the main tree with the batch diff as spec, exactly like rust-seq/mosaic. CAUTION: it edits phd2_models.dart/.freezed which the ui-small MERGE already changed on the tree — the port must reconcile, not overwrite. Deletion list snapshot: scratchpad/deletions-list.txt |
| fits-master | 6 | b7e8f77f5 HEAD | same as scheduler; then `cargo test -p` the imaging crate |
| hub sweep | none (main tree, reports only) | — | verify status.json parses + only `hub:` keys added; read findings file |

## After all merges

1. Check no batch stepped on another: `git status --short` review; `dart analyze` all packages; `cargo build --workspace`.
2. Wire the AF-failure push if the pushes batch missed it (classifier: DecisionLogged
   SystemEvent with the AUTOFOCUS_TRIGGER_CONTINUATION summary → autofocus category, INFO).
3. Full gates: melos run test; cargo test --workspace; analyzer_rollup; placeholder_audit;
   behavioral_audit; formats. Golden-tagged capture failures are the documented exception.
4. Revert the four regenerating PNGs; commit everything with the decisions message;
   `git add -f` for reports/ paths (CHECK the new impl logs + checklist + this runbook in).
5. build_native.sh + flutter build linux --release; verify content markers
   ('Autopilot paused' expected from the scheduler batch; 'System: stop' already present).
6. Launch reports/release-pass/scripts/release-decisions-verify.js. Kill orphan Xvfb first.
7. On a dry verify: extend the changelog's Unreleased with the decisions, close task #53
   and #36, update the campaign memory to fully-closed, allow-stop.

## Release 6.2.0 endgame (staged 2026-08-14, owner-directed)

Draft release EXISTS on GitHub (v6.2.0, body = docs/release/v6.2.0.md). Versions
bumped to 6.2.0+26 in all three sources; changelog cut to [6.2.0]. Schema 57 ==
v6.1.0's, so the notes' rollback claim is true. After the verify wave returns dry:

1. Finalize docs/release/v6.2.0.md numbers (deletion line total from the port's
   PORTED section; test totals from the final gate run) + changelog deletions line.
2. Commit (decisions message, extended with the release lines). Push the branch.
3. `git push origin v6.2.0` (tag the final commit). The tag push makes release.yml
   build Android+Linux+Windows, attach everything to the draft, and PUBLISH it
   (softprops updates the draft for the tag; make_latest). No manual attach needed.
4. Watch the run (`gh run watch`); on green confirm the release is public and
   `--clobber`-free; on red, fix and re-tag (delete tag first).
