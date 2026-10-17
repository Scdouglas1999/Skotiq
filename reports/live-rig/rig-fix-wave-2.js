export const meta = {
  name: 'skotiq-rig-wave-2',
  description: 'Fix the defects found once the rig could actually capture',
  phases: [
    { title: 'Fix', detail: 'one agent per defect' },
    { title: 'Refute', detail: 'adversarial verification' },
  ],
}

const CONTEXT = `## Context

The owner runs an UNATTENDED imaging session tonight, babysitting only for safety. A live rig is
attached to a Windows laptop: ZWO **ASI1600MM-Cool** and **ASI178MM** cameras, ZWO **EAF** focuser,
ZWO **EFW2** filter wheel, **Pegasus NYX101** mount. Two ASCOM drivers on that machine are
*phantoms* with no hardware behind them (ASI Mount, ZWO CAA rotator) — useful as negative controls.

The appliance has just been rebuilt and now captures correctly: a two-frame run completed and wrote
real FITS. The defects below were found **after** that point, by inspecting what it actually wrote.

## The rule that governs all of this

**No bug is fixed on the strength of reading code.** Reproduce it in the running app, record what
the app actually did, then fix. ~38% of this campaign's P0/P1 findings cited a \`file:line\` that did
not contain the claim. If you cannot reproduce it, say so and leave it open.

## Ground truth — read this first

\`reports/live-rig/FINDINGS-2026-08-09.md\`, sessions 4 and 5. Every entry carries the raw request and
response, and where it matters an independent reading taken from the ASCOM driver itself via a
standalone PowerShell COM probe.

## Reaching the rig

\`ssh nslaptop\` works. The appliance is tunnelled to \`http://127.0.0.1:18084\`; the bearer token is in
\`reports/live-rig/.rig-token\`. **Do NOT rebuild or restart the appliance** — the owner may be using
it, and a rebuild takes the rig offline. If the tunnel is down, reproduce against the Linux
simulator build and say clearly which one you used.

Linux bundle: \`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop\`, runs headless with
\`--headless --auth-token=<anything> --allow-unauthenticated-lan\` and a scratch
\`SKOTIQ_DATABASE_DIR\`. Simulator ids: \`sim_camera_1\`, \`sim_mount_1\`, \`sim_focuser_1\`,
\`sim_filterwheel_1\`.

## Sequence wire format (worked out the hard way — do not re-derive it)

\`POST /api/sequencer/load\` takes \`{"json":"<stringified SequenceDefinition>"}\`. Rust requires
\`SequenceDefinition.id\` and \`.name\`; \`TargetHeaderConfig.priority\`; \`ExposureConfig.duration_secs\`
(NOT \`duration\`) and \`.count\`; \`Binning\` as the bare string \`"One"\`. Set the base save path with
\`POST /api/sequencer/save-path {"path":"..."}\` — a per-node \`save_to\` is a filename TEMPLATE, not a
directory, and passing a directory fails mid-run with "Access is denied".

## Rules
* \`graphify query "<question>"\` before grepping or reading source.
* Tests: \`dart run melos exec --scope="<pkg>" -- flutter test <path>\`; Rust via \`cargo test\` under
  \`native/skotiq_native\`. Never \`flutter test packages/<pkg>/...\` from the root.
* Every fix needs a test that fails when the fix is reverted. Sever the PRODUCTION CALL SITE and say
  what happened.
* \`dart format\` / \`cargo fmt\` what you touch. NEVER \`git stash\`/\`checkout\`/\`restore\`.`

