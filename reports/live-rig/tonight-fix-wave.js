export const meta = {
  name: 'skotiq-tonight-critical',
  description: 'Fix the defects that would break tonight\'s unattended imaging run',
  phases: [
    { title: 'Fix', detail: 'one agent per tonight-critical defect' },
    { title: 'Refute', detail: 'adversarial verification of each fix' },
  ],
}

const CONTEXT = `## The deadline

The owner runs an UNATTENDED imaging session tonight. They will be nearby for safety, but the app
is expected to run the night by itself. Every defect below either loses the whole session or lies
to the operator about what the hardware is doing. Judge every change by one question: *would this
survive eight hours with nobody watching?*

## The rule that governs all of this

**No bug is fixed on the strength of reading code.** Reproduce it in the running app, record what
the app actually did, then fix. This campaign measured ~38% of P0/P1 findings citing a \`file:line\`
that did not contain the claim. If you cannot reproduce it, say so and leave it open — do not fix
on a hypothesis, and do not quietly drop it.

## Ground truth — read these first, they are evidence, not summaries

* \`reports/live-rig/FINDINGS-2026-08-09.md\` — findings from the REAL rig (ZWO ASI1600MM-Cool, EAF,
  EFW2, ASICAA rotator, Pegasus NYX101), each with the raw request and response, and where it
  matters an independent ground-truth reading taken from the ASCOM driver itself via a standalone
  PowerShell COM probe.
* \`reports/coverage/closeout/FINDINGS.md\` — 74 findings from the closeout wave, most severe first.

## The rig, if you can reach it

The appliance runs on the owner's Windows laptop and is reachable through an SSH tunnel at
\`http://127.0.0.1:18080\` with a bearer token in \`/tmp/rig-token.txt\` (\`TOKEN=...\`). \`ssh nslaptop\`
works. The tunnel may be down by the time you run — if it is, do NOT try to rebuild or restart the
appliance yourself (a rebuild takes the rig offline and the owner may be using it). Reproduce
against the Linux simulator build instead and say clearly which one you used.

Simulator devices are \`sim_camera_1\`, \`sim_mount_1\`, \`sim_focuser_1\`, \`sim_filterwheel_1\`. The
Linux release bundle is at \`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop\` and runs
headless with \`--headless --auth-token=<anything> --allow-unauthenticated-lan\`. Give it a scratch
\`SKOTIQ_DATABASE_DIR\`.

## Sequence wire format — this cost four rejections to work out, do not repeat it

\`POST /api/sequencer/load\` takes \`{"json": "<stringified SequenceDefinition>"}\`. The Rust parser
requires, and the Dart test fixtures get wrong: \`SequenceDefinition.id\` and \`.name\`;
\`TargetHeaderConfig.priority\`; \`ExposureConfig.duration_secs\` (NOT \`duration\`) and \`.count\`;
\`Binning\` as a bare enum string \`"One"\`. A working example is in FINDINGS-2026-08-09.md under L8.

## Rules
* Run \`graphify query "<question>"\` to orient before grepping or reading source.
* Tests: \`dart run melos exec --scope="<package>" -- flutter test <path>\`. Never
  \`flutter test packages/<pkg>/...\` from the root. Rust: \`cargo test\` under
  \`native/skotiq_native\`. Redirect long runs to a file rather than piping through \`tail\`.
* Every fix needs a test that fails when the fix is reverted. Sever the PRODUCTION CALL SITE, not
  just the logic, and say what happened when you did.
* Run \`dart format\` / \`cargo fmt\` on what you touch.
* NEVER run \`git stash\`, \`git checkout\` or \`git restore\` — other agents share this tree.`

