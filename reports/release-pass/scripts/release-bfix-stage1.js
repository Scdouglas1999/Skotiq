export const meta = {
  name: 'release-bfix-stage1',
  description: 'Wave B-fix stage 1: the adjudicated GUI P0/P1 findings + shared-path P2s, 8 batches',
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

const CHARTER = `You are a fix engineer in the release pass for Skotiq (Flutter/Dart melos monorepo + Rust via flutter_rust_bridge). Repo root is the cwd. The tree is GREEN at HEAD — full melos + cargo workspace + all custom gates passed before this wave launched. Any failure inside your scope is yours.

FIRST ACTIONS, in order: (1) run one \`graphify query\` (a PreToolUse hook requires it before source reads — comply once, then work freely); (2) read reports/release-pass/RELEASE-PASS-2026-08-11.md section "Wave B findings (adjudicated 2026-08-13)" — it carries re-scopes and class definitions that OVERRIDE the raw reports; (3) read your cluster report(s) listed below — they carry the evidence, exact repro steps, and screenshot paths.

VERIFICATION LADDER (non-negotiable):
- Every finding gets a FAILING TEST FIRST (unit/widget/integration in the owning package) that reproduces the defect, then the fix, then green. If you cannot make a test fail against the current code, re-check the finding's repro in the report; if the behavior genuinely is not present at HEAD, record it under false_positives with what you observed and change nothing.
- GUI-only findings (layout overlap, clipping, z-order) where a widget test genuinely cannot express the defect: pin the fixed geometry/semantics in a widget test anyway (e.g. no-overlap assertions via tester.getRect, semantics-node assertions). Live-drive verification is deferred to Wave D against a fresh bundle — do NOT launch the GUI harness or rebuild the release bundle; eight agents share it.
- Cross-cutting class fixes (A11Y-STATE, STATE-VOCAB, ...) are fixed at the shared component named in the adjudication, not per-screen. If your batch hits a per-screen instance of a class another batch owns at the component level, fix ONLY your screen's usage if it is independently wrong; otherwise record it in notes as covered-by-component.
- Behavior fixes must not regress the "held up" sections of the cluster reports — read them; they list what already works.

RULES:
- Edit ONLY within your SCOPE paths, plus the owning package's test dirs, plus single-line barrel-export edits (one atomic Edit per line; other agents edit other lines concurrently).
- FORBIDDEN: any git command (read-only git status/log/diff allowed), melos commands, repo-wide formatters (format only files you touched), editing generated files (*.g.dart, *.freezed.dart, frb_generated.*), rebuilding the release bundle, launching the GUI harness. If a fix would require regenerating FRB bindings, STOP that item and record it blocked.
- Rust: the cargo target dir is shared — "Blocking waiting for file lock" means another agent; wait it out. Dart: run tests scoped to files (flutter test test/<file>), retry once on infrastructure-looking flakes.
- Other agents own other scopes. If a build/test error traces outside your scope, wait ~2 minutes, retry, then record blocked after 3 tries and continue.
- Write code that reads like the best of the surrounding code. Comments only for constraints the code cannot show.
- Keep a running log at reports/release-pass/impl/bfix-<batch>.md (create it; append as you go).
- Your final message is machine-read: return ONLY the structured result.`

const BATCHES = [
  {
    key: 'sequencing-autopilot',
    reports: 'reports/release-pass/gui/sequencing.md + SCI-39/SCI-40 in reports/release-pass/gui/science-review.md',
    items: 'SEQ-12 (P0 autopilot kills manual runs — find the stop call the autopilot tick issues and make it own-run-scoped + surface a visible reason), SEQ-13 (P1 stale scheduler coordinates), SEQ-14 (P1 "No astronomical darkness" empty-projects path), SEQ-3 (P1 pre-flight warning for a categorical engine refusal), SEQ-15 (P1 unconfirmed silent slew: confirmation when idle, locked during a run, a Slewing state + log line always), SEQ-16 (P1 pre-flight must flag mount-off-target with no slew instruction), SCI-39 (P1 Null Island daylight gate — absent location is UNKNOWN, not (0,0); fix the gate, and pre-flight says the real reason), SCI-40 (P2 dark-library matcher keys on actual sensor temp when no cooler), SEQ-6 + the STATE-VOCAB class instance "paused-stopped" (one presentation mapping for run-outcome states), SEQ-17/18/19 (P2s: two Target Queues copy, 0/4-after-success node card, No Filter vs filter R).',
    scope: 'packages/skotiq_core/lib/src/services/scheduler/**, packages/skotiq_core/lib/src/providers/sequence/**, packages/skotiq_app/lib/screens/{sequencer,scheduler,planner,tonight}/**, native/skotiq_native/sequencer/src/** (daylight gate + observer location only)',
  },
  {
    key: 'imaging-guiding-polar',
    reports: 'reports/release-pass/gui/imaging-spine.md',
    items: 'IMG-1 (P1 capture-folder validation latch — revalidate on edit), IMG-8 (P1 guider never leaves Settling while status bar says Guiding — find the settle-state transition and the two disagreeing surfaces), IMG-12 (P1 Polar Alignment Stop ignored — check BOTH stop implementations, screen wiring vs standalone slice; the 2026-07-13 hardening claimed stop terminates), IMG-4 (P2 "Found 0 objects" green chip on a failed solve), IMG-14 (P2 TPPA preflight: parked mount + blind solve with no hints — point the imaging/TPPA solver calls at the hinted path, see adjudication delta 2), IMG-9/10/13/18/19/21 (P2s), IMG-2/3 (P2 overlay collisions), IMG-16 (P3 bullseye dead-centre marker with no data — also the Guiding target-display twin).',
    scope: 'packages/skotiq_app/lib/screens/{imaging,guiding,polar_alignment,flat_wizard}/**, packages/skotiq_core/lib/src/services/: imaging_service.dart, plate_solve_service.dart, flat_wizard_service.dart, guiding-related services, polar_alignment*',
  },
  {
    key: 'onboarding-settings',
    reports: 'reports/release-pass/gui/settings-onboarding.md',
    items: 'SET-17 (P1 pairing store outside the data dir — move pairing.db under the configured data dir with migration; see adjudication delta 3), SET-1 (P2 red backend chips with no message on a clean scan), SET-3 (P2 contradictory guider status lines), SET-6 (P2 wizard switches invisible to a11y — component-level if the owning widget is in skotiq_app; if in skotiq_ui record covered-by-component), SET-8/9 (P2 location dialog + "No site on record yet" after detect), SET-12 (P2 tour narrates panels not on the dashboard), SET-18 (P2 pairing QR: missing phrase/expiry/stop + a11y), SET-23 (P2 fake-editable profile boxes), SET-28 (P2 three notification systems — disclose precedence at minimum), SET-2/5/11 (P3s: Add slot invents Filter 7, stale library badge, silent preset overwrite).',
    scope: 'packages/skotiq_app/lib/screens/{onboarding,settings,tutorial}/**, the pairing/remote-access store location code wherever it lives (locate it first; likely apps/desktop or packages/skotiq_core server/pairing paths)',
  },
  {
    key: 'equipment-shell-chrome',
    reports: 'reports/release-pass/gui/equipment-shell.md + CON-44/60/61 in reports/release-pass/gui/consistency.md',
    items: 'EQP-1 (P1 epoch-zero heartbeats reported OK — no timestamp means UNKNOWN, and epoch zero must never render as a 20676d-ago OK), EQP-10 (P1 three device counts on one screen), EQP-23 (P2 silent process death — add a last-gasp shutdown record + device safing hook on fatal render errors; see adjudication delta 4), EQP-11 (P2 never-connected device degrades health + raw id in copy), EQP-12 (P2 bell opens a science feed — make the chrome bell the notification centre or relabel), EQP-13 (P2 weather screen gates sensors on location), EQP-18/19/20/21/22 (P2s: edit-dashboard mismatch, dead Glance toggle, debug events in Recent Events, toast queue lag, double-connect), CON-44 (P2 in-flow tour nudge shortens every screen — float it; highest-leverage single fix), CON-60 (P2 Connection Status dialog clipped at bottom), CON-61 (P2 title bar absent from a11y tree + dead person icon).',
    scope: 'packages/skotiq_app/lib/screens/{equipment,dashboard,weather,diagnostics,shell}/**, packages/skotiq_app/lib/widgets/** (nudge/tour + chrome widgets), packages/skotiq_core/lib/src/providers/** device-health/heartbeat state only',
  },
  {
    key: 'sky-planetarium',
    reports: 'reports/release-pass/gui/sky-discovery.md',
    items: 'SKY-2 (P0 region-create modal never completes — the write commits, the dialog awaits something that never resolves; find it, and make Cancel/Escape always live), SKY-1 (P1 pause does not pause — the time model is wall-clock+offset with nothing stopping it), SKY-5 (P1 planetarium clock rewrites the Dashboard Local clock/dark countdown/moon — scope simulated time to the planetarium), SKY-6 (P1 DSOs render with no angular size while the data is present), SKY-3/4/7/8/9 (P2s: RA-degrees field, silent Create with no target, doubled search lists, orphan tooltips, framing gated on live camera instead of profile sensor specs), SKY-15 (P3 Escape unwired), SKY-17 (P3 layer toggles a11y — component instance).',
    scope: 'packages/skotiq_planetarium/**, packages/skotiq_app/lib/screens/{planetarium,your_sky,framing,first_light}/**',
  },
  {
    key: 'science-analytics',
    reports: 'reports/release-pass/gui/science-review.md (wave 2 + the still-reproducing wave-1 table)',
    items: 'SCI-46 (P2 three meanings of "session"; quick-capture sessions invisible to History/Diagnostics), SCI-44 (P2 inverted selected-tab styling in Session Review), SCI-36 (P2 working controls announced disabled — screen-level instances), SCI-37 (P3 tile score differs from stored quality_score), SCI-38 (P3 "Good — Low star count" contradiction), SCI-41 (P3 inert Integrate now), SCI-27/28 from wave 1 (black stacked preview; Stop destroys the stack with no confirm and nothing on disk), SCI-22 (science claims no solver while ASTAP runs and fails), SCI-48 (P3 astap .ini debris in the capture folder), SCI-34/42/43/47 (P3s).',
    scope: 'packages/skotiq_app/lib/screens/{analytics,science,session_review,stack_result}/**, packages/skotiq_core/lib/src/services/: stacking/session/science services as needed (claim specific files in your log before editing)',
  },
  {
    key: 'collab-mosaic-catalogs',
    reports: 'reports/release-pass/gui/collab-catalogs.md',
    items: 'COL2-16 (P1 Create mosaic project is a silent no-op — make it create or visibly refuse with the reason), COL2-15 (P2 preview omits panels across the RA 0h seam — fix with the wave-1 COL-7 publish-path wrap-around together), COL2-17 (P2 wizard contradicts itself about panel size), COL2-1 (P2 MPC copy says MPCORB, fetches 312 bright asteroids — make the copy truthful), COL2-3 (P2 Deep-Star Download silent no-op with empty URL), COL2-11 (P2 "No active alerts" without ever checking — add last-checked/refresh or an honest never-checked state), COL2-7 (P2 top imaging candidate is a naked-eye star typed Star), COL2-2/8/12/13 (P3s).',
    scope: 'packages/skotiq_app/lib/screens/{mosaic,collaborative_sky,constellation,suggestions,transients}/**, packages/skotiq_core/lib/src/services/: mosaic*, constellation/, catalog/transient-alert services (claim specific files in your log before editing)',
  },
  {
    key: 'a11y-design-system',
    reports: 'the A11Y-STATE class in RELEASE-PASS-2026-08-11.md + every cluster report a11y finding it lists',
    items: 'Fix the A11Y-STATE family AT THE COMPONENT LEVEL in skotiq_ui: (1) controls that render enabled but expose [DISABLED] or no role (chips, dropdown menu items, toggles, panels wrapping InkWell — recall excludeFromSemantics), (2) selectable chips/toggles exposing no checked/selected state, (3) the title bar and nav rail absent from the semantics tree entirely, (4) dialog/menu items inheriting a disabled ancestor. Add semantics widget tests per component pinning role+state. Then fix instances in shared app widgets under packages/skotiq_app/lib/widgets/**. Per-screen leftovers belong to feature batches — list them in notes instead of editing other scopes. Also CON-47 both directions (the [DISABLED] flag untrustworthy both ways) and the SEQ-10/SCI-36/COL2-9 menu-item family if the menu component is shared.',
    scope: 'packages/skotiq_ui/**, packages/skotiq_app/lib/widgets/**',
  },
]

phase('Fix')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nCLUSTER REPORT(S): ${b.reports}\nITEMS (the adjudicated selection — the reports carry full evidence): ${b.items}\nSCOPE: ${b.scope}`,
    { label: `bfix:${b.key}`, phase: 'Fix', schema: FIX_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const ok = results.filter(Boolean)
log(`${ok.length}/${BATCHES.length} batches returned`)
return {
  batches_returned: ok.length,
  fixed: ok.flatMap(r => r.fixed.map(f => ({ batch: r.batch, ...f }))).length,
  false_positives: ok.flatMap(r => r.false_positives.map(f => ({ batch: r.batch, ...f }))),
  blocked: ok.flatMap(r => r.blocked.map(f => ({ batch: r.batch, ...f }))),
  results: ok,
}
