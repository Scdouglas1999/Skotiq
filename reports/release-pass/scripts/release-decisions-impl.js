export const meta = {
  name: 'release-decisions-impl',
  description: 'Implement the ten owner decisions that close the release campaign',
  phases: [
    { title: 'Implement', detail: '7 batches, worktree-isolated, no shared files', model: 'opus' },
  ],
}

const RESULT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['batch', 'done', 'blocked', 'tests', 'notes'],
  properties: {
    batch: { type: 'string' },
    done: { type: 'array', items: { type: 'string' } },
    blocked: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['item', 'why'], properties: { item: { type: 'string' }, why: { type: 'string' } } } },
    tests: { type: 'string' },
    notes: { type: 'string' },
  },
}

const COMMON = `You are an implementation batch of the Skotiq release-campaign closing wave, executing OWNER DECISIONS recorded in reports/release-pass/RELEASE-PASS-2026-08-11.md ("Owner decisions (made 2026-08-14...)"). Repo: Flutter/Dart melos monorepo + Rust via flutter_rust_bridge, branch audit/end-to-end-campaign. MANDATORY: run one graphify query before grepping/reading source (PreToolUse hook enforces it; include this in any sub-exploration too). Doctrine: failing-test-first where a behavior changes; write code that reads like the surrounding code; NO Claude commit trailers; do NOT commit — leave changes in the worktree; run the targeted tests for what you touched and report their verdicts honestly. Write an impl log to reports/release-pass/impl/decisions-<your-batch>.md. Return ONLY the structured result.`

