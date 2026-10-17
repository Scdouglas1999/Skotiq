export const meta = {
  name: 'release-decisions-verify',
  description: 'Verify the ten owner-decision implementations — the true final wave',
  phases: [
    { title: 'Check', detail: '1 live driver + 1 refuter over the decisions commit', model: 'opus' },
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
    `You are the live DRIVER verifying the owner-decision implementations (see "Owner decisions (made 2026-08-14...)" in reports/release-pass/RELEASE-PASS-2026-08-11.md). Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; fresh profile opens onboarding: Skip by image coordinates if the tree lacks geometry). One graphify query first. Verify with evidence:
1. AUTOPILOT PAUSE (decision 1): dispatch a run via the autopilot/scheduler with sim devices, press Stop → the autopilot does NOT re-dispatch (~44s wait), and a visible "Autopilot paused — resume?" affordance appears; Resume restores dispatching.
2. REMOVAL = INELIGIBLE (decision 3): remove a target from the scheduler → the autopilot never picks it afterwards (watch at least one evaluation cycle).
3. IMG-9 (decision 9): loop exposures on the imaging screen → the Frame Count label counts loop frames and resets on a new loop.
4. CON-56: the time control panel reads "Now"/"Tonight", not ALL-CAPS.
5. Regressions: a normal sequence still runs to completion; one press of Stop still yields ONE honest feed row; dashboard + run dashboard a11y scans clean.
Write reports/release-pass/gui/decisions-verify.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'V:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the REFUTER of the owner-decision implementations (newest commit; the decisions list is in reports/release-pass/RELEASE-PASS-2026-08-11.md "Owner decisions"). One graphify query first. Throwaway tests in an untracked dir, deleted after; no repo edits. Attack each implementation with adjacent counter-inputs:
(1) autopilot pause: does the engine distinguish ITS OWN stop (origin scheduler) from the operator's — i.e. does a scheduler-initiated stop wrongly pause the autopilot? Does pause survive a rebuild/restart of the engine? Can a paused engine still be resumed after the run that triggered the pause is long gone?
(2) pushes: feed each producer set (operator press / Autopilot: stop / System: stop origins / bare safety abort) through the classifier+router — exactly the non-operator ones push, at NORMAL priority (accepted adjudication: the app has no 'info' push tier — sequenceCompleted's tier is the correct one; do NOT refute on priority naming), one push per episode, honest copy?
(3) removal-ineligible: is the ineligibility persisted, and can a re-added target become eligible again? Does 'Clear all' behave the same as per-target removal?
(4) unpark gating: a parked mount unparks; an unparked mount is a no-op; what does a mount that cannot report park state do?
(5) deletions: does anything still import the deleted files (analyzer across every package)? Did the bridge_stub policy comment get corrected?
(6) mosaic sink: is SessionWizardCheckpointSink REALLY the production wiring now (read the provider, not the docs), and do the resume tests exercise that wiring?
(7) fits-master: a stack save without per-frame headers → valid FITS, synthesized EXPTIME = total integration, DATE-OBS = first frame; does a NORMAL sequenced save still carry its real headers?
(8) AF-fail policy: non-convergence restores the pre-AF position and continues with a decision row; an EXPLICIT AF node's configured failure_action is untouched.
(9) IMG-9 reset semantics; (10) CON-62 search index regenerated and the search test green.
Be proportionate. Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'V:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
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
