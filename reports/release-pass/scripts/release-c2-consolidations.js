export const meta = {
  name: 'release-c2-consolidations',
  description: 'Wave C2: the cross-package consolidations from Wave A delta 1, serialized',
  phases: [
    { title: 'Consolidate', detail: '6 topics, one agent each, run in sequence (topics share files)', model: 'opus' },
  ],
}

const C2_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['topic', 'consolidated', 'skipped_fp', 'blocked', 'tests', 'files_touched'],
  properties: {
    topic: { type: 'string' },
    consolidated: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['what', 'call_sites', 'proof'], properties: { what: { type: 'string' }, call_sites: { type: 'integer' }, proof: { type: 'string' } } } },
    skipped_fp: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['what', 'why'], properties: { what: { type: 'string' }, why: { type: 'string' } } } },
    blocked: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['what', 'why'], properties: { what: { type: 'string' }, why: { type: 'string' } } } },
    tests: { type: 'string' },
    files_touched: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const CHARTER = `You are a consolidation engineer in the Skotiq release pass (Flutter/Dart melos monorepo + Rust via FRB). Repo root is the cwd. The tree is GREEN at HEAD — full melos + cargo + custom gates passed before this wave. You run ALONE on the tree (topics are serialized), so you may edit across packages freely within your topic.

FIRST ACTIONS: (1) one \`graphify query\` (a PreToolUse hook requires it — comply once); (2) read the Wave A map reports under reports/release-pass/map/ that name your topic (start with the cross-cutting duplication report and sequencing.md); (3) read the "Wave A findings (adjudicated)" section of reports/release-pass/RELEASE-PASS-2026-08-11.md — its overrides win over the raw reports.

RULES (behavior-preserving is the whole point):
- One canonical implementation per topic, all call sites re-pointed. FRESH proof for every call site you retire (grep + graphify; watch headless routes, FRB exports, registries, string lookups, tests).
- Divergent call sites are NOT silently unified: if two formatters genuinely differ (rounding, padding, units), either parameterize the canonical one to reproduce both behaviors exactly, or leave the divergent site alone and record it. The C1 wave's mad_sigma non-adoption note in robust_stats.rs is the standard to meet.
- Add parity tests: for each consolidated helper, a test that pins the exact output the retired copies produced (sample inputs incl. edge cases: negative angles, >24h durations, zero, NaN where representable).
- Existing tests pass unchanged (imports excepted). No behavior change, no file splits, no renames beyond the new shared module files.
- FORBIDDEN: git write commands, melos commands, repo-wide formatters (format only files you touch), editing generated files. If FRB regeneration would be needed, stop that item and record blocked.
- Keep a log at reports/release-pass/impl/c2-<topic>.md.
- Your final message is machine-read: return ONLY the structured result.`

const TOPICS = [
  { key: 'astronomy-sidereal', brief: 'The ~14 sidereal-time / astronomy-math duplicates across Dart packages (and any Rust twin the map names): one canonical module in skotiq_core, parity-tested against every retired copy. LST, JD, GMST, obliquity, alt/az conversions.' },
  { key: 'coordinate-formatters', brief: 'The ~39 RA/Dec coordinate formatter copies: one canonical formatter set (sexagesimal RA h/m/s, Dec ±d/m/s, degree variants) in skotiq_core, parameterized for the real presentation differences. The CoordinateFormat seconds-carry fix from C1 is the canonical base — do not fork it.' },
  { key: 'format-duration', brief: 'The ~30 _formatDuration copies across screens: one shared duration formatter honoring the sub-minute-renders-seconds rule the sequencing B-fix introduced (SEQ-20). Kill the "0m" class everywhere the copies lived.' },
  { key: 'device-registry', brief: 'The device-registry collapse the map proposes: one registry, the six unpopulatable bridge registries removed only if the Wave A owner-decision items do not protect them — check the doc section "Owner decisions" first; anything listed there is OFF LIMITS.' },
  { key: 'phd2-registry-split', brief: 'The PHD2 registry split named in the map (separate the client registry from the guider-state registry). Behavior-preserving; the phd2 framing/reassembly tests from C1/B-fix must pass unchanged.' },
  { key: 'wcs-conformance', brief: 'The WCS conformance fixture: one shared test fixture (golden WCS headers + expected parses) that the Dart parser tests and Rust parser tests both consume, so the two implementations can never drift apart silently again. Include the .wcs 80-char-card cases C1 fixed.' },
]

phase('Consolidate')
const results = []
for (const t of TOPICS) {
  const r = await agent(
    `${CHARTER}\n\nTOPIC: ${t.key}\n${t.brief}`,
    { label: `c2:${t.key}`, phase: 'Consolidate', schema: C2_SCHEMA, model: 'opus', effort: 'high' }
  )
  if (r) results.push(r)
  log(`${t.key} done (${results.length}/${TOPICS.length})`)
}

return {
  topics_returned: results.length,
  consolidated: results.flatMap(r => r.consolidated.map(c => ({ topic: r.topic, ...c }))),
  blocked: results.flatMap(r => r.blocked.map(b => ({ topic: r.topic, ...b }))),
  results,
}
