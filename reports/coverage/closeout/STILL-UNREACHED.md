# Units still unreached after the closeout wave

## `screen:sequencer/broadcast_panel.dart`

Has no call site in the shipping app - only its own declaration and one widget test instantiate BroadcastPanel, so there is no route to it from the running binary. Recorded as a finding rather than a coverage gap.

Evidence: grep -rn BroadcastPanel packages apps --include=*.dart returns exactly 3 lines: the class declaration, its const constructor, and broadcast_panel_test.dart:30.

## `screen:sequencer/forensics_panel.dart` — REACHED 2026-09-12, but only via seeded rows (production persistence is dead — see FINDINGS)

Reached live on the Tonight dashboard during run #8 (session 9): enabled the opt-in 'Frame forensics' cockpit widget via Edit layout > Widgets, then the panel rendered 'WHY DID THIS FRAME FAIL? — 2 rejections', cause bar 'Cloud passage (2)', two colour-coded rows (shot /tmp/ns-pair/shots/252-c3.png). The render path was verified end to end; the DATA path is broken — see the new P1 finding 'FrameRejected events are never persisted to frame_forensics'. All four graded runs (5,6,7,8) produced real rejects (12 captured_images rows with is_accepted=0) and the native [FORENSICS] classifier ran on every one, yet zero rows ever landed in frame_forensics: event_operations.dart's FrameRejected handler calls _carryFrameVerdict + _registerSequenceFrame and never ForensicsService.recordRejection. The panel therefore shows real data in production only when the missing call is wired; today's render proof used two rows seeded directly into the table for the active session id.

Evidence: shot 252 (panel live), sqlite frame_forensics=2 seeds while captured_images had 2+ real rejects mid-run; app.log [FORENSICS] lines per reject.

## `screen:sequencer/session_report_forensics_section.dart` — UNIT IS STALE: file does not exist in the tree

There is no session_report_forensics_section.dart anywhere under packages/skotiq_app (only .claude/worktrees copies). session_report_dialog.dart contains zero 'forensic' references, and the provider it would have watched — forensicsRecordsForRunProvider — is defined in forensics_provider.dart:45 but watched by NO production caller. The post-session report's forensics surface was removed from the tree (or never landed); the live report for failed session #7 (3 real rejects) renders Statistics/Mount/Guiding/Targets/Review-and-Integrate and nothing else. Recorded as a dead-surface finding; the STILL-UNREACHED entry that cited this file was pointing at a removed name.

Evidence: find packages -name '*forensics*' lists only run_dashboard/forensics_panel.dart + run_dashboard/frame_detail_dialog.dart; grep -rn forensic session_report_dialog.dart -> empty; shot 258-report2.png.

## `screen:sequencer/frame_detail_dialog.dart` — REACHED 2026-09-12 (same seed caveat as the panel)

run_dashboard/frame_detail_dialog.dart opened by tapping a forensics row during live run #8: 'Why did this fail? — Cloud passage, Frame 2/3' with GRADER REASON, EVIDENCE ('No structured evidence'), FRAME METRICS (HFR 2.30px, Ecc 0.35, Stars 41), ENVIRONMENT AT CAPTURE, and the Reject/ preview path (shot /tmp/ns-pair/shots/253-detail.png). Reachable in production only via the forensics panel, which per the new finding only ever has rows if recordRejection gets wired.

Evidence: shot 253-detail.png.

## `screen:sequencer/session_handoff_dialog.dart` — REACHED 2026-09-12 (remove on next ledger pass)

Reached in the remote-local-sweep-2 wave: seeded the isolated profile DB directly (targets row 'New Target' + a yesterday imaging_sessions row + 3 accepted light frames), restarted the app so the Drift-backed StreamProviders re-read, then Start → Pre-flight → Start anyway produced 'Resume from previous night?' with correct carry-over totals (1m 30s, 3 accepted frames, per-filter L). Full evidence in remote-local-sweep-2.json.

