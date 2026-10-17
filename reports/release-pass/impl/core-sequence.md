# core-sequence — implementation log

Scope: `packages/skotiq_core/lib/src/providers/sequence/**` (+ package test dirs).
Baseline: `b07d91c9d`.

## Resume context

A previous attempt was killed mid-flight. The tree already carried its source
work for items 1–7 plus one untracked test file
(`test/providers/sequence/sequence_run_frame_verdict_test.dart`). No impl log
existed. I verified every inherited change against the work order with
`git diff b07d91c9d`, proved the BUG items fail against the pre-fix code by
temporarily restoring baseline behaviour, and added the tests that were still
missing. No stray `*.tmp.*` files were found in scope.

## Item 1 — frames-rejected structurally 0 (BUG)

`ExposureCompleted` was the only caller of `_recordRunFrame`, with
`accepted: true` hardcoded, so `framesRejected` and `FilterStats.rejected` were
structurally 0 for every night.

Fix (inherited, verified): `FrameAccepted` / `FrameRejected` — which are emitted
BEFORE `ExposureCompleted` and are the only events that carry the verdict — park
`(accepted, capture)` in a new `_gradedFrames` map keyed on the frame index;
`ExposureCompleted` consumes it. `NodeStarted` clears the map so a verdict
cannot strand across nodes (frame indices restart per node).

Proof: temporarily restored `accepted: true`. Three tests failed
(`framesRejected` expected 1, actual 0; the per-filter breakdown likewise; and
the leak-guard case). Restored the fix; all pass.

## Item 2 — nine unawaited backend pushes + sky poll + updateStats (BUG)

Two distinct defects here.

**2a. The pushes.** Every backend call inside the three `_ref.listen` callbacks
and the sky-brightness tick was invoked from a synchronous callback with the
future discarded: a rejection was an unhandled zone error and the operator was
told nothing. The observer-profile push even sat inside a `try/catch` that could
never fire, because the call it guarded was never awaited.

Fix (inherited, verified): a `_pushMidRun(what, push)` helper awaits the push,
logs the failure, and records an operator-facing run warning naming what could
not be sent — so it survives into `sequence_runs.stats_json` and the
post-session report. All nine sites plus the sky poll route through it. The
logger is read before the await (a previous incarnation of the sky-brightness
guard threw out of its own error handler by reading a provider from inside the
catch).

**2b. A blocker I found while testing it — the watcher never ran at all.**
`_settingsSubscriptions` is declared `List<ProviderSubscription>`, i.e.
`<dynamic>`. Downward inference therefore made `_ref.listen` generic `dynamic`,
so the callback parameters were `dynamic` — and `AsyncValue.valueOrNull` is an
**extension** getter, which does not exist on a dynamic receiver. Every mid-run
app-settings change threw `NoSuchMethodError` inside the Riverpod listener, so
not one of the location / safety-fail-mode / grading / reject-folder /
observer-name / adaptive-exposure pushes ever reached the executor. Pre-existing
at baseline (the `valueOrNull` lines are unchanged context in the diff); fixing
item 2 without this would have left the whole watcher inert.

Fix: explicit type arguments on all three `listen` calls
(`_ref.listen<AsyncValue<AppSettingsState>>`, `<SequencerDefaults>`,
`<EquipmentProfileModel?>`), with a comment recording why.

Proof: `sequence_executor_launch_parity_test.dart` group E. Before the typing
fix the two failure tests died with the raw `NoSuchMethodError` from
`runtime_config_operations.dart:749`; after it they observe the run warning.

## Item 3 — double full-image fetch + fabricated preview stamp (BUG)

`_fetchAndDisplaySequenceImage` was called twice per frame — once from the
imaging `ExposureComplete` and once from the sequencer `ExposureCompleted`,
both of which native emits for the same exposure. The imaging payload carries
only `{success}`, so its duration fell through to a literal `?? 2.0` and the
preview was stamped `gain: 0, offset: 0, bin 1x1`. Whichever landed last won, so
a 300 s sub could be labelled "2 s, gain 0, bin 1".

Fix (inherited, verified): the imaging branch is gone; the sequencer branch
fetches once and stamps `_previewSettingsForFrame(graded?.capture, duration)`,
which prefers the camera's reported capture truth and falls back to the
producing node's configuration. `_fetchAndDisplaySequenceImage` now takes the
`ExposureSettings` rather than building them from literals.

Proof: restoring the baseline branch made "a frame fetches the full image
exactly once" fail with expected 1 / actual 2, "the imaging duplicate fetches
nothing" fail, and the stamp test fail with expected gain 120 / actual 0.

## Item 4 — observer-profile derivation written twice (DEDUP)

