export const meta = {
  name: 'release-waveM-close',
  description: 'Wave M: verify the L-response batch — scoped to the five L fixes',
  phases: [
    { title: 'Check', detail: '1 live smoke + 1 refuter over the L-response commit', model: 'opus' },
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
    `You are the live SMOKE check of the Skotiq release pass (Wave M). Drive the fresh bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (profile AFTER subcommand; the AT-SPI tree lags — re-dump before judging; fresh profile opens onboarding: Skip by image coordinates if the tree lacks geometry). One graphify query first. Quick pass:
1. Boot to dashboard, connect sim devices, run a short sequence, press Stop once → ONE "Sequence stopped" row, "Stopped by request", no regression from the L-response.
2. a11y error scan on dashboard + run dashboard.
Write reports/release-pass/gui/waveM-close.md. Do not fix anything. Return ONLY the structured result with role='driver'.`,
    { label: 'M:driver', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
  ),
  () => agent(
    `You are the refuter of the Skotiq release pass Wave M, scoped to the FIVE L-response fixes in the newest commit (git log --oneline -3). One graphify query first. Throwaway tests in an untracked dir, deleted after; no repo edits. Attack ONLY:
(a) the rollback origin: does _rollbackStart's 'rollback' origin reach the native call on BOTH rollback shapes (pre-native-launch — where nativeStopRequired is false and no stop is issued — and partial-launch), and does the Rust "System: stop" arm behave for origin strings like '' or 'operator ' (trailing space)?
(b) the spine rule in _foldStopFamilyRows: can a run-id-bearing member still extend the spine into a stepping-stone chain (id-bearing stoppeds 110s apart of the SAME run are legitimate; of DIFFERENT runs are blocked by id inequality — but what about alternating id-less/id-bearing members)? Is D17's greaterThanOrEqualTo(3) the honest contract or a hedge?
(c) the run-id stamp clear: does the clear race the NEXT run's set (start during a slow finalization tail)? Does a cleanupFailed retry double-clear harmlessly?
(d) the retry origin upgrade: a scheduler retry of an OPERATOR's failed stop must NOT downgrade (verify the guard direction); does the upgrade persist if the retry ALSO fails and a third attempt comes from the scheduler?
(e) anything the five fixes broke in adjacent behavior (the launch-parity and operator-stop suites are the canaries).
Be proportionate: file only what an operator would notice or a maintainer must know. Return ONLY the structured result with role='refuter', verified=holds, failed=refuted-with-evidence.`,
    { label: 'M:refuter', phase: 'Check', schema: CHECK_SCHEMA, model: 'opus', effort: 'high' }
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
