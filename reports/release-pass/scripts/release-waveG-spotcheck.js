export const meta = {
  name: 'release-waveG-spotcheck',
  description: 'Wave G: the closing spot-check — verify only the F-fix items, then the campaign closes',
  phases: [
    { title: 'Check', detail: '2 drivers on the decisive experiments + 1 refuter over the ffix logs', model: 'opus' },
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
    `You are the closing spot-check driver for the Skotiq release pass, sequencer half. Drive the FRESH bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand). One graphify query first. Execute EXACTLY these decisive experiments from reports/release-pass/impl/ffix-*.md and report verified/failed per item:
1. WF-STOP-N1: build a Target whose RA sits ON the meridian so the flip trigger fires during frame 1 of a 4x15s burst (the ffix log describes the setup). Oracle: 'select exposure_duration from captured_images order by id desc limit 4' on the profile DB — every light frame must read 15.0; and the flip must still run (log shows it waiting for the in-flight frame then firing).
2. SEQ-18: run a 2-node sequence where node 1 completes (4 frames) and node 2 is stopped at 0. Node 1's card must read '4 / 4 frames' with filled boxes; node 2 '0 / 4'. Check BOTH mid-run after node 1 finishes and after the stop.
3. WF-STOP-N2: the same run's integration must agree across Session Report, Dashboard Last-night card, and Execution History row.
4. One operator stop → exactly ONE stop toast (WF-N4/WF-STOP-N3), no ISO timestamp in the copy (WF-STOP-N5 first half), and the Session Report + banners all tell the stopped story.
5. WF-STOP-N4: if reachable, a retrying meridian flip must not report Running with a past ETA (best-effort; skip if the sim cannot stall a flip).
Write reports/release-pass/gui/waveG-sequencer.md. Do not fix anything. Return ONLY the structured result with role='driver-sequencer'.`,
    { label: 'G:driver-seq', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the closing spot-check driver for the Skotiq release pass, chrome/sky half. Drive the FRESH bundle via tools/ui_audit/drive_linux.py on display :91, profile waveG-chrome. One graphify query first. Verify per reports/release-pass/impl/ffix-{chrome-polish,sky-science-polish}.md and report verified/failed per item:
1. WD-EQ-2a: disconnect a device — the toast names the device ('Built-in Guider'), not a raw id. WD-EQ-3: the guider double-refusal now collapses to one toast (trailing-punctuation-normalized key).
2. CON-56 (Now/Tonight case), CON-62 (one button treatment + one title case across Help & Tutorials, search still finds renamed rows), WE-EQ-N5 (status-bar cut item has an ellipsis at 1000px), WF-EQ-N1/N2/N3 spot-checks, WE-SP-5 (dashboard prompt no longer hides the Moonrise value at hard bottom-scroll).
3. D-2/WF-SS-N3: the projection cycler tooltip leaves the a11y tree after hover and the control carries an accessible name; time-transport buttons named.
4. WF-SN-N4/WF-SCI-N3: a disabled SkotiqButton now reads DISABLED in the tree (probe Pre-Flight Start Anyway with errors present, and the Pause button under the builtin guider).
5. WF-SCI-N1/N2/N4: Session tab shows the most recent night after a run; Night Doctor verdict updates; Open last run opens the run.
Write reports/release-pass/gui/waveG-chrome.md. Do not fix anything. Return ONLY the structured result with role='driver-chrome'.`,
    { label: 'G:driver-chrome', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the closing refuter for the Skotiq release pass. One graphify query first. Over reports/release-pass/impl/ffix-*.md, sample the 6 boldest claims (the SEQ-18 provider tally, the camera-claim serialization incl. the must-NOT-wait list, the WF-STOP-N2 integration source swap, the router dedupe key normalization, the SkotiqButton disabled semantics) and try to refute each with an adjacent counter-input at HEAD (throwaway tests under /tmp only; no repo edits). Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'G:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
])

const ok = results.filter(Boolean)
log(`${ok.length}/3 checkers returned`)
return {
  checkers: ok.length,
  verified: ok.flatMap(r => r.verified).length,
  failed: ok.flatMap(r => r.failed.map(f => ({ role: r.role, ...f }))),
  results: ok,
}