Original blocker note (kept for the method): its only call site is preflight_validation_dialog.dart:280, guarded by `if (carry.isNotEmpty)`. sessionCarryOverProvider only yields entries when the sequence's target NAME matches a row in the target LIBRARY (session_handoff_service.dart:262 does a byCatalog/byName lookup and `continue`s when null). The runs used an ad-hoc 'New Target' typed into the node, which is never written to the target library, so carry-over was empty.

## `screen:sequencer/meridian_flip_progress_dialog.dart` — DEAD CODE 2026-09-12 (a real flip ran; nothing mounts it)

`showMeridianFlipProgressDialog` has zero call sites outside its own file (`grep -rn` across packages/ + apps/): the class declaration, its show function, and a styling comment in the countdown banner are the only references. A real 4-minute flip executed on the sim rig this session (target set 15 min past meridian, mount tracking — 8-step procedure, 4 plate-solve retries, PauseAndAlert) and no dialog ever appeared; the run-dashboard node header carried the live status instead ('MeridianFlip: attempt 3/4 failed, retrying in 120s'). The prior note's blocker is also stale: the sim mount DID flip — the earlier 'no flip ever fired' run predates whatever now drives `trigger:meridian_flip` NodeProgress events.

Bonus unit reached in the same run: `meridian_flip_countdown_banner` renders armed on the Imaging screen the moment the mount is unparked+tracking ('Meridian flip imminent — Automatic — the meridian-flip watchdog is running it now', shot 392-banner.png). It needs no sequence — only mount tracking + a reported RA + location + flip enabled.

## `screen:sequencer/recovery_insights.dart` — ROOT CAUSE FOUND 2026-09-12: the recovery event bridge is dead code in production

