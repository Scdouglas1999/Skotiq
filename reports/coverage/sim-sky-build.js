export const meta = {
  name: 'skotiq-sim-sky',
  description: 'Make the simulated camera render the real sky so plate solving works with no hardware',
  phases: [
    { title: 'Build', detail: 'sim_sky.rs + sim_frame wiring + tests' },
    { title: 'Refute', detail: 'adversarial verification of the result' },
  ],
}

const BACKGROUND = `## The problem

\`native/skotiq_native/bridge/src/sim_frame.rs\` paints 45 pseudo-random Gaussian stars (\`add_stars\`, fixed LCG seed 0x5EED_1234_ABCD_0001) and translates the whole field as a rigid body with the mount's guide offset. It does NOT render the sky the mount is pointing at.

Plate solving is not special-cased for the simulator: \`native/skotiq_native/bridge/src/api/plate_solve.rs\` shells out to the real ASTAP binary. So under the simulator every plate-solve-dependent feature is unexercisable without hardware — Slew & Center, the centering dialog, the framing wizard, mosaic tile solving, meridian-flip recentre, blind solve, the catalog overlay (it needs a WCS), the plate-solving settings Test button, and polar alignment's solve path. That is the single largest simulator-fidelity gap left in the product.

## The design, already proven

\`tools/sim_fidelity/plate_solve_probe.py\` is a working reference implementation and the acceptance test. Read it first — it is heavily commented and it encodes two traps that already cost a full debugging cycle each. Measured on this machine, rendering from ASTAP's own D05 database and handing the frame back to ASTAP:

    1000mm  0.78"/px  stars=  70  SOLVED  centre error 0.5"
     400mm  1.94"/px  stars= 319  SOLVED  centre error 1.4"
     200mm  3.88"/px  stars= 615  SOLVED  centre error 2.6"
     135mm  5.74"/px  stars= 630  SOLVED  centre error 3.9"

Sub-pixel at every focal length. Reproduce it before you start:

    python3 tools/sim_fidelity/plate_solve_probe.py --astap ~/.local/share/skotiq-audit/astap/bin

## Everything you need is already native-side — no Dart plumbing

* \`api/plate_solve.rs\` reads a preference holding \`astap_path\` and \`catalog_path\`. \`catalog_path\` is the ASTAP star-database directory — the very catalogue the solver will match against. Read the SAME preference; then the simulated sky and the solver cannot disagree by construction.
* \`storage.rs\` already holds \`telescope_focal_length\` (default 1000.0).
* \`device_capabilities.rs\` declares the simulated sensor: 1920x1080, \`pixel_size_x/y = 3.76\` µm. \`sim_frame.rs\` exports \`SIM_W\`/\`SIM_H\`.
* The sim mount's RA/Dec is on \`crate::api::devices::simulation::get_sim_mount()\`; the rotator is \`get_sim_rotator()\`. The frame is built in \`device_manager/ops/camera.rs\` (search \`SimFrameRequest\`), inside an async fn that can await both.

## What to build

1. A new \`native/skotiq_native/bridge/src/sim_sky.rs\`:
   * Parse ASTAP's \`.1476\` record-format-5 files. 110-byte text header whose \`byte[109]\` is the record size; 5-byte records; RA in three little-endian bytes scaled \`24/(2^24-1)\` hours; DEC's high byte comes from the most recent header record (RA == 0xFFFFFF), which also carries the magnitude as \`(byte - 16)/10\`. DEC scale is \`90/(128*256*256-1)\`.
   * An area index built ONCE and cached: per file a unit vector and an angular radius. **Do not use an RA/Dec bounding box** — it tears at the RA=0 wrap and is degenerate near the poles, and a dropped file leaves a blank wedge that makes ASTAP fail to match. The Python probe has the exact algorithm.
   * \`field(ra_deg, dec_deg, radius_deg, limit)\` returning stars sorted BRIGHTEST FIRST. Truncating on anything else leaves the frame complete to no particular depth, which breaks quad matching.
2. Wire it into \`sim_frame.rs\`: an optional sky view (centre RA/Dec, rotation, arcsec/px, the star list). When present, project gnomonically (TAN) and render each star with flux from its magnitude through the EXISTING electron model — bias, dark, sky, shot and read noise, focuser-driven sigma via \`sim_star_sigma\`, the well clip. When absent, the current pseudo-random field must be produced completely unchanged.
3. Build the sky view in \`camera.rs\` from the sim mount's pointing, the rotator angle, \`telescope_focal_length\` and the declared pixel size.

## Hard requirements

* **The existing behaviour is the default.** Sim tests assert star counts, HFR and autofocus V-curves against the current field. If no \`catalog_path\` is configured, or the directory holds no \`*.1476\` files, the old field must be byte-identical. Prove it with a test.
* **Nothing slow on the capture path.** Indexing 1476 files takes ~6 s in Python; do it once, lazily, cached behind a \`OnceLock\`/\`RwLock\`, and never per frame.
* **Determinism.** A given seed and pointing must reproduce a given frame.
* Tests: unit-test the \`.1476\` parser against a fixture you synthesise in the test (do not depend on a database being installed), the cap index, and the TAN projection (project a star at the centre and at a known offset; assert the pixel). Add an integration test that runs \`astap_cli\` and asserts the solved centre — \`#[ignore]\` by default so CI without ASTAP stays green, and say in its doc comment how to run it.
* \`cargo fmt\`, \`cargo clippy\`, and the existing Rust workspace suite (2086 tests) must all stay green. Report the numbers you actually saw.
* NEVER run \`git stash\`, \`git checkout\` or \`git restore\` — other agents are working in this tree.`

