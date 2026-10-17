export const meta = {
  name: 'release-ffix',
  description: 'F-fix: the terminal batch — recipe closers, the two P2s, the tractable tail',
  phases: [
    { title: 'Fix', detail: '4 feature-scoped batches, shared tree, strict ownership', model: 'opus' },
  ],
}

const FIX_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['batch', 'fixed', 'false_positives', 'blocked', 'tests', 'files_touched'],
  properties: {
    batch: { type: 'string' },
    fixed: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['id', 'root_cause', 'proof'], properties: { id: { type: 'string' }, root_cause: { type: 'string' }, proof: { type: 'string' } } } },
    false_positives: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['id', 'why'], properties: { id: { type: 'string' }, why: { type: 'string' } } } },
    blocked: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['id', 'why'], properties: { id: { type: 'string' }, why: { type: 'string' } } } },
    tests: { type: 'string' },
    files_touched: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const CHARTER = `You are a fix engineer in the TERMINAL batch of the Skotiq release pass. Tree GREEN at HEAD. Evidence: reports/release-pass/waveF-result.json (each item carries the live evidence AND usually the exact recipe) + reports/release-pass/gui/waveF-*.md + the "Wave F verdict" adjudication in RELEASE-PASS-2026-08-11.md (its PRODUCT CALLS list is OFF LIMITS — do not implement policy). One graphify query first. Failing test FIRST for every behavior item; the refutation follow-ups must encode the refuter's counter-input. NO GUI harness, NO bundle rebuilds, NO git writes, NO melos, NO repo-wide formatters, NO generated files EXCEPT: build_runner scoped to a package IS allowed where an item names a generated index (CON-62). Log to reports/release-pass/impl/ffix-<batch>.md. Final message: ONLY the structured result.`

const BATCHES = [
  { key: 'exposure-integrity', items: 'WF-STOP-N1 (P2: the FIRST light frame exposes 5.0s instead of the configured 15.0s — find where the first exposure inherits a default/preview duration instead of the node config; the waveF evidence names the run), WF-STOP-N2 (integration disagrees across surfaces — reconcile onto the recorded sum), WF-STOP-N4 (P2: a run stalled in a retrying meridian flip says Running 50% with a past ETA — surface the retrying state and recompute or suppress the ETA), SEQ-18 fifth look (the completed-node card: waveF proves the card cannot distinguish captured-everything from captured-nothing; the second witness never arrives on screen — instrument the actual provider the card watches in a widget test with a REAL completed-node event sequence from the waveF log, find where the count is dropped, fix it).', scope: 'packages/skotiq_core/lib/src/providers/sequence/**, packages/skotiq_app/lib/screens/sequencer/**, native/skotiq_native/sequencer/src/** (exposure duration only if the 5s originates natively)' },
  { key: 'stop-toasts-scheduler', items: 'WF-N4 + WF-STOP-N3 (one stop → three identical toasts/rows: three reclassifying producers each emit; dedupe at the router with a normalized key — and the WD-EQ-3 recipe: normalize trailing punctuation before keying so the one-character body difference cannot defeat the collapse; ALSO fix the producer that appends the stray full stop), WF-STOP-N5 (raw ISO timestamp in operator copy), WF-N1 (scheduler diagnostics unreadable: route SchedulerEngine dart logs into the on-disk log and rate-limit the SequenceExecutor DBG spam that eats the 1000-entry ring), WF-N5 (modal report + note prompt after every autopilot run — for unattended runs queue quietly instead of stacking modals).', scope: 'packages/skotiq_core/lib/src/services/notification/**, packages/skotiq_core/lib/src/services/scheduler/** (logging only), packages/skotiq_core/lib/src/providers/sequence/** (report modal gating), packages/skotiq_app/lib/screens/sequencer/** (report modal gating)' },
  { key: 'chrome-polish', items: 'WD-EQ-2a AT LAST (the disconnect-toast template: equipment.device_name context key via friendlyNameFromDeviceId — the reverted fix is described in the equipment-chrome-3 impl log), CON-56 (the two ALL-CAPS literals), CON-62 full (unify row-title case AND regenerate settings_search_index via scoped build_runner; also unify the Guided-Flows-vs-Tutorial-Tours button treatment split waveF found), WE-EQ-N5 residual (the second status-bar pill still slices mid-word — ellipsis at the cut), WF-EQ-N1 (SequencerTabTitle truncates its own mandate), WF-EQ-N2 (NotificationToastOverlay honors the bottom inset), WF-EQ-N3 (direction word), WE-SP-5 residual (the reserved band does not affect this layout — fix the actual overlap: offset the prompt or pad the scroll extent, proven by the waveF control experiment), NEW-C2/C3 remaining halves (Imaging Overlays toggle, palette tab roles, Frame Type/Binning paired labels).', scope: 'packages/skotiq_core/lib/src/services/notification/** (template), packages/skotiq_core/lib/src/utils/device_id.dart, packages/skotiq_planetarium/lib/src/widgets/time_control_panel.dart, packages/skotiq_app/lib/screens/{settings,sequencer,imaging,dashboard}/**, packages/skotiq_app/lib/widgets/**' },
  { key: 'sky-science-polish', items: 'D-2 final (the projection cycler is a DIFFERENT widget than the fixed tooltip — find it, apply the same trigger-borne message; also give it and the search toggle accessible names per WF-SS-N3), WF-SS-N1 (Copy-code contrast), WF-SS-N2 (pairing route traps the nav rail while the rail claims to move), WF-SS-N4 (tutorial card focusable-without-enabled), WF-SN-N1 (Auto Select reports crop-local coordinates — report frame coordinates), WF-SN-N2 (the coalescer should prefer the hinted caller or merge hints), WF-SN-N3 (SNR 0.0 on a stopped loop — em dash not a fabricated zero), WF-SCI-N1 (Session tab pins the previous night after a run), WF-SCI-N2 (Night Doctor verdict cached forever — recompute on diagnostics change), WF-SCI-N3 + WF-SN-N4 (disabled buttons announce enabled to AT-SPI: SkotiqButton must drop the button action / set the proper flags when disabled so the bridge reports it — this also unblocks every future audit), WF-SCI-N4 (Open last run opens an empty builder).', scope: 'packages/skotiq_planetarium/**, packages/skotiq_app/lib/screens/{planetarium,settings,guiding,analytics,dashboard,science}/**, packages/skotiq_ui/lib/src/components/skotiq_button.dart, packages/skotiq_core/lib/src/services/: plate_solve/guiding coalescer + science session selection (claim files in your log first)' },
]

phase('Fix')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nITEMS: ${b.items}\nSCOPE: ${b.scope}`,
    { label: `ffix:${b.key}`, phase: 'Fix', schema: FIX_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const ok = results.filter(Boolean)
log(`${ok.length}/${BATCHES.length} batches returned`)
return {
  batches_returned: ok.length,
  fixed: ok.flatMap(r => r.fixed).length,
  false_positives: ok.flatMap(r => r.false_positives.map(f => ({ batch: r.batch, ...f }))),
  blocked: ok.flatMap(r => r.blocked.map(f => ({ batch: r.batch, ...f }))),
  results: ok,
}
