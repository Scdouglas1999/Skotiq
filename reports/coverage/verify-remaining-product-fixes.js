export const meta = {
  name: 'skotiq-verify-remaining-product-fixes',
  description: 'Adversarially verify the 73 product fixes that no verifier ever reached',
  phases: [
    { title: 'Refute', detail: 'one verifier per shard of ~6 fixes, told to break them' },
  ],
}

const SHARDS = [
  'analytics-1', 'analytics-2', 'equipment', 'imaging', 'planetarium',
  'planning', 'science', 'seqrun', 'sequencer', 'settings-general',
  'settings-system', 'widgets', 'wizards-1', 'wizards-2',
  // Eight items an earlier pass DID verify, whose verdict files were overwritten
  // when this run's shard names collided with the old per-area filenames. The
  // records are gone; re-verifying is cheaper and more honest than
  // reconstructing them from a summary.
  'recovered',
]

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['shard', 'items'],
  properties: {
    shard: { type: 'string' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'verdict', 'reasoning'],
        properties: {
          title: { type: 'string' },
          verdict: {
            type: 'string',
            enum: ['HOLDS', 'INCOMPLETE', 'RELOCATED', 'DISCLOSURE-ONLY', 'INVERTED', 'REGRESSION', 'NOT-APPLIED'],
          },
          reasoning: { type: 'string' },
          evidence: { type: 'string' },
          severedCallSite: { type: 'boolean' },
          repaired: { type: 'boolean' },
          repairSummary: { type: 'string' },
        },
      },
    },
    regressionsFound: { type: 'array', items: { type: 'string' } },
    blockedOnSharedCode: { type: 'array', items: { type: 'string' } },
    testsRun: { type: 'string' },
  },
}