const DEFECTS = [
  {
    key: 'phantom-connect',
    title: 'The app reports a phantom device as connected (fix written, NOT validated)',
    body: `See L4 in the live-rig findings. \`AscomDeviceConnection::connect\`
(\`native/skotiq_native/ascom/src/windows/connection.rs\`) set \`Connected = true\`, saw no COM
exception, and returned success without reading the property back. On the real rig, the ASI Mount
driver — installed but with no hardware behind it — accepted the write, then reported
\`Connected = False\`, \`Slewing = True\`, \`SiderealTime = -1\` and RA/Dec/Alt/Az all zero. The app
announced a connected mount and served \`slewing: true\` for ever, which hangs any wait-for-slew.

**A fix is already in the tree**: poll \`Connected\` back for up to \`CONNECT_VERIFY_TIMEOUT\`, set it
false again on failure, return a message naming the real causes. It has **never been compiled** —
it is Windows-only code and the workstation is Linux — and it has **no test**.

Your job: review it critically (is 5 s right? does the failure path leave the driver clean? does it
break a slow-but-genuine device?), add a unit test at whatever seam is testable without a COM
runtime, and make sure \`cargo check --target x86_64-pc-windows-msvc\` or an equivalent
cross-check catches compile errors. If you can reach the rig, validate against both the phantom ASI
mount (must now fail with the new message) and the five real devices (must still connect).`,
  },
  {
    key: 'no-profile-hang',
    title: 'A run starts with no equipment profile and hangs in "recovering" for ever',
    body: `See L6. \`GET /api/profiles\` returned \`{"profiles":[]}\` and \`POST /api/sequencer/start\`
still answered \`{"status":"started"}\`. The run then sat at
\`{"state":"recovering","message":"Recovering: Device disconnected","progress":0.0}\` indefinitely
with no frames written — while \`GET /api/devices/connected\` listed the camera, wheel and rotator as
connected, and that same camera had taken a real 4656x3520 frame minutes earlier.

Two things to establish, in this order, both by reproduction:
1. **Root cause.** The hypothesis is that the executor resolves hardware through the profile
   assignment rather than the session's connected devices, so an empty profile reads as a
   disconnected device. Prove or disprove it — create a profile with the camera assigned and re-run.
   If that fixes it, the executor/device-manager disagreement is still worth reporting.
2. **The unbounded silent retry.** Regardless of cause, a run that cannot find its camera must not
   loop at \`progress 0.0\` for ever. The pre-flight layer already refuses a start with no image save
   path, and does it well — *"every frame would otherwise be captured and discarded"*. It has no
   equivalent check for "no profile / no camera assigned". Add one, in the same voice, and bound the
   recovery retry so an unattended run fails loudly instead of hanging silently.`,
  },
  {
    key: 'stop-lies',
    title: 'Stop reports "hardware was NOT confirmed stopped" after successfully stopping',
    body: `See L7. \`POST /api/sequencer/stop\` returned a 30 s \`TimeoutException\`:
*"The native executor accepted the stop command but never reported a terminal state within 30s. The
hardware was NOT confirmed stopped, so nothing has been torn down."* — while
\`GET /api/sequencer/status\` showed \`{"state":"failed","message":"Cancelled: Preflight"}\`. The stop
had worked. The waiter missed the terminal state.

At 2am that message reads as "your mount may still be moving", which is exactly the false alarm that
makes an operator intervene destructively. The wording is otherwise excellent — it refuses to claim
a teardown it cannot verify — so fix the observation, not the sentence.

Second defect in the same call: stopping an **already-terminal** run also blocks for the full 30 s
and returns the same error, instead of returning immediately.`,
  },
  {
    key: 'meridian-stall',
    title: 'A run stalls waiting for a meridian flip that is hours overdue and will never fire',
    body: `P1 in \`reports/coverage/closeout/FINDINGS.md\`, at
\`native/skotiq_native/sequencer/src/instructions.rs:1954\`. Live repro: 12 x 5 s lights on a
target at RA 12.5 h / Dec +70 from a site at 40N 42E. Frame 1 saved normally, then the run froze at
\`1/12 8%\` for the rest of the session. Log:

    Waiting for the meridian flip before the next 5s exposure: the flip fires in ~0s
    (hour angle +8.93h, threshold 5 min past meridian) and would interrupt the frame

No "Capturing frame 2/12" ever followed. \`fire_in_secs = (threshold_min - ha*60)*60\` goes hugely
negative once the target is hours past the meridian, and the gate treats that as "about to fire".

This is the single most likely way tonight's run dies, because a target crossing the meridian is
routine. The UI said only "Running" throughout — so it stalls silently.`,
  },
  {
    key: 'sim-sky-second-path',
    title: 'The Imaging screen still paints random stars, so simulated capture cannot be plate-solved',
    body: `Two P1s in the closeout findings, one root cause. S9's real-sky renderer was wired into
\`device_manager/ops/camera.rs:1217\` and genuinely works —
\`cargo test -p skotiq_bridge --lib sim_sky_wiring -- --ignored\` prints
\`downloaded frame solved, centre error 0.5"\`. But the capture the **Imaging screen** performs goes
through \`api/imaging.rs:791\`, whose \`device_id.starts_with("sim_")\` branch calls
\`generate_simulated_image()\` at \`imaging.rs:1304-1344\` — background plus \`rand::thread_rng()\` stars
at random positions. Reproduced end to end on the release build with ASTAP and D05 correctly
configured and a 400 mm / 3.76 um profile the app itself resolved to 1.94 arcsec/px.

So there are **two** simulated-capture paths and only one renders the sky. This is the exact shape
the campaign keeps hitting: severing the call site you found proves that site is load-bearing, not
that it is the only one. Route both paths through the same renderer, and add a test that fails if a
third path ever appears — for instance, assert that no code outside \`sim_frame\`/\`sim_sky\` calls a
random-star generator.`,
  },
]

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
    reproducedBefore: { type: 'string' },
    reproducedAfter: { type: 'string' },
    severedCallSite: { type: 'string' },
    testsRun: { type: 'string' },
    repaired: { type: 'boolean' },
    repairSummary: { type: 'string' },
    remaining: { type: 'array', items: { type: 'string' } },
  },
}

