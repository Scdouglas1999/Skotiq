# Coverage closeout plan — the units no sweep has actually exercised

Generated from `reports/coverage/status.json` and `inventory.json` on 2026-08-09.

> **2026-08-14 reconciliation (release-pass campaign)**: the Wave B/D/E/F/G live drives
> (reports/release-pass/gui/*.md) have since exercised most of the runtime-run cluster —
> completed sequences with session reports, live frame panels, exposure thumbnail strips,
> frame detail dialogs, post-run stats, meridian-flip progress (incl. a flip fired during
> an in-flight frame), replay screens (NEW-E2/E3), and the live-stacking broadcast panel
> (ND-1/SCI-28). The narrow-mobile blocker is STALE: drive_linux.py now has `resize` and
> `wheel`, and the waves drove 900/1000/1100px layouts extensively. A future closeout
> should re-run the inventory against the wave reports before claiming any of these
> unreached; the remaining genuinely-unreached residue is likely the remote-only gated
> states, recovery/critical-event surfaces, and the session-handoff dialog.
>
> **Denominator status (task #31, assessed 2026-08-14)**: the extension this task asked
> for LANDED on 2026-08-09 — coverage_inventory.dart now counts desktop-app, planetarium,
> design-system, web and API trees (see the dated comment at its unit-collection block).
> ~~What remains: (a) server/skotiq_hub is still uncounted; (b) the C3 file splits
> orphaned pre-split status.json history~~ **Closed 2026-08-14**: (a) the hub tree is
> counted (`hub:`-prefixed path-qualified units; inventory now 1182 units / 3826
> controls — the 28 hub files are NEW unswept denominator, honestly widening the gap);
> (b) reconciled by basename resolution — only two units were truly orphaned
> (session_report_forensics_section, sub_gallery_panel), both deleted as dead code in
> de5223a4f and now recorded `resolved-by-deletion`; every other pre-split id still
> resolves because the basename-keyed sources key on basename, not path. (c) the
> duplicate basename ids remain by design — and the C3 splits added a FOURTH
> (`screen:sequencer/node_palette.dart`: widgets/ and sequencer_screen_parts/ collide).
>
> **Hub sweep EXECUTED (2026-08-14): 28/28 visited, 0 unreached.** A live hub was
> driven through all 44 routes (auth/lockout, narrowed tokens, tile contribute→fuse→
> retract, calibration incl. poison-422, mosaic broker incl. 409/eviction, co-imaging
> SSE, moderation, the 429, the audit ledger); 89/90 driver checks passed. Two
> findings, BOTH FIXED in-session: H1 — login handed a fresh bearer token to a
> SUSPENDED account (false success audit row; now refused, pinned in auth_test); H2 —
> the earlier "hub counted" claim was FALSE (the control filter dropped every
> widget-less server file; inventory said 1182 with the hub contributing ZERO). The
> tool now counts controlless server units: **1,211 units / 3,827 controls**, and all
> 28 `hub:` status entries id-match the inventory. Findings file:
> reports/coverage/hub-sweep-findings.md.
>
> ~~Hub sweep charter (recon 2026-08-14)~~: the 28 newly-counted `hub:` units are NOT
> untested — the hub's own suite is 205/205 green (auth, coimaging, schema, fusion, DB
> upgrade). What they lack is the campaign's per-unit exercise ledger. The right sweep
> is API-driven, not GUI: stand the hub up locally, drive each service's endpoints the
> way the Collaborative Sky clients do (account/token/consent flows, tile submit/fuse,
> calibration share, mosaic broker claim/handoff, follow-the-night), and record each
> `hub:` unit visited/unreached in status.json — the same shape as the desktop
> `_apiUnits` sweep. One agent, one evening, no hardware.

**68 units recorded unreached with a reason, 12 never claimed at all.**
The inventory tool reports 390/402; that counts only the never-claimed. A unit whose sweeper
wrote down why they could not get to it is still a unit nobody exercised, so both belong here.

## Clusters, with what would actually unblock each

### runtime-run — 15 units

Run a real sequence against the simulators, end to end, and let it finish.
Nothing here is blocked by missing capability — it is blocked by nobody having run
a sequence to completion during a sweep. This is also where the product-critique
questions bite hardest, because these surfaces only ever appear mid-night.

* `mobile:session_replay_screen.dart` — SessionReplayScreen requires a runId and is pushed from exactly one place, session_picker_screen.dart:244 `builder: (_) => SessionReplayScreen(runId: run.id)`, inside the tap handl
* `screen:imaging/meridian_flip_countdown_banner.dart` — Mounted unconditionally at imaging_screen.dart:195 but renders nothing unless a meridian flip is pending. The simulated mount stayed Parked at RA 00h00m/Dec +00 for the whole sessi
* `screen:sequencer/broadcast_panel.dart` — Live-stacking broadcast run-time surface.
* `screen:sequencer/critical_event_banner.dart` — Run-time surface; requires a critical event during a run.
* `screen:sequencer/exposure_node_thumbnail_strip.dart` — Run-time surface; populated only by captured frames.
* `screen:sequencer/forensics_panel.dart` — Run-time/post-run surface.
* `screen:sequencer/frame_detail_dialog.dart` — Needs captured frames.
* `screen:sequencer/live_frame_panel.dart` — Run-time surface; needs an executing run with a connected camera.
* `screen:sequencer/meridian_flip_progress_dialog.dart` — Run-time surface; fires during an actual flip.
* `screen:sequencer/post_session_stats_dialog.dart` — Post-run surface.
* `screen:sequencer/recovery_insights.dart` — Run-time surface; requires recovery events.
* `screen:sequencer/replay_debug_screen.dart` — Needs a recorded run to replay.
* `screen:sequencer/session_handoff_dialog.dart` — Run/handoff surface, no run performed.
* `screen:sequencer/session_report_dialog.dart` — Post-run surface; requires a completed run.
* `settings:captured-images (populated state)` — Reached and rendered, but only its gated empty state ('Connect to a remote appliance to browse its captured frames'). The grid, thumbnails and metadata rows are remote-only (backen

### narrow-mobile — 6 units

Drive the Android emulator harness (`tools/ui_audit/drive_android.py`), or teach
`drive_linux.py` to resize its window — it currently has no resize command, which is
why every narrow-layout branch is unvisited.

* `screen:guiding/mobile_sections.dart` — Phone layout only. The harness runs a fixed 1600x900 window on Xvfb and drive_linux.py has no window-resize command, so the Responsive.isMobile branch of guiding_screen.dart could 
* `screen:imaging/fullscreen_image_viewer.dart` — Phone-only. live_preview_area.dart:239 gates FullscreenImageViewer.show on `Responsive.isPhone(context)`; on the 1600x900 desktop window the preview onTap is null. The toolbar's fo
* `screen:planetarium/compass_calibration_dialog.dart` — Phone-only. The dialog's only two call sites are the gyro-aiming toggles, and both are wrapped in 'if (isMobilePlatform)' (command_bar.dart:429-431 and the mobile view controls), s
* `screen:sequencer/mobile_playback_bar.dart` — Mobile layout + running sequence.
* `screen:sequencer/mobile_sequence_editor.dart` — Mobile layout; not selected on the desktop breakpoint.
* `screen:sequencer/narrow_layout.dart` — Requires a narrow window; the harness window geometry is fixed at 1920x1200.

### remote-appliance — 10 units

Run the headless appliance on localhost and pair the desktop client to it.
These surfaces are gated on `backendProvider` being a `NetworkBackend`; no hardware
is required, only a second process.

* `mobile:checkpoint_resume_dialog.dart` — Shown only from _checkForCheckpoint (mobile_reconnect_ops.dart:552-583), which runs once after a connection is established and returns early unless executor.getCheckpointInfo() yie
* `mobile:first_run_setup_screen.dart` — FirstRunSetupScreen is only mounted by mobile_dashboard_screen.dart:96 when shouldRunFirstRunSetupProvider resolves to setupNeeds.hasAnyMissing, which requires a live NetworkBacken
* `screen:constellation/shared_target_detail_screen.dart` — Reachable only from a live Constellation hub: the screen's only entry point is a shared target published by a federated hub, and Constellation is LAN-only/self-hosted with no hub o
* `screen:suggestions/slider_controls.dart` — Dead code. It is a `part of` suggestion_filters.dart, whose only class SuggestionFilters is referenced solely by packages/skotiq_app/test/screens/suggestions/suggestion_filters
* `settings:backup (WebDAV/S3 push and remote restore)` — no WebDAV or S3 endpoint is available to this sandbox; I exercised the three buttons only far enough to confirm they fail closed with 'Server URL is required.'
* `settings:rig-catalogs (connected state)` — the page requires an active NetworkBackend session to a remote appliance; with no appliance paired it renders only its explanatory note, so the download/verify controls could not b
* `settings:updates (connected state)` — same -- Appliance Updates drives /api/system/update/* on a remote rig and degrades to a note off-network. The local-desktop half is covered as a finding.
* `widget:connection_stale_banner.dart` — Renders only when backendProvider is a NetworkBackend (remote/paired client) and its websocket is inside the reconnect grace window; _handleRetry itself bails with 'The remote sess
* `widget:remote_directory_picker_dialog.dart` — Remote-client-only. Every caller (imaging capture_panel, calibration_section, flat-wizard save_path_dialog, onboarding capture_dir_step) branches on isRemote and falls back to file
* `widget:remote_host_path_dialog.dart` — Same isRemote gate — plate_solving_settings_screen, calibration_settings and phd2_guiding_settings all call it only when isRemote is true, otherwise they use the native open/save-f

### dead-code — 9 units

Not a coverage gap — a finding. Each of these is either deleted or wired up, and
either way the answer is a code change, not another sweep.

* `screen:imaging/focus_model_panel.dart` — Orphaned widget. `grep -rn FocusModelPanel` over packages/ returns only its own definition file plus a comment in screens/settings/widgets/focus_model_settings.dart that calls it '
* `screen:suggestions/sort_and_reset_controls.dart` — Same dead-code chain as slider_controls.dart (part of the unreferenced SuggestionFilters). The Sort/Reset controls that DO ship are the planner's own _SortDropdown/_ResetChip in sc
* `screen:suggestions/transient_alerts_panel.dart` — Dead code. `grep -rn TransientAlertsPanel packages/ --include=*.dart` returns only its own declaration at transient_alerts_panel.dart:29-30 — zero call sites, not even a test.
* `widget:actions.dart` — `part of` widgets/focus_model_curve_card.dart. FocusModelCurveCard has zero instantiations in the desktop app: repo-wide the only non-test caller is apps/mobile/lib/screens/dashboa
* `widget:guide_health_card.dart` — Instantiated only by apps/mobile (screens/dashboard/tabs/devices_tab.dart:101). Zero instantiations anywhere in the desktop app — the desktop Guiding screen renders its own Guide G
* `widget:object_info_panel.dart` — Dead code - no instantiation anywhere in packages/ or apps/ (not even in tests); only the barrel export at skotiq_app.dart:37 references the file. Nothing in the running app ca
* `widget:sequence_controls.dart` — Dead code - the only reference outside its own file is packages/skotiq_app/test/widgets/run_controls_paused_skip_test.dart:123. No screen mounts SequenceControls; the Sequencer
* `widget:tour_selection_sheet.dart` — Dead code - zero calls to TourSelectionSheet.show anywhere, despite the file's own doc comment claiming 'Used from Settings and contextual prompts'. Verified live: Settings > Help 
* `widget:variable_picker.dart` — Dead code - VariablePickerField has no callers outside test/widgets/variable_picker_test.dart, and VariablePickerButton is used only as that field's own suffixIcon. No sequencer te

### forced-failure — 6 units

Force the failure in a scratch profile: remove the catalogs, corrupt the database,
point the solver at nothing. Now unblocked for plate solving specifically — see S9 in
the simulator-fidelity backlog.

* `screen:equipment/fujifilm_disclaimer_dialog.dart` — The dialog is gated on selecting a Fujifilm camera. No Fujifilm driver or simulator is present (gPhoto2 detected 0 cameras, native discovery found 0 devices), so the disclaimer pat
* `screen:imaging/centering_dialog.dart` — Only opened from Slew & Center / dashboard quick actions / planetarium, all of which require a configured plate solver. ASTAP is not installed in this environment and the Framing w
* `screen:planetarium/star_catalog_fallback_banner.dart` — Only renders when the bundled star catalog fails to load. On this build the catalog loads (Catalog Settings reports HYG 119.6k / OpenNGC 14.0k both Installed 2026-06-11), so the fa
* `screen:transients/transient_card.dart` — The card only renders for an existing transient alert. No alert can be obtained on this build: MPEC/CBAT have no fetch implementation, TNS needs a bot API key with no field on this
* `widget:catalog_setup_dialog.dart` — Startup-only surface with exactly one call site (screens/shell/app_shell.dart:310) and it never fires on this machine. The gate needs BOTH star and DSO catalogs to be missing, but 
* `widget:database_recovery_launcher.dart` — Mounted at the app root (app.dart:198) but only surfaces when the database open fails and a recovery/backup path exists. Every launch in this sweep opened /tmp/ns-audit/r-shared-wi

### native-dialog — 2 units

Needs a window manager under Xvfb so the GTK chooser can be activated, or drive the
import service directly and sweep the dialog separately.

* `screen:sequencer/import_sequence_dialog.dart` — 'Import from NINA / SGP' opens the native GTK 'Open File' chooser. Under Xvfb+softpipe with no window manager it renders as an opaque black window and xdotool cannot activate it (_
* `screen:sequencer/import_summary_dialog.dart` — Only reachable after a successful file import, which is blocked by the undriveable native file chooser.

### budget — 6 units

Simply not reached before the sweeper ran out of context. Re-sweep with a tighter scope.

* `MQTT transport Save/Test buttons (screen:settings/mqtt_transport_section.dart)` — Fields were enumerated and one (Topic) was edited live, but I did not press 'Save MQTT config' / 'Test MQTT'. The other six transports' Test buttons were all exercised and all beha
* `screen:sequencer/budget_filter_controls.dart` — Part of the Smart Exposure properties panel, which I did not reach (see above).
* `screen:sequencer/global_notes_dialog.dart` — Reached the per-target 'New note' editor but not the global 'Browse all notes' dialog (it lives on the History tab and I did not open it).
* `screen:sequencer/smart_exposure_properties.dart` — Smart Exposure node was added and round-tripped through the DB, but its properties panel sits below the pinned minimap strip in the tree scroll and I ran out of budget before selec
* `screen:settings/filter_settings_row.dart` — A sub-row of the Autofocus filter table, rendered only when a filter wheel is connected with named filters. Not reached in this pass: the fresh profile lands on the Equipment first
* `screen:settings/notification_routing_settings.dart -> _HomeAssistantSection (tail of the Notifications page, below MQTT broker)` — The Notifications page is ~3000px of scroll; I enumerated it down through the MQTT broker section and ran out of budget before the final Home Assistant routing block. Home Assistan

### other — 14 units

Read the recorded reason and decide individually.

* `screen:dashboard/next_use_prompt_card.dart` — Never rendered in four sessions on this profile. The card is gated on the first-launch coach being finished (and suppresses itself whenever the Smart Night prompt is eligible); onb
* `screen:equipment/switch_control_card.dart` — No Switch device exists on this platform. Discovery honestly reports 'No switches found' (log line 'Discovery complete for Switch: 0 devices, 0 backend errors'), and there is no wa
* `screen:first_light/first_light_detail_screen.dart` — Already marked visited in reports/coverage/status.json by the equipment/diagnostics/shell/onboarding/first_light/tutorial sweep, so per the assignment rules it is not mine to re-au
* `screen:sequencer/missing_specs_dialog.dart` — Never triggered; no flow in the builder raised it during the sweep.
* `screen:sequencer/note_tile.dart` — No notes were saved, so no tile rendered.
* `screen:sequencer/secondary_rig_card.dart` — Requires a second connected rig.
* `screen:sequencer/sequence_diff_dialog.dart` — No entry point found while idle. The library card exposes preview / run-history / version-history / tags / open / duplicate / export / delete; version history offers only Restore, 
* `screen:sequencer/session_report_forensics_section.dart` — Part of the session report dialog.
* `screen:sequencer/target_notes_dialog.dart` — Only the inline Notes strip on the target header card was exercised.
* `seq-node:PluginInstructionNode` — Only surfaces in the palette when a plugin registers a node blueprint (node_palette.dart:510-571 builds 'Plugins / <category>' sections from pluginNodeBlueprintsProvider, whose def
* `seq-node:PolarAlignmentNode` — Not present in the node palette. I enumerated every palette category live (Target, Imaging, Science, Guiding, Mount, Dome, Flat Panel, Focus, Camera, Logic, Timing, Utilities = 36 
* `settings:focus-model / screen:settings/focus_model_settings.dart` — Unreachable BY DESIGN FAULT, not by budget: no SettingsSectionDef with key 'focus-model' is built (settings_catalog.dart:591-678) and the alias kMergedSectionAliases['focus-model']
* `widget:details_panel.dart` — A `part of` catalog_overlay_widget.dart, whose only non-test instantiation is screens/imaging/widgets/live_preview_area.dart:445. That overlay only builds once the live preview hol
* `widget:filter_offsets.dart` — Same file family as actions.dart - `part of` focus_model_curve_card.dart, which is instantiated only by apps/mobile devices_tab.dart. Not reachable from the desktop app.

### never claimed — 12 units

No sweeper recorded these at all, with or without a reason.

* `screen:analytics/frame_detail_dialog.dart`
* `screen:collaborative_sky/coimaging_create_sheet.dart`
* `screen:mosaic/mosaic_projects_list_screen.dart`
* `screen:onboarding/capture_dir_step.dart`
* `screen:planetarium/star_chart_depth_notice.dart`
* `screen:sequencer/coordinate_lookup.dart`
* `screen:sequencer/sequence_issues_dialog.dart`
* `screen:settings/connection_settings_alpaca_dialog.dart`
* `screen:settings/settings_color_and_path_inputs.dart`
* `settings:logs`
* `settings:observing-lists`
* `widget:geolocation_consent.dart`


## Reasons already known to be stale

A recorded reason is a snapshot of the tree at sweep time, and several have since been overtaken.
Re-checking the reason is part of the work; taking it at face value is how a closed gap stays on
the books.

* `screen:equipment/switch_control_card.dart` — "No Switch device exists on this platform" is no
  longer true. `api/discovery.rs:882` advertises `sim_switch_1`, `ops/switch.rs` has a real
  `DriverType::Simulator` arm, and `device_manager/mod.rs` tests it. See S7 in
  `simulator-fidelity-backlog.md`.
* `seq-node:PolarAlignmentNode` — "absent from the palette" was refuted live on 2026-08-05: the
  Nodes search for `Polar` lists **Polar Alignment / Measure polar error by rotating in RA** under
  Mount.
* `screen:imaging/centering_dialog.dart` and `widget:details_panel.dart` — both were blocked on
  plate solving, which under the simulator could never succeed. That is now a solved problem in
  principle; see S9.
* `screen:first_light/first_light_detail_screen.dart` — not a gap at all. The sweeper declined it
  because another sweep had already claimed it, so it is double-counted as unreached.

## The one design fault in this list

`settings:focus-model` is not unreached for want of effort or hardware. `settings_catalog.dart`
builds no `SettingsSectionDef` with key `focus-model`, so `focus_model_settings.dart` has no route
into it from the settings shell at all. A settings screen that ships with no way to open it is a
defect, not a coverage gap, and closing it is a code change.

## Recipe: a paired appliance with no hardware and no second machine

Verified working on 2026-08-09. This is what unblocks the `remote-appliance` cluster.

```
mkdir -p /tmp/ns-appliance/data
cd apps/desktop/build/linux/x64/release/bundle
SKOTIQ_DATABASE_DIR=/tmp/ns-appliance/data \
  ./skotiq_desktop --headless --require-auth --pairing-print-codes
```

Came up in ~1 s on `http://127.0.0.1:8080`. `SKOTIQ_DATABASE_DIR` does isolate the database
(`/tmp/ns-appliance/data/skotiq.db` plus its own `pairing.db`); the "Data directory:" line the
appliance prints still points at the real application-support directory and is about catalogs and
checkpoints, not the database — do not read it as a sign the isolation failed.

Two things to plan around:

* Without `--allow-unauthenticated-lan` the server binds loopback only, and a LAN claim over
  loopback is refused by design (relay security — a settled won't-fix). Bind the real interface
  (192.168.1.20 on this machine) for anything that has to pair.
* The client is the same binary: `--remote-host <host>:<port>`. It refuses to combine that with
  `--serve/--master`, and the single-instance lock refuses two instances sharing a database path,
  so give the client its own `SKOTIQ_DATABASE_DIR` too.

## Adjudicated 2026-08-09 — what this list actually contains

Before handing the clusters out, every entry was re-checked against the current tree. The list
shrank, and not in the flattering direction: most of the shrinkage is code that was deleted rather
than surfaces that were exercised.

* **Six of the nine "dead code" units no longer exist.** `object_info_panel.dart`,
  `sequence_controls.dart`, `tour_selection_sheet.dart`, `focus_model_panel.dart`,
  `slider_controls.dart` and `sort_and_reset_controls.dart` were reported as findings and then
  deleted, and the regenerated inventory no longer lists them. They are recorded as
  `resolved-by-deletion`, not as unreached.
* **Two of the nine claims were wrong.** `transient_alerts_panel.dart` was recorded as having
  "zero call sites, not even a test" — `planner_screen_parts/_recommendation_tab.dart`
  instantiates it. `variable_picker.dart` was recorded at a path it no longer occupies; it lives
  at `widgets/sequence/variable_picker.dart`. Both are still open and still need sweeping.
* **`settings:focus-model` was the one real defect in the list, and it is fixed.**
  `kMergedSectionAliases` mapped `focus-model` onto `autofocus` and `kSettingsSectionIndex` listed
  the key, so every deep link and search hit resolved successfully — to an Autofocus pane that did
  not contain the widget. Repo-wide, `FocusModelSettings`'s only references were inside its own
  declaration. It is now the third pane of `AutofocusMergedSettings`;
  `focus_model_section_reachable_test.dart` goes red when the mount is severed.

**The honest denominator after adjudication: 55 unreached units that are still in the inventory,
12 never claimed, and 6 free-form sub-states** (the MQTT Save/Test buttons, the Home Assistant
section, `settings:backup` over WebDAV/S3, `settings:captured-images` populated,
`settings:rig-catalogs` connected, `settings:updates` connected). Sub-states are not inventory ids
— the inventory counts each of those settings pages once — but they are real work and dropping them
because they lack an id would be the same accounting failure this campaign exists to end.
