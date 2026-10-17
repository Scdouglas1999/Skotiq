export const meta = {
  name: 'skotiq-mobile-sweep',
  description: 'Sweep the 14 mobile units on a real Android emulator: defects + product critique',
  phases: [{ title: 'Sweep', detail: 'two agents on one emulator, serialised' }],
}

// The last 14 uncovered coverage units. "Needs an Android emulator" was never the
// blocker -- the SDK, emulator and the ns_test_api35 AVD were already installed;
// the harness was missing. tools/ui_audit/drive_android.py is that harness.
//
// ONE emulator, so these run in a pipeline rather than in parallel: two agents
// tapping the same device would interleave taps and neither would be able to
// trust what it saw. This is the mobile version of the display-collision trap
// that corrupted a desktop sweep earlier in this campaign.
const HARNESS = `
# DRIVING THE MOBILE APP
The emulator is ALREADY BOOTED (ns_test_api35, animations disabled) and a FRESH debug APK has been
built and installed. Do NOT run \`flutter build\` yourself.

  python3 tools/ui_audit/drive_android.py start
  python3 tools/ui_audit/drive_android.py tree            # names, classes, bounds, [ON]/[off]/[DISABLED]
  python3 tools/ui_audit/drive_android.py tap "Connect"   # BY NAME - resolves bounds itself
  python3 tools/ui_audit/drive_android.py tap-xy 540 1200
  python3 tools/ui_audit/drive_android.py back | home
  python3 tools/ui_audit/drive_android.py type "M31"
  python3 tools/ui_audit/drive_android.py shot /tmp/ns-android/shots/NN-what.png
  python3 tools/ui_audit/drive_android.py log --tail 120
  python3 tools/ui_audit/drive_android.py stop

Unlike the desktop harness, \`tree\` here gives GEOMETRY, so \`tap "<name>"\` works and is preferred
over coordinates -- it does not go stale when a layout shifts, and it REFUSES to tap a control the
hierarchy reports as DISABLED rather than silently pressing a dead button.

CONTEXT BUDGET: screenshots are what killed four agents earlier in this campaign (~2000 tokens
each). Use \`tree\` for state -- it is text and nearly free. Screenshot only for layout/rendering
questions. Budget ~30 image reads. Capture liberally, Read selectively.

WRITE AS YOU GO: append each finding to reports/coverage/swept/<YOUR KEY>.json the moment you
confirm it. Agents here have died mid-report; that file is what survives.

WHAT THIS APP IS: a REMOTE COMPANION. It talks to a Skotiq host appliance over the network. No
host is running, so the honest first-run and disconnected states ARE the subject, not an obstacle:
what does this app tell a user who has just installed it and has no appliance yet?
`

const MANDATE = `
Report BOTH, tagged by kind:
1. DEFECT — it states something untrue, silently does nothing while claiming to act, loses data,
   contradicts itself between surfaces, crashes/overflows, or has a dead control.
2. PRODUCT CRITIQUE — it works as built but the design is wrong. Judge it as a demanding
   astrophotographer holding a phone at 2am in the cold and the dark, next to a running rig:
   * would this be cumbersome? how many taps to do the obvious thing?
   * is the DEFAULT wrong? name the better default and why.
   * what is MISSING that a user would reach for on a phone specifically?
   * is text legible and are tap targets big enough for a gloved hand in red light?
   * does it degrade honestly when the appliance is unreachable, or does it lie/hang?
Be concrete and quantified. "Could be better" is worthless.

EVIDENCE: every defect must be observed on the running emulator, with steps and what you saw versus
what should have happened. Source-only claims must say "source-only" and why they were unreachable.
Every unit must end up in units_visited or units_unreached WITH A REASON.
`

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['area', 'units_visited', 'units_unreached', 'findings', 'verified_correct', 'coverage_note'],
  properties: {
    area: { type: 'string' },
    units_visited: { type: 'array', items: { type: 'string' } },
    units_unreached: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['unit', 'why'],
        properties: { unit: { type: 'string' }, why: { type: 'string' } },
      },
    },
    verified_correct: { type: 'array', items: { type: 'string' } },
    coverage_note: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'kind', 'severity', 'unit', 'what_happened', 'expected', 'repro', 'evidence', 'where'],
        properties: {
          title: { type: 'string' },
          kind: { type: 'string', enum: ['defect', 'ux', 'default', 'missing'] },
          severity: { type: 'string', enum: ['P0', 'P1', 'P2', 'P3'] },
          unit: { type: 'string' }, what_happened: { type: 'string' },
          expected: { type: 'string' }, repro: { type: 'string' },
          evidence: { type: 'string' }, where: { type: 'string' },
          proposed_fix: { type: 'string' },
        },
      },
    },
  },
}

const SLICES = [
  {
    key: 'mobile-onboarding',
    scope: `First run and connection: mobile:main.dart, first_run_setup_screen.dart,
qr_scanner_screen.dart, saved_servers_screen.dart, tailscale_setup_sheet.dart,
mobile_discovery_ops.dart, checkpoint_resume_dialog.dart.
This is a brand-new install with NO appliance reachable, which is exactly the state most first-time
users are in. Judge how well the app explains what to do next, whether discovery failure is honest
or silent, whether the QR path degrades gracefully with no camera permission, and whether a saved
server that cannot be reached is reported truthfully.`,
  },
  {
    key: 'mobile-operation',
    scope: `The operating surfaces: mobile_dashboard_screen.dart, mount_tab.dart, sequencer_tab.dart,
settings_tab.dart, log_tab.dart, session_picker_screen.dart, session_replay_screen.dart.
With no host connected, the question is whether each tab degrades honestly — an empty state that
says so — or whether it renders confident-looking controls that do nothing, shows fabricated
values, or hangs. Check every switch in settings_tab for its state and whether it persists across
an app restart (drive_android.py stop, then start).`,
  },
]

phase('Sweep')

// Serialised on purpose: one emulator.
const out = []
for (const s of SLICES) {
  const r = await agent(
    `You are auditing the Skotiq MOBILE app by driving it on a real Android emulator.

Your findings file: reports/coverage/swept/${s.key}.json
Your units: the mobile:* entries in reports/coverage/units_by_area.json.

## YOUR SCOPE
${s.scope}

${HARNESS}
${MANDATE}

Work the whole checklist. When done, \`drive_android.py stop\` (do NOT pass --kill-emulator; the
next agent needs it), make sure your findings file is valid JSON, and return the same object.`,
    { label: `sweep:${s.key}`, phase: 'Sweep', schema: SCHEMA },
  )
  if (r) out.push(r)
}

log(`${out.length}/${SLICES.length} mobile slices returned`)
return {
  slices: out.map((r) => ({
    area: r.area,
    visited: r.units_visited.length,
    unreached: r.units_unreached,
    findings: r.findings.length,
  })),
}