const DEFECTS = [
  {
    key: 'camera-identity',
    title: 'No stable camera identity: both transports use positional ids that re-order',
    body: `See **L23** and **L18**. With two ZWO cameras attached, the id a user picks does not
identify a camera:

| | before a replug | after |
|---|---|---|
| \`native:zwo:0\` | ZWO ASI178MM | **ZWO ASI1600MM-Cool** |
| \`native:zwo:1\` | ZWO ASI1600MM-Cool | **ZWO ASI178MM** |

They swapped. A run was started on \`native:zwo:1\` believing it was the 1600 and captured entirely on
the 178MM — proven from the written header (\`NAXIS1/2 3096 x 2080\`, \`PIXSIZE 2.4\`, which are the
178's geometry and pixel size).

ASCOM is no better: \`ASCOM.ASICamera2.Camera\` is a driver SLOT. With both cameras present it was the
1600; with one present it is the 178 — and so is \`ASCOM.ASICamera2_2.Camera\`.

The ZWO SDK exposes a **serial number**; ASCOM exposes \`Name\` (and often \`SensorName\`) once
connected. Build identity from something stable, and at minimum **re-read the identity and
capabilities after every connect** so a swap cannot go unnoticed. Related and worth folding in:
**L2** — the app displays a ProgID-derived name (\`ASICamera2 Camera\`) when the driver reports
\`ZWO ASI1600MM-Cool\`, for all five device types.

Consider also what the operator sees: two cameras that both display as "ASI Camera (1)" / "(2)" with
no model, no serial, no sensor size.`,
  },
  {
    key: 'fits-missing-keywords',
    title: 'Written FITS has no ALTITUDE/AIRMASS and no INSTRUME/TELESCOP/FOCALLEN',
    body: `A real frame written by a real run on the rig (\`C:\\src\\rigframes\\Polaris_1_0001.fits\`)
carries a genuinely good header — \`SITELAT 39.97190\`, \`SITELONG -75.35760\`, \`FOCUSPOS 22850\`,
\`FOCTEMP 30.53\`, \`OBJCTRA '02 31 49.08'\` agreeing with \`RA 37.95450\`, plus \`NS-SESID\`/\`NS-FIDX\`.

Two gaps:

1. **No \`ALTITUDE\`, no \`AIRMASS\`.** This is item **S5** in
   \`reports/coverage/simulator-fidelity-backlog.md\`, recorded there from source
   (\`bridge/src/api/imaging.rs\` passes \`altitude: None\`, and \`frame_context.rs\` says AIRMASS is left
   to the bridge writer "when present" — it never is). Now **confirmed on real hardware**. Every
   frame is missing the two keywords photometry depends on, and the app has the site coordinates,
   the pointing and the timestamp needed to compute both.
2. **No \`INSTRUME\`, \`TELESCOP\`, \`FOCALLEN\`.** Nothing in the file says which camera or scope took
   it. On this rig, with two cameras, \`PIXSIZE 2.4\` is the only clue. Most processing tools group
   by \`INSTRUME\`.

Beware the two airmass implementations that disagree — **S6** in the same backlog:
\`imaging/src/fits.rs:1273 calculate_airmass\` and
\`sequencer/src/scheduling/astronomy.rs:98 airmass\` were measured to differ at the horizon
(31.73 vs infinity). Pick one, delete or delegate the other, and say which you chose and why.`,
  },
  {
    key: 'ascom-write-errors',
    title: 'Every ASCOM property WRITE discards the driver\'s explanation',
    body: `See **L13**. Enabling tracking on the parked NYX101 (correctly refused) produced only:

\`SDK error: Failed to set property Tracking: Exception occurred. (0x80020009)\`

ASCOM drivers put a human sentence in \`EXCEPINFO\` for exactly this — something like "Cannot set
Tracking while the mount is parked" — and it never reaches the operator.

The asymmetry is one line in \`native/skotiq_native/ascom/src/windows/connection.rs\`:

* property **reads** pass a real \`EXCEPINFO\` and decode it via \`excepinfo_to_string\` (lines 876,
  918, 956, 994, 1036)
* property **writes** pass \`None\`: \`invoke_with_retry(dispid, DISPATCH_PROPERTYPUT, &params, None, None)\`
  at lines **708, 752, 795**

So \`0x80020009\` on any write is unexplainable by construction — connect, tracking, gain, offset,
cooling setpoint, filter position. A previous live-rig session recorded exactly this pain as
"gain/offset + FW-move fault 0x80020009".

Care needed in the retry loop: \`EXCEPINFO\` carries \`BSTR\`s that must be freed between attempts,
which is presumably why the setters were written this way. This is Windows-only code that cannot
compile on the Linux workstation — arrange a cross-check.`,
  },
  {
    key: 'cooler-off-setpoint',
    title: 'Turning the cooler OFF sends a fabricated -10C setpoint and fails',
    body: `See **L19**. \`POST /api/camera/cooling {"enabled":false}\` with no \`targetTemp\`:

\`Failed to set ASCOM camera ... cooler (enabled=false, target=-10C): SDK error: Failed to set
cooler: Failed to set property SetCCDTemperature...\`

\`camera_handlers.dart\` correctly forwards \`targetTemp: null\`. The \`-10\` is applied at
\`device_manager/ops/camera.rs:2251\` and \`:2327\` via \`target_temp.unwrap_or(-10.0)\`, documented in
the module header as "the historical Skotiq default target when the caller does not specify".

Defensible when *enabling* cooling; wrong when *disabling*. No setpoint is needed to turn a cooler
off, and writing \`SetCCDTemperature\` is what threw — the camera in question reports
\`CanSetCCDTemperature = False\`. Net effect: **the cooler cannot be turned off at all** on such a
camera, and end-of-night warm-up is exactly when this is called.

Skip the setpoint write when \`enabled == false\`, and skip it when the camera reports no
set-temperature capability. While there, check the warm-up story generally: is there any ramp, or
does the app just switch the TEC off? Abrupt warming of a cooled sensor is a real-world hazard.`,
  },
  {
    key: 'preflight-device-guards',
    title: 'Pre-flight refuses a missing save path and a missing solver, but not missing devices',
    body: `See **L16**. Three start attempts, three outcomes, on the live rig:

| sequence needs | pre-flight |
|---|---|
| a save path — missing | **BLOCKED**: *"...every frame would otherwise be captured and discarded."* |
| a plate solver — missing | **BLOCKED**: *"...centering would fail on every target otherwise."* |
| a filter wheel — not resolvable | started, failed mid-run |
| an equipment profile — none | started, then retried silently |

The two existing guards are excellent and share a shape worth copying exactly: name the missing
thing, name the consequence in the operator's terms, refuse before anything moves.

The device-wiring bug behind rows 3 and 4 is now fixed, but the **guard gap remains** and is the
cheap insurance: the sequence declares what it needs (a filter index implies a wheel, an exposure a
camera, a slew a mount, \`CenterTarget\`/\`Autofocus\`/\`CoolCamera\` a camera). A verifier already noted
that \`tree_needs_camera\` in \`executor/mod.rs\` covers only \`TakeExposure\`/\`SmartExposure\`/
\`FlatWizard\` — \`CenterTarget\`, \`Autofocus\` and \`CoolCamera\` call \`ctx.camera_id()\` at
\`instructions.rs:1542, 4611, 6132\` and are ungated.

Extend the walk, in the same voice as the two guards that already work.`,
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
    `You are fixing a defect on an astrophotography app whose owner images unattended tonight.\n\n${CONTEXT}\n\n` +
    `# Your defect: ${d.title}\n\n${d.body}\n\n` +
    `Reproduce it, fix the cause, add a test that fails when the fix is reverted, and report what ` +
    `you actually ran and what it printed.`,
    { label: `fix:${d.key}`, phase: 'Fix' },
  ),
  (impl, d) => agent(
    `You are an ADVERSARIAL VERIFIER. Refute the fix below rather than admiring it.\n\n${CONTEXT}\n\n` +
    `# The defect\n\n${d.title}\n\n${d.body}\n\n` +
    `# What the fixer claims\n\n${(impl || '(nothing returned)').slice(0, 6000)}\n\n` +
    `Check in order: does the cited code exist and say what is claimed; does the fix address the ` +
    `CAUSE or only disclose/relocate it; does the test fail when the PRODUCTION CALL SITE is severed ` +
    `(do it, then restore); did anything else break. Failure shapes seen repeatedly in this ` +
    `campaign: DISCLOSURE-ONLY, RELOCATED, INCOMPLETE (the sim-sky fix missed an entire second ` +
    `capture path this way), INVERTED. Reproduce the original symptom yourself before accepting it ` +
    `is gone. Repair what is confined; do not invent defects.`,
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
    reasoning: (v.reasoning || '').slice(0, 800),
    remaining: v.remaining || [],
  })),
}
