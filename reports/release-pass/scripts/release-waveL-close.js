export const meta = {
  name: 'release-waveL-close',
  description: 'Wave L: verify the K-response batch — the campaign closes on a dry return',
  phases: [
    { title: 'Check', detail: '1 live smoke + 1 refuter over the K-response commit', model: 'opus' },
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
    `You are the live SMOKE check of the Skotiq release pass (Wave L), confirming the K-response batch (origin-threaded stop + run-id on Stopped + FRB regeneration) did not regress the working surface. Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; fresh profile opens onboarding: Skip by image coordinates if the tree lacks geometry). One graphify query first. Verify with evidence:
1. The app STARTS and reaches the dashboard (the FRB regeneration touched every API family — a wire-format mismatch would fail fast). Connect sim devices; confirm device status renders.
2. Run a short sim sequence to completion — frames captured, tally correct, session report opens. This exercises the regenerated event stream end-to-end.
3. Press Stop on a second run → exactly ONE "Sequence stopped" row with "Stopped by request", no regression.
4. Scan the a11y tree on dashboard + run dashboard + equipment for error widgets/overflow after all of the above.
Write reports/release-pass/gui/waveL-close.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'L:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the FINAL refuter of the Skotiq release pass (Wave L). One graphify query first. Attack the newest commit (git log --oneline -3; the K-response) with adjacent counter-inputs at HEAD (throwaway tests in an untracked dir, deleted after; no repo edits). Under attack:
(a) origin threading: enumerate EVERY caller chain into SequenceExecutor.stop and api_sequencer_stop (Dart and Rust, including headless handlers and recovery paths) and verify each carries the honest origin — is there any non-operator path still defaulting to operator evidence? Does the stopFailed RETRY preserve the original origin (a scheduler stop that fails and is re-driven must not become an operator stop)?
(b) run-id identity in the fold (run_dashboard_providers.dart): a Stopped with runId joining an id-LESS group of a different run; two same-run groups forced apart by kind capacity then a neutral Stopped choosing between them; the id-less fallback's pairwise chaining absorbing beyond the bound via stepping-stone members — is that acceptable?
(c) the Rust side: stop_with_origin's scheduler branch emits "Autopilot: stop" as SystemEvent — check it respects decision_logging_enabled, that the ManualIntervention path is unchanged for None/operator, and that active_sequence_run_id is read BEFORE stop clears it in api_sequencer_stop (is it cleared? verify).
(d) the FRB regeneration fallout: stale re-export shims (event.dart, device_capabilities.dart, api_barrel) — any type-identity split remaining (two SkotiqEvent types reachable)? Any Dart consumer still importing a deleted monolith path?
(e) the suite D1-D16: tautologies or producer-set infidelity.
Be proportionate: file only findings an operator would notice or a maintainer must know; P4 nits in notes. Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'L:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
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