const results = await pipeline(
  DEFECTS,
  (d) => agent(
    `You are fixing a defect that would break tonight's unattended imaging run.\n\n${CONTEXT}\n\n` +
    `# Your defect: ${d.title}\n\n${d.body}\n\n` +
    `Reproduce it first, fix the cause, add a test that fails when the fix is reverted, and report ` +
    `honestly what you ran and what it printed. If you cannot reproduce it, say so plainly rather ` +
    `than fixing on faith.`,
    { label: `fix:${d.key}`, phase: 'Fix' },
  ),
  (impl, d) => agent(
    `You are an ADVERSARIAL VERIFIER. Refute the fix below; do not admire it.\n\n${CONTEXT}\n\n` +
    `# The defect\n\n${d.title}\n\n${d.body}\n\n` +
    `# What the fixer claims\n\n${(impl || '(the fixer returned nothing)').slice(0, 6000)}\n\n` +
    `Check, in order: does the cited code exist and say what is claimed; does the fix address the ` +
    `CAUSE or merely disclose/relocate it; does the shipped test fail when the PRODUCTION CALL SITE ` +
    `is severed (actually do it, then restore); did anything else break. Recurring failure shapes ` +
    `observed in this campaign: DISCLOSURE-ONLY (the app now says the thing is broken instead of ` +
    `not being broken), RELOCATED (a threshold nudged, one false claim swapped for another), ` +
    `INCOMPLETE (one of several call sites — the sim-sky fix missed an entire second capture path ` +
    `exactly this way), INVERTED (the fix creates the opposite failure).\n\n` +
    `Reproduce the original symptom yourself before accepting that it is gone. If a repair is ` +
    `confined, make it and add a test. Do not invent a defect to look thorough.`,
    { label: `verify:${d.key}`, phase: 'Refute', schema: VERDICT },
  ),
)

const ok = results.filter(Boolean)
return {
  reporting: ok.length,
  lost: DEFECTS.filter((d, i) => !results[i]).map((d) => d.key),
  verdicts: ok.map((v, i) => ({
    defect: DEFECTS[i] && DEFECTS[i].key,
    verdict: v.verdict,
    repaired: v.repaired === true,
    reasoning: (v.reasoning || '').slice(0, 900),
    remaining: v.remaining || [],
  })),
}
