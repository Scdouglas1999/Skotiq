export const meta = {
  name: 'skotiq-coverage-closeout',
  description: 'Exercise the 80 units no sweep ever reached, with product critique, not just defect-hunting',
  phases: [
    { title: 'Close', detail: 'one agent per cluster of unreached units' },
  ],
}

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['cluster', 'units'],
  properties: {
    cluster: { type: 'string' },
    units: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['unit', 'state'],
        properties: {
          unit: { type: 'string' },
          state: { type: 'string', enum: ['visited', 'unreached'] },
          why: { type: 'string' },
          evidence: { type: 'string' },
        },
      },
    },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['kind', 'severity', 'title', 'detail'],
        properties: {
          kind: { type: 'string', enum: ['defect', 'ux', 'default', 'missing'] },
          severity: { type: 'string', enum: ['P0', 'P1', 'P2', 'P3', 'P4'] },
          title: { type: 'string' },
          detail: { type: 'string' },
          location: { type: 'string' },
          fixed: { type: 'boolean' },
          fixSummary: { type: 'string' },
          needsOwnerDecision: { type: 'boolean' },
        },
      },
    },
    testsRun: { type: 'string' },
  },
}

const CLUSTERS = [
  {
    key: 'runtime-run',
    title: 'Run-time and post-run sequencer surfaces',
    body: `Drive a real sequence against the simulators, END TO END, and let it FINISH. Nothing in this cluster is blocked by a missing capability — it is blocked by nobody ever having completed a run during a sweep.

Units: screen:sequencer/live_frame_panel.dart, exposure_node_thumbnail_strip.dart, forensics_panel.dart, recovery_insights.dart, critical_event_banner.dart, meridian_flip_progress_dialog.dart, post_session_stats_dialog.dart, session_report_dialog.dart, session_report_forensics_section.dart, session_handoff_dialog.dart, replay_debug_screen.dart, frame_detail_dialog.dart, broadcast_panel.dart, smart_exposure_properties.dart, budget_filter_controls.dart, missing_specs_dialog.dart, note_tile.dart, global_notes_dialog.dart, target_notes_dialog.dart, sequence_diff_dialog.dart.

Build a short sequence (a few 2-5 s exposures so it completes quickly), run it, and then work the post-run surfaces from the completed run. Save a note so note_tile renders. The replay screen needs a recorded run — you will have one once the sequence finishes.`,
  },
  {
    key: 'remote-appliance',
    title: 'Remote / paired-appliance surfaces',
    body: `These are gated on \`backendProvider\` being a \`NetworkBackend\`. No hardware is needed, only a second process. The recipe is in reports/coverage/CLOSEOUT-PLAN.md under "Recipe: a paired appliance" and was verified working on 2026-08-09.

Units: widget:remote_directory_picker_dialog.dart, widget:remote_host_path_dialog.dart, widget:connection_stale_banner.dart, settings:rig-catalogs (connected state), settings:updates (connected state), settings:backup (WebDAV/S3 push and remote restore), screen:constellation/shared_target_detail_screen.dart, mobile:session_replay_screen.dart, mobile:checkpoint_resume_dialog.dart, mobile:first_run_setup_screen.dart.

Bind the appliance to the real interface (192.168.1.20), not loopback — a LAN claim over loopback is refused by design. Give the client its own SKOTIQ_DATABASE_DIR; the single-instance lock refuses two instances sharing one database path. For settings:backup, stand up a throwaway local WebDAV or S3-compatible endpoint if you can; if you cannot, say so plainly rather than calling the unit reached.`,
  },
  {
    key: 'narrow-mobile',
    title: 'Narrow and phone-only layouts',
    body: `Units: screen:sequencer/narrow_layout.dart, mobile_sequence_editor.dart, mobile_playback_bar.dart, screen:guiding/mobile_sections.dart, screen:imaging/fullscreen_image_viewer.dart, screen:planetarium/compass_calibration_dialog.dart, widget:guide_health_card.dart, widget:actions.dart, widget:filter_offsets.dart.

Two routes. \`tools/ui_audit/drive_android.py\` drives a real Android emulator where uiautomator supplies geometry, so controls can be tapped BY NAME — that is the right tool for the genuinely phone-only ones (compass_calibration_dialog is wrapped in \`if (isMobilePlatform)\`; guide_health_card, actions.dart and filter_offsets.dart are only instantiated by apps/mobile). For the responsive-breakpoint ones a narrower desktop window is enough — \`drive_linux.py\` has NO resize command today, so add one (xdotool windowsize) as part of this work; that gap is why every narrow-layout branch is unvisited.`,
  },
  {
    key: 'forced-failure',
    title: 'Surfaces that only appear when something is wrong',
    body: `Force the failure in a scratch profile rather than waiting for it.

Units: widget:catalog_setup_dialog.dart (needs BOTH star and DSO catalogs missing — note CatalogManager uses the SHARED application-support directory, so a fresh profile alone does not do it; point the app at an empty catalog dir), widget:database_recovery_launcher.dart (needs the database open to fail with a recovery/backup path present), screen:planetarium/star_catalog_fallback_banner.dart (bundled star catalog fails to load), screen:imaging/centering_dialog.dart and widget:details_panel.dart (both need a plate-SOLVED frame — see below), screen:transients/transient_card.dart (needs a transient alert; check whether one can be injected through the DB rather than a live feed).

centering_dialog and details_panel were blocked because the simulator could never be plate-solved. That is being closed in parallel (S9 in simulator-fidelity-backlog.md, and \`tools/sim_fidelity/plate_solve_probe.py\`). Check whether \`native/skotiq_native/bridge/src/sim_sky.rs\` has landed; if it has, configure the plate solver at ~/.local/share/skotiq-audit/astap/bin (astap_cli plus the d05 database are already there) and drive the real thing. If it has not, say so and leave those two unreached with an accurate reason.`,
  },
  {
    key: 'survivors-of-the-dead-code-cull',
    title: 'The two dead-code claims that were wrong',
    body: `Nine units were recorded unreached because a sweeper judged them dead. Six of those files have since been deleted outright and the regenerated inventory no longer lists them; \`settings:focus-model\` turned out to be a live design fault and is fixed. Two claims were simply WRONG, and they are yours:

* \`screen:suggestions/transient_alerts_panel.dart\` — recorded as "zero call sites, not even a test". False: \`screens/planner/planner_screen_parts/_recommendation_tab.dart\` instantiates \`TransientAlertsPanel\`. Reach it through the planner's Recommendation tab and sweep it properly.
* \`widget:variable_picker.dart\` — recorded at a path that no longer exists; the file now lives at \`packages/skotiq_app/lib/widgets/sequence/variable_picker.dart\`. Re-establish the truth about \`VariablePickerField\` and \`VariablePickerButton\`: count real INSTANTIATIONS outside tests and barrels (a bare grep counts a file's own declaration and its barrel export as "references"). If it is genuinely unreachable from any sequencer text field, that is a missing-capability finding, not a deletion — the sequencer's own settings advertise variables.

Then take \`widget:details_panel.dart\`, a \`part of\` catalog_overlay_widget.dart whose overlay only builds once the live preview holds a plate-SOLVED frame. Coordinate with the forced-failure cluster: if \`native/skotiq_native/bridge/src/sim_sky.rs\` has landed, the simulator can now be solved (ASTAP and its d05 database are at ~/.local/share/skotiq-audit/astap/bin) and this is reachable for the first time.

Careful with \`part of\` files generally: widget:actions.dart and widget:filter_offsets.dart are parts of focus_model_curve_card.dart, which apps/mobile DOES instantiate — a desktop-routing gap, not dead code, and they belong to the narrow-mobile cluster.`,
  },
  {
    key: 'settings-tail',
    title: 'The settings tail, and the one design fault',
    body: `Units: screen:settings/notification_routing_settings.dart -> _HomeAssistantSection (the tail of a ~3000px page, below the MQTT broker), MQTT transport Save/Test buttons, settings:captured-images (populated state), screen:settings/filter_settings_row.dart, settings:logs, settings:observing-lists.

\`settings:focus-model\` is already closed and is NOT yours — it was the one real design fault in this list (nothing mounted \`FocusModelSettings\`, so a whole settings screen shipped with no route into it) and it is now the third pane of \`AutofocusMergedSettings\`, pinned by \`focus_model_section_reachable_test.dart\`. Mentioned only so you do not re-report it.

filter_settings_row needs a filter wheel connected with named filters: connect the Simulated Filter Wheel and assign it to the profile first — connecting from Discovery without assigning leaves \`profile.cameraId\`/wheel empty and several shortcuts stay hidden. captured-images (populated) needs frames on disk.`,
  },
  {
    key: 'never-claimed-a',
    title: 'Units no sweeper ever claimed (first half)',
    body: `Nobody recorded these at all, with or without a reason: screen:analytics/frame_detail_dialog.dart, screen:collaborative_sky/coimaging_create_sheet.dart, screen:mosaic/mosaic_projects_list_screen.dart, screen:onboarding/capture_dir_step.dart, screen:planetarium/star_chart_depth_notice.dart, screen:sequencer/coordinate_lookup.dart.

Reach each one in the running app, exercise every control on it, and critique it as well as testing it.`,
  },
  {
    key: 'never-claimed-b',
    title: 'Units no sweeper ever claimed (second half)',
    body: `Nobody recorded these at all: screen:sequencer/sequence_issues_dialog.dart, screen:settings/connection_settings_alpaca_dialog.dart, screen:settings/settings_color_and_path_inputs.dart, widget:geolocation_consent.dart.

Also pick up the leftovers whose recorded reason is thin rather than substantive: screen:dashboard/next_use_prompt_card.dart (gated on the first-launch coach finishing and suppressed while the Smart Night prompt is eligible), screen:sequencer/secondary_rig_card.dart (needs a second connected rig — a second simulator profile may satisfy it), seq-node:PluginInstructionNode (needs a plugin registering a node blueprint; check whether the bundled plugin SDK examples can).

Reach each one, exercise every control, and critique it as well as testing it.`,
  },
]

