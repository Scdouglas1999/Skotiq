export const meta = {
  name: 'release-waveI-close',
  description: 'Wave I: verify the H-response batch live, then the campaign closes',
  phases: [
    { title: 'Check', detail: '1 live driver + 1 refuter over the H-response commit', model: 'opus' },
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
    `You are the CLOSING live check of the Skotiq release pass (Wave I). Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; a fresh profile opens onboarding: Skip it by image coordinates if the tree has no geometry). One graphify query first. Verify the four H-response fixes, each with evidence:
1. STOP FOLD: run a short sim sequence, press Stop ONCE → RECENT EVENTS shows exactly ONE "Sequence stopped" row (message "Stopped by request"), no "Decision logged" row about the stop, earlier rows intact. Then start another run and mash Stop 3-4 times over ~10 s → MORE THAN ONE stop row (one per press), none wearing an xN badge.
2. TWO SIBLINGS: fresh sequence, add two "Take Exposures" via the palette (re-select the root card between adds so they are siblings) → the tree renders TWO instruction cards, both present in the a11y tree, neither painted over the root card. Run it; after the first node completes check its card tally reads N / N while the second untouched node reads 0 / N (the SEQ-18 comparison Wave H could not make).
3. PROMPT RESERVE: with devices connected at 1000x800 and the next-use ("Skip this step") card showing, scroll the dashboard to the hard bottom → the LAST content row is fully readable below/beside the card (reserve now 210 px). Dismiss all steps → reserve released, bottom pixel-identical to the no-prompt state.
4. PROMPT SIGNAL: while the Smart Night "Plan tonight" card is the one showing (enable its auto-prompt in settings if needed), confirm the scroll reserve stays present (the stood-down next-use card must not clear it).
Write reports/release-pass/gui/waveI-close.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'I:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the CLOSING refuter of the Skotiq release pass (Wave I). One graphify query first. Attack the newest commit (git log --oneline -3; the H-response: the per-evidence-kind stop fold + collapse exemption in packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart, the floatingPromptOwnersProvider owner-set in the two dashboard prompt cards, the depth-1 tutorial-anchor fix in lib/screens/sequencer/widgets/sequence_tree/node_tree_view.dart) with adjacent counter-inputs at HEAD (throwaway tests under /tmp only; no repo edits). Priorities:
(a) the stop fold: a real error arriving inside the 10 s window of a stop must survive as its own row; a fault abort (bare Stopped, no operator evidence) must stay cause-neutral; two stops of DIFFERENT runs seconds apart (stop, instant restart, stop) must not merge; the fold must not resurrect the Decision-logged row it demotes.
(b) the owner-set: a card disposed while showing (navigate away mid-prompt) — does the reserve leak? both cards showing in the same frame — is that reachable, and does dismissal of one keep the other's reserve?
(c) the anchor fix: THREE siblings of the same type; a TargetHeaderNode sibling pair; deleting the first sibling (the anchor holder) then re-rendering — any duplicate-GlobalKey path left?
(d) the conformance suite itself: is any of its C/D cases now tautological (asserting the implementation rather than the contract)?
Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'I:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
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
