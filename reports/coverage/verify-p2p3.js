export const meta = {
  name: 'skotiq-verify-p2p3',
  description: 'Reproduce the 120 unverified P2/P3 defects against a REBUILT bundle',
  phases: [{ title: 'Verify', detail: 'one agent per area, told to refute' }],
}

// Two reasons this runs AFTER the fix waves and a rebuild, not before:
//  * a finding that a fix has already closed must come back REFUTED, and it only
//    can if the binary under test contains the fix;
//  * the P0/P1 pass showed 21 of 55 findings cited the WRONG file:line even when
//    the symptom was real, so "where" is not trustworthy input to a fixer until
//    somebody has checked it.
const BATCHES = [
  { key: 'v2-analytics', src: 'r-analytics', display: ':81', n: 22 },
  { key: 'v2-planetarium', src: 'r-planetarium', display: ':82', n: 18 },
  { key: 'v2-settings-system', src: 'r-settings-system', display: ':83', n: 17 },
  { key: 'v2-settings-general', src: 'r-settings-general', display: ':84', n: 14 },
  { key: 'v2-shared-widgets', src: 'r-shared-widgets', display: ':85', n: 13 },
  { key: 'v2-science-review', src: 'r-science-review', display: ':86', n: 13 },
  { key: 'v2-wizards', src: 'r-wizards', display: ':87', n: 12 },
  { key: 'v2-sequencer-run', src: 'r-sequencer-run', display: ':88', n: 11 },
]

const BRIEF = `
# YOU ARE AN ADVERSARIAL VERIFIER. DEFAULT TO REFUTED.

Assume each claim is wrong until you reproduce it yourself in the running app. On the P0/P1 pass
9% of findings were refuted outright and 38% cited a file:line that did not contain what was
claimed — and a wrong location is WORSE than a false positive, because it sends a fixer into
unrelated code. So check the location too, not just the symptom.

The bundle you are driving was REBUILT after several fix waves. A finding that has since been fixed
must come back REFUTED with a note saying so — that is a correct and useful result, not a failure.

Per finding, return exactly one verdict:
  CONFIRMED — you reproduced it yourself
  REFUTED   — it does not reproduce, the code does not say that, the reasoning does not hold, or it
              has already been fixed
  UNCLEAR   — you could not reach it; say precisely what blocked you. Not a hedge for "probably
              real".
Also correct the severity if it is wrong in either direction, and flag a wrong "where".

# HOW TO DRIVE
Read tools/ui_audit/README.md. The release bundle is ALREADY BUILT — do NOT run flutter build or
cargo build; other agents share this machine.

  env SK_AUDIT_DISPLAY=<DISPLAY> python3 tools/ui_audit/drive_linux.py start --profile <PROFILE> --fresh
  env SK_AUDIT_DISPLAY=<DISPLAY> python3 tools/ui_audit/drive_linux.py tree
  env SK_AUDIT_DISPLAY=<DISPLAY> python3 tools/ui_audit/drive_linux.py shot /tmp/sk-audit/shots/<PROFILE>-NN.png
  env SK_AUDIT_DISPLAY=<DISPLAY> python3 tools/ui_audit/drive_linux.py click-img <that shot> X Y
  env SK_AUDIT_DISPLAY=<DISPLAY> python3 tools/ui_audit/drive_linux.py stop --profile <PROFILE>

CONTEXT BUDGET — this is what killed four agents earlier: a screenshot costs ~2000 tokens and one
agent read 140. Use \`tree\` (text, nearly free) for state; screenshot only for layout or rendering
questions. Budget ~30 image reads for the whole batch. \`click-img\` takes coordinates AS MEASURED IN
THAT IMAGE; \`click-xy\` takes root coordinates and would land elsewhere.

For any finding about a NUMBER, recompute it yourself from the scratch DB
(/tmp/sk-audit/<PROFILE>/data/skotiq.db) or by hand. Comparing two of the app's own readouts
proves nothing about which is right.

WRITE AS YOU GO: append each verdict to reports/coverage/verdicts/<YOUR KEY>.json the moment you
decide it. Agents here have died mid-report and that file is what survives.
`

const SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'verdict', 'reasoning'],
        properties: {
          title: { type: 'string' },
          verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED', 'UNCLEAR'] },
          reasoning: { type: 'string' },
          corrected_severity: { type: 'string' },
          location_wrong: { type: 'string' },
          already_fixed: { type: 'boolean' },
        },
      },
    },
  },
}

phase('Verify')

const results = await parallel(
  BATCHES.map((b) => () =>
    agent(
      `Verify ${b.n} unverified P2/P3 defect claims about the Skotiq astrophotography app.

Display: ${b.display}
Profile: ${b.key}
Claims to attack: reports/coverage/verify/${b.src}.json — read it first. Take only the entries whose
severity is P2, P3 or P4 and whose kind is "defect"; the P0/P1s in that file are already verified.
Write verdicts to: reports/coverage/verdicts/${b.key}.json

${BRIEF}

Return every verdict. Stop the app when done.`,
      { label: `verify:${b.key}`, phase: 'Verify', schema: SCHEMA },
    ),
  ),
)

const all = results.filter(Boolean).flatMap((r) => r.verdicts || [])
const tally = all.reduce((a, v) => ({ ...a, [v.verdict]: (a[v.verdict] || 0) + 1 }), {})
log(`${results.filter(Boolean).length}/${BATCHES.length} batches returned, ${all.length} verdicts`)
return { verdicts: all.length, tally, wrong_location: all.filter((v) => v.location_wrong).length }