function brief(cluster) {
  return `You are closing coverage gaps on the Skotiq astrophotography app (Flutter/Dart + Rust), repo root /home/scdouglas/Documents/Skotiq2.

## Why this exists
Every previous audit of this app wandered a path, found what was on it, and declared the area complete. This campaign built a denominator instead: \`reports/coverage/inventory.json\` lists every screen, settings row, sequence node and dialog, and \`reports/coverage/status.json\` records what has actually been exercised. 347 units are visited; **68 were recorded unreached with a reason and 12 were never claimed at all**. You are closing one cluster of those.

Read \`reports/coverage/CLOSEOUT-PLAN.md\` first — it clusters all 80 and flags four whose recorded reason is already stale.

## Your cluster: ${cluster.title}

${cluster.body}

## No fix from reading code — reproduce it first

The owner's rule, and it is absolute: **never fix a bug you found only by reading code.** See it in
the running app, confirm the app does the wrong thing, and only then fix it.

This campaign's own numbers are why. Roughly 38% of P0/P1 findings cited a \`file:line\` that did not
contain the claim — one pointed at a file with no weather or safety code in it at all — and 26
findings were refuted outright by an independent check. A code-read finding is a HYPOTHESIS. Fixing
a hypothesis edits working code and leaves the real symptom live.

So: reproduce, record what the app actually did (accessibility tree line, log line, or a cropped
screenshot), put that in \`evidence\`, then fix. If you cannot reach the surface to reproduce it, the
finding stays open with that reason — do not fix on faith, and do not quietly drop it.

## This is not only defect-hunting

The owner's standing instruction is explicit: it is not enough to ask "does this work as is?". For every surface you reach, also ask **would a user find this cumbersome? are the defaults right? what is this feature missing?** A finding of kind \`ux\`, \`default\` or \`missing\` is as valuable as a \`defect\` here, and several of this campaign's best results were wrong defaults (a narrowband mixer that opened with every channel weight at 0.00, i.e. rendering black; a weather radar that opened on the OLDEST frame; changing a flat count taking 27 clicks).

If something would decide *what the app is* rather than having an objectively right answer, do NOT decide it: set \`needsOwnerDecision\` and describe the options and trade-offs. If it has a right answer and the fix is confined, make the fix and add a test that fails when it is reverted.

## Driving the app

\`tools/ui_audit/drive_linux.py\` runs sandboxed desktop instances under Xvfb with a live accessibility tree, control STATES, window-cropped screenshots and \`click-img\` coordinate mapping. \`tools/ui_audit/drive_android.py\` does the same against a real Android emulator, where uiautomator supplies geometry so controls can be tapped BY NAME and a DISABLED control refuses the tap. Read the tool's own \`--help\` and header comment before using it.

Hard-won environment facts, all verified:
* Mesa 26 on this box only survives with \`GALLIUM_DRIVER=softpipe\` — llvmpipe crashes. \`LIBGL_ALWAYS_SOFTWARE=1\`, \`GDK_BACKEND=x11\`.
* \`SKOTIQ_DATABASE_DIR\` isolates the database. Use a scratch dir; never point a sweep at the real one.
* The single-instance lock refuses two instances sharing a database path, and \`pkill\`/\`pgrep\` patterns can match your own shell — kill by recorded PID.
* **Screenshots are what kill agents in this harness** (~2k tokens each). Prefer the accessibility tree, budget roughly 40 image reads for the whole run, and write findings to disk AS YOU FIND THEM rather than holding them to emit at the end. A context-exhausted agent loses its entire cluster.

## Recording your result

Write incrementally to \`reports/coverage/closeout/${cluster.key}.json\` — the same object you will return. Every unit in your cluster must end up with \`state: "visited"\` (with evidence) or \`state: "unreached"\` (with an honest, specific reason). **An unreached unit with a reason is still a unit nobody exercised** — do not dress one up as the other, and do not claim a unit you only read the source of. This whole campaign exists because that distinction was blurred.

## Rules
* This repo has a knowledge graph. Run \`graphify query "<question>"\` to orient BEFORE grepping or reading source files.
* Run tests as \`dart run melos exec --scope="<package>" -- flutter test <path>\`. Never \`flutter test packages/<pkg>/...\` from the root — it fails with a flutter_test dependency error. Redirect long runs to a file rather than piping through \`tail\`.
* App suites exclude the \`golden\` tag by design; golden baselines here are host-specific and gitignored. A golden pixel-diff on this Linux box is not a regression, and Linux-regenerated goldens must never be committed.
* Run \`dart format\` on everything you edit.
* NEVER run \`git stash\`, \`git checkout\` or \`git restore\` — other agents are working in this same tree.
* Report honestly. If a cluster is half-blocked, say which half and why.`
}

