export const meta = {
  name: 'skotiq-simulator-fidelity',
  description: 'Close the verified simulator-fidelity gaps so no-hardware audits stop having blind spots',
  phases: [
    { title: 'Fix', detail: 'one agent per gap, disjoint file ownership' },
    { title: 'Verify', detail: 'independent reproduction that the gap is actually closed' },
  ],
}

// Each item is verified-open as of 2026-08-01; see
// reports/coverage/simulator-fidelity-backlog.md for the evidence.
// They are split so that no two agents edit the same file: sim_frame.rs,
// sim_gate.rs, stats.rs, fits.rs and api/imaging.rs are each owned by exactly
// one agent, so no two agents write the same file.
const GAPS = [
  {
    key: 'S1-slewing',
    files: 'bridge/src/device_manager/ops/sim_gate.rs',
    brief: `The simulated mount is never in a "slewing" state -- a slew completes instantly.
Give the sim mount a real slew that takes time proportional to the angular distance (a plausible
rate, e.g. a few degrees per second, with settle), reports is_slewing true while it runs, and can be
aborted mid-slew leaving the mount somewhere between start and target. This is what makes slew
progress UI, abort-during-slew, settle handling and "refuse while moving" guards testable at all.`,
  },
  {
    key: 'S2-pedestal-binning',
    files: 'bridge/src/sim_frame.rs',
    brief: `The bias pedestal is added per source pixel at sim_frame.rs:278 and the array is then
summed by bin_region (:199, :361-377), so a 2x2 binned frame carries 4x the pedestal (measured
499.5 ADU at bin1 vs 1999.5 at bin2). Real on-chip binning sums CHARGE and reads out ONCE, applying
the offset pedestal once. Restructure so electrons are binned first and the pedestal plus read noise
are applied once per output pixel. Read noise should also not be summed in quadrature per source
pixel -- one read means one read-noise draw. Add a test asserting the bias level is independent of
binning and that signal still scales with bin area.`,
  },
  {
    key: 'S3-saturation-max-adu',
    files: 'imaging/src/fits.rs',
    brief: `Saturation uses a hardcoded threshold of 65024 (fits.rs:1482) and CameraStatus.max_adu is
never consulted (grep max_adu in imaging/ returns nothing). On any 12- or 14-bit sensor saturation
can never be reported, and a fully clipped frame is misdiagnosed. Derive the threshold from the
sensor's actual ADU ceiling, keeping the same ~99.2% proportion, and fall back to the current
constant only when the ceiling is genuinely unknown. Also reconsider the "only above 90% clipped"
reporting rule -- a frame with 50% of pixels clipped is ruined and currently says nothing.
Add tests at 12-bit, 14-bit and 16-bit ceilings.`,
  },
  {
    key: 'S4-eccentricity-ceiling',
    files: 'imaging/src/stats.rs (+ the grading settings copy in packages/skotiq_app)',
    brief: `stats.rs:190 sets max_eccentricity 0.7 and :309 DISCARDS every star above it, so the
image-grading eccentricity rule can never fire above 0.70 -- while the settings UI
(image_grading_settings.dart:190) recommends 0.8 as the threshold that "catches catastrophic
tracking failure". A wind-trailed frame therefore has no measurable stars and is silently ACCEPTED,
because grade_frame passes when the measurement is None.
Fix all three parts: (a) let the detector measure stars well above 0.7 so trailing is measurable --
the detection filter and the grading threshold must not be the same number; (b) make grade_frame
treat "no measurable stars" as a REJECT-worthy condition rather than a pass; (c) make the settings
copy describe a threshold that can actually fire. Add a test with a deliberately trailed star field
asserting it is rejected.`,
  },
  {
    key: 'S5-altitude-airmass',
    files: 'bridge/src/api/imaging.rs',
    brief: `PARTLY OVERTAKEN — check first: a later change added mount pointing and a
\`context_altitude_pointing\` fallback to \`bridge/src/sequencer_ops.rs\`, so ALTITUDE/AIRMASS may
already reach sequenced frames. Verify by writing a frame and reading the header back before
changing anything; if it is closed, say so with evidence and spend your effort on the airmass
UNIFICATION half, which is almost certainly still open.
Historically: api/imaging.rs:3399 passes altitude: None for sequencer-written frames, and
frame_context.rs states AIRMASS is deliberately left to the bridge writer "when present" -- so it is
never present. Every frame a sequence writes lacks ALTITUDE and AIRMASS, the two keywords photometry
depends on. Compute the altitude at the exposure midpoint from the frame's RA/Dec and the observer
location and pass it through. Also unify the TWO disagreeing airmass implementations
(imaging/src/fits.rs:1273 vs sequencer/src/scheduling/astronomy.rs:98, which differ at the horizon):
one implementation, used by both, with a test pinning it against published values.`,
  },
  {
    key: 'S7-switch-cover-sim',
    files: 'bridge/src/api/devices/simulation.rs + device_manager/ops/{switch,cover}.rs',
    brief: `There is NO simulator for Switch or Cover Calibrator -- confirmed live: every app launch
logs "Discovery complete for Switch: 0 devices" and "Cover Calibrator: 0 devices" while every other
device type finds 1. So flat-panel and power-switch flows cannot be exercised without hardware,
including the CalibratorOn, CalibratorOff, OpenCover and CloseCover sequence instructions.
Add simulators for both, matching the fidelity bar the other simulators now meet: state that takes
time to change, operations that can fail, and status that is honest about what the device is doing.
A cover that opens instantly is the same class of bug as the instant slew above.`,
  },
]

const RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['key', 'landed', 'summary', 'files_changed', 'tests_added', 'verification'],
  properties: {
    key: { type: 'string' },
    landed: { type: 'boolean' },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    tests_added: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string', description: 'the exact command run and its result' },
    caveats: { type: 'string' },
  },
}

phase('Fix')

const done = await pipeline(
  GAPS,
  (g) =>
    agent(
      `You are closing a verified simulator-fidelity gap in the Skotiq astrophotography app.

Repo root is the working directory. Native code is under native/skotiq_native/.
Your files: ${g.files}

## THE GAP
${g.brief}

## WHY THIS MATTERS
These simulators are the ONLY way this app gets tested -- there is no telescope attached. Every
place a simulator is unrealistic in the pass-making direction is a place where a real bug ships
green. That has already happened repeatedly on this codebase. So the bar is not "the test passes",
it is "a real device could behave this way and the app cannot tell the difference".

## RULES
* Match the surrounding code's style, comment density and idiom. This codebase comments WHY, not
  WHAT, and its comments are load-bearing -- read the ones near your change before writing.
* Add real tests. A test that asserts the thing you just wrote returns what you wrote is worthless;
  assert the PHYSICS or the CONTRACT (bias independent of binning, saturation at the sensor's real
  ceiling, a trailed frame actually rejected).
* Build and test what you touched:
    cd native/skotiq_native && cargo test --package <the package you changed>
  Do NOT run a full workspace build if you can avoid it, and do NOT run flutter build.
* If you find the gap is already fixed, or the described fix is wrong, say so plainly with evidence
  rather than inventing work. That is a valid and useful result.
* **Your test must fail when your change is reverted.** Revert it, run the test, confirm it fails,
  restore, confirm it passes, and report that you did. On this codebase an audit found a whole batch
  whose tests stayed green when the entire production wiring was severed, because every test called
  the helper directly with hand-made arguments. Test the WIRING, not just the function.
* Append your result to reports/coverage/fixes/sim-<YOUR KEY>.json as you go. Agents here have died
  mid-report before; that file is what survives.
* If your fix requires touching a file another agent owns, do NOT touch it -- describe the needed
  change in caveats instead.

Report honestly: 'landed' is true only if it compiles and your tests pass.`,
      { label: `fix:${g.key}`, phase: 'Fix', schema: RESULT },
    ),
  (r, g) => {
    if (!r || !r.landed) return r
    return agent(
      `Independently verify a simulator fidelity fix. Be adversarial: on this codebase a verify pass
previously found 7 of 11 "complete" fix batches were incomplete, and the recurring failure is
RELOCATING a defect rather than fixing it (moving a threshold, matching a poll period, replacing one
false claim with another).

Gap: ${g.key}
${g.brief}

What the implementer says they did:
${JSON.stringify(r, null, 1)}

Check, at source and by running the tests yourself:
1. Does the change actually make the simulator behave like real hardware, or does it just make the
   named symptom go away?
2. Do the new tests fail if the fix is reverted? If a test passes either way it proves nothing.
3. Did the fix break a neighbouring behaviour or an existing test?
4. Is anything in the brief left unaddressed and unmentioned?

Return a verdict.`,
      {
        label: `verify:${g.key}`,
        phase: 'Verify',
        schema: {
          type: 'object',
          additionalProperties: false,
          required: ['key', 'verdict', 'reasoning'],
          properties: {
            key: { type: 'string' },
            verdict: { type: 'string', enum: ['SOLID', 'INCOMPLETE', 'WRONG'] },
            reasoning: { type: 'string' },
            still_open: { type: 'array', items: { type: 'string' } },
          },
        },
      },
    ).then((v) => ({ ...r, verdict: v }))
  },
)

return { fixes: done.filter(Boolean) }
