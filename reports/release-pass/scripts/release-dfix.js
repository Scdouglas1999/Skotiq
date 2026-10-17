export const meta = {
  name: 'release-dfix',
  description: 'D-fix: the Wave D harvest — refuted claims, re-opened items, new findings',
  phases: [
    { title: 'Fix', detail: '8 feature-scoped batches, shared tree, strict ownership', model: 'opus' },
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

const CHARTER = `You are a fix engineer in the FINAL fix wave of the Skotiq release pass (Flutter/Dart melos monorepo + Rust via FRB). Repo root is the cwd; tree GREEN at HEAD. Your items come from Wave D's live verification: the machine-readable verdict is reports/release-pass/waveD-result.json (still_broken evidence, new_findings repros, refuted-claim details) and the per-cluster narratives are reports/release-pass/gui/waveD-*.md. READ YOUR ITEMS' ENTRIES THERE FIRST — they carry exact live evidence from the running app, screenshots, and log excerpts. The adjudication section "Wave D verdict" in reports/release-pass/RELEASE-PASS-2026-08-11.md carries overrides.

One graphify query first (PreToolUse hook). VERIFICATION LADDER: failing test FIRST for every behavior item; if you cannot make it fail at HEAD, record false_positive with what you observed. Several of your items are REFUTATIONS of earlier "fixes" — the bar is higher: your test must encode the exact counter-input the refuter used (their throwaway tests are referenced in the JSON; adopt them into the repo properly). GUI geometry gets widget-test pins. Do NOT launch the GUI harness or rebuild the bundle.

RULES: edit only within SCOPE + owning-package test dirs + single-line barrel edits. FORBIDDEN: git writes, melos, repo-wide formatters, generated files, FRB regeneration (stop + record blocked). Rust target dir shared. Log to reports/release-pass/impl/dfix-<batch>.md. Final message is machine-read: ONLY the structured result.`

const BATCHES = [
  { key: 'autopilot-ownership', items: 'REFUTED SEQ-12 both halves (adopt scratchpad seq12_race_test.dart into the repo: fix the dispatch-vs-tick race AND replace currentTargetId!=null with a sound run-ownership token — e.g. the autopilot records the run id it dispatched and only stops that exact run while it is still the active run), SEQ-13 (engine holds a stale target RA/Dec snapshot; site changes are live — find where target coords are captured and make re-evaluation read current coords), WD-SEQ-N4 (STATUS says Below horizon at +9.8deg — decision text vs threshold mismatch), WD-SEQ-N5 (Clear all does not persist), WD-SEQ-N6 (no armed-autopilot warning when starting a manual run — add the banner/pre-flight notice).', scope: 'packages/skotiq_core/lib/src/services/scheduler/**, packages/skotiq_core/lib/src/providers/sequence/**, packages/skotiq_app/lib/screens/{planner,scheduler,sequencer}/** (warning surfaces only)' },
  { key: 'sequencer-ui', items: 'SEQ-18 (node card 0/N after a successful run — success path resets the counter the stop path keeps), SEQ-19 (card says "R 180s" two rows above "Exposure: No Filter" — one filter story per card), SEQ-20 residual (elapsed renders whole minutes; render seconds under 1m like the estimate beside it), WD-SEQ-N1 (operator Stop reported as Sequence Error in three places — stopped is not an error), WD-SEQ-N2 (builder unusable at 900px — collapse panes), WD-SEQ-N3 (palette tabs announced disabled), SCI-43 preflight string at packages/skotiq_core/lib/src/providers/sequence/rules/preflight_rules.dart:246 (suggested text in the doc), NEW-C1 (palette tab strip clips at 1000px).', scope: 'packages/skotiq_app/lib/screens/sequencer/**, packages/skotiq_core/lib/src/providers/sequence/rules/preflight_rules.dart' },
  { key: 'imaging-guiding-polar-2', items: 'ND-1 P1 (live-stacking counters freeze at 1 while the stacker consumes 68 — find where stats stop flowing after frame 1; the Stop dialog then under-reports), IMG-4 (a solve with no WCS must not render the green success chip — the annotate chip needs a solve-outcome input), IMG-10 (Pause on builtin guider: make it visibly disabled with the tooltip reason, not a silent no-op), IMG-13 (slew-step headline lags: "Slewing to point 1" while detail says point 2), IMG-14 (pass the field scale: ASTAP -fov from the profile arcsec/px the app computed), IMG-16 (post-run bullseye says "No measurement yet" beside a 3.2" result — plot the final measurement), IMG-9 residual (Auto Select needs feedback + a log line), ND-2 (annotate solves must use the same hinted path the polar wizard now uses), ND-3 ("Alignment Complete" green beside "Improvement: Worse" red — reconcile), ND-4 (bottom bar overflow at narrow width), ND-5 (bottom-bar semantics), ND-6 (saveMaster silently swaps extension to .png — name the format honestly in the picker or write FITS when asked).', scope: 'packages/skotiq_app/lib/screens/{imaging,guiding,polar_alignment}/**, packages/skotiq_core/lib/src/services/: live_stacking_service.dart, plate_solve_service.dart, polar_alignment*' },
  { key: 'equipment-shell-2', items: 'WD-EQ-1 (heartbeats STILL 20676d for 5 of 6 device types — the EQP-1 fix covered only the camera path; find where non-camera heartbeat timestamps are (not) recorded), CON-61 (title bar + nav rail absent from the AT-SPI tree — the accessibility bridge only exports the Flutter view content; investigate whether the custom title bar widgets exclude semantics, fix what is fixable in-widget, record precisely what needs the GTK layer if any), WD-EQ-2 (raw device ids in toasts), WD-EQ-3 (three toasts for one failure — dedupe), WD-EQ-3b (person-icon deep-link dead when already inside Settings — the CON-61b fix listens for route changes only from outside), WD-EQ-4 (Edit Dashboard silently inert in standby — disable with reason), WD-EQ-5 (floating nudge covers Scan All at 1000x800 — reposition/clamp), WD-EQ-6 (full-bleed snackbars cover the status bar — constrain width), WD-EQ-7 (heartbeat start/stop log asymmetry), CON-46/49/51/52/53/54/55/56/58/59/62/63 (the mechanical consistency backlog: empty-state tokens, dead Back button on step 1, run-state vocabulary chips, header rules, Plan-Tonight self-reference, tick copy, Open Settings roles, Projects contradiction, duration formats on template cards, ALL-CAPS buttons, Help&Tutorials button treatments, crossed-eye icon).', scope: 'packages/skotiq_app/lib/screens/{equipment,dashboard,shell,settings,planner,sequencer,analytics}/** (consistency items only where listed), packages/skotiq_app/lib/widgets/**, packages/skotiq_core/lib/src/providers/** heartbeat state only' },
  { key: 'settings-pairing-2', items: 'SET-2 residual, SET-12 residual (tour still narrates absent panels), SET-18 residual (see waveD report), WD-N1 (raw Rust error debug text in onboarding chips — human copy), WD-N2 (overlapping texts on step 6), WD-N3 (step 13 re-asserts the edited-away scope name), WD-N4 (pairing phrase invisible to a11y — the one credential a blind user must read), WD-N5 (paired banner survives revocation), WD-N6 (singular form), WD-N7 (coach mark covers Manage Pairing), WD-N8 (Reset All Progress promises a tour that never reappears), WD-N9 (SET-20 shrink-wrap residual).', scope: 'packages/skotiq_app/lib/screens/{onboarding,settings,tutorial}/**, packages/skotiq_remote_protocol/** (banner state only)' },
  { key: 'sky-planetarium-2', items: 'SKY-4 (Create region silently no-ops with no target — Wave D says still reproducible live despite the B-fix FP call; re-examine with their evidence), SKY-10 (wheel zoom ignores pointer), SKY-16 (desktop says tap), D-1 (status-bar LST shows simulated time next to the real clock while scrubbing — scope it or label it), D-2 (tooltips never leave the a11y tree), D-3 (time-transport buttons have no accessible names), D-4 (Layers drawer overlays the transport at 900px).', scope: 'packages/skotiq_planetarium/**, packages/skotiq_app/lib/screens/{planetarium,your_sky}/**' },
  { key: 'science-collab-2', items: 'WD-SCI-N1 (quick captures unreachable once a sequence run exists — session pickers need both), WD-SCI-N2/N3 (chips + Start Anyway announced as panels), WD-SCI-N4 (tab-strip chevrons overlay tabs at 900px), WD-SCI-N5 (Night Doctor 100/100 clean while the same run shows warnings — reconcile inputs), WD-COL-N1 (list not refreshed after create — invalidate on return), WD-COL-N2 (gated actions inert with the reason only in the footer — disable + inline reason), WD-COL-N3 (auto-filled panel dimension swallows keystrokes), WD-COL-N4 (status bar clips Mount at 900px), COL2-3 + COL2-13 (B-fix called these fixed-at-HEAD; Wave D reproduced them live — resolve the contradiction with the waveD evidence and fix what is real), CON-45/48 (Analytics empty-state unification + Diagnostics prose), NEW-C2/C3/C4 (remaining [DISABLED] mispublish sites, dropdown announce parity, selected-option marking).', scope: 'packages/skotiq_app/lib/screens/{analytics,science,session_review,mosaic,collaborative_sky,suggestions,transients,diagnostics}/**, packages/skotiq_ui/lib/src/components/skotiq_dropdown.dart (selected-state only)' },
  { key: 'native-fixes', items: 'REFUTED C1 frame-verdict half (verdicts reach the counters but NOT the integration total printed beside them — sequence_run stats integration must follow accepted frames; see the refuter evidence in waveD-result.json), REFUTED phd2AutoSelectStar (the refusal RELOCATED into _phd2 path — complete the removal or make the call real), REFUTED SCI-48 sparing rule (string-prefix match spares M31_dark.ini for image M31.fits — match on exact base name + known debris extensions).', scope: 'packages/skotiq_core/lib/src/providers/sequence/** (stats), packages/skotiq_bridge/lib/src/bridge_stub/guiding_operations.dart, native/skotiq_native/imaging/src/platesolve.rs' },
]

phase('Fix')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nITEMS: ${b.items}\nSCOPE: ${b.scope}`,
    { label: `dfix:${b.key}`, phase: 'Fix', schema: FIX_SCHEMA, model: 'opus', effort: 'high' }
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