phase('Close')

const results = await parallel(
  CLUSTERS.map((cluster) => () =>
    agent(brief(cluster), {
      label: `close:${cluster.key}`,
      phase: 'Close',
      schema: SCHEMA,
    })
  )
)

const ok = results.filter(Boolean)
const units = ok.flatMap((r) => r.units || [])
const findings = ok.flatMap((r) => r.findings || [])
const visited = units.filter((u) => u.state === 'visited')

log(`${visited.length}/${units.length} units reached; ${findings.length} findings`)

return {
  clustersReporting: ok.length,
  clustersLost: CLUSTERS.filter((c, i) => !results[i]).map((c) => c.key),
  unitsReached: visited.length,
  unitsStillUnreached: units.filter((u) => u.state !== 'visited'),
  findingsByKind: findings.reduce((acc, f) => {
    acc[f.kind] = (acc[f.kind] || 0) + 1
    return acc
  }, {}),
  fixed: findings.filter((f) => f.fixed).length,
  needsOwnerDecision: findings.filter((f) => f.needsOwnerDecision).map((f) => f.title),
  findings: findings.map((f) => ({
    kind: f.kind,
    severity: f.severity,
    title: f.title,
    location: f.location,
    fixed: f.fixed === true,
    detail: (f.detail || '').slice(0, 500),
  })),
}
