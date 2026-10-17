# Closeout wave findings — 2026-08-09

Generated from workflow `wf_2f69338e-00e` (8 clusters, 51 of ~73 units reached).
Counts: {'defect': 38, 'default': 5, 'missing': 12, 'ux': 19}. 25 were fixed in place by the agent that found them.

Ordered most severe first. `fixed: true` means the finding was repaired during the wave.

## [P1 / defect] A run can stall 30 minutes per frame waiting for a meridian flip that is hours overdue and will never fire, and the UI says only 'Running'

`native/skotiq_native/sequencer/src/instructions.rs:1954`

Live repro, run #2 (12 x 5s LIGHT on a target at RA 12.5h Dec +70, site 40N 42E). Frame 1 captured and saved normally; the run then froze at '1/12  8%' for the rest of the session. App log at 21:24:12.219964Z: 'Waiting for the meridian flip before the next 5s exposure: the flip fires in ~0s (hour angle +8.93h, threshold 5 min past meridian) and would interrupt the frame'. No 'Capturing frame 2/12' line ever followed. fire_in_secs = (threshold_min - ha*60)*60 goes hugely NEGATIVE when the target 

## [P1 / defect] Enabling the 'Live Frame' dashboard widget blanks the entire primary column - it lays out at infinite height and the engine drops the layer  — FIXED

`packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/live_frame_panel.dart:74`

Live repro: Dashboard > Edit Dashboard > Widgets > tick 'Live Frame' > Done. Now Imaging, Frames and Live Frame are all still ticked in the picker, but the primary column renders NOTHING (in edit mode the tiles show as empty placeholders). The app log starts emitting 'TransformLayer is constructed with an invalid matrix' at that exact moment (app.log:690 onward, 33 times, none earlier in the session). Cause: dashboard tiles are laid out in a vertical scroll view, so this widget builds with const

## [P1 / defect] Plate-solver settings cannot be saved from a remote client unless all three solver paths are already non-empty  — FIXED

`apps/desktop/lib/headless_api/handlers/imaging_handlers.dart:228`

