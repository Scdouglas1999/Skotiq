# D-fix — batch `autopilot-ownership`

Items: REFUTED SEQ-12 (both halves), SEQ-13, WD-SEQ-N4, WD-SEQ-N5, WD-SEQ-N6.
Evidence read first: `reports/release-pass/waveD-result.json` (`refuted[2]`, `refuted[3]`,
`still_broken` SEQ-13, `new_findings` N4/N5/N6) and `reports/release-pass/gui/waveD-sequencing.md`.

---

## SEQ-12 (P0) — REFUTED twice, now closed at both seams

The Wave-B fix claimed "`_handleNoEligibleTarget` only stops a run the autopilot itself
dispatched". Wave D's refuter showed `currentTargetId != null` is a **stale-state** test, not
an ownership test, and that `stop()` races a dispatch that is still starting.

Adopted the refuter's throwaway `seq12_race_test.dart` into the repo as
`packages/skotiq_core/test/services/scheduler/scheduler_autopilot_ownership_test.dart`,
hardened: its `_ExecutorSink` now MODELS the executor (`activeRunId`) instead of only counting
calls, so ownership can be asked the way production asks it.

**Fail-at-HEAD proof.** Restored the four lib files from `git show HEAD:` into the tree, ran the
adopted test, then restored the fix:

```
stop() during an in-flight dispatch …   FAIL  calls=[dispatch-begin, stop, release, dispatch-end]
a run the autopilot no longer owns …    FAIL  stopCount=1  calls=[dispatch-begin, dispatch-end, stop]
stop() leaves a run the operator owns   FAIL  stopCount=1
a tick still stops its OWN run          pass  (regression guard — must keep passing)
```

### The race half
* `SchedulerEngine.stop()` now cancels the debounce timer, bumps `_runGeneration`, publishes the
  idle status, and then **waits for evaluation quiescence** (`_awaitEvaluationQuiescence`) before
  touching the executor. A dispatch already in flight finishes starting its run, so the stop lands
  after it instead of ahead of it.
* `_evaluateWithReason` publishes a `_evaluationIdle` completer for that wait.
* `_evaluateOnce` records `_dispatchedRunId = seq.id` **before** awaiting `dispatchSequence`, and
  after the await refuses to commit `currentTargetId` when `_runGeneration` moved or the engine is
  no longer running — so an idle autopilot can no longer print
  `SchedulerState.idle currentTargetId=1`.

### The ownership half
* New `SchedulerRunOwnership` interface (`contracts.dart`): `bool ownsRun(String sequenceId)`.
  Implemented by `_ExecutorSequenceSink`, which answers with three facts — the editor slot is still
  owned by `ActivePlanOwner.autopilot`, the loaded plan's id is the dispatched one, and the run is
  still `running/paused/recovering`.
* It is a SEPARATE interface rather than a new member on `SchedulerSequenceSink` because Dart
  `implements` inherits no bodies: adding a member would have broken 11 sinks, including
  `apps/desktop/test/headless_api/scheduler_handlers_test.dart`, which is outside this batch's
  scope. Sinks that do not implement it fall back to the engine's own belief (`_ownsDispatchedRun`),
  i.e. exactly today's behaviour, so no existing test changed.
* `_handleNoEligibleTarget` and `stop()` both gate their `stopSequence()` on
  `_ownsDispatchedRun(_dispatchedRunId)` instead of `currentTargetId != null`.

Residual risk, stated plainly: the adopted test proves the ENGINE consults the oracle and behaves;
`_ExecutorSequenceSink.ownsRun` itself is private and container-bound, so it is covered by
analysis + the three facts it reads, not by a test of its own.

## SEQ-13 (P1) — still-broken; the stale copy is the catalog row

The engine does not cache coordinates: it re-reads `targets` every evaluation (which is why a SITE
change was live). What was stale is the **row**: the builder tree and `targets` are two copies of
"where is this object", and only the RUN path reconciled them
(`SequenceExecutor._refreshCatalogCoordinates`). Editing without re-running left the scheduler on
the old position.

* New `packages/skotiq_core/lib/src/providers/sequence/target_catalog_coordinate_sync.dart`:
  pushes a re-pointed `TargetHeaderNode`'s coordinates onto its catalog row. Resolves the row by
  `catalogTargetId` when bound, else by the same trimmed/case-insensitive name identity
  `TargetsDao.findOrCreateByName` uses. Only ever UPDATES (never creates — editing the builder must
  not litter the library), ignores an unset (0, 0), ignores sub-arcsecond noise, moves only ra/dec.
