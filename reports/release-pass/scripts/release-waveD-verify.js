export const meta = {
  name: 'release-waveD-verify',
  description: 'Wave D: live GUI re-drive + adversarial verification of every fix wave',
  phases: [
    { title: 'Re-drive', detail: '8 GUI clusters against the fresh bundle with the fixed a11y dump', model: 'opus' },
    { title: 'Refute', detail: 'one adversarial verifier per fix wave, sampling the boldest claims', model: 'opus' },
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

const DRIVE_CHARTER = `You are an adversarial GUI verifier for the Skotiq release pass. Drive the FRESH release bundle at apps/desktop/build/linux/x64/release/bundle/skotiq_desktop via tools/ui_audit/drive_linux.py (Xvfb, softpipe; profile AFTER the subcommand: 'start --fresh --profile <yours>'; the harness now has a 'wheel x y notches' command and role-based [DISABLED] reporting — trust the dump this time). One graphify query first (hook). Your PRIMARY job: for each finding ID assigned below, run its exact repro from the original cluster report (reports/release-pass/gui/<cluster>.md) and classify VERIFIED_FIXED (behavior now correct, say what you saw) or STILL_BROKEN (evidence). Your SECONDARY job: adversarial sweep for NEW defects the fixes may have introduced (banner order, layout at 1600x900 and one narrow width, semantics states). Write your report to reports/release-pass/gui/waveD-<cluster>.md as you go. Do not fix anything. Screenshots are expensive — prefer the a11y tree; budget ~30 image reads.`

const CLUSTERS = [
  { key: 'imaging-spine', display: ':81', ids: 'IMG-1, IMG-8, IMG-12, IMG-4, IMG-14 (hinted solves now — check the log shows -ra/-fov args), IMG-9, IMG-10, IMG-13, IMG-18, IMG-19, IMG-21, IMG-2, IMG-3, IMG-16; plus SCI-27 (stacked preview must show a stretched sky, not black) and SCI-28 (Stop must offer Save master)' },
  { key: 'sequencing', display: ':82', ids: 'SEQ-12 (arm autopilot then start a manual run — it must survive the tick), SEQ-13, SEQ-14, SEQ-3, SEQ-15 (slew now confirms/locks/logs), SEQ-16, SEQ-6 (outcome vocabulary), SEQ-17, SEQ-18, SEQ-19, SEQ-20 (sub-minute durations), SCI-43 wizard copy' },
  { key: 'equipment-shell', display: ':83', ids: 'EQP-1 (heartbeats), EQP-10 (one device count), EQP-11, EQP-12, EQP-13, EQP-18, EQP-19, EQP-21, EQP-22, CON-44 (nudge floats — screens full height on first run), CON-60, CON-61 (title bar in the a11y tree; person icon), CON-61b (settings deep-link while open)' },
  { key: 'settings-onboarding', display: ':84', ids: 'SET-17 (fresh install shows NO inherited pairings + Revoke all exists), SET-1, SET-3, SET-9, SET-8, SET-12, SET-18, SET-23, SET-2, SET-5, SET-11, IMG-1 (onboarding path revalidates)' },
  { key: 'sky-discovery', display: ':85', ids: 'SKY-2 (region create completes and dialog closes), SKY-1 (pause freezes the clock — measure 60s), SKY-5 (Dashboard clock unaffected by planetarium scrub), SKY-6 (M31 renders extended at 2 deg FOV), SKY-3, SKY-7, SKY-8 (tooltips anchored + retire), SKY-15; PLUS the JD+0.5 repro: read the planetarium LST/time readout and any surface that uses CelestialCoordinate.toHorizontal (sky_view tap readouts?) and cross-check alt/az of a known object against the details panel — a ~12h sidereal discrepancy between two surfaces confirms the dormant bug; record findings, do NOT fix' },
  { key: 'science-review', display: ':86', ids: 'SCI-38, SCI-37, SCI-22, SCI-44, SCI-34, SCI-46 (quick captures appear in Diagnostics picker), SCI-42 (warning printed once), SCI-36, SCI-41, SCI-48 (capture folder stays clean of .ini after solves)' },
  { key: 'collab-catalogs', display: ':87', ids: 'COL2-16 (create works or says why inline), COL2-17, COL2-15 (RA-seam preview counts panels correctly), COL2-1, COL2-2, COL2-3, COL2-7, COL2-11, COL2-13; mosaic resume banner renders ABOVE the panel-size warning' },
  { key: 'consistency', display: ':88', ids: 'CON-45..CON-63 spot checks per the wave-2 report; the AccessibleDropdown semantics on 3 sampled screens; hunt the test-asset writer: run nothing, but note if the app itself writes assets/screenshots/ or docs/design/goldens/ during a session' },
]

const WAVES = [
  { key: 'C1', source: 'reports/release-pass/impl/ (C1 batch logs) + commits 3e1be6cdc..7aadcacce', hint: 'Sample 8 of the boldest BUG claims (frames-rejected verdicts, .wcs card parsing, save_fits precedence, PHD2 split-frame reassembly, INDI writer-death state). Refute against HEAD: does the claimed fix actually hold under an input the batch did not test? Watch for RELOCATED defects (the moved-threshold pattern).' },
  { key: 'B-fix', source: 'reports/release-pass/impl/bfix-*.md + commits e1f10a24b..b17655239', hint: 'Sample 8 P0/P1 fixes (SEQ-12 autopilot ownership, SKY-2 dialog completion, SCI-39 unknown-location gate, EQP-1 heartbeats). Try inputs adjacent to the tested ones: autopilot tick racing a run START (not mid-run), region create with a failing backend, location set-then-cleared.' },
  { key: 'C2+S2', source: 'reports/release-pass/impl/c2-*.md + s2-*.md', hint: 'Sample the consolidations: pick 5 retired call sites and diff their parity tests against the ORIGINAL bodies in git history (git show <pre-C2>:<file>) — is the transcription faithful? Then the stage-2 fixes: does saveMaster actually write before release (order proven?), does the debris sweep spare pre-existing sidecars?' },
]

phase('Re-drive')
const drives = parallel(CLUSTERS.map(c => () =>
  agent(
    `${DRIVE_CHARTER}\n\nCLUSTER: ${c.key} (display ${c.display}, profile waveD-${c.key})\nFINDING IDS TO VERIFY: ${c.ids}`,
    { label: `D:drive:${c.key}`, phase: 'Re-drive', schema: DRIVE_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const refutes = parallel(WAVES.map(w => () =>
  agent(
    `You are an adversarial verifier for the Skotiq release pass. One graphify query first (hook). Wave under audit: ${w.key}. Sources: ${w.source}. ${w.hint} For each sampled claim: try to REFUTE it with a concrete test or counter-input run at HEAD (you may write throwaway tests under /tmp, never in the repo). Report refuted (with how) vs holds. Do not fix anything; do not edit the repo. Your final message is machine-read: return ONLY the structured result.`,
    { label: `D:refute:${w.key}`, phase: 'Refute', schema: REFUTE_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const [driveResults, refuteResults] = await Promise.all([drives, refutes])
const d = driveResults.filter(Boolean), rf = refuteResults.filter(Boolean)
log(`${d.length}/8 clusters re-driven, ${rf.length}/3 waves refuted`)
return {
  clusters: d.length,
  verified_fixed: d.flatMap(x => x.verified_fixed).length,
  still_broken: d.flatMap(x => x.still_broken.map(s => ({ cluster: x.cluster, ...s }))),
  new_findings: d.flatMap(x => x.new_findings.map(n => ({ cluster: x.cluster, ...n }))),
  refuted: rf.flatMap(x => x.refuted.map(r => ({ wave: x.wave, ...r }))),
  claims_held: rf.flatMap(x => x.holds).length,
  results: { drives: d, refutes: rf },
}
