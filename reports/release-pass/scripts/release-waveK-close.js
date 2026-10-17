export const meta = {
  name: 'release-waveK-close',
  description: 'Wave K: verify the J-response batch — the dryness call for the campaign',
  phases: [
    { title: 'Check', detail: '1 live smoke + 1 refuter over the J-response commit', model: 'opus' },
  ],
}

const CHECK_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['role', 'verified', 'failed', 'notes'],
  properties: {
    role: { type: 'string' },
    verified: { type: 'array', items: { type: 'string' } },
    failed: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['id', 'evidence'], properties: { id: { type: 'string' }, evidence: { type: 'string' } } } },
    notes: { type: 'string' },
  },
}

phase('Check')
const results = await parallel([
  () => agent(
    `You are the live SMOKE check of the Skotiq release pass (Wave K), confirming the J-response batch did not regress the working surface. Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; a fresh profile opens onboarding: Skip it by image coordinates if the tree has no geometry). One graphify query first. Verify quickly, with evidence:
1. One press of Stop on a short sim run → exactly ONE "Sequence stopped" row, message "Stopped by request", no Decision-logged row about it, earlier rows intact.
2. The dashboard prompt reserve still works at 1000x800: next-use card showing → last row fully readable at the hard bottom; dismiss all → reserve released.
3. Nothing new broken on the dashboard or the run dashboard at a glance (scan the a11y tree for error widgets/overflows on both).
Write reports/release-pass/gui/waveK-close.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'K:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the FINAL refuter of the Skotiq release pass (Wave K). One graphify query first. Attack the newest commit (git log --oneline -3; the J-response) with adjacent counter-inputs at HEAD (throwaway tests in an untracked dir, deleted after; no repo edits). The five changes under attack:
(a) the 2-minute _stopEpisodeSpan bound in _foldStopFamilyRows (packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart): can a REAL single press whose api Stopped trails by MORE than 2 minutes split into two rows, and is that degradation acceptable — and can the bound plus nearest-group still merge two happenings inside 2 minutes with no Started between (the operator-relevant case)?
(b) the SizeChangedLayoutNotifier republish in both prompt cards: does it fire on the FIRST layout too (double-publish harmless?); a rewrap that changes height during the slide-in animation; RTL or width-only changes.
(c) the claimant registry (floatingPromptClaimants): three instances in two frames; a stand-down (publish false) racing a replacement's claim; does the registry leak entries when the container dies?
(d) the Rust ungate (native/skotiq_native/sequencer/src/executor/lifecycle.rs — emit_manual_intervention bypasses decision_logging_enabled for "stop"): does the decision now reach persistence/UI surfaces that the setting was supposed to silence (check what consumes DecisionLogged besides the stop fold — decision log panels, exports), and is that acceptable or a leak of the toggle's contract?
(e) the suite (recent_events_feed_conformance_test.dart D1-D13): any case still tautological, any producer-set infidelity left.
Be proportionate: file only findings an operator would notice or a maintainer must know; P4 nits go in notes. Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'K:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
])

const ok = results.filter(Boolean)
log(`${ok.length}/2 checkers returned`)
return {
  checkers: ok.length,
  verified: ok.flatMap(r => r.verified).length,
  failed: ok.flatMap(r => r.failed.map(f => ({ role: r.role, ...f }))),
  results: ok,
}
