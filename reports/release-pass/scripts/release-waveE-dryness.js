export const meta = {
  name: 'release-waveE-dryness',
  description: 'Wave E: focused re-verify of the D-fix batches — the dryness test',
  phases: [
    { title: 'Re-drive', detail: '6 focused clusters against the fresh bundle', model: 'opus' },
    { title: 'Refute', detail: '2 refuters over the D-fix claims', model: 'opus' },
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

const DRIVE_CHARTER = `You are the DRYNESS check for the Skotiq release pass: the campaign ends when you find nothing new. Drive the FRESH release bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER the subcommand; 'wheel' command available; role-based [DISABLED]; the AT-SPI tree can lag navigation by tens of seconds — re-dump before judging). One graphify query first. Verify EXACTLY the assigned D-fix items against their Wave-D evidence (reports/release-pass/waveD-result.json + reports/release-pass/impl/dfix-*.md list what was claimed fixed and how); classify verified_fixed / still_broken with evidence. Then ONE adversarial sweep pass of your screens for anything the fixes broke. Report to reports/release-pass/gui/waveE-<cluster>.md. Do not fix anything.`

const CLUSTERS = [
  { key: 'sequencing-autopilot', display: ':81', ids: 'SEQ-12 hardened ownership (arm autopilot, start a manual run AT the tick boundary if you can time it, and after an operator stop of an autopilot run), SEQ-13 (edit target coords, Re-evaluate must use them), SEQ-18 (node card N/N after success), SEQ-19 (one filter story), SEQ-20 (elapsed in seconds), WD-SEQ-N1 (operator Stop = no error banners AND no critical notification — check the bell), WD-SEQ-N2 (900px builder), WD-SEQ-N4, WD-SEQ-N6 (armed-autopilot warning), SCI-43 preflight copy' },
  { key: 'imaging-stacking-polar', display: ':82', ids: 'ND-1 (stack 20+ frames — counters must move; Stop dialog reports truthfully), IMG-4 (failed solve must not show green), IMG-13 (slew headline), IMG-14 (log must show -fov on solves now), IMG-16 (post-run bullseye plots the final measurement), ND-2, ND-3, ND-6 (master save format honesty), IMG-9/IMG-10 residuals' },
  { key: 'equipment-chrome', display: ':83', ids: 'WD-EQ-1 (connect mount+focuser+wheel: heartbeats must show real ages), WD-EQ-2/3/3b/4/5/6, CON-46/49/51/52/53/54/55/56/58/59/62/63 spot-checks, CON-61 whatever in-widget half landed (read the dfix impl log first)' },
  { key: 'settings-pairing', display: ':84', ids: 'WD-N1..N9, SET-2/12/18 residuals; pair + revoke-all flow end to end' },
  { key: 'sky-planetarium', display: ':85', ids: 'SKY-4/10/16, D-1..D-4; guide-graph Time/Scale selectors must announce as buttons (Guiding screen)' },
  { key: 'science-collab', display: ':86', ids: 'WD-SCI-N1..N5, WD-COL-N1..N4, COL2-3/13 resolution, CON-45/48, NEW-C2/C3/C4' },
]

const REFUTERS = [
  { key: 'dfix-behavior', hint: 'Sample 8 of the boldest D-fix behavior claims from reports/release-pass/impl/dfix-*.md (autopilot run-ownership token, SEQ-13 live coords, ND-1 counters, sequenceStopped classification, SCI-48 base-name sparing, frame-verdict integration total). Attack each with an adjacent input at HEAD via throwaway tests under /tmp.' },
  { key: 'dfix-regression', hint: 'Hunt collateral damage: diff the D-fix commits (git log --oneline, the dfix batch), pick the 6 highest-blast-radius changes (notification category enum, scheduler ownership, stacking service), and try to construct a regression the batch tests would miss (e.g. a consumer of sequenceFailed that should now see sequenceStopped but still filters on failed; a third-party transport switch with a default that silently drops the new category).' },
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
