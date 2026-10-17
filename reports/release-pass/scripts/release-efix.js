export const meta = {
  name: 'release-efix',
  description: 'E-fix: the Wave E harvest — the unattended-night P1, two-implementations strikes, chartered residue',
  phases: [
    { title: 'Fix', detail: '6 feature-scoped batches, shared tree, strict ownership', model: 'opus' },
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

const CHARTER = `You are a fix engineer in the E-fix wave of the Skotiq release pass (Flutter/Dart melos monorepo + Rust via FRB). Tree GREEN at HEAD. Your evidence: reports/release-pass/waveE-result.json (live evidence per item, incl. refuted-claim details) and reports/release-pass/gui/waveE-*.md. The "Wave E verdict" section of reports/release-pass/RELEASE-PASS-2026-08-11.md carries overrides. Several items are SECOND or THIRD strikes on the two-implementations trap — your job is to find and fix the implementation that RUNS, and add a log line or test that distinguishes the implementations so this cannot silently happen again.

One graphify query first (hook). Failing test FIRST for every behavior item; refutation items must encode the refuter's exact counter-input. GUI geometry via widget-test pins. NO GUI harness, NO bundle rebuilds, NO git writes, NO melos, NO repo-wide formatters, NO generated files, NO FRB regen (stop + record blocked). Log to reports/release-pass/impl/efix-<batch>.md. Final message: ONLY the structured result.`

const BATCHES = [
  { key: 'autopilot-night', items: 'WE-SEQ-N1 (P1: after a dispatched run FAILS the autopilot never dispatches again — the ownership token or in-flight latch is not cleared on failure; failing test = fail a dispatched run, next eligible tick must dispatch), WE-SEQ-N5 (generated plans need an Unpark step — or dispatch must unpark first, mirroring the manual pre-start dialog), WE-SEQ-N6 (an autopilot-dispatched run stopped by the operator records Failed + CRITICAL — route through the same stopped-outcome path as manual runs), WE-SEQ-N3 (armed-autopilot warning suppressed once a plan was dispatched this session), plus the two refuted autopilot claims in waveE-result.json (SEQ-12 unowned-run seam, SEQ-13 re-point path).', scope: 'packages/skotiq_core/lib/src/services/scheduler/**, packages/skotiq_core/lib/src/providers/sequence/**' },
  { key: 'stop-pipeline', items: 'WD-SEQ-N1 completion (Session Report is fixed; the RED TOAST "Sequence failed / Sequence aborted", the "Critical - Sequencer" toast, the Dashboard banner "Sequencer error", RECENT EVENTS "Sequencer error", and the target rollup "Error: Sequence cancelled" all still fire on an operator stop at HEAD — find each producer; some listen to the raw Rust event stream where a stop may arrive as Error: fix the CLASSIFICATION at each producer, with the refuted-claim details from waveE-result.json), WE-SEQ-N4 (Dashboard Last-night card prints raw "Paused-stopped"), SEQ-18 (0/N after success — THIRD strike: instrument the provider chain the node card reads and find what resets on the success path; the stop path works), WE-SEQ-N2 (altitude curve plotted for a target with no coordinates), WE-SEQ-N7 (900px palette/properties toggles).', scope: 'packages/skotiq_app/lib/screens/{sequencer,dashboard}/**, packages/skotiq_core/lib/src/providers/sequence/** (event classification only), packages/skotiq_core/lib/src/services/notification/** (only if a producer lives there)' },
  { key: 'solver-native', items: 'IMG-14 FINAL (thread hint_scale into the native solve path that RUNS: the polar wizard computes "1.29\\"/px unbinned" then calls a solve that drops it; imaging solves pass -ra/-spd but never -fov. Find every native solve call site (api/polar_alignment, imaging annotate/snapshot), pass the scale, and assert -fov appears in the built astap args via the existing arg-builder tests. Also the parked-mount refusal must SAY something: footer message + disabled state), ND-E2 (two concurrent ASTAP solves of one frame — dedupe), IMG-9 (auto-select: find the implementation that runs and make the attempt + lock observable in UI and log).', scope: 'native/skotiq_native/bridge/src/** (solve call sites), native/skotiq_native/imaging/src/platesolve.rs, packages/skotiq_app/lib/screens/{polar_alignment,guiding}/** (messages only)' },
  { key: 'equipment-chrome-3', items: 'WD-SEQ-N4 (target_score_row.dart:175 _statusLabel overrides the engine reason — render the reason it was given), WD-EQ-2 (extend friendlyNameFromDeviceId: native:builtin_guider:* → "Built-in Guider", sim_* → the simulator display names), WD-EQ-3 (dedupe the triple toast), WD-EQ-4 (Edit Dashboard in standby: disabled + a reason that actually reaches the semantics bridge — the D-fix hint never arrived), WE-EQ-N1/CON-53 (copy must name a tab that exists: "the Schedule tab"), CON-49 (step-1 Back: hide or disable), CON-51 (History chips disabled over zero rows + one vocabulary), CON-52/55/56/58/59/62 (header rules, Open Settings roles, ALL-CAPS, Projects contradiction, template durations, Help&Tutorials buttons), WE-EQ-N2 (snackbar vs nudge band), WE-EQ-N3 (Dashboard primary actions published panel+DISABLED while live), WE-EQ-N5/N6 (status-bar + card truncations).', scope: 'packages/skotiq_app/lib/screens/{scheduler,equipment,dashboard,shell,planner,sequencer,analytics,settings}/** (listed items only), packages/skotiq_app/lib/widgets/**, packages/skotiq_core/lib/src/utils/device_id.dart' },
  { key: 'settings-sky-3', items: 'SET-12 (tour still narrates absent panels — read the waveE evidence for which step), WE-SP-1..5 (device-row clip, swallowed nav click after Reset, empty-state contrast, pairing-card semantics collapse, nudge over the Moon card), D-2 (tooltips never leave the a11y tree), D-3 (time-transport accessible names), E-SKY-1 (inset the remaining planetarium chrome), E-SKY-2 (play/pause name/state swap), E-SKY-3 (restore the selected VALUE the guide-graph a11y fix dropped — label AND value, both).', scope: 'packages/skotiq_app/lib/screens/{onboarding,settings,tutorial,planetarium}/**, packages/skotiq_planetarium/**, packages/skotiq_ui/lib/src/widgets/phd2/guide_graph_advanced.dart, packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart' },
  { key: 'science-collab-3', items: 'NEW-E5/WD-SCI-N5 (P2: Night Doctor 100/100 "clean night" beside visible warnings — feed it the diagnostics the report already shows), NEW-E2 (P2: Replay screen swallows left-rail navigation while the rail repaints as moved), WD-SCI-N3 (Start Anyway panel role), WD-SCI-N4 (chevrons over tabs at 900px), WD-COL-N2 (inert gated actions need inline reasons), WD-COL-N3 (auto-filled dimension swallows keystrokes), WD-COL-N4 (status-bar Mount clip), COL2-3 THIRD strike (Deep-Star Download: honor the waveE live evidence — find why the disabled-with-reason build is not what renders), NEW-C2/C3 (remaining [DISABLED] mispublish + dropdown announce parity), NEW-E1 (Back control name), NEW-E3 (decision count), NEW-E4 (status-bar chip panel+DISABLED while openable).', scope: 'packages/skotiq_app/lib/screens/{analytics,science,session_review,mosaic,collaborative_sky,replay,diagnostics}/**, packages/skotiq_app/lib/widgets/** (status bar chip), packages/skotiq_ui/lib/src/components/skotiq_dropdown.dart (announce parity only)' },
]

phase('Fix')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nITEMS: ${b.items}\nSCOPE: ${b.scope}`,
    { label: `efix:${b.key}`, phase: 'Fix', schema: FIX_SCHEMA, model: 'opus', effort: 'high' }
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