The 55-line derivation (camera-name split, focal-length and aperture legacy
fallbacks, the seven-argument push) existed verbatim in
`_seedRuntimeConfigFromSettings` and `_pushObserverProfile`, including a
duplicated 8-line comment recording an aperture bug that had already been fixed
once — in two places.

Fix (inherited, verified): `_pushObserverProfile` is now `Future<void>`, is the
one derivation, and the seed calls it inside its `try`/`firstError` block. This
also makes the previously decorative catch at the old line 1030 real.

Parity test: group D asserts the legacy `aperture` / `focalLength` fallback
reaches the backend identically from the run-start seed and from the mid-run
watcher.

## Item 5 — three copies of the native-event subscribe block (DEDUP)

`attachHostListenersForNativeRun()` is now the single subscribe site;
`_startNativeExecution` and `_resumeFromCheckpointInner` call it. This also
fixes the missing cancel in `_startNativeExecution`, which overwrote the field
and would have double-handled every event after a run that ended in
`stopFailed` / `cleanupFailed` (those deliberately retain their subscription).

Parity test: group B — a started run, a resumed run, and a run that gets
re-attached over all count exactly one frame per `ExposureCompleted`.

## Item 6 — run acquisition + launch-config push duplicated (DEDUP)

Extracted `_openRunRecords` (run row + `currentRunIdProvider` + fresh
`SequenceRunStats` + the per-run flag resets + `sequencerSetActiveSequenceRunId`)
and `_startPerRunTimers` (start time, pause flag, ETA reset, the 1 s ticker,
checkpoint timer, disk watchdog) from `start()` / `resumeFromCheckpoint()`, and
`_pushLaunchConfig(backend, settings, {required bool isResume})` from
`_startNativeExecution` / `_resumeFromCheckpointInner`. The two real behavioural
differences are expressed as `isResume` branches with the original comments
carried over.

Parity tests: group A (both paths open the same records and start their timers)
and group C (an empty save path is pushed as null on start but left alone on
resume; resume pushes no device ids while the camera is offline, start does).

## Item 7 — recordDither, dead code, mojibake

* **`SequenceRunStats.recordDither()` (BUG)** — zero call sites, so the Session
  Report's "Dithers" figure was a hard zero. Now incremented from the guiding
  `DitherCompleted` event, which is the only event emitted when the mount is
  actually dithered and covers both a `Dither` node and the far more common
  per-burst `dither_every` pulse (counting the node's own completion as well
  would double-count). Proof: removing the branch made both dither tests fail
  with 0.
* **`SequenceExecutor.validateSequence` (DELETE)** — re-proved zero callers
  fresh across `packages/ apps/ native/ tools/`:
  `grep -rn '\.validateSequence(' --include='*.dart'` returns nothing now that
  the self-delegation is gone. Every real consumer calls the top-level
  `validateSequence` from `sequence_validation.dart` directly. No test existed
  for it. Its own doc comment ("external callers still depend on the sync
  semantics") was false.
* **Four orphan doc comments (DELETE)** — removed from
  `checkpoint_watchdog_operations.dart`, `event_operations.dart`,
  `runtime_config_operations.dart` and `serialization_operations.dart`. Each
  documented a method that lives in a different file.
* **Mojibake (FIX)** — all 5 `mag/arcsecÂ²` sequences corrected to
  `mag/arcsec²` (4 in `runtime_config_operations.dart`, one of them an
  operator-visible log line; 1 in `session_diagnostics_operations.dart`).
  `grep -rn 'arcsec'` over the scope now returns only `accuracy_arcsec`, a JSON
  wire key.

## Not done

The file splits (work-order §1) and §2.5 (the two-decoder problem) are out of
scope for this wave — no file splits or renames were permitted.

## Tests

* `test/providers/sequence/sequence_run_frame_verdict_test.dart` — 10 tests
  (items 1, 3, 7-dither). All 10 pass; 8 of the 10 fail against the pre-fix
  code (verified by temporarily restoring it, then restoring the fix).
* `test/providers/sequence/sequence_executor_launch_parity_test.dart` — new,
  14 tests (items 2, 4, 5, 6). All pass. Group E fails against the pre-fix
  code: with the push left fire-and-forget the rejection escapes into the zone
  as an unhandled `Bad state: backend went away` and no warning is recorded.
* Regression guards named by the work order, run unchanged:
  `sequence_executor_run_lifecycle_test.dart`,
  `sequence_executor_lifecycle_test.dart`,
  `resume_recovers_sequence_tree_test.dart`,
  `resume_session_identity_test.dart` — 68 passed.
* Whole-directory sweep: `flutter test test/providers/sequence/` — **543
  passed, 0 failed**.
* `flutter analyze lib/src/providers/sequence/ test/providers/sequence/` —
  no issues. All touched files `dart format`ted.