A real recovery loop DID run live (run #8: 3 consecutive grading rejects → ConsecutiveRejectsExceeded → unattended-rig SafeAbandon — mount parked, run failed, ExecutorEvent::RecoveryGaveUp emitted natively per monitoring.rs:496). Yet session_diagnostics.recovery_history_json for session 9 is [] and the report shows no Recoveries section. Cause: `recoveryEventBridgeProvider` — the side-effect provider that forwards SequencerEvent_Recovery* wire events into currentRecoveryProvider/recoveryHistoryProvider — is never ref.watch-ed or ref.read anywhere outside tests. Its own comment claims 'the Run Dashboard scaffolding watches it'; nothing does. The executor reads recoveryHistoryProvider at session end (session_diagnostics_operations.dart:218), always finds it empty, and persists []. Same defect family as the forensics wire: events fire, translation exists, consumers exist, but the bridge that feeds them is never activated. Recovery_banner + the report Recoveries section + persisted recovery history are all unreachable until it is watched.

Evidence: app.log run #8 '[RECOVERY] Attempt 1/9 (cause=ConsecutiveRejectsExceeded)' → 'escalated to operator Pause ... UNATTENDED rig ... abandoning safely' → 'Parked mount sim_mount_1'; sqlite session_diagnostics session_id=9 -> []; grep -rn recoveryEventBridgeProvider (only tests + comments).

Secondary observation recorded as a finding: on a guider-less rig with ditherEvery>0, the reject-storm operator-pause never lands — the queued dither step fails ('Built-in guider dither requires active guiding') and kills the run before the recovery driver engages (runs 5,6,7 all died this way). With ditherEvery=0 the recovery driver ran and escalated to unattended safe-abandon. A real 'paused for inspection' run requires operator_present=true, so on an unattended sim rig a reject storm always ends the run rather than pausing.

## `screen:sequencer/missing_specs_dialog.dart` — REACHED 2026-09-12

Smart Night wizard (Sequencer overflow → 'Plan tonight') → step 5 Preview auto-opened 'Camera specs needed' for the Simulated Camera — it has no match in the camera-specs catalog, so all four caveats (pixel size / read noise / full well / QE) fired. Filled 3.76µm / 3.5e- / 18000e- / 0.65 → Save specs → preview built ('Tonight: 1 target, 2.4h integration', LRGB filter plan + dark-library warnings, shot /tmp/ns-pair/shots/267-saved.png).

Evidence: shots 266-sn5.png (dialog), 267-saved.png (post-save preview).

## `settings:backup (S3 push)`

No S3-compatible endpoint is available in this sandbox — no minio, no moto, no boto3 — and I did not install packages onto the user's system. Unlike WebDAV, a hand-rolled S3 stub that accepts anything would not exercise the part that can actually be wrong (SigV4 signing), so it would be a green light with no evidence behind it. The WebDAV half of the same SyncTarget code path was exercised end to end instead.



## `screen:constellation/shared_target_detail_screen.dart`

Both call sites (constellation_screen.dart:312 and :673) push the screen with a SharedTarget obtained from a Constellation hub. There is no hub server in this tree — packages/ holds app, bridge, core, planetarium, plugins, remote_protocol, ui, updater and no skotiq_hub — and the paired appliance is a rig, not a hub. Faking one the way I faked WebDAV was rejected on cost: constellation_client.dart is 1145 lines implementing the whole §5 hub contract, not a single endpoint.



## `mobile:first_run_setup_screen.dart` — DEAD CODE 2026-09-12 (call site removed by 8d9af4ff7; test-only reference)

I got the mobile app paired to the appliance (second Android emulator on port 5556 so the sibling agent's emulator-5554 was untouched; pairing code COSMOS-QUASAR-5851 accepted with admin scope) and confirmed the screen still cannot appear. FirstRunSetupScreen's only mount point is mobile_dashboard_screen.dart:96, and MobileDashboardScreen's only instantiation is main.dart:509 inside `if (useCompanionUi)`; useCompanionUi = isPhone && isCompanionUiEnabled, and isCompanionUiEnabled is a --dart-define defaulting to false plus a Platform.environment lookup an Android app cannot satisfy. The paired phone rendered the shared SkotiqApp shell and its 13-step 'Set up your rig' wizard instead. Recorded as a finding.

Re-resolved 2026-09-12 against the 7.0 tree (fresh debug APK built and run on emulator-5556): the whole path described above is gone — `mobile_dashboard_screen.dart`, `useCompanionUi`, `companion_ui_config.dart` and the `SKOTIQ_COMPANION_UI` flag no longer exist in the tree. `git log -S FirstRunSetupScreen` shows commit 8d9af4ff7 ("the ten owner decisions — ~13.7k dead lines out") removed the call site, and today `first_run_setup_screen.dart` is imported only by `apps/mobile/test/screens/first_run_setup_test.dart`. The screen is dead code, not a gated or missing-runtime unit.



## `mobile:checkpoint_resume_dialog.dart` — REACHED 2026-09-12 on the emulator with a real appliance checkpoint

Pairing was not the blocker and is now closed; host state is. With the phone paired, GET /api/sequencer/checkpoint/has on the appliance returns {"hasCheckpoint":false} and /info returns {"info":null}, so _checkForCheckpoint's `if (info == null || !info.canResume) return;` fires. It cannot be seeded from outside a run: POST /api/sequencer/checkpoint/save answers {"error":"internal_error","message":"No sequence loaded"}, and the on-disk artefact is a serialised SessionCheckpoint carrying a whole SequenceDefinition (sequencer/src/checkpoint.rs:234, CHECKPOINT_VERSION 3). This unit belongs with the runtime-run cluster.

REACHED 2026-09-12 on the current tree. A real resumable checkpoint was produced on the headless appliance entirely through its own API: POST /api/profiles (sim rig) → /api/profiles/1/load → connect sim_camera_1 + sim_mount_1 → POST /api/sequencer/load (canonical wire document) → /api/sequencer/start → ~25 s run → /api/sequencer/stop {preserveCheckpoint:true}. /checkpoint/has then returned true and /info {canResume:true, sequenceName:"Checkpoint test run"}. Fresh 7.0 debug APK on emulator-5556, paired via POST /api/pairing/start + code entry (CYGNUS-NOVA-2714); on connect the dialog rendered: 'Recover Sequence? / A previous sequence was interrupted and can be resumed. / Checkpoint test run / Saved 0m ago / Completed 0 frames (0m integration)' with Discard/Resume. Pressing Resume exercised the retry loop (see FINDINGS: the resume opened imaging_sessions id 2 then reported `active_session_exists` against that same session — the run DID resume, state:running, so the error is a false failure). Evidence: /tmp/ns-pair/shots/mobile-checkpoint-dialog.png, mobile-checkpoint-retry.png.



## `mobile:session_replay_screen.dart` — DEAD CODE 2026-09-12 (picker call site removed by 8d9af4ff7)

Same dependency, different artefact. SessionReplayScreen is pushed only from session_picker_screen.dart:244 with a runId, and the paired appliance has never executed a sequence: its dashboard reads 'No runs yet — your first night will appear here' and /api/status reports sequencer state 'idle'. A completed run on the host is what is missing, not a paired client.

Re-resolved 2026-09-12: the missing run now exists on the appliance (sequence_runs row from the checkpoint-test run above), but it no longer matters — `git log -S SessionPickerScreen` shows commit 8d9af4ff7 removed the picker's call site along with the old mobile dashboard. In the current tree `session_picker_screen.dart` is referenced only by its own widget test (and a comment in duration_format_parity_test.dart), so SessionReplayScreen is transitively dead code. The live replay surface on 7.0 is `/replay/:runId` → ReplayDebugScreen, already reached.



## `widget:connection_stale_banner.dart` — REACHED 2026-09-12 on the mobile client (desktop remains undriven)

Not reachable on the desktop remote client, which is what this cluster provides. connectionStaleProvider is a StateProvider whose only writers anywhere in the tree are apps/mobile/lib/main_parts/mobile_connection_state.dart:151/258/282/292/346; the shared shell mounts the banner (app_shell.dart:840) but nothing on the desktop side ever flips the flag. Verified live rather than by reading: I SIGSTOPped the appliance for two minutes with the client on the dashboard and no banner appeared at any point — the chip stayed green 'LAN 192.168.1.20 2 ms' for ~90 s and then went red 'Offline 192.168.1.20'. Reaching it needs the MOBILE app inside its reconnect grace window; my emulator app was paired but I did not hold it in that window.

Re-verified 2026-09-12 with a harder failure mode: SIGKILLed the appliance process outright (sockets die, not just stall). The chip went red within ~12 s — much faster detection than under SIGSTOP — and still no 'Reconnecting to server' banner at 12 s or 40 s. Even a hard disconnect on the desktop thin client does not surface the banner; the provider remains undriven on desktop.

REACHED 2026-09-12 on the mobile client, which is where the provider lives. With the fresh 7.0 debug build paired to the appliance and on the sequencer dashboard, I SIGSTOPped the appliance process: the phone rendered 'Reconnecting to server… session controls may be stale.' + a Retry affordance at ~61 s (matches the 45 s LAN heartbeat timeout in network_backend.dart:223 plus detection). SIGCONT at 14:23:04 and the banner cleared within ~15 s, with live data resuming ('Last sub 14:23:05'). The desktop observation above stands — the banner is mobile-driven by design — but the unit itself is reached. Evidence: /tmp/ns-pair/shots/mobile-stale-banner.png.



## `screen:sequencer/narrow_layout.dart`

Provably unreachable in the shipping build, demonstrated live rather than argued from source. _NarrowDesktopLayout is chosen only when the builder's availableWidth < 396 (48 rail + 300 centre + 48 rail), but its parent already returns the phone builder whenever min(width,height) < 600 — which every sub-396 width satisfies. Driven at 420x900 and again at 380x900: both rendered the phone builder (SequenceToolbar + MobilePlaybackBar + 'Tap + to add instructions' + add FAB), never the 48px icon rail. It is dead code, not a coverage gap.

Evidence: scratchpad/shots/seq-380.png plus the a11y tree at 380x900 showing the playback bar and 'Tap + to add instructions' with no rail

## `screen:imaging/centering_dialog.dart`

Still blocked on plate solving — the plan's 'now unblocked by S9' is stale. sim_sky.rs has landed and IS in the shipped bridge (bundle .so and target/release .so share an md5, built after the source), and its own ignored test solves a downloaded simulator frame to 0.5". But it does not engage in the running app: with sim camera + sim mount connected, the solver preference loaded at startup as astap='.../skotiq-audit/astap/bin/astap_cli' catalog='.../astap/bin' (full D05), and the mount unparked and slewed to RA 05h30m/Dec +22 (the slew was accepted, which also proves the sim mount reads connected), the app's own solve logged 'Running ASTAP: ... -d .../astap/bin -wcs' then 'ASTAP exited with non-zero status 1'. Independent hinted solves at 0.582 deg (400 mm) and 0.2327 deg (1000 mm default) plus a 180-degree blind solve all returned 'No solution found', two consecutive frames at a fixed pointing share ZERO of their 40 brightest median-filtered sources, and no 'sim sky: indexed N area files' line is ever logged. Without a WCS none of Slew & Center / dashboard quick actions / planetarium can produce the dialog.



## `widget:details_panel.dart`

Same root cause. details_panel is `part of` catalog_overlay_widget, which live_preview_area only builds once the preview holds a plate-solved frame with a WCS. No simulated frame can be solved in the shipped app (see centering_dialog), so the overlay never mounts. The recorded reason on file is still accurate; only its 'plate solving is now solved in principle' caveat is not.



## `widget:details_panel.dart`

Still blocked on plate solving, but for a NEW reason, not the recorded one. S9's sky renderer is wired only into device_manager/ops/camera.rs:1217; the Imaging screen's capture runs through api/imaging.rs, whose simulator branch calls its own generate_simulated_image() (imaging.rs:1304-1344, rand::thread_rng star field). The log never prints sim_sky's 'sim sky: indexed' line, the frame is visibly a uniform random blob field, and no solve is possible, so CatalogOverlayWidget never receives a catalogWcs and CatalogOverlayDetailsPanel (catalog_overlay_widget.dart:319) cannot mount. It becomes reachable the moment api/imaging.rs's simulator branch renders through synthesize_sim_frame + sim_sky_view like the device-manager path already does.

Evidence: Live release build with the whole chain stood up: ASTAP 2026.07.16 + D05 detected by the app ('ASTAP detected /home/scdouglas/.local/share/skotiq-audit/astap/bin/astap'), platesolver.json catalog_path pointed at the D05 directory, Simulated Camera + Simulated Mount connected, optical train 1000mm f/5.0 (app-computed 0.78"/px, the exact configuration the S9 probe solved sub-pixel at). Snapshot produced /tmp/skotiq_captures/capture_1786311827034.fits (FOCALLEN=1000, RA=0, DEC=0) and the app auto-solved it: ASTAP reported '49 stars, 173 quads selected in the image' then '30d,30d,No solution found!  :('. With that frame loaded, Overlays > Catalog overlay produced 'Catalog overlay unavailable / Solve this frame to project catalog objects.'

## `settings:captured-images (populated state)` — REACHED 2026-09-12 against the live appliance

The pairing recipe already existed: the remote client (pid 4113299, display :78, /tmp/ns-pair/remote) is paired to the headless appliance (pid 4159902, :8080), which holds 2 real captured frames (`/tmp/ns-appliance/captures/Light_001.fits`, `Light_002.fits`). Settings → Captured images rendered '2 frames' with real L-filter thumbnails, and clicking a tile opened the detail preview with the honest degraded state ('Full-frame preview unavailable — showing the thumbnail. Download the frame to inspect it at full resolution.'). Evidence: shots 409-captured.png, 410-detail.png.


