export const meta = {
  name: 'release-c3-splits',
  description: 'Wave C3: the mechanical file splits from the Wave A map, per subsystem',
  phases: [
    { title: 'Split', detail: '10 subsystem batches, shared tree, strict file ownership', model: 'opus' },
  ],
}

const SPLIT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['batch', 'split', 'skipped', 'blocked', 'tests', 'files_touched'],
  properties: {
    batch: { type: 'string' },
    split: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['file', 'into', 'lines_before'], properties: { file: { type: 'string' }, into: { type: 'array', items: { type: 'string' } }, lines_before: { type: 'integer' } } } },
    skipped: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['file', 'why'], properties: { file: { type: 'string' }, why: { type: 'string' } } } },
    blocked: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['file', 'why'], properties: { file: { type: 'string' }, why: { type: 'string' } } } },
    tests: { type: 'string' },
    files_touched: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const CHARTER = `You are a refactoring engineer in the Skotiq release pass (Flutter/Dart melos monorepo + Rust via FRB). Repo root is the cwd. The tree is GREEN at HEAD — full gates passed. Your job is ONLY mechanical file splits: the oversized files in your scope, split along the seam plans in the Wave A map reports (reports/release-pass/map/<subsystem>.md). C1/C2 already deleted and consolidated heavily — re-measure before splitting: any file now under the threshold (Dart 1000 lines, Rust 1500) is SKIPPED with its current line count recorded.

FIRST ACTIONS: (1) one \`graphify query\` (hook requires it); (2) read your subsystem's map report split plan; (3) wc -l your candidate files at HEAD.

RULES (strictly behavior-preserving):
- Splits move code verbatim: extensions/parts/modules out of the giant, imports adjusted, visibility widened only where the move demands it (record each widening). NO logic edits, NO renames of public symbols, NO signature changes.
- Dart: prefer part/part-of or extension files matching the existing codebase idiom for that package (look at how sequence_executor/ was already split into operations files). Rust: child modules in a directory, pub(crate) where needed.
- Generated files, FRB bindings, and anything the map marks as pending-deletion are UNTOUCHABLE. If a split would require FRB regeneration, skip it and record why.
- Existing tests pass UNCHANGED except import lines. Run the owning package's full test suite before returning.
- FORBIDDEN: git writes, melos commands, repo-wide formatters (format only files you touch).
- Log to reports/release-pass/impl/c3-<batch>.md. Your final message is machine-read: return ONLY the structured result.`

const BATCHES = [
  { key: 'rust-sequencer-instructions', scope: 'native/skotiq_native/sequencer/src/instructions.rs (11.7k baseline) + its module tree' },
  { key: 'rust-sequencer-executor', scope: 'native/skotiq_native/sequencer/src/executor/mod.rs (11.2k baseline) + triggers.rs (4.5k)' },
  { key: 'rust-bridge-imaging', scope: 'native/skotiq_native/bridge/src/api/imaging.rs (7.4k baseline)' },
  { key: 'rust-bridge-rest', scope: 'native/skotiq_native/bridge/src/** other >1500-line files per the map (NOT api/imaging.rs)' },
  { key: 'rust-devices', scope: 'native/skotiq_native/{indi,alpaca,ascom,native}/** files >1500 lines per the map' },
  { key: 'core-services', scope: 'packages/skotiq_core/lib/src/services/** files >1000 lines per the map (sequence_executor.dart itself belongs to core-providers)' },
  { key: 'core-providers-models', scope: 'packages/skotiq_core/lib/src/{providers,models,repositories,database}/** files >1000 lines per the map' },
  { key: 'app-screens', scope: 'packages/skotiq_app/lib/screens/** files >1000 lines per the map (headless handlers belong to shells)' },
  { key: 'shells-headless', scope: 'apps/desktop/lib/headless_api/** files >1000 lines per the map (sequencer_handlers.dart 2.3k baseline etc.)' },
  { key: 'planetarium-ui', scope: 'packages/skotiq_planetarium/** and packages/skotiq_ui/** files >1000 lines per the map' },
]

phase('Split')
const results = await parallel(BATCHES.map(b => () =>
  agent(
    `${CHARTER}\n\nBATCH: ${b.key}\nSCOPE: ${b.scope}`,
    { label: `c3:${b.key}`, phase: 'Split', schema: SPLIT_SCHEMA, model: 'opus', effort: 'high' }
  )
))

const ok = results.filter(Boolean)
log(`${ok.length}/${BATCHES.length} batches returned`)
return {
  batches_returned: ok.length,
  files_split: ok.flatMap(r => r.split).length,
  skipped: ok.flatMap(r => r.skipped.map(s => ({ batch: r.batch, ...s }))).length,
  blocked: ok.flatMap(r => r.blocked.map(s => ({ batch: r.batch, ...s }))),
  results: ok,
}