Reproduced twice in the GUI ('Failed to save plate-solver settings: Value must not be empty (invalid_request) [HTTP 400]', row stayed 'Not set') and then isolated at the API. POST /api/plate-solver/config used requireString() for astapPath, astrometryPath, catalogPath and solverChoice, so an empty astrometryPath — the normal state for anyone running ASTAP only — failed the whole save: curl with {"astapPath":"…/astap","astrometryPath":"","catalogPath":"/tmp","solverChoice":"astap"} returned 400 {

## [P1 / defect] The "database recovered" notice never appears in the one case where the data is recoverable

`packages/skotiq_app/lib/widgets/database_recovery_launcher.dart (_maybeShow / _showRecoveryDialog)`

Three controlled variants, same marker payload. (a) Real corruption, pre-flight rotated the file: dialog SHOWN with 'Re-checked just now: SQLite still cannot read this file' (screenshot /tmp/ns-forced/db1f.png). (b) Marker staged with NO skotiq-corrupt-* file: dialog SHOWN, marker left on disk until acknowledged. (c) Marker staged with a HEALTHY skotiq-corrupt-*.db beside it, run TWICE: NO dialog across ~30 s of polling the a11y tree, and the .recovered-on-*.txt marker deleted within 4 s

## [P1 / defect] S9 is not closed in the shipped app: the simulated camera still does not render the catalogue sky

`native/skotiq_native/bridge/src/device_manager/ops/camera.rs:129 sim_sky_view / src/sim_sky.rs configured_index`

The closeout plan treats centering_dialog and details_panel as unblocked because sim_sky landed. The machinery works — `cargo test -p skotiq_bridge --lib sim_sky_wiring -- --ignored` prints 'downloaded frame solved, centre error 0.5"' — and the compiled bridge in the bundle is the current build. The running desktop app never engages it. Live setup: sim camera + sim mount connected from a saved 400 mm / 3.76 um profile (the app computed 1.94 arcsec/px itself), plate-solver preference loaded a

## [P1 / defect] The Imaging screen's simulated capture still paints a random star field, so nothing captured under simulation can be plate-solved

`native/skotiq_native/bridge/src/api/imaging.rs:791 (sim branch) and :1304 generate_simulated_image; contrast native/skotiq_native/bridge/src/device_manager/ops/camera.rs:1217`

S9 added a real-sky renderer (sim_sky.rs + sim_frame::synthesize_sim_frame) and wired it into device_manager/ops/camera.rs:1217, but the capture the Imaging screen actually performs goes through api/imaging.rs, whose `device_id.starts_with("sim_")` branch calls generate_simulated_image() (imaging.rs:1304-1344) - background plus rand::thread_rng() stars at random positions with random brightness. Reproduced end to end on the release build with everything else correct: ASTAP + D05 detected and set

## [P1 / defect] Rejected frames are never persisted to frame_forensics — the whole forensics surface is dead data in production

`packages/skotiq_core/lib/src/providers/sequence/sequence_executor/event_operations.dart (case 'FrameRejected'); packages/skotiq_core/lib/src/services/forensics_service.dart recordRejection`

Proven live across four graded runs (2026-09-12, min-stars 99999 so every light frame rejects): 12 frames landed in captured_images with is_accepted=0 / runtime_grade='reject', the native sequencer logged '[FORENSICS] Frame N/M cause=... evidence=[...]' for every reject, and the FrameRejected wire event carries the full forensics payload (likely_cause_label, evidence, environment stats — event_translation.rs). Yet frame_forensics stayed EMPTY except for two rows I seeded by hand. The Dart FrameRejected handler calls _carryFrameVerdict(accepted:false) + _registerSequenceFrame and breaks — it never calls ForensicsService.recordRejection, the only code path that inserts into frame_forensics and broadcasts to forensicsStreamProvider. Consequence: the 'Frame forensics' cockpit panel (opt-in widget), run_dashboard/frame_detail_dialog, and the report-side forensics provider (forensicsRecordsForRunProvider — which additionally has NO production watcher and no report section file left in the tree) can only ever render seeded/test data. One call-site fix unwedges the entire surface.

Evidence: sqlite — captured_images rows 12-21 is_accepted=0 vs frame_forensics only seeds; app.log 16:34-16:55 [GRADE]...REJECTED + [FORENSICS] lines; shots 252-c3.png / 253-detail.png (panel + dialog rendered with seeds).

## [P1 / defect] Recovery loops run and are recorded natively but never reach Dart — recovery banner, report Recoveries section, and persisted history are all unreachable

`packages/skotiq_core/lib/src/providers/recovery_provider.dart:175 (recoveryEventBridgeProvider)`

Run #8 (2026-09-12) executed a complete native recovery loop live: 3 consecutive grading rejects → '[RECOVERY] Attempt 1/9 (cause=ConsecutiveRejectsExceeded)' → escalation to operator Pause → UNATTENDED-rig SafeAbandon (mount parked, run Failed, ExecutorEvent::RecoveryGaveUp emitted — monitoring.rs:496). The Dart side recorded nothing: session_diagnostics.recovery_history_json persisted [] for session 9, and no Recoveries section appears in the session report. Cause: recoveryEventBridgeProvider — the sole forwarder from SequencerEvent_Recovery* wire events into currentRecoveryProvider/recoveryHistoryProvider — is never ref.watch-ed or ref.read anywhere in app/core/desktop code (only in tests). Its doc comment claims 'the Run Dashboard scaffolding watches it'; no watcher exists. currentRecoveryProvider therefore never populates (recovery_banner dead live), recoveryHistoryProvider stays empty (report section + recovery_history_json dead), all despite the native side emitting RecoveryStarted/Progress/GaveUp correctly. Same defect family as the frame_forensics wire: production events + translation + consumers all exist, but the bridging provider is never activated.

Evidence: app.log run #8 recovery lines 2034-2042 ('Stopping mount tracking', 'Attempt 1/9', 'escalated ... UNATTENDED rig ... abandoning safely', 'Parked mount'); sqlite session_diagnostics session_id=9 → recovery_history_json='[]'; grep -rn recoveryEventBridgeProvider packages apps → only comments + tests.

## [P2 / defect] A reject-storm 'pause for inspection' never lands on a guider-less rig — the queued dither kills the run first, and unattended rigs abandon outright

`native/skotiq_native/sequencer/src/executor/recovery_ops.rs:254 (PauseForOperator); executor/monitoring.rs:386 (apply_recovery_escalation)`

Live on runs #5/#6/#7: when image grading hit '3 consecutive rejects' the executor logged 'Sequence paused for inspection' and '[RECOVERY] Promoted consecutive-reject storm to recovery', but the in-flight post-frame dither executed before the pause could take effect and failed hard — 'Dither failed: Built-in guider dither requires active guiding; not guiding' — failing the whole run in the same tick. The advertised operator-pause path is effectively unreachable with ditherEvery>0 and no guider. With ditherEvery=0 (run #8) the recovery driver did engage, but an unattended rig (operator_present=false, the default) escalates to SafeAbandon — park + close + fail the run — rather than pausing. So on a default unattended rig a reject storm ALWAYS ends the run; the 'paused for inspection' state the error message announces never actually exists for the operator to find.

Evidence: app.log 16:34:49 / 16:38:35 'Promoted ... to recovery' immediately followed by 'Dither failed ... Exposure failed' → NodeCompleted Failure; 16:55:17 same promotion → 'abandoning safely (park + close cover + close dome)' → run Failed.

## [P2 / defect] Inline sequencer quick-edit popovers commit from a stale node snapshot, so a stepper only ever moves by one  — FIXED

`packages/skotiq_app/lib/screens/sequencer/widgets/node_summary_inline_editors.dart:195`

Live repro: tapped the Take Exposures count chip (value 4) to open the 'Exposure count' popover, then clicked '+' EIGHT times. The node chip and the thumbnail strip went 4 -> 5 and stopped ('0 / 5 frames'), while the popover kept rendering '4'. A ninth '+' still produced 5; two '-' clicks produced 3 - i.e. every click re-applies snapshot+-1. Root cause: showInlineNodeEditor passes the node captured at tap time into _InlineEditorBody, which never re-reads the live tree, so each editor commits sna

## [P2 / defect] Pre-Flight says the sequence 'has changed since last successful run' while diffing against a run that failed

`packages/skotiq_app/lib/screens/sequencer/widgets/sequence_diff_dialog.dart / preflight_validation_dialog.dart`

Live: run #3 completed successfully at 17:33 with 12 accepted frames using exactly 5.0s x12 at RA 22.5000 / Dec 50.0000, and nothing was edited afterwards. Pressing Start at 17:57 still raised 'Sequence has changed since last successful run - 2 changes ... 2 modified node(s)', and 'View changes' listed duration 3.0s -> 5.0s, frame count 4 -> 12, RA 12.5 -> 22.5, Dec 70 -> 50. Those are the values of run #1, which FAILED after one second with zero frames. The comparison base is the last run with 

## [P2 / defect] The critical-event banner shows errors from earlier runs on top of a healthy run, with no run attribution

`packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/critical_event_banner.dart`

Live: run #1 (17:12:20 daylight gate) and run #2 (17:28:50 sequence cancelled) each left a critical event. Starting run #3 did not clear or scope them, so the whole time run #3 was capturing normally the dashboard carried a full-width red 'Sequencer error' banner about two runs that had already ended, and the events carry only a wall-clock time - nothing says which run they belong to. One screenshot shows 'Run complete - start another pass' and status 'Completed' directly underneath two red erro

## [P2 / defect] The auto-composed run note says the sequence 'completed' even when it was cancelled

`packages/skotiq_app/lib/screens/sequencer/widgets/notes_panel`

Live: run #2 was stopped by hand; the Session Report for it reads 'New Sequence - paused-stopped' with Errors 'Sequence cancelled'. The note the app pre-composed for that same run reads '**New Sequence** completed in 4m 44s.' The note is what the user keeps, so it is the copy most likely to be believed months later.

## [P2 / defect] Smart Night's 'Next' looks enabled on the Equipment step but does nothing when the profile has no camera, with no explanation

`packages/skotiq_app/lib/screens/sequencer/widgets/smart_night_dialog.dart`

Live: opened Smart Night with an active profile that has no devices ASSIGNED (the simulators were connected session-only, which the Equipment page itself warns about). Step 1 Window advanced fine. Step 2 Equipment renders 'Camera <no camera>', 'OTA <no telescope> (0mm @ f/0.0)', 'Mount <no mount>'. The Next button is painted in the same enabled blue as on step 1 and the accessibility tree reports it as a plain 'button: Next' with no DISABLED state, but four separate clicks left the stepper on '2

## [P2 / defect] The Altitude Limit trigger fires every 60s requesting 'next target' when there is no next target, and the run neither advances nor ends

`native/skotiq_native/sequencer/src/instructions.rs (trigger dispatch) / sequencer run header`

Same live run #2. The single target sat at 24.8 deg, below the 30 deg Min Altitude default, so the log shows 'Trigger fired: Altitude Limit (altitude_limit) - action: NextTarget' / 'Trigger requested advance to next target' repeating once a minute (21:24:05, 21:25:05, 21:26:05 ...). There is only one target, so nothing advances; the run stays 'Running' forever and the header's only explanation is the sub-line 'Trigger Altitude Limit fired: NextTarget'. A NextTarget action with no next target sho

## [P2 / default] Integration budget switches on with Total time 0.00 h, and the panel's own readout says the resolved budget is 0m

`packages/skotiq_app/lib/screens/sequencer/widgets/target_node_properties/integration_budget_section.dart`

Live on the Target node properties: flipping 'Integration budget' ON leaves 'Total time (hours)' at 0.00 and the panel immediately prints 'Resolved budget - Total: 0m (sum of caps)' with 'Stop target when budget met' defaulted ON. Adding a per-filter cap of ratio 1.00 does not change it. A budget that resolves to zero the instant it is enabled is the same shape as the narrowband mixer that opened at 0.00 - the feature is armed and set to stop immediately. The runtime consequence was not isolated

## [P2 / defect] Remote folder picker opens in the appliance's install directory and the curated 'Host roots' list is never reachable  — FIXED

`packages/skotiq_app/lib/screens/imaging/widgets/capture_panel.dart:198,651`

Reproduced live: with no capture folder set ('Not set — choose a folder'), the host folder picker opened at /home/…/build/linux/x64/release/bundle — the appliance process's working directory. The appliance already serves a curated root list for exactly this case: GET /api/files/browse with no path returns {"currentPath":null,"directories":[Documents, Backups, Scratch]} (plus Image Output / Sequences / Logs / SKOTIQ_BROWSE_ROOTS entries), and the dialog even has a label for it ('Host roots').

## [P2 / defect] Appliance catalog Verify always reports failure, in raw Dart error text  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/rig_catalog_settings.dart:207 (_verifyCatalog) / packages/skotiq_planetarium/lib/src/catalogs/catalog_manager/unified_catalog_api.dart:747`

Reproduced live: Settings > Appliance Catalogs > Verify (stars) showed the red snackbar 'Verify failed: Bad state: no_expected_hash'. The appliance answered POST /api/catalog/verify with {"stars":{"ok":false,"actualHash":"b2983a8d…","errors":["no_expected_hash"]}} — it computed the digest but had no baseline, because none of the installed catalogs' *_metadata.json sidecars carry a sha256 field. 'Cannot verify' was being reported as 'verification failed', which for a plate-solve catalog reads as 

## [P2 / defect] First backup push to a spec-compliant WebDAV server always fails with a 409 'remote state conflict'  — FIXED

`packages/skotiq_core/lib/src/services/sync/webdav_sync_target.dart:137 (ensureDirectory)`

Found by a decisive experiment rather than by reading: my first throwaway DAV server used makedirs and the push succeeded; making MKCOL obey RFC 4918 §9.3.1 (409 when the parent collection is absent) made the very same push fail, and /api/sync/status recorded lastError 'Create directory "skotiq-sync" failed: remote state conflict (HTTP 409)'. WebDavSyncTarget.ensureDirectory walked only the segments of the RELATIVE path while _uriFor prepends baseUrl.pathSegments, so with serverUrl http://ho

## [P2 / defect] FirstRunSetupScreen is unreachable in any shipped build

`apps/mobile/lib/screens/dashboard/mobile_dashboard_screen.dart:96 / apps/mobile/lib/main.dart:509 / apps/mobile/lib/companion_ui_config.dart:7`

apps/mobile/lib/screens/setup/first_run_setup_screen.dart ('First-run setup': image output path, catalogs, equipment profile, including its own 'Choose capture folder on host' remote picker) is mounted only by mobile_dashboard_screen.dart:96, and MobileDashboardScreen is instantiated only at main.dart:509 inside `if (useCompanionUi)`. isCompanionUiEnabled is false unless the APK was compiled with --dart-define=SKOTIQ_COMPANION_UI=1 or the process environment carries SKOTIQ_COMPANION_UI=1

## [P2 / defect] Mobile app renders a working dashboard while its event websocket is being refused 401, and floods unhandled exceptions

`packages/skotiq_core/lib/src/backend/network_backend/connection_lifecycle.dart:281`

Reproduced twice on the emulator (against a sibling appliance on :8099 and again against mine on :8080 before pairing). logcat shows a continuous storm of 'Unhandled Exception: WebSocketChannelException: … /events?apiVersion=2.6.0 was not upgraded to websocket, HTTP status code: 401' — several per second, each a full unhandled-error dump through dart_vm_initializer — while the UI showed a normal dashboard (TONIGHT'S BRIEFING, Readiness, a green '3 ms' latency chip) with nothing saying the device

## [P2 / defect] Plate Solving page contradicts the host's own /api/plate-solver/config, and the host appears to hold two disagreeing solver stores

`packages/skotiq_app/lib/screens/settings/plate_solving_settings_screen.dart + packages/skotiq_core/lib/src/services/plate_solve_service.dart:908/945 (detect vs getConfig)`

Reproduced, then PARTLY REFUTED on root cause — reported as it actually stands rather than as first written. Proven: with the thin client paired, GET /api/plate-solver/config on the appliance returned astapPath /home/scdouglas/.local/share/skotiq-audit/astap/bin/astap_cli, astrometryPath "", catalogPath …/astap/bin, solverChoice auto, while Settings > Plate Solving showed 'ASTAP executable /tmp/ns-audit/fake-astap/astap' and 'ASTAP catalog directory: Auto-detect — not found / Not set'; after

## [P2 / defect] Escape does not close the fullscreen frame inspector, and its only exit has no accessible name  — FIXED

`packages/skotiq_app/lib/screens/imaging/widgets/fullscreen_image_viewer.dart`

The viewer is an opaque full-screen PageRouteBuilder with no barrier, so off Android its only exit is a 40px circle in the corner. Reproduced at 420x900: Escape pressed, viewer still up (scratchpad/shots/d2-afteresc.png). Every other modal in the app dismisses on Escape. The route's whole accessibility subtree is a single `button:` node with an empty name — the IconButton tooltip did not reach AT-SPI — so the sole exit is unnamed for assistive tech too.

## [P2 / missing] The temperature-compensation focus model cannot be bootstrapped from the UI, and the card instructs the user to do something that does not work

`packages/skotiq_app/lib/widgets/focus_model_curve_card.dart:182 and packages/skotiq_core/lib/src/services/device_service/autofocus_controls.dart:612`

The empty card says 'Run an autofocus to start building the temperature compensation curve' and offers a Run autofocus button. I ran one on the desktop against the simulator: it converged (best 25069, HFR 2.10, R² 0.944) and the card did not change. Two confirmed reasons. (1) _recordPredictiveAfOutcome returns early with no filter wheel connected ('skipping training (no active filter to key the model)'), so on any filterless OSC rig autofocus trains nothing — focus_models stayed at 0 rows. (2) E

## [P2 / defect] The mobile companion dashboard is off in every shipped build, so three of its surfaces can never be seen by a user

`apps/mobile/lib/companion_ui_config.dart:7`

isCompanionUiEnabled defaults to false and is enabled only by --dart-define=SKOTIQ_COMPANION_UI=1 or the same env var. Repo-wide that define appears in no build script, gradle file or CI workflow, and a default launch of the installed APK lands on the shared SkotiqApp shell (Home/Gear/Imaging/Sequence/Guiding/Plan/More), not the tabbed dashboard — verified live. Every surface only the companion dashboard mounts is therefore dead in the shipping product: MobileSequenceEditor, GuideHealthC

## [P2 / defect] The mobile app presents itself as connected while every request to the appliance is being rejected 401

`packages/skotiq_core/lib/src/backend/network_backend/connection_lifecycle.dart:281 (symptom surfaced in apps/mobile connection flow)`

With a fail-closed headless appliance on the LAN, the app auto-discovered it, declared the connection good, ran First-run setup and dropped into the dashboard — while logcat looped 'WebSocketException: Connection to http://10.0.2.2:8099/events was not upgraded to websocket, HTTP status code: 401' and every REST read failed identically. The user-visible result is a Devices tab reading 'No active equipment profile' with every device Offline, indistinguishable from an idle rig. Nothing in the UI sa

## [P2 / defect] Catalog Setup advertised the Complete package's contents no matter which package was selected  — FIXED

`packages/skotiq_app/lib/widgets/catalog_setup_dialog.dart`

Live: with both catalogs missing, the startup dialog rendered 'HYG Star Database ~120,000 stars' and 'OpenNGC ~13,000 DSOs (NGC/IC)' under green ticks, above a selector defaulting to Standard (~30 MB). Selecting Essential (~10 MB) left both lines unchanged (screenshots /tmp/ns-forced/cat1c.png, cat2c.png). Those are the Complete figures; Essential installs ~9,000 stars / ~2,000 objects and Standard ~40,000 / ~8,000, so the default was advertised as three times — and the smallest as thirteen time

## [P2 / defect] Native settings, equipment profiles and the plate-solver preference live in ~/Documents, outside every isolation knob

`apps/desktop/lib/desktop_logging_init.dart:148-152`

A brand-new scratch profile (fresh SKOTIQ_DATABASE_DIR, fresh XDG_DATA_HOME) opened Settings > Plate Solving already populated with '/tmp/ns-audit/fake-astap/astap' — a nonexistent path left by a different sweep on 2026-08-01. The store is ~/Documents/Skotiq/profiles/{profiles,settings,platesolver}.json: getApplicationDocumentsDirectory() joined with 'Skotiq/profiles', which honours neither SKOTIQ_DATABASE_DIR nor XDG_DATA_HOME. It is live-shared too: after I pointed platesolver.

## [P2 / missing] Auto-queue bright transients enforces a magnitude the app gives you no way to change  — FIXED

`packages/skotiq_app/lib/screens/suggestions/widgets/transient_alerts_panel.dart:872`

TransientAlertSettings.autoQueueMagnitude defaults to 10.0 and transient_alert_service.dart:771 gates auto-queueing on `alert.magnitude <= autoQueueMagnitude`. Most transients an amateur rig can reach sit at mag 13-17, so a hard 10.0 makes the switch effectively inert. The value is settable over the headless API (apps/desktop/lib/headless_api/handlers/transient_handlers.dart:144-158) and by TransientAlertSettingsNotifier.setAutoQueueMagnitude (transient_alert_provider.dart:362), which had zero U

## [P2 / defect] Home Assistant publish toggle draws ON after being refused, then Save says it was saved  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/notification_routing_settings/home_assistant_section.dart:74`

With no MQTT broker host set, tapping 'Publish to Home Assistant' left the switch drawn ON while the subtitle still read 'Configure the MQTT broker above first'. Pressing 'Save Home Assistant config' then reported 'Home Assistant config saved'. Returning to the page (Settings -> Equipment -> Settings -> Notifications, scrolled to the tail) showed the toggle OFF again, while 'Device name' = Backyard Rig and 'Allow control' = ON had both persisted -- so the user is told the integration is on and o

## [P2 / defect] Alpaca and INDI "Test Connection" print the Dart error object's debug form to the operator  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/connection_settings_alpaca_dialog.dart:141 and packages/skotiq_app/lib/screens/equipment/dialogs/indi_server_dialog.dart:151`

Both dialogs build their failure line as 'No response on ${host}:${port}. $e', and $e is the flutter_rust_bridge freezed union, whose toString() is its DEBUG rendering. Live, Settings > Connection > Alpaca > Configure > Test Connection against a dead localhost:11111 displayed, inside the red status box: 'No response on localhost:11111. SkotiqError.connectionFailed(deviceId: localhost:11111, reason: Failed to connect to Alpaca server: error sending request for url (http://localhost:11111/mana

## [P2 / defect] The next-use prompt's "Not now" button permanently retires the step  — FIXED

`packages/skotiq_app/lib/screens/dashboard/widgets/next_use_prompt_card.dart (_buildCard action row)`

Reproduced live: with the card showing 'Confirm your plate solver' I pressed 'Not now', navigated to Equipment and back -- the card had moved on to 'Capture first light' and the plate-solver step never returned. 'Not now' calls the same _dismissStep as the overflow menu's 'Skip this step', which writes the next_use.<id> dismissal row (the method's own doc says 'Permanently retire a single step'). The label promises a deferral the card does not implement, and the word means something different tw

## [P2 / ux] In the shipping default configuration the next-use coach can never appear

`packages/skotiq_app/lib/screens/dashboard/widgets/next_use_prompt_card.dart:_smartNightPromptEligibleProvider`

The card suppresses itself whenever Smart Night is BASE-eligible: active profile + usable optics + auto-prompt setting on (the default) + no active sequence + a real site -- almost exactly the conditions under which the card's own gate (readiness.isReadyToImage) is satisfied. Reproduced live on a fresh profile with the simulators connected: Smart Night appeared, I pressed its 'Not now', the bottom-centre slot went EMPTY, and the next-use card still did not appear, because the suppression deliber

## [P2 / missing] Plugin sequence nodes are configured by hand-writing JSON whose keys are undiscoverable

`packages/skotiq_plugins/lib/src/plugin_api.dart:270 (SequenceNodeDefinition) and the PluginNode properties panel`

Live: adding the bundled 'Discord Webhook' node gives a properties panel whose only configuration control is a free-text 'Configuration (JSON)' field pre-filled with '{}'. The JSON is validated well (invalid input reports 'Invalid JSON: FormatException ...' with a caret at the offending column), but nothing in the UI names the keys the node reads -- webhookUrl, username, content, embedTitle, embedDescription, embedColor -- and the node description does not list them. Configuring a plugin node th

## [P3 / defect] Session Report renders a 'Journal' heading with no content and no empty state

`packages/skotiq_app/lib/screens/sequencer/widgets/session_report_dialog.dart`

In the post-run Session Report the sibling sections all state their empty case ('No guide data recorded for this session.', 'No accepted light frames recorded.'), but 'Journal' renders as a bare heading with nothing under it. Confirmed in the live accessibility tree for both the failed and the stopped run: 'panel: Journal' is followed immediately by 'panel: Notes' with no child node in between.

## [P3 / defect] After a completed run the exposure node card still reads '0 / 12 frames' with every pip empty, directly above a strip of the 12 thumbnails it captured

`packages/skotiq_app/lib/screens/sequencer/widgets/sequence_tree/node_tree_view.dart`

Live: run #3 captured and accepted all 12 frames (Session Summary: Captured 12 / Accepted 12). Back on the Builder the 'Exposure: No Filter' card on the Take Exposures node still reads '0 / 12 frames' and draws 12 empty pips, while the ExposureNodeThumbnailStrip immediately beneath it shows the real frames. The two statements are visible in the same screenshot and contradict each other.

## [P3 / defect] Replay Debug reports '1 of 2 decisions' with no filter applied and the time range fully open

`packages/skotiq_app/lib/screens/sequencer/widgets/replay_debug_screen.dart`

Live: opened Replay for the completed 12-frame run with the 'All' chip selected, an empty search box and both slider handles at the extremes of the stated range 17:32:35 - 17:33:52. The header reads '1 of 2 decisions' and exactly one row renders. Either the second decision is being filtered by something the UI does not show, or the total is wrong; either way the count contradicts the list.

## [P3 / default] The auto-composed run note is titled with a raw DateTime.toString(), microseconds and all

`packages/skotiq_app/lib/screens/sequencer/widgets/notes_panel`

Live: 'How did this run go?' > 'Write note' pre-filled the Title field with 'Run on 2026-08-09 17:28:51.286008'. Every other timestamp in the same dialog is formatted ('Aug 9, 2026 - 17:29'), and that raw title is then the note's permanent name in the All-notes list.

## [P3 / missing] BroadcastPanel is built but mounted nowhere - live-stacking broadcast has no UI surface

`packages/skotiq_app/lib/screens/sequencer/widgets/run_dashboard/broadcast_panel.dart:19`

Repo-wide, BroadcastPanel appears only in its own declaration and in packages/skotiq_app/test/screens/sequencer/run_dashboard/broadcast_panel_test.dart:30. No screen, no dashboard-widget registry entry and no tab mounts it. The Live Stacking node does expose broadcastPath/broadcastPort knobs (live_stacking_properties.dart), so the feature is configurable with no way to see whether the broadcast is live or to get the QR the panel was written to show. Options: wire it in as a cockpit dashboard

## [P3 / missing] A 12-frame run records two replay decisions and no per-frame ones, so most Replay filters can never match

`packages/skotiq_app/lib/screens/sequencer/widgets/replay_debug_screen.dart`

The completed run captured and accepted 12 frames, yet the decision feed holds 2 entries and the only one shown is 'Sequence started'. Its payload says 'grading_active: false', so no Frame accepted / Frame rejected decisions are ever written - and those are two of the eleven filter chips the screen offers, alongside Scheduler pick, Recovery, Budget met and Adaptive swap which were likewise empty. A user opening Replay after a normal night sees a feed with one line in it. Options: record frame de

## [P3 / defect] 'Check for Updates' is enabled on an appliance with no update server, and answers with a green success and a red failure at once  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/update_settings.dart:614 (canAct) and :693 (_statusLabel)`

Reproduced live: the Appliance Updates card already stated 'No update server configured (set SKOTIQ_UPDATE_SERVER)', yet 'Check for Updates' was enabled. Pressing it showed the green snackbar 'Check request accepted' and simultaneously flipped Update Status to 'Update failed' with 'Last error: UpdateException: Update server URL not configured'. Two problems in one press: contradictory success/failure feedback, and a *check* that could not run labelled 'Update failed', which on an observatory

## [P3 / ux] Installed appliance catalogs are labelled with internal keys while the same catalogs below use product names  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/rig_catalog_settings.dart:374`

On one screen: 'Installed on appliance' listed stars / dso / annotation, and 'Available to download' immediately below listed HYG Star Database / OpenNGC Deep Sky Objects / GLADE+ Galaxy Catalog — the same three catalogs, twice, under two naming schemes, with nothing connecting 'annotation' to GLADE+. The Remove confirmation read 'Remove annotation catalog?'.

## [P3 / missing] The host folder picker cannot create a folder or accept a typed path

`packages/skotiq_app/lib/widgets/remote_directory_picker_dialog.dart`

Observed in the live dialog: the only controls are 'Parent folder', the child-directory rows, Cancel and 'Use this folder'. There is no 'New folder' and no editable path field, so a remote operator whose appliance has no suitable directory yet — a fresh Pi, or a USB disk just mounted — cannot create one from the app at all and must SSH in. The sibling remote_host_path_dialog does accept a typed path, so the capability gap is inconsistent within one product.

## [P3 / missing] The remote host-path dialog cannot browse the host it is already connected to

`packages/skotiq_app/lib/widgets/remote_host_path_dialog.dart`

remote_host_path_dialog is a blind text field: the operator must type an absolute path on the appliance from memory (the hint is 'C:\Program Files\astap or /opt/astap'), on a tablet, with no completion and no existence check. The same app already ships remote_directory_picker_dialog, which lists the host's directories over /api/files/browse, and the appliance also exposes /api/files/validate. Two remote path pickers, one that browses and one that does not, chosen per call site.

## [P3 / ux] A thin client with no hardware still scans 32 local serial ports every five minutes

`apps/desktop/lib/main.dart (the native bridge starts before the remote/local branch)`

The desktop client launched with --remote-host owns no hardware, yet its own native bridge keeps the hot-plug poll watcher running: /tmp/ns-audit/remoteclient/app.log repeats, every 300 s, 'Found 0 QHY cameras', 'gPhoto2: Detected 0 cameras', 'Sky-Watcher discovery: found 32 serial ports to scan', 'iOptron discovery: found 32 serial ports to scan', 'LX200 discovery: found 32 serial ports to scan', 'Native discovery complete: found 0 total devices'. On a laptop used as a couch client this is poin

## [P3 / defect] Connecting the guider replaces its friendly name with the raw device id, permanently  — FIXED

`packages/skotiq_core/lib/src/providers/equipment/guider_state_provider.dart:29`

GuiderStateNotifier.connect() called _setConnectingState(deviceId, deviceId) — it passed the id AS the display name. Observed live: the mobile Devices tab guider card read 'Built-in Multi-Star Guider' while offline and flipped to 'native:builtin_guider:multi_star' the moment Connect succeeded, and the GuideHealthCard below then showed the same raw id. Nothing later restores the name, so it stays wrong for the session.

## [P3 / ux] The fullscreen frame inspector shows the frame and nothing else — no identity, no measurements

`packages/skotiq_app/lib/screens/imaging/widgets/fullscreen_image_viewer.dart`

The in-place preview it replaces carries HFR, star count, median, mean, the filename and a histogram. Tapping to inspect a frame more closely discards all of it: fullscreen is pixels plus a close button. The moment an operator most wants 'is this frame sharp, and which frame is it' is the moment the numbers vanish. A dismissible overlay strip (filename, exposure, HFR, stars) is what the phone user came for, but what belongs on it is a product choice.

## [P3 / default] drive_linux.py had no way to change the window size, which is the sole reason every responsive branch was filed as 'needs an emulator'  — FIXED

`tools/ui_audit/drive_linux.py`

Four of this cluster's units (sequencer phone builder, playback bar, guiding mobile tabs, fullscreen viewer) are plain window-width branches on the desktop binary, not phone-only code, and all four were recorded unreached purely because the harness ran a fixed 1600x900 window. Added a `resize` subcommand (xdotool windowsize --sync, windowmove to the origin, settle pause) that reports the size the window ACTUALLY took, since the X server clamps to the Xvfb screen and GTK enforces its own minimum.

## [P3 / ux] The database-recovery dialog has no maximum width and runs the full window

`packages/skotiq_app/lib/widgets/database_recovery_launcher.dart (_showRecoveryDialog AlertDialog)`

On the 1600x1000 harness window the recovered-database AlertDialog spans essentially edge to edge (screenshot /tmp/ns-forced/db1f.png): body lines run ~150 characters, far past a readable measure, and it does not match the rest of the app, which constrains dialogs through AdaptiveDialogConstraints. This is the first thing a user sees after losing their data, so it is worth looking deliberate.

## [P3 / missing] A transient alert card never says whether the target is up

`packages/skotiq_app/lib/screens/transients/widgets/transient_card.dart`

Live on Observing Alerts with two seeded First Light detections: the card shows type, classification, delta-mag, state badge, RA/Dec, and on expand Source / Discovered / Last Updated / Notes. Nowhere does it show altitude now, or rise/set/transit. For an alert-driven 'go look now' surface that is the first question a user has — deciding whether tonight is the night is the entire point of the Queue button — and the app already computes altitude-now for planner candidates (the planner exposes an '

## [P3 / defect] SettingsSwitch has no way to refuse a change, so every guarded toggle can misreport its state

`packages/skotiq_app/lib/screens/settings/widgets/settings_widgets/settings_switch_and_dropdown.dart:63`

The Home Assistant case is one instance of a general contract gap, observed in the running app and then confirmed in the widget: onChanged is FutureOr<void>, so the only way a handler can reject a flip is to return normally -- indistinguishable from success. _SettingsSwitchState flips optimistically and rolls back only when onChanged THROWS. Any settings toggle that validates a precondition and returns keeps drawing the state the user asked for rather than the state the app holds.

## [P3 / default] One planner pass evicts the entire in-app log buffer

`packages/skotiq_app/lib/screens/settings/widgets/log_viewer.dart (buffer cap) + TargetSuggestionService per-target debug lines`

Settings > Advanced > Logs reported '1000 of 1000 entries' about ten minutes into a session in which nothing had happened but clicking around Settings, and every visible entry was a DBG line of the form '[TargetSuggestionService] Skipping NGC7689: peak altitude -3.9 deg / 0.0h above the local horizon (min 30.0 deg)'. The same pass logged '[TargetSuggestionService] Generated 1188 suggestions from 3716 targets' -- one target-suggestion run emits thousands of debug lines into a 1000-entry ring and 

## [P3 / ux] Settings > Captured Images is a remote-only browser but is listed on every local desktop

`packages/skotiq_app/lib/screens/settings/settings_catalog.dart (captured-images section)`

On a local desktop the section renders its title, the subtitle 'Browse frames captured on the connected appliance' and one note: 'Connect to a remote appliance to browse its captured frames.' That is the whole page, permanently, for every user not driving a remote appliance -- and it is offered unconditionally in the Advanced group and matched by the Settings search for 'captured'. A desktop user does have captured frames (the capture folder is set during onboarding and shown in the status bar),

## [P3 / defect] drive_linux.py type() silently typed nothing for any value starting with a dash  — FIXED

`tools/ui_audit/drive_linux.py:557`

Harness defect, found while driving the onboarding observing-site step: 'type -74.0' into the Longitude field produced an empty field, because xdotool parsed the leading dash as one of its own flags. The failure is silent -- the field stays empty and the wizard shows 'Enter both latitude and longitude', which reads exactly like an app defect. Any sweep entering a negative declination, longitude, focus offset or temperature has been recording a harness failure as an app finding.

## [P3 / defect] Co-imaging create sheet: the "required field" errors can never render, so the primary action is silent about what is missing  — FIXED

`packages/skotiq_app/lib/screens/collaborative_sky/coimaging_create_sheet.dart`

Live: with the sheet freshly opened I pressed 'Start session' and nothing happened at all — no message, no field error, no tooltip (a11y tree unchanged, shot coimg_empty.png) — while the two buttons directly above it both explain themselves on hover ('Type at least two characters of a target name', 'Connect a mount to use its position'). The sheet does carry the right copy — 'Enter a target name.', 'Enter the target center RA.', 'Enter the target center Dec.', 'Enter a session radius.' — gated o

## [P3 / defect] Mosaic projects: the word "Back" is not tappable — only the chevron beside it is  — FIXED

`packages/skotiq_app/lib/screens/mosaic/mosaic_projects_list_screen.dart (_BackBar)`

Live on the pushed /mosaic screen: clicking the label 'Back' left 'Multi-panel mosaics' on screen (unchanged a11y tree); clicking the chevron ~28 px to its left popped the route. The label was a plain Text sitting outside the IconButton, so the part of the control that most reads as a button swallowed the press — and this bar is the screen's only way out, since it is only ever reached by a push.

## [P3 / ux] Mosaic projects empty state sends the user elsewhere while "New mosaic" sits in the same header  — FIXED

`packages/skotiq_app/lib/screens/mosaic/mosaic_projects_list_screen.dart`

Live (shot mosaic.png): the header carries a 'New mosaic' button and the body says 'No mosaic projects yet / Design a mosaic in Framing or the Planetarium and save it as a project to capture and stitch it here.' The one moment the operator has nothing on screen and is reading for instructions, the copy routes them away from the button directly above it.

## [P3 / default] The capture-folder step still opens with an empty box and no proposed default (repeat of an only half-fixed finding)

`packages/skotiq_app/lib/screens/onboarding/steps/capture_dir_step.dart`

Live: Step 10 opens with an empty field, hint 'Type or paste a folder, or use Browse', and Next blocked with 'Pick a capture folder.'. FINDINGS.md:4905 already reported this as two problems — no typed-path input and no suggested default; the text field was added and the default was not, so the second half is still live. The app knows a good candidate (it has a platform data dir, and Settings > Files & Storage has its own default for the same setting), and a first-run wizard is exactly where a pr

## [P3 / ux] The star-chart depth notice is permanent and undismissable, and its only action is one most users cannot complete

`packages/skotiq_app/lib/screens/planetarium/widgets/star_chart_depth_notice.dart`

Live: at FOV 3.1 deg the chart shows 'Chart is shallower than the sky ... No deep-star tileset is published; it must be self-hosted.' with a single 'Configure' button and no close control (shot depth.png). Zooming to an imaging-scale field is the normal thing to do for framing and guide-star checks, so the banner covers the top-left of the chart for the entire session, every session, and the remedy it points at is 'build a tileset with tools/catalog_prep and host it yourself'. The honesty is rig

## [P3 / defect] A failed Test Connection verdict stays on screen after the address it describes is replaced  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/connection_settings_alpaca_dialog.dart (host/port onChanged) and the same pair in indi_server_dialog.dart`

Reproduced live: tested localhost:11111, got 'No response on localhost:11111. ...', then typed 192.168.1.50 into the host field. The per-field errors cleared but the red failure box kept reporting localhost, with nothing marking it stale -- the natural reading is that the address now in the field is the one that failed. On a rig where the point of the dialog is finding a LAN address by trial, that is a wrong answer at the moment the operator decides whether their new guess worked.

## [P3 / defect] The accent-colour swatches have no accessibility semantics at all  — FIXED

`packages/skotiq_app/lib/screens/settings/widgets/settings_widgets/settings_color_and_path_inputs.dart:_buildColorCircle`

Live accessibility dump of Settings > Appearance (drive_linux.py tree --all) showed 'panel: Accent color / Primary accent color' followed immediately by 'panel: Display' -- ZERO child nodes for the seven swatches -- while the switch one row down reported 'toggle button: Sidebar collapsed by default [off]'. They were bare GestureDetectors: no name, no button role, no selected state, no focus, no tooltip. A screen-reader or keyboard user cannot pick an accent colour or learn which is active. The c

## [P3 / ux] The geolocation consent dialog rendered ~1520px wide on a 1600px window  — FIXED

`packages/skotiq_app/lib/widgets/geolocation_consent.dart`

Captured live during onboarding step 11: the AlertDialog had no width constraint, so it filled the window minus the 40px inset and its body ran as one unbroken edge-to-edge line. Every other dialog reached in this sweep (SequenceIssuesDialog, the unwritable-capture-folder confirm, the Alpaca editor) is bounded near 480px. This is the consent gate for the app's only outbound request that carries the operator's public IP address.

## [P3 / missing] The simulator advertises exactly one device per type, so no dual-device feature can be exercised without hardware

`native/skotiq_native/bridge/src/api/discovery.rs:872 scan_simulator_for_type`

The function returns a single hard-coded DeviceInfo per DeviceType (sim_camera_1, sim_mount_1, ...). The Secondary Rig card therefore cannot be driven past its 'No additional camera detected.' state on any machine without a second real camera: the camera dropdown and Start button stay disabled, and the arm/status/dither-coordination half of the feature is unverifiable. Same limitation applies to multi-camera profiles. This is the pass-making direction of simulator failure the campaign has alread

## [P3 / ux] The Secondary Rig card is built from stock Material widgets, not the Skotiq design system

`packages/skotiq_app/lib/screens/sequencer/widgets/secondary_rig_card.dart`

Seen live in the dashboard's secondary column: a raw Material Card with Theme.of(context).textTheme typography, DropdownButtonFormField and outlined TextFields with floating labels, sitting between panels that use Skotiq tokens throughout -- it reads as a different application. The file says so itself ('Strings are intentionally hardcoded English', 'Kept self-contained so it can be dropped into the sequencer or equipment area'). Concretely visible: the 'Frames (blank = until end)' label is e

## [P4 / ux] The global 'All notes' dialog has no way to create a note; the per-target one does

`packages/skotiq_app/lib/screens/sequencer/widgets/notes_panel/global_notes_dialog.dart`

Sequencer > History > 'Browse all notes' offers search, tag filter, edit and delete but no 'Add note' action. The per-target dialog reached from the same note system has '+ Add note' bottom-left, so the two dialogs in one feature disagree about whether creating a note belongs there.

## [P4 / defect] A remote client keeps claiming a healthy 2 ms link for ~90 seconds after the appliance stops answering

`packages/skotiq_core/lib/src/backend/network_backend (heartbeat / latency chip)`

With the appliance SIGSTOPped (socket open, nothing answering), the desktop client's status chip still read a green 'LAN 192.168.1.20 2 ms' 90 seconds later, and flipped to red 'Offline 192.168.1.20' at about the two-minute mark. It does detect the outage, so this is a latency complaint rather than a lie that persists — but two minutes is a long time to keep telling an operator their rig is 2 ms away while a run could be failing.

## [P4 / ux] Harness limitation: drive_linux.py cannot type any value beginning with '-'

`tools/ui_audit/drive_linux.py:558 cmd_type`

Not an app defect, but it silently narrows what every sweep can cover. `type` shells out to `xdotool type --clearmodifiers --delay 30 <text>`; xdotool parses a leading '-' as an option, so typing '-105.0' into the onboarding longitude field died with CalledProcessError and left the field empty. Every negative latitude, longitude, declination and temperature offset in the app is therefore untypeable by the harness — I had to move my scratch observing site to the eastern hemisphere. Inserting `--`

## [P4 / ux] Settings search finds nothing for 'focal', the number that decides plate scale, framing and solving

`packages/skotiq_app/lib/screens/settings (settings search index)`

Typing 'focal' into the Settings search box returns 'No settings match your search.' Focal length is not a Settings row - it lives in Equipment > Edit Profile > Optical Train - but a user hunting for it has no reason to know that, and the search that is otherwise the fastest way around the app dead-ends. Reproduced live on the release build; by contrast 'plate' correctly surfaces Plate Solving, Sequencer, Annotations, Notifications and Appliance Catalogs. The same applies to the other optical-tr

## [P4 / ux] Onboarding hard-blocks on a camera pixel size it cannot supply, even for the app's own Simulated Camera

`packages/skotiq_app/lib/screens/onboarding (optical train step)`

Step 8 of the setup wizard refuses to advance with 'Pixel size is required.' while the pixel-size field's own helper text reads 'Not in the camera library - check your camera's datasheet'. This happened with Simulated Camera selected -- the app's own built-in device is absent from its camera library, so the wizard blocks a first-run user on a number the app never offers to find. Any real camera missing from the library hits the same wall with a datasheet as the only suggested route.

## [P4 / ux] Capture-folder rejection dropped the actual OS reason ("Not writable: Cannot open file")  — FIXED

`packages/skotiq_app/lib/screens/onboarding/steps/capture_dir_step.dart`

Live: typing /root into onboarding Step 10 answered 'Not writable: Cannot open file'. That is dart:io's generic FileSystemException.message; the reason the operator can act on — Permission denied, Read-only file system, No space left on device — only ever lives in OSError, which the step discarded. Every distinct failure therefore read identically and none said what to do.

## [P4 / missing] Capture-folder step did not expand ~, and still will not create a folder that does not exist  — FIXED

`packages/skotiq_app/lib/screens/onboarding/steps/capture_dir_step.dart`

Live: typing '~/Documents' — which exists — answered 'That folder does not exist.', because dart:io does not expand a tilde and the step passed the raw text to Directory(). Separately '/tmp/does-not-exist-xyz' is rejected with the same flat message and no offer to create it, even though the class doc claimed 'the path must exist (or be creatable)'. On a fresh appliance the folder you want usually does not exist yet.

## [P4 / ux] Coordinate-lookup results open below the fold in the sequencer Properties panel

`packages/skotiq_app/lib/screens/sequencer/widgets/target_node_properties/coordinate_lookup.dart`

Live at the app's 1600x900 window: on a freshly added Target node the 'Look up coordinates' button sits near the bottom of the Properties scroll, and the result list (maxHeight 190) renders under the status bar — the first row visible, the second cut in half (shot lookup.png) — with no scroll-into-view. Pressing the primary action reads as 'something appeared, mostly off-screen'. Up to 12 catalog matches can be returned and 1.5 are visible.

## [P4 / missing] Lookup result rows throw away the object type and catalog id they already carry

`packages/skotiq_app/lib/screens/sequencer/widgets/target_node_properties/coordinate_lookup.dart`

Live: searching 'M31' in the sequencer Target editor returns two rows — 'M31' and 'M3' — each showing nothing but a name and coordinates. TargetCoordinateMatch already carries objectType and catalogId from the same query; neither reaches the ListTile. The co-imaging sheet's copy of the list has the same shape ('M42' + 'M4', degrees only). For M31-vs-M3 the coordinates disambiguate; for a name matching several NGC/IC/Sh2 entries, type and catalog id are exactly what tells them apart, and picking 

## [P4 / missing] The frame inspector cannot step to the next frame, and its file path is inert

`packages/skotiq_app/lib/screens/analytics/widgets/frame_detail_dialog.dart`

Live: the Analytics frame detail dialog's only controls are 'Flag as poor quality' and 'Close' (a11y tree + shot framedlg.png). Reviewing a night therefore means close, tap the next thumbnail, read, close — once per frame, for however many hundred the night produced, with the strip scrolling underneath. The File row prints the full path as plain text; clicking it produced no clipboard or reveal feedback of any kind.

## [P4 / ux] The onboarding step rail is not clickable, even for steps already completed

`packages/skotiq_app/lib/screens/onboarding/onboarding_screen.dart (step rail)`

Live: at Step 10 of 13 with steps 1-9 ticked, clicking 'Camera' in the left rail did nothing (still Step 10). The rail lists all 13 steps with completion ticks and reads exactly like navigation, but the only way back to a finished step is pressing Back repeatedly. Found while sweeping capture_dir_step; the rail itself belongs to onboarding_screen.dart.

## [P4 / ux] The unwritable-capture-folder dialog quotes a raw Dart PathAccessException

`Settings > Files & Storage > Image output confirm dialog`

Typing an unreachable path produced: 'Skotiq could not create or reach "/root/definitely-not-writable-xyz": PathAccessException: Exists failed, path = '/root/definitely-not-writable-xyz' (OS Error: Permission denied, errno = 13)'. The dialog itself is good -- correct title, correct 'store it anyway if the share is not mounted yet' escape hatch -- but the cause is quoted as the Dart exception class plus errno rather than 'Permission denied'. Same family as the Alpaca/INDI finding, one severit

## [P4 / ux] The plugin-node Timeout field silently clamps out-of-range input as you type

`PluginNode properties panel, Timeout field`

Typing 99999 into Timeout left 7200 in the field with no message -- the input formatter rewrites each keystroke to the maximum. The Alpaca editor two screens away treats the same situation as a validation error on purpose ('no silent coercion of a bad port'), so the app contradicts itself about what a too-large number means. A 0 is also accepted with no indication of whether it means 'no timeout' or 'give up immediately' (plugin_node_rules.dart treats 0 as legal, so it is deliberate but unexplai

## [P4 / ux] Geolocation 'Detect location' fails silently on a desktop with no fix

`Onboarding > Observing site > Use my current location` (geolocation_consent dialog)

Live on the 2026-09-12 sweep: granting consent and pressing 'Detect location' simply closed the dialog with no position applied and no message of any kind -- no spinner result, no 'could not get a fix' error. A first-time operator on a machine without GPS cannot tell whether detection ran, is still running, or failed. The consent gate itself worked correctly (dialog appears on first use only).

## [P2 / stability] The desktop UI froze ~100 s after a trigger-terminated run, while the native side kept running

Observed live on the 2026-09-12 L52 repro (local sim rig, scratch profile). At 17:18:51 UTC the Dawn Approaching trigger fired ParkAndAbort: the cancel cascade ran, the mount parked, `[TRIGGER_MONITOR] terminating sequence` logged at .808774 — the last run-related line in app.log. The window then went dead: the status-bar clock stuck at 13:20:36 EDT (~105 s after the abort), clicks produced nothing, and the AT-SPI tree collapsed to the bare window frame, while the process stayed alive at ~18% CPU logging `conditions_score` every 30 s until it was killed at ~17:23. A restart was required.

Attribution is not proven: the freeze followed a trigger-terminal + post-run report + 'How did this run go?' prompt sequence on a softpipe/Xvfb rig, and the app had been driven hard all session. But the native executor had already returned to idle, so whatever wedged was on the Flutter side after a terminated run — the same window a real operator watches at dawn. Follow-up: the identical trigger-abort re-run on the rebuilt bundle did NOT freeze (responsive 2.5+ min post-abort), so it is a single occurrence of unknown cause, not a deterministic abort-path wedge.

## [P3 / untrue] 'Meridian flip completed' notification is emitted per progress tick, not on the outcome — it claims success while attempts are still failing

`packages/skotiq_core/lib/src/services/notification/event_classifier.dart` (`case 'InstructionProgress'`)

During the live flip on 2026-09-12 (run 11, sim rig), the toast 'Meridian flip performed — Meridian flip completed.' appeared while the node header read 'MeridianFlip: attempt 1/4 failed, retrying in 30s'. The classifier maps ANY InstructionProgress event whose instruction contains 'meridian' to NotificationCategory.meridianFlipPerformed — with no success check at all — so every 25/50/75% NodeProgress tick asserts 'completed', including on a flip that ultimately failed all 4 attempts and failed the run. The real verdict arrives separately as MeridianFlipOutcome, which the classifier ignores. An operator glancing at the notification sees 'flip completed' for a procedure that is, at that moment, in a retry loop heading for failure.

## [P3 / dead-code] meridian_flip_progress_dialog has no production call site — a real flip shows only the node-header status

`packages/skotiq_app/lib/screens/sequencer/widgets/meridian_flip_progress_dialog.dart`

`showMeridianFlipProgressDialog` is referenced nowhere outside its own file. During the same live flip (~4 min, 8 steps, 4 retries) no dialog ever mounted; the only UI surface was the Take Exposures node header's 'MeridianFlip: attempt N/4 failed' line. The dialog is unreachable by construction, not by missing runtime state. Same class of finding as NextUsePromptCard and broadcast_panel.

## [P3 / ux] PauseAndAlert for a failed flip never produces an observable pause when a second trigger is armed — the abort wins the same tick

`native/skotiq_native/sequencer/src/executor/start/trigger_monitor.rs`

Run 11 logged '[MERIDIAN] Flip failed - pausing and alerting user' and 'Trigger fired: Dawn Approaching - ParkAndAbort' in the same 100 ms window, then '[TRIGGER_MONITOR] terminating sequence ... fired 2 triggers' + 'In-flight trigger recovery action quiesced; ending run'. The pause the failure action promises was quiesced by the co-firing abort, and the run went straight to failed. Third distinct mechanism by which 'paused for inspection' never lands on an unattended sim rig (after the dither-step kill and the unattended safe-abandon): any second armed trigger sharing the poll tick outranks the pause. Whether that ordering is intended is a product question; the observable result is that PauseAndAlert can silently never pause.

## [P1 / wiring] hotplugEventBridgeProvider is never watched — plugging a device mid-session never refreshes the equipment lists

`packages/skotiq_core/lib/src/providers/hotplug_event_bridge_provider.dart`

Same defect family as the recovery bridge, wider blast radius. The Rust hot-plug watcher (hotplug.rs: 300 s poll + libusb/WM_DEVICECHANGE callbacks) emits DeviceDiscovered/DeviceLost events; this bridge is the ONLY code that invalidates the ten per-class discovery providers in response. `grep -rn 'watch(hotplugEventBridgeProvider)\|read(hotplugEventBridgeProvider)'` across packages/ + apps/ finds zero non-test watchers — its own comment claims 'the desktop/mobile dashboard scaffolding does this', and nothing does. Live consequence: a camera plugged in mid-session fires the native event, the event reaches the FFI stream (event_mapping.dart maps it), and the equipment screen still never updates until the operator manually rescans — the entire hot-plug feature is dead in production.

## [P3 / wiring] usbDisconnectEventBridgeProvider + recoveryAudibleBridgeProvider + recoveryPushBridgeProvider are also unwatched

`packages/skotiq_core/lib/src/providers/usb_disconnect_log_provider.dart:41`, `recovery_provider.dart:447,481`

A systematic audit of every `*BridgeProvider` found five side-effect providers and exactly one watcher (`errorNotificationBridgeProvider`, app_shell.dart:367). Beyond the already-recorded recovery bridge and the hotplug bridge above: the USB-disconnect log bridge ('Run Dashboard scaffolding watches this' — it does not) so the disconnect history misses every event that arrives before a manual recorder runs, and the recovery audible/push bridges, so recovery events produce no sound and no push notification even where those channels are configured. All five comments assert a watcher that does not exist.

## [P2 / defect] Remote checkpoint resume always reports failure: the companion's own session-open collides with the session the host's resume just created

`packages/skotiq_core/lib/src/providers/sequence/sequence_executor.dart:2227` (inside `_resumeFromCheckpointInner`) → `imaging_records_repository.dart:160` (`_remote.createSession`) → `apps/desktop/lib/headless_api/handlers/analytics_handlers.dart:279`

Observed end-to-end on the emulator (fresh 7.0 debug build paired to the headless appliance, resumable checkpoint from a real stopped run). On the companion, `resumeFromCheckpoint()` runs `_resumeFromCheckpointInner` locally with a NetworkBackend: step one POSTs `/api/sequencer/checkpoint/resume`, which makes the HOST run the identical inner flow — the host's executor opens imaging_sessions row N, opens the run row and starts execution. The companion's inner flow then reaches its own `sessionNotifier.startSession`, which forwards `createSession` remotely; the host's `sessionsDao.startSession` sees the session its own resume just opened and throws `ActiveImagingSessionException`, surfacing as `409 active_session_exists` back to the phone. Verified live: the phone displayed 'Recovery did not complete — active_session_exists: Imaging session 2 is already active. The checkpoint is still on disk.' with Retry/Discard affordances, while `/api/sequencer/status` simultaneously showed `state: running` on the resumed sequence — which then ran to completion (6/6 frames, run 'completed', session 2 'completed', checkpoint consumed). Every remote resume hits this: the companion-side session open is unconditional, so the collision is guaranteed. The dialog's retry loop works as designed but presents a false failure for a recovery that succeeded; an operator who then taps Discard clears a checkpoint belonging to a live run.
