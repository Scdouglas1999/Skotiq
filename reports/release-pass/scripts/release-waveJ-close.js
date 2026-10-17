export const meta = {
  name: 'release-waveJ-close',
  description: 'Wave J: verify the I-response batch, then the campaign closes',
  phases: [
    { title: 'Check', detail: '1 live driver + 1 refuter over the I-response commit', model: 'opus' },
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
    `You are the CLOSING live check of the Skotiq release pass (Wave J), verifying the Wave-I response batch. Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; a fresh profile opens onboarding: Skip it by image coordinates if the tree has no geometry). One graphify query first. Verify, each with pixel/a11y evidence:
1. OPERATOR STOP still reads as one: run a short sim sequence, press Stop once → exactly ONE "Sequence stopped" row, message "Stopped by request" (the evidence source changed to the manual-intervention decision — confirm the message still appears live), no Decision-logged row, earlier rows intact.
2. MEASURED RESERVE at 1000x800: with the next-use ("Skip this step") card showing, scroll to the hard bottom and measure by pixel scan: the last content row must be FULLY readable, and the extent delta vs the no-prompt state must be within a few px of (card height + its 16px inset) — no longer a fixed 210. Then dismiss all steps so the SHORTER Smart Night card shows (enable its auto-prompt if needed): the extent delta must SHRINK to that card's band — the over-reserve is gone. Then dismiss it: delta returns to 0.
3. RESTART-THEN-STOP: run a sequence, stop it, immediately start another run and stop it ~5-10 s after the first stop → the feed shows BOTH runs' stop rows (run boundary honoured) as far as the 5-row budget allows; raise nothing if budget hides one — check the row set right after the second stop.
4. Sanity: two sibling Take Exposures still render two cards.
Write reports/release-pass/gui/waveJ-close.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'J:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the CLOSING refuter of the Skotiq release pass (Wave J). One graphify query first. Attack the newest commit (git log --oneline -3; the I-response: manual-intervention-only evidence + Started-boundary/nearest-group/no-window fold + message-copy in packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart; measured-band publish in the two dashboard prompt cards + floatingPromptReservedHeightProvider readers in glass_card.dart/cockpit_standby.dart; microtask dispose release; the rewritten conformance suite recent_events_feed_conformance_test.dart) with adjacent counter-inputs at HEAD (throwaway tests under /tmp only, run from an untracked dir then deleted; no repo edits). Priorities:
(a) fold: a PAUSED run's Stopped-family shape (pause/resume events between producers); a run where the manual-intervention decision arrives but the run then FAILS (does the failure row survive and the stop row stay honest?); history truncation (maxHistorySize) cutting the Started boundary off the tail — does an orphan Stopped join a newer run's group?; two manual-intervention decisions in ONE press (double-emit) — badge or two rows?
(b) measured band: text-scale 1.3 or a narrow window rewrapping the card taller AFTER the first publish — does the band follow (the publish runs per build post-frame; does a pure repaint change height without a rebuild?); the fallback path (no layout yet) — can a stale fallback stick?
(c) the copy-message step: can it overwrite a NON-empty neutral message ever, and can the newest emitted row be a cancel-notice row whose own title differs?
(d) the suite: any case still assertable against the implementation rather than the contract?
Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'J:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
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
