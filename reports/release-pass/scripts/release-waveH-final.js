export const meta = {
  name: 'release-waveH-final',
  description: 'Wave H: the final check — verify the G-fix set, then the campaign closes',
  phases: [
    { title: 'Check', detail: '1 live driver + 1 refuter over the G-fix set', model: 'opus' },
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
    `You are the FINAL live check of the Skotiq release pass. Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; a fresh profile opens onboarding: Skip it by image coordinates if the tree has no geometry). One graphify query first. Verify these, each with evidence:
1. Sequencer → Templates at a 1000x800 window: the tab heading reads "Sequence Templates" IN FULL (stacked above a full-width search row, not beside it).
2. Recent-events fold: run a short sequence (sim devices), press Stop once → RECENT EVENTS shows ONE "Sequence stopped" row (not three, no "Decision logged · system_event" row), exactly ONE stop toast, no red error toast, and earlier events still present behind it.
3. The dashboard next-use nudge ("Skip this step" card): with devices connected at 1000x800, scroll the dashboard to the hard bottom — the last content row must be fully readable (the scroll extent now reserves the prompt band). Dismissing the card must not change what was reachable, only remove the reserve.
4. SEQ-18 live: after a completed 4-frame node, its card reads "4 / 4 frames" with filled boxes (the wire-shape tally); a second untouched node reads 0 / N.
Write reports/release-pass/gui/waveH-final.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'H:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the FINAL refuter of the Skotiq release pass. One graphify query first. Over reports/release-pass/impl/gfix-*.md plus the closer commits (git log --oneline -12; the RECENT EVENTS stop-family fold, the time-windowed collapse, the Templates stacked header, the shared prompt-visibility publish in next_use_prompt_card.dart), sample the 6 boldest claims and attack each with an adjacent counter-input at HEAD (throwaway tests under /tmp only; no repo edits). Priorities: (a) the tally now decodes the REAL wire string — feed it a malformed/empty detail_json and a non-exposure structured payload; (b) the claim release covers EVERY arm — enumerate the match arms yourself and diff against the release sites; (c) the 10-minute collapse window cannot fold two stops of different runs NOR split a genuine repeat storm; (d) the stop-family fold cannot eat a real error that arrives inside the 10s window of a stop. Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'H:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
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