phase('Implement')
const batches = [
  { key: 'scheduler', prompt: `${COMMON}
BATCH scheduler — decisions 1 and 3:
(1) An operator Stop of an autopilot-dispatched run must PAUSE the autopilot and surface a visible "Autopilot paused — resume?" affordance instead of silently re-dispatching ~44s later. The re-dispatch lives in scheduler_engine/evaluation.dart + scheduler_engine.dart (packages/skotiq_core/lib/src/services/scheduler/); the sink already passes origin 'scheduler' on ITS stops — the operator's stop is detectable because the engine's dispatched run ends WITHOUT the engine having stopped it (see _reconcileDispatchedRun / ownsRun). Add a paused state to the engine (persisted enough to survive rebuilds), stop evaluating while paused, and a resume affordance: a banner/chip on the scheduler panel (packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/scheduler_panel.dart or the scheduler surface the GUI actually shows — find it via graphify; follow the skotiq_ui design contract). Failing test first: engine-level test that an externally-stopped dispatched run flips the engine to paused and evaluation ticks dispatch nothing until resume.
(3) "Remove from scheduler"/"Clear all" must make the target INELIGIBLE for autopilot selection, not merely goal-less. Find the eligibility filter the evaluation uses and the removal path; removal marks the target ineligible (persisted); test: a removed goal-less target is never picked.` },
  { key: 'pushes', prompt: `${COMMON}
BATCH pushes — decision 2: restore the sequenceStopped push for NON-operator stops only, INFO priority, carrying the real cause. The category exists (packages/skotiq_core/lib/src/models/notification/notification_categories.dart, sequenceStopped, info/non-critical) but the push was deleted rather than de-escalated. The stop's true author is now on the wire: DecisionLogged category 'manual_intervention' summary starting 'Operator: stop' = operator (NO push); DecisionLogged 'system_event' summary 'Autopilot: stop' = autopilot (push "Sequence stopped by autopilot"); 'System: stop' with details.origin (e.g. 'rollback', 'disk-watchdog') = system (push with the origin); a cancel-notice family with NO operator/autopilot/system decision = safety abort (push cause-neutral "Sequence stopped"). Wire this in event_classifier.dart / notification_router.dart / system_push_transport.dart (packages/skotiq_core/lib/src/models/notification/ + services). Use the shared dedupe signature so one stop episode = ONE push. Failing tests first for each author class (mirror the D-suite's producer sets in packages/skotiq_app/test/screens/sequencer/widgets/run_dashboard/recent_events_feed_conformance_test.dart for realistic shapes).` },
  { key: 'rust-seq', prompt: `${COMMON}
BATCH rust-seq — decisions 4 and 10 (Rust, native/skotiq_native/sequencer):
(4) UnparkNode (instructions.rs) must execute the unpark only when the mount reports parked; when not parked it is a logged no-op success. Test in the crate's test style.
(10) The interval-autofocus TRIGGER failure policy for unattended runs: on AF non-convergence the executor restores the pre-AF focuser position, CONTINUES the run, and logs a decision row (SystemEvent, summary like "Autofocus failed — continuing with last-good focus", details incl. positions). Find the trigger's failure path (triggers.rs / executor trigger handling — graphify first); today's behavior may abort or apply the failed position. Keep any per-node configured failure_action semantics for EXPLICIT AF nodes — this decision governs the TRIGGER default. cargo test -p skotiq_sequencer must pass; cargo fmt.` },
  { key: 'deletions', prompt: `${COMMON}
BATCH deletions — decisions 5 and 6, mechanical:
(5) Delete the Dart fallback device stack: packages/skotiq_bridge/lib/src/{phd2_client,alpaca_client,ascom_client}.dart + the retry/circuit_breaker helpers that exist only for them (~2,656 lines) and their imports in bridge_stub.dart (the fail-closed policy comment there must be updated to state the truth: Rust is the only device path).
(6) Delete: the six unimplemented Native* traits + six unpopulatable bridge registries (the unreachable device backend — locate via graphify/Wave A map reports/release-pass/map/); the SKOTIQ_COMPANION_UI mobile dashboard (4,845 unreachable lines, nothing enables it); the seven production-unreachable public device-service methods and the unused sequential profile-connect path (packages/skotiq_core/lib/src/services/device_service/profile_connections.dart:11-106 region per the map).
Delete their tests with them. After deleting, dart analyze must be clean in every touched package and the touched packages' test suites must pass. List every deleted file + line count in the impl log.` },
  { key: 'mosaic', prompt: `${COMMON}
BATCH mosaic — decision 7: make mosaic panel resume REAL: production currently wires NullCheckpointSink where docs/tests claim SessionWizardCheckpointSink. Find the production wiring site (graphify: mosaic checkpoint sink), swap in SessionWizardCheckpointSink with whatever construction it needs, align the docs, and make sure the existing wizard-sink tests exercise the PRODUCTION wiring (a test that reads the production provider and asserts the sink type, plus a resume round-trip test if the harness allows). Record in the impl log that ON-RIG VALIDATION IS OWED (owner accepted). Targeted tests + analyzer clean.` },
  { key: 'fits-master', prompt: `${COMMON}
BATCH fits-master — decision 8 (Rust, native/skotiq_native/imaging): the live-stacked master must save as FITS. The FITS writer currently demands EXPTIME/DATE-OBS the live stacker lacks: make them optional or synthesized (EXPTIME = total integration seconds of the stack; DATE-OBS = first-frame timestamp) — graphify for the writer (fits.rs) and the stacker's save call. Keep the PNG if it is what the UI previews; the FITS master is the data product. Failing test first: a stack save without per-frame headers produces a valid FITS with synthesized EXPTIME/DATE-OBS. cargo test -p the imaging crate green; cargo fmt.` },
  { key: 'ui-small', prompt: `${COMMON}
BATCH ui-small — decision 9 + two conformance handoffs:
(9) IMG-9: the imaging screen's Frame Count label during LOOPING counts loop frames only and resets when a new loop starts (graphify: imaging screen frame count loop). Widget test.
(CON-56) time_control_panel.dart:396/:432 — the ALL-CAPS 'NOW'/'TONIGHT' literals become sentence case per the design system.
(CON-62) the settings row-title case fix that needs the settings_search_index regen — fix the title, regenerate the index the way the repo does it (find the generator via graphify), and keep the search test green.
Targeted tests + analyzer clean.` },
]

const results = await parallel(batches.map(b => () =>
  agent(b.prompt, { label: `impl:${b.key}`, phase: 'Implement', schema: RESULT_SCHEMA, model: 'opus', effort: 'high', isolation: 'worktree' })
))
const ok = results.filter(Boolean)
log(`${ok.length}/7 batches returned`)
return {
  batches: ok.length,
  done: ok.flatMap(r => r.done).length,
  blocked: ok.flatMap(r => r.blocked.map(x => ({ batch: r.batch, ...x }))),
  results: ok,
}