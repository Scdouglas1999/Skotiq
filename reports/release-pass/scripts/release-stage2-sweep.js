export const meta = {
  name: 'release-stage2-sweep',
  description: 'Stage-2 sweep: the cross-scope leftovers from B-fix/C2 with root causes already located',
  phases: [
    { title: 'Sweep', detail: '7 feature-scoped batches, shared tree, strict ownership', model: 'opus' },
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

const CHARTER = `You are a fix engineer in the Skotiq release pass (Flutter/Dart melos monorepo + Rust via FRB). Repo root is the cwd. The tree is GREEN at HEAD — full gates passed before this wave. Root causes for your items were already located by earlier waves and are quoted in your item list; verify each against HEAD before fixing (the locator may be stale).

FIRST ACTIONS: (1) one \`graphify query\` (PreToolUse hook requires it — comply once); (2) read the referenced sections of reports/release-pass/RELEASE-PASS-2026-08-11.md and the impl log(s) your items name.

VERIFICATION LADDER: failing test FIRST for every behavior item (unit/widget/integration in the owning package); if you cannot make it fail at HEAD, record false_positive and change nothing. GUI-only geometry gets pinned by widget tests (tester.getRect / semantics assertions). Live-drive verification belongs to Wave D — do NOT launch the GUI harness or rebuild the release bundle.

RULES: edit only within SCOPE plus owning-package test dirs plus single-line barrel edits. FORBIDDEN: git writes, melos commands, repo-wide formatters (format only files you touch), editing generated files, FRB regeneration (stop the item, record blocked). Rust target dir is shared — file-lock waits are other agents. Log to reports/release-pass/impl/s2-<batch>.md. Your final message is machine-read: return ONLY the structured result.`

const BATCHES = [
  {
    key: 'stacking',
    items: 'SCI-27 (stacked preview renders black: stackedPreviewGrayRgba/ColorRgba in packages/skotiq_app/lib/screens/imaging/widgets/stacking_panel-adjacent code use a LINEAR min/max stretch — match the viewer\'s autostretch), SCI-28 (Stop destroys the stack: LiveStackingService.stop() releases the native stacker without reading the result — offer/save the master, confirm before discard, and never leave nothing on disk after N aligned frames), SCI-47 (Statistics list mixes frame counts and pixel counts with no units — add units and a visual break).',
    scope: 'packages/skotiq_app/lib/screens/imaging/**, packages/skotiq_core/lib/src/services/live_stacking_service.dart',
  },
  {
    key: 'science-copy-diag',
    items: 'SCI-42 (the no-focuser warning prints twice in the Session Report: session_diagnostics_operations.dart:393 noticedConcerns = stats.warningMessages duplicates the postsession rule — dedupe at the source), SCI-46 diagnostics half (the Select-session dropdown offers only imaging_sessions rows; quick-capture sessions with frames must be diagnosable), SCI-43 (Quick-Start Wizard says "Save targets from Sky or Planner", Pre-Flight says "Open Calibration → Dark Library" — neither destination exists; use real navigation names), SCI-36 remainder (bare InkWells: mosaic_projects_list_screen.dart:161 Back control + diagnostics_screen Learn-more — give them real button semantics).',
    scope: 'packages/skotiq_app/lib/screens/{analytics,diagnostics,mosaic,sequencer}/** (copy + semantics only in sequencer), packages/skotiq_core/lib/src/providers/sequence/sequence_executor/session_diagnostics_operations.dart',
  },
  {
    key: 'native-solver',
    items: 'IMG-14 solver-hints half (extract unified_device_ops::plate_solve\'s hint-gathering — FOCALLEN/XPIXSZ/RA/DEC cards from profile + camera — into a shared helper; make api/polar_alignment.rs::write_temp_fits_for_solve and the annotate/blind-solve path use it so no production solve runs blind when hints are known), SCI-48 (ASTAP writes .ini/.wcs debris beside the user\'s FITS: solve from a scratch copy or redirect the solver output dir, and clean up; native/skotiq_native/imaging/src/platesolve.rs).',
    scope: 'native/skotiq_native/bridge/src/** (solver call paths), native/skotiq_native/imaging/src/platesolve.rs (+ tests)',
  },
  {
    key: 'chrome-desktop',
    items: 'EQP-23 (a fatal render error exits silently: add a last-gasp shutdown record + device-safing hook at the desktop entry point — apps/desktop main/runner; scope = write the record and trigger the existing safing path, no new UI), CON-61b (navigating to /settings?section=X while Settings is open does nothing: SettingsScreen reads the section only in initState — listen for route updates), SET-17 revoke-all (add PairingNotifier.revokeAll + a confirm flow on the pairing screen).',
    scope: 'apps/desktop/lib/** (entry point + shutdown), packages/skotiq_app/lib/screens/{settings,shell}/**, packages/skotiq_remote_protocol/** (revokeAll)',
  },
  {
    key: 'ui-tooltip-framing',
    items: 'SKY-8 (SkotiqTooltip: anchor maths in _TooltipOverlay/_TooltipLayoutDelegate draws the label ~176px off its control, and tooltips never retire when another opens — fix both in packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart), SKY-9 (Framing FOV gated on a CONNECTED camera because framingEquipmentProvider only reads sensor dims from live getCameraStatus — persist sensor dimensions into the profile when a camera connects, read them back when disconnected; if the profile schema change would require FRB regeneration, STOP and record blocked with the exact schema delta needed).',
    scope: 'packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart (+ ui tests), packages/skotiq_core/lib/src/providers/framing_provider/**, profile persistence code you locate (claim files in your log first)',
  },
  {
    key: 'dropdown-sweep',
    items: 'The 29 raw DropdownButton call sites listed in reports/release-pass/impl/bfix-a11y-design-system.md (per-screen A11Y-STATE remainders): apply the recorded recipe — Semantics(enabled:, selected:) on each DropdownMenuItem child + selectedItemBuilder, or migrate to SkotiqDropdown where drop-in. Mechanical; parity of rendered pixels where feasible.',
    scope: 'packages/skotiq_app/lib/screens/** (ONLY the listed dropdown call sites + their test files)',
  },
  {
    key: 'phd2-crywolf',
    items: 'The PHD2 registry cry-wolf fix the C2 phd2 topic deferred: api_get_connected_devices / api_is_device_connected cannot see a connected PHD2 guider because it registers in AppState.devices, not DeviceManager.devices. This IS a behavior change and that is the point: failing test first (a connected PHD2 must appear in the connected-devices API), then unify the read path via the C2 canonical accessors (phd2_client / resolve_guider_backend). Read the C2 impl log reports/release-pass/impl/c2-phd2-registry-split.md first — it maps every consumer.',
    scope: 'native/skotiq_native/bridge/src/** (device queries + phd2 registry), packages affected read paths if the wire shape changes (STOP if FRB regen would be needed)',
  },
]

phase('Sweep')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nITEMS: ${b.items}\nSCOPE: ${b.scope}`,
    { label: `s2:${b.key}`, phase: 'Sweep', schema: FIX_SCHEMA, model: 'opus', effort: 'high' }
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
