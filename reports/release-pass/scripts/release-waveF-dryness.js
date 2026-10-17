export const meta = {
  name: 'release-waveF-dryness',
  description: 'Wave F: re-verify the E-fix batches — the second dryness test',
  phases: [
    { title: 'Re-drive', detail: '6 focused clusters against the fresh bundle', model: 'opus' },
    { title: 'Refute', detail: '2 refuters over the E-fix claims', model: 'opus' },
  ],
}

const DRIVE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['cluster', 'verified_fixed', 'still_broken', 'new_findings', 'report_path'],
  properties: {
    cluster: { type: 'string' }, report_path: { type: 'string' },
    verified_fixed: { type: 'array', items: { type: 'string' } },
    still_broken: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['id', 'evidence'], properties: { id: { type: 'string' }, evidence: { type: 'string' } } } },
    new_findings: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['id', 'severity', 'summary', 'repro'], properties: { id: { type: 'string' }, severity: { type: 'string' }, summary: { type: 'string' }, repro: { type: 'string' } } } },
    notes: { type: 'string' },
  },
}

const REFUTE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['wave', 'claims_sampled', 'refuted', 'holds'],
  properties: {
    wave: { type: 'string' }, claims_sampled: { type: 'integer' },
    refuted: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['claim', 'how'], properties: { claim: { type: 'string' }, how: { type: 'string' } } } },
    holds: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const DRIVE_CHARTER = `You are the SECOND DRYNESS check for the Skotiq release pass: the campaign ends when you find nothing new. Drive the FRESH release bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER the subcommand; 'wheel' command available; role-based [DISABLED]; the AT-SPI tree can lag navigation by tens of seconds — re-dump before judging). One graphify query first. Verify EXACTLY the assigned D-fix items against their Wave-D evidence (reports/release-pass/waveE-result.json + reports/release-pass/impl/efix-*.md list what was claimed fixed and how); classify verified_fixed / still_broken with evidence. Then ONE adversarial sweep pass of your screens for anything the fixes broke. Report to reports/release-pass/gui/waveF-<cluster>.md. Do not fix anything.`

const CLUSTERS = [
  { key: 'autopilot-night', display: ':81', ids: 'WE-SEQ-N1 (fail a dispatched run: the next eligible tick MUST dispatch again — check the new reconcile log line says which branch ran), WE-SEQ-N5 (generated plan starts with Unpark; dispatch after a park succeeds), WE-SEQ-N6 (operator stop of an autopilot run records Stopped, no critical), WE-SEQ-N3 (armed warning persists after a dispatch), refuted SEQ-12/SEQ-13 seams per the efix impl logs' },
  { key: 'stop-pipeline', display: ':82', ids: 'WD-SEQ-N1 FULL sweep on an operator stop: toast, Dashboard banner, RECENT EVENTS, target rollup, Session Report — all five must tell the stopped story; WE-SEQ-N4 (no raw Paused-stopped token), SEQ-18 (node card N/N after success — fourth look), WE-SEQ-N2, WE-SEQ-N7 (900px palette/properties toggles)' },
  { key: 'solver-native', display: ':83', ids: 'IMG-14 FINAL CHECK: grep the session log for -fov on polar AND imaging solves (the native path must now receive hint_scale); parked-mount refusal says something; ND-E2 (no concurrent duplicate solves — watch the new follower log line); IMG-9 (auto-select attempt + lock observable in UI and log)' },
  { key: 'equipment-chrome', display: ':84', ids: 'WD-SEQ-N4 (chip renders the engine reason at 9.8deg), WD-EQ-2b/WD-EQ-3/WD-EQ-4 (friendly names in RECENT EVENTS, deduped toasts, Edit Dashboard disabled-with-reason reaching the tree), CON-49/51/52/53/55/56/58/59/62 spot-checks, WE-EQ-N1 (copy names a real tab), WE-EQ-N2/N3/N5/N6; KNOWN-OPEN handoffs that should still be broken (confirm, do not relitigate): the disconnect-toast device id (WD-EQ-2a) and ALL-CAPS NOW/TONIGHT (CON-56) — both awaiting the F-fix closers' },
  { key: 'settings-sky', display: ':85', ids: 'SET-12, WE-SP-1..5, D-2 (tooltips leave the tree — the restored lifecycle test pins the mechanism; verify LIVE), D-3, E-SKY-1/2/3 (transport names + play/pause state + guide-graph label AND value)' },
  { key: 'science-collab', display: ':86', ids: 'NEW-E5 (Night Doctor reads the diagnostics), NEW-E2 (Replay navigation), WD-SCI-N3/N4, WD-COL-N2/N3/N4, COL2-3 (fourth look — the efix impl log records what landed), NEW-C2/C3 in-scope halves, NEW-E1/E3/E4' },
]

const REFUTERS = [
  { key: 'dfix-behavior', hint: 'Sample 8 of the boldest D-fix behavior claims from reports/release-pass/impl/efix-*.md (autopilot run-ownership token, SEQ-13 live coords, ND-1 counters, sequenceStopped classification, SCI-48 base-name sparing, frame-verdict integration total). Attack each with an adjacent input at HEAD via throwaway tests under /tmp.' },
  { key: 'dfix-regression', hint: 'Hunt collateral damage: diff the E-fix commits (git log --oneline, the dfix batch), pick the 6 highest-blast-radius changes (notification category enum, scheduler ownership, stacking service), and try to construct a regression the batch tests would miss (e.g. a consumer of sequenceFailed that should now see sequenceStopped but still filters on failed; a third-party transport switch with a default that silently drops the new category).' },
]

phase('Re-drive')
const drives = parallel(CLUSTERS.map(c => () =>
  agent(
    `${DRIVE_CHARTER}\n\nCLUSTER: ${c.key} (display ${c.display}, profile waveE-${c.key})\nITEMS: ${c.ids}`,
    { label: `E:drive:${c.key}`, phase: 'Re-drive', schema: DRIVE_SCHEMA, model: 'opus', effort: 'high' }
  )
))
const refutes = parallel(REFUTERS.map(w => () =>
  agent(
    `You are an adversarial verifier in the dryness check of the Skotiq release pass. One graphify query first. ${w.hint} Do not edit the repo; throwaway tests under /tmp only. Return ONLY the structured result.`,
    { label: `E:refute:${w.key}`, phase: 'Refute', schema: REFUTE_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const [d, rf] = await Promise.all([drives, refutes])
const dd = d.filter(Boolean), rr = rf.filter(Boolean)
log(`${dd.length}/6 clusters, ${rr.length}/2 refuters returned`)
return {
  clusters: dd.length,
  verified_fixed: dd.flatMap(x => x.verified_fixed).length,
  still_broken: dd.flatMap(x => x.still_broken.map(s => ({ cluster: x.cluster, ...s }))),
  new_findings: dd.flatMap(x => x.new_findings.map(n => ({ cluster: x.cluster, ...n }))),
  refuted: rr.flatMap(x => x.refuted.map(r => ({ wave: x.wave, ...r }))),
  claims_held: rr.flatMap(x => x.holds).length,
  results: { drives: dd, refutes: rr },
}
