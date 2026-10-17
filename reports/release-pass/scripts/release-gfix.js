export const meta = {
  name: 'release-gfix',
  description: 'G-fix: close the Wave G refutations — the wire-shape tally, the claim release hole, the toast producers',
  phases: [
    { title: 'Fix', detail: '3 surgical batches from the G verdict', model: 'opus' },
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

const CHARTER = `You are closing the Wave G refutations in the Skotiq release pass. Tree GREEN at HEAD. Your evidence is reports/release-pass/waveG-result.json — the refuter's entries name exact files, lines, wire paths, and provide throwaway tests under /tmp/claude-1000/.../scratchpad/ that you MUST adopt into the repo as the failing tests. The G drivers' entries carry live screenshots and repro traps (e.g. the WD-EQ-3 second toast lands between 3s and 5s — a short-wait check reads as fixed). One graphify query first. Failing test FIRST, encoding the refuter's exact counter-input (the REAL wire shape, not a convenient one). NO GUI harness, NO bundle rebuilds, NO git writes, NO melos, NO repo-wide formatters, NO generated files, NO FRB regen unless an item explicitly weighs it (then stop + record blocked with the exact delta). Log to reports/release-pass/impl/gfix-<batch>.md. Final message: ONLY the structured result.`

const BATCHES = [
  { key: 'tally-wire', items: 'SEQ-18 SIXTH and final look, from the refutation: (1) node_exposure_tally must decode detail_json as the STRING production sends (reuse _decodeStructuredProgressJson or jsonDecode like event_operations.dart:521), with the adopted refuter test asserting the wire-string shape; (2) the id-less ExposureCompleted fallback commits join-by-position at node boundaries — either thread node_id onto the wire event (weigh FRB regen; if needed, STOP and record the exact delta) or drop the fallback entirely and key the tally ONLY on node-addressed structured progress (the safer likely answer — the boundary test from the refuter must pass: node1 3/4 must NOT happen); (3) update exposure_card_wave_f_events_test to feed the REAL wire shape so it can never pass on a shape production never sends.', scope: 'packages/skotiq_core/lib/src/providers/sequence/** (+ tests)' },
  { key: 'claim-release', items: 'The camera-claim release hole from the refutation: executor/start.rs Autofocus arm releases the claim only in the (Some,Some) camera+focuser branch; the `_ =>` skip branch (start.rs:~3954) falls through with no clear_camera_busy so the capture loop waits out the ten-minute expiry. Restructure so the claim is released on EVERY exit of every camera-driving arm (RAII guard or a single release point after the match). The refuter enumerated the branches — cover each with a test in the existing every_camera_driving_trigger_action test module.', scope: 'native/skotiq_native/sequencer/src/executor/** (+ tests)' },
  { key: 'toast-producers', items: 'From the G drivers: (1) the RED "Sequence Error / Sequence cancelled" toast is BACK beside the info stop toast — a differently-worded error-classified producer shows through; trace which producer emits it on an operator stop (the classification was fixed for the router path; this one bypasses it) and route it through the same outcome gate, failing-test-first; (2) WD-EQ-3: the trailing-punctuation-normalized dedupe key does NOT collapse its own target pair live — find why (different transport? key computed before normalization? per-producer instance?) and fix WHERE THE TOASTS ACTUALLY FLOW, with a test reproducing the two exact strings 2s apart; (3) RECENT EVENTS still triplicates the stop — dedupe the feed writer the same way; (4) the two layout residuals: Templates title truncation (the shrink floor never reaches this caller) and the connected-dashboard prompt painting over RECENT EVENTS at 1000x800 (the G evidence has exact geometry).', scope: 'packages/skotiq_core/lib/src/services/notification/**, packages/skotiq_app/lib/screens/{sequencer,dashboard,equipment}/**, packages/skotiq_app/lib/widgets/**' },
]

phase('Fix')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nITEMS: ${b.items}\nSCOPE: ${b.scope}`,
    { label: `gfix:${b.key}`, phase: 'Fix', schema: FIX_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const ok = results.filter(Boolean)
log(`${ok.length}/${BATCHES.length} batches returned`)
return {
  batches_returned: ok.length,
  fixed: ok.flatMap(r => r.fixed).length,
  false_positives: ok.flatMap(r => r.false_positives.map(f => ({ batch: r.batch, ...f }))),
  blocked: ok.flatMap(r => r.blocked.map(f => ({ batch: r.batch, ...f }))),
  results: ok,
}