function brief(shard) {
  return `You are an ADVERSARIAL VERIFIER on the Skotiq astrophotography app (Flutter/Dart monorepo + Rust via flutter_rust_bridge), repo root /home/scdouglas/Documents/Skotiq2.

A previous wave landed fixes for product-critique findings (UX / wrong-default / missing-capability). Your job is to REFUTE them, not to admire them. Every earlier verify pass in this campaign refuted roughly one fix in six, so a shard where everything holds is possible but should make you look harder before you believe it.

## Your input
\`reports/coverage/verify-product/shards/${shard}.json\` — a small JSON array (this is YOUR shard and no other agent has it). Each entry has the fixer's own \`title\` and \`summary\`: their claim about what they changed and why. Work every entry.

Write your verdicts INCREMENTALLY to \`reports/coverage/verify-product/verdict-${shard}.json\` (a JSON array) as you finish each item — rewrite the whole file each time with everything decided so far. Do NOT hold them to emit at the end: context-heavy agents die at exactly that moment and the whole shard is lost. Your structured return value should repeat what is in that file.

## Orientation (required)
This repo has a knowledge graph. Run \`graphify query "<question>"\` to orient BEFORE grepping or reading source files; \`graphify explain "<concept>"\` for a focused concept; \`graphify path "<A>" "<B>"\` for a relationship. Only read raw files after graphify has pointed you at them, or to inspect specific lines.

## What to check, in order
For each item:

1. **Does the code actually contain the claim?** In this campaign's earlier waves ~38% of P0/P1 findings cited a \`file:line\` that did not contain what was claimed — one pointed at a file with no weather or safety code at all. Open the file. If the summary describes code that is not there, the verdict is NOT-APPLIED.

2. **Does the fix address the CAUSE, or only disclose / relocate it?** These are the recurring failure shapes, each actually observed in this campaign:
   - **DISCLOSURE-ONLY** — the app now *says* the thing is broken instead of not being broken; a label change where behaviour was the complaint.
   - **RELOCATED** — the defect moved rather than went away: a threshold nudged, a poll period matched to a timer, one false claim swapped for a different false claim.
   - **INCOMPLETE** — one of several call sites fixed, or it works on the path the fixer tested and not the others. Real example from this shard's own wave: an empty-state fix covered three surfaces and missed a fourth, in a file whose own comment called it "the third copy of the bug". Another: a thumbnail rail was given wheel scrolling with a bare \`Listener\`, which does not CONSUME the pointer signal, so one wheel notch scrolled the rail AND the page under it.
   - **INVERTED** — the fix creates the opposite failure. Real example: a scheduler fix made a filter-wheel-less rig unschedulable the moment the operator followed the app's own on-screen prompt.

3. **Sever the wiring, not the logic.** If the fix ships a test, check that the test fails when the PRODUCTION CALL SITE is cut — not merely when logic inside the function changes. A batch was caught here whose entire production wiring could be deleted with all 434 tests still green. Actually do it: comment out the call, run the test, confirm red, restore. Set \`severedCallSite\` and say in \`evidence\` what happened. If a fix ships no test at all, that alone is not a verdict — judge the code — but note it.

4. **Did the fix break something else?** Run the tests covering the files it touched and report anything in \`regressionsFound\`. One fix in this wave added a third element to a Row header and overflowed the Equipment screen by 24px at 360dp — caught only because a non-golden mobile-layout test failed two files away.

## Running tests
From the repo root: \`dart run melos exec --scope="<package>" -- flutter test <path>\`. Do NOT run \`flutter test packages/<pkg>/...\` from the root — it fails with a flutter_test dependency error. Package names: skotiq_app, skotiq_core, skotiq_ui, skotiq_desktop, skotiq_planetarium, skotiq_bridge. Redirect long runs to a file rather than piping through \`tail\`, which destroys the failure detail.

If a widget test you add gives a scope a real (in-memory) database, disposing it makes drift schedule a ZERO-DURATION timer in \`StreamQueryStore.markAsClosed\` and the binding fails with \`'!timersPending'\` against whatever assertion ran last. A \`tearDown\` cannot fix it (the binding checks first) and neither can a bare \`pump()\`. Use \`settleProviderTeardown(tester)\` from \`packages/skotiq_app/test/harness/provider_teardown.dart\`.

## Repairing
If a verdict is anything other than HOLDS and the repair is CONFINED to the area you are verifying, fix it properly, set \`repaired: true\` with a \`repairSummary\`, and add or strengthen a test that fails when the fix is reverted. If the repair would touch shared or foundational code that other areas use, do NOT edit it — describe it precisely in \`blockedOnSharedCode\` so it can be handled without two agents editing one file.

Run \`dart format\` on every file you edit. NEVER run \`git stash\`, \`git checkout\`, or \`git restore\` — thirteen other agents are working in this same tree and it will destroy their work.

## Honesty rules
- HOLDS must be earned by looking, not inferred from the summary being well written.
- If something cannot be verified without hardware, a live paired appliance, or an on-sky run, say so in \`reasoning\` and pick the closest honest verdict rather than HOLDS.
- Do not invent a defect to look thorough.`
}

phase('Refute')

const results = await parallel(
  SHARDS.map((shard) => () =>
    agent(brief(shard), {
      label: `verify:${shard}`,
      phase: 'Refute',
      schema: SCHEMA,
    })
  )
)

const ok = results.filter(Boolean)
const all = ok.flatMap((r) => r.items || [])
const tally = {}
for (const item of all) {
  tally[item.verdict] = (tally[item.verdict] || 0) + 1
}

log(`${all.length} fixes verified across ${ok.length}/${SHARDS.length} shards`)

return {
  verified: all.length,
  shardsReporting: ok.length,
  shardsLost: SHARDS.filter((s, i) => !results[i]),
  tally,
  regressions: ok.flatMap((r) => r.regressionsFound || []),
  blockedOnSharedCode: ok.flatMap((r) => r.blockedOnSharedCode || []),
  notHolding: all.filter((i) => i.verdict !== 'HOLDS').map((i) => ({
    title: i.title,
    verdict: i.verdict,
    repaired: i.repaired === true,
    reasoning: (i.reasoning || '').slice(0, 700),
    repairSummary: (i.repairSummary || '').slice(0, 500),
  })),
}