const BUILD = `You are implementing a simulator-fidelity feature in the Skotiq astrophotography app (Flutter/Dart + Rust via flutter_rust_bridge), repo root /home/scdouglas/Documents/Skotiq2.

${BACKGROUND}

## Orientation
The repo has a knowledge graph: \`graphify query "<question>"\` before grepping. The graph is Dart-centric, so for the Rust side go straight to the files named above.

Work end to end and leave the tree green. Report honestly what you ran and what it printed — if the ASTAP integration test does not solve, say so with the solver's output rather than describing the feature as done.`

const VERIFY = `You are an ADVERSARIAL VERIFIER on the Skotiq astrophotography app, repo root /home/scdouglas/Documents/Skotiq2.

Another agent has just implemented a simulated-sky renderer so that simulated camera frames can be plate-solved. Your job is to REFUTE it.

${BACKGROUND}

## What the implementer claims

$$IMPL$$

## How to refute it

1. **Does the claimed code exist and do what is claimed?** Open the files. In this campaign ~38% of cited \`file:line\` references did not contain the claim.
2. **Run the acceptance test yourself.** \`python3 tools/sim_fidelity/plate_solve_probe.py --astap ~/.local/share/skotiq-audit/astap/bin\` must still solve. Then run the Rust integration test the implementer added (it is \`#[ignore]\`d; run it explicitly) and confirm a real solve on a frame produced by the PRODUCTION path, not by a test-only helper that re-implements the renderer.
3. **Sever the wiring, not the logic.** Comment out the call that attaches the sky view in \`camera.rs\`, re-run the tests, confirm something goes red, restore. A batch was caught in this campaign whose entire production wiring could be deleted with all 434 tests still green. Say what happened.
4. **Check the fallback is really unchanged.** With no catalogue configured the old pseudo-random field must be byte-identical. Verify by construction, not by trusting a test name.
5. **Check the capture path did not get slower.** If the index is rebuilt per frame, say so.
6. **Run the full Rust workspace suite** and report the real numbers.

Recurring failure shapes here, each actually observed: DISCLOSURE-ONLY (the app now says the thing is broken instead of not being broken), RELOCATED (a threshold nudged, one false claim swapped for another), INCOMPLETE (one of several call sites), INVERTED (the fix creates the opposite failure).

If a defect is confined and you can repair it properly, do so and add a test that fails when the fix is reverted. Run \`cargo fmt\`. NEVER run \`git stash\`, \`git checkout\` or \`git restore\`.

Do not invent a defect to look thorough, and do not accept a claim because it is well written.`

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'reasoning'],
  properties: {
    verdict: {
      type: 'string',
      enum: ['HOLDS', 'INCOMPLETE', 'RELOCATED', 'DISCLOSURE-ONLY', 'INVERTED', 'REGRESSION', 'NOT-APPLIED'],
    },
    reasoning: { type: 'string' },
    probeOutput: { type: 'string' },
    severedCallSite: { type: 'string' },
    fallbackUnchanged: { type: 'boolean' },
    rustSuite: { type: 'string' },
    repaired: { type: 'boolean' },
    repairSummary: { type: 'string' },
    remaining: { type: 'array', items: { type: 'string' } },
  },
}

phase('Build')
const impl = await agent(BUILD, { label: 'build:sim-sky', phase: 'Build' })

phase('Refute')
const verdict = await agent(VERIFY.replace('$$IMPL$$', (impl || '(the builder returned nothing)').slice(0, 6000)), {
  label: 'verify:sim-sky',
  phase: 'Refute',
  schema: VERDICT,
})

return { impl: (impl || '').slice(0, 4000), verdict }