* `CurrentSequenceNotifier.updateNode` calls it (fire-and-forget) when a target header's
  coordinates actually changed.
* Fixed a second instance in the run path: `_bindCatalogTargets` SKIPPED the coordinate refresh
  entirely when `catalogTargetId != null`, so a target picked from the library and then re-pointed
  stayed stale even across a re-run.

Tests: `packages/skotiq_core/test/providers/sequence/target_repoint_sync_test.dart` (catalog
write + the editor trigger, 7 cases).

## WD-SEQ-N4 (P3) — "Below horizon" at +9.8°

`_summarizeRejection` mapped every `altitude … below site minimum` reason to the chip
`below horizon`, while the row's own sentence said `altitude 9.8° below site minimum 30.0°`. The
chip now parses the altitude out of the same sentence: negative → `below horizon`, otherwise
`too low (9.8° < site minimum 30.0°)`.

## WD-SEQ-N5 (P3) — "Clear all" does not stick — BLOCKED (product decision)

Traced end to end. `Clear all` (`queue_table.dart:_confirmClearAll`) deletes integration goals and
constraints, and its dialog correctly says "targets themselves stay in your catalog". The row comes
back because the "Scheduler queue" table renders `decision.scoredCandidates`, i.e. every catalog
target the engine scored — and a target with NO goals is deliberately eligible
(`scoring.dart:57-60`, "no goals at all is fine - free-form imaging", plus the free-form fallback in
`buildSequenceForCandidate`). There is no queue-membership column on `targets`.

So making Clear all stick means changing what "queued" MEANS, in one of three ways, all outside
this batch's scope (scheduler scoring semantics with a large blast radius, the planner's queue
table, or the schema):
  1. hard-reject goal-less candidates — would also stop the autopilot from imaging any free-form
     target, and breaks the existing free-form contract and its tests;
  2. the planner lists only targets with goals/constraints as "queued";
  3. add explicit queue membership to the schema and have Clear all clear it.
Recommendation: (2) for 6.x — it is the smallest change that makes the button honest.

## WD-SEQ-N6 (P3) — nothing warned that autopilot was armed

New pre-flight rule `AutopilotArmedRule`
(`packages/skotiq_core/lib/src/providers/sequence/rules/autopilot_rules.dart`), registered in
`defaultRefAwareSequenceValidators`. Warns (equipment category) when a run is started while the
scheduler is `running` or `paused` AND the plan owner is not the autopilot itself — naming the
target it is on and the fact that it parks the mount at dawn. Fails at HEAD trivially (no such
rule; pre-flight listed only Disk space / Dark Library / Equipment Health).

Tests: `packages/skotiq_core/test/providers/sequence/autopilot_armed_rule_test.dart` (4 cases,
including "the autopilot's own dispatched run is not warned about itself").

---

## Verification

| suite | result |
|---|---|
| `skotiq_core test/services/scheduler` (incl. the 4 new ownership + 2 new label cases) | 121 passed |
| `skotiq_core test/providers/sequence` (686 cases; includes `sequence_validation_ref_aware_test.dart`, which runs the whole ref-aware registry with the new rule in it) | all passed |
| `skotiq_core test/providers/scheduler_engine_provider_lifecycle_test.dart`, `scheduler_project_filter_test.dart` | 12 passed |
| `skotiq_app test/screens/scheduler` | 18 passed |
| `skotiq_app test/screens/sequencer/preflight_*_test.dart` | 11 passed |
| `apps/desktop test/headless_api/scheduler_handlers_test.dart` (its sink is untouched — proof the interface change is non-breaking) | 11 passed |

Pre-existing failures, NOT from this batch: `skotiq_app test/screens/planner/captures_*_test.dart`
golden pixel diffs. Re-ran them with every file of this batch reverted to `HEAD:` — identical
diffs (11.25% landscape / 6.97% portrait), so they fail at HEAD too. (Known class: goldens captured
on Windows.)

## Environment note

Concurrent agents were mid-edit in the same tree during this batch: `equipment_health_provider.dart`
+ `device_last_contact_provider.dart` and, later, `skotiq_planetarium`'s
`interactive_sky_view*.dart` and `time_control_panel.dart` were transiently uncompilable. Those
failures are not from this batch; test runs were repeated until the package compiled.
