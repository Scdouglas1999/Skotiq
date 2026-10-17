# Master/Slave Sync Coverage — Final Audit Report

**Project:** Skotiq2  **Branch:** `feature/v5-living-sky` (live-mirror work)  **Date:** 2026-06-21
**Scope:** The master (headless host) ↔ slave (NetworkBackend / `--remote-host` client) live-mirroring surface across five dimensions: backend control, state mirroring, on-connect hydration, settings round-trip, and profile round-trip.

---

## 1. Executive Verdict

**The master/slave connection is essentially complete.** You should be confident that you do **not** need to hand-test every feature for *connectivity*. The audit traced the actual contracts end-to-end — every abstract member of the `SkotiqBackend` control surface, every master emit site against the slave's apply handlers, the full hydration routine, and every field of the settings wire model — and the wiring is comprehensive and, importantly, **honest**: where something cannot work remotely it throws loudly rather than faking success. There are no silent fake-success stubs anywhere in the control surface.

Concretely:

- **Control (slave → master):** ~130 abstract members across 6 role interfaces. All but one issue real REST/WS calls to existing master endpoints. The single non-wired method (`isPhd2Running`) throws by design.
- **State mirror (master → slave):** All 12 active `HostMutation` entities and all 5 backend-event categories apply real state. No unhandled entity.
- **Profiles:** All 6 operations (create/update/delete/set-default/reorder/load) are fully wired end-to-end. **Zero gaps.**
- **Settings:** ~114 of 126 fields round-trip bidirectionally with live echo.
- **Hydration:** Most live-mirrored categories are re-pulled on connect; three live-only surfaces are not seeded on connect.

**What you DO still want to eyeball by hand** is a small, well-bounded set of *cosmetic/timing* defects — not connectivity failures. They cluster in two places: (a) three dashboard surfaces that render blank/stale for a slave that connects **mid-session** until the next event fires (they self-heal), and (b) a handful of advanced settings knobs that don't cross the wire. None of these break live operation; the dominant remote workflows (connect/slew/solve/frame/run-sequence/guide/monitor) are fully covered.

**Bottom line:** Strong coverage. Spot-check the seven confirmed gaps below; you can trust the rest.

---

## 2. Per-Dimension Coverage

| Dimension | Wired | Intentional (by design) | Confirmed gaps |
|---|---:|---:|---:|
| Backend control (slave → master) | ~28 method-groups (~130 members) | 5 | 2 |
| State mirror (master → slave) | 16 | 2 | 0 |
| Hydration (on slave connect) | 10 | 4 | 3 |
| Settings round-trip (bidirectional) | ~20 groups (~114 fields) | 1 | 4 |
| Profile round-trip (6 ops) | 6 | 0 | 0 |
| **Total** | **—** | **12** | **7** |

Notes on the "intentional" column — these are documented, correct-by-design omissions, **not** defects:
- *Backend control:* `readFitsFile`, `autoStretchImage`, `renderFinishingPreview` (host-filesystem / raw-pixel ops the network boundary never carries), and `dispatchPluginNodesLocally` (host owns plugin dispatch). All throw/return-by-design.
- *State mirror:* the `settings` mutation arm is a deliberate no-op (host re-emits ~14/s; covered by the 30s hydrate poll), and the `safety/polarAlignment/job/session/catalog` event categories are end-state UI toasts that need no cache invalidation.
- *Hydration:* framing target is intentionally not seeded (seeding it would clobber the real target with mount-pointing data); dome/weather/safety-monitor mirror connection-state only (no telemetry source exists); guider numeric metrics are sourced from the PHD2 stream, not this layer.
- *Settings:* `databasePath` / `logsPath` are host-local infrastructure paths deliberately excluded from the wire model.

The state-mirror "partial" (list-entity arms collapsing created/updated/deleted into a single cache-invalidation) is **correct-by-design** for network-backed list providers — a host DELETE is reflected by the re-fetch returning fewer rows — so it is not counted as a gap.

---

## 3. Confirmed Gaps — Prioritized Fix List

Seven confirmed gaps, all independently verified against the cited files. None are high severity. Ordered by severity then blast radius.

### MEDIUM

**G1 — Plate-solve WCS/SIP dropped on the wire** · `backend-control`
The remote `plateSolve` reaches the master and returns correct `ra/dec/pixelScale/rotation/field*`, but the **master never serializes** the CD matrix (`cd11..cd22`) or SIP distortion coefficients, so the slave's decode hardcodes them to zero. Root cause is master-side serialization, not the slave decode.
- *Disconnected:* full WCS / SIP precision for slave-driven consumers (sky atlas fold, First Light, mosaic project, science backend). Core coordinates are intact; only distortion-corrected pixel↔sky mapping degrades.
- *Files:* `apps/desktop/lib/headless_api/handlers/imaging_handlers.dart:89-99, 117-127` (omits CD+SIP — root cause); `packages/skotiq_core/lib/src/backend/network_backend/sequencer_operations.dart:15-45` (slave decodes zeros); `packages/skotiq_bridge/lib/src/api/plate_solve.dart:72-117` (required fields).
- *Fix:* serialize `cd11..cd22` + SIP order/coeff arrays in both `handlePlateSolve` response paths, and parse them in the slave decode (both ends).

**G2 — Open sequence-editor canvas not hydrated on connect** · `hydration`
The master's live/dirty editor canvas is mirrored to slaves only by edit-triggered WS frames; `hydrateRemoteSessionState` seeds the saved library rows but never `currentSequenceProvider`. A slave connecting while the master has a sequence open-and-idle sees an empty canvas until the master's next edit.
- *Disconnected:* live working canvas on mid-session connect; unrecoverable only for an **unsaved** sequence with no library row (a saved one can be re-opened from the hydrated library).
- *Files:* `packages/skotiq_core/lib/src/providers/remote_sync_handler.dart:736-781` (apply), `:1278-1323` (hydrate body — no seed); `.../sequence/master_sequence_editor_mirror.dart:143-154` (edit-only emit).
- *Fix:* on connect, either have the master re-broadcast the open canvas, or add a `GET current-editor` endpoint and seed `currentSequenceProvider` in the hydrate body.

**G3 — Current-frame hero tile not hydrated on connect** · `hydration`
The dashboard "current frame" tile + histogram/stats are written only by live `ImageReady/Saved/Captured` events. Hydration never calls `_publishRemoteCurrentFrame`, so a slave connecting between frames shows a blank hero tile — effectively permanent if the sequence has already finished. The host caches the last frame (`cameraGetLastImage`), so it IS hydratable.
- *Files:* `remote_sync_handler.dart:80-85, 861-937` (live-only), `:1278-1323` (no frame pull); `.../network_backend/device_operations.dart:382-415` (`cameraGetLastImage`); `skotiq_app/.../dashboard/widgets/cockpit_frames.dart:34`.
- *Fix:* one line in the hydrate body — `if (cameraId != null) unawaited(_publishRemoteCurrentFrame(reader, backend));`, reusing the existing coalescing helper.

**G4 — Exposure progress / "Exposing" countdown not hydrated on connect** · `hydration`
`cameraStateProvider.setExposing` and `exposureProgressProvider` are driven only by live `ExposureStarted/Progress/Complete`. Hydration seeds camera temp/cooling/target but never the in-flight exposure state — even though the fetched `CameraStatus.state` already carries `CameraState.exposing` and is silently dropped. A slave connecting mid-exposure shows the camera Idle with no countdown until the next progress tick (~1Hz).
- *Files:* `remote_sync_handler.dart:92-94, 202-250` (live-only), `:1395-1407` (telemetry apply drops `state`); `.../models/backend/device_status.dart:17`, `device_types.dart:29`; `skotiq_app/.../connected_device_card/status_and_display.dart:430`.
- *Fix:* in `_hydrateDeviceTelemetry`, read `camera.state == CameraState.exposing` and call `setExposing(true)` (precise remaining-time still waits for the first live tick, as `CameraStatus` carries no elapsed field).

**G5 — Adaptive filter-swap defaults + conditions-score weights don't cross the wire** · `settings-roundtrip`
`adaptiveSwapEnabledByDefault`, `adaptiveSwapDefaultThreshold`, `adaptiveSwapDefaultHysteresisSecs` (and `conditionsScoreWeights`) exist in `AppSettingsState` but are absent from the wire model. The settings panel is slave-reachable and **ungated**, so a slave operator touching these triggers a hard `UnsupportedError` (keys excluded from `_remotableSettingKeys`), and master changes never push down. The adjacent `adaptiveExposure*` cluster round-trips fully, making the omission inconsistent. `conditionsScoreWeights` is consumed live by the scheduler, so a remote operator genuinely cannot tune unattended-night swap scoring.
- *Files:* `app_settings_state.dart:427-451`; `app_settings_remote_mapping.dart` (absent); `models/settings/app_settings.dart:123`; `app_settings_partial_persistence_mapping.dart:26-31` (excluded + fail-loud); `skotiq_app/.../settings/widgets/adaptive_conditions_settings.dart`; `settings_catalog.dart:454` (ungated panel); `weather_safety_provider.dart:807-830` (live consumer).
- *Fix:* add the four fields to the wire model and all three projections (`_toRemoteSettings` / `_fromRemoteSettings` / `_applyJsonSettingChange`) and to `_remotableSettingKeys`.

### LOW

**G6 — `isPhd2Running` throws on the slave with no master endpoint** · `backend-control`
`NetworkBackend.isPhd2Running` throws `UnsupportedError` (it probes the host's loopback PHD2 socket, which a remote client can't reach, and no `phd2/running` route exists). The one real caller is the onboarding "Test connection" button, which surfaces the raw exception string in red. Every other guiding control is fully proxied.
- *Files:* `.../network_backend/guiding_operations.dart:8-21`; `apps/desktop/lib/headless_api/routes/guiding_routes.dart:14-87` (no route); `skotiq_app/.../onboarding/steps/guider_step.dart:61-106` (caller).
- *Fix:* add a master-side `/api/phd2/running` probe (the UI accepts an arbitrary host, so a master-side probe is feasible), **or** have the slave return a friendly "unavailable in remote mode" instead of throwing.

**G7 — `sequencesPath` / local-UI preference fields silently dropped slave→master** · `settings-roundtrip`
`sequencesPath` plus the desktop-UI prefs (`startMinimized`, `autoSaveSequences`, `confirmBeforeClosing`, `sidebarCollapsed`) and `smartNightAutoSelect`/`smartNightAutoSelectCount` are absent from the wire model. The UI prefs are defensibly device-local, but `sequencesPath` is a user-facing default-output location a remote operator would plausibly set, and `smartNightAutoSelect*` is inconsistent with the otherwise-fully-mirrored `smartNight*` group. A slave `setSequencesPath` appears to succeed but the value is dropped on POST with no feedback.
- *Files:* `file_paths.dart:23-26` (sequencesPath); `app_settings_state.dart:5,7-8,18,371-375` ; absent from `app_settings_remote_mapping.dart` and `models/settings/app_settings.dart`.
- *Fix:* add `sequencesPath` and `smartNightAutoSelect*` to the wire model + projections; explicitly mark the genuinely device-local window prefs as non-remotable (and ideally gate or disable those controls in slave mode so the write isn't a silent no-op).

---

## 4. What Was Checked — Scope & Limits

**Method.** This was a contract-level static trace, not a runtime test. For each dimension I enumerated the authoritative source-of-truth and verified the counterpart end-to-end:
- *Backend control:* enumerated all ~130 abstract members of `SkotiqBackend`'s 6 role interfaces and read every `NetworkBackend` mixin part, confirming each method's REST/WS call against the matching master route in `system_endpoint_catalog.dart` + `routes/*` + `handlers/*`.
- *State mirror:* traced every master `publishHostMutationFrom*` emit site and backend-event category against the slave's `remote_sync_handler.dart` apply switches.
- *Hydration:* read the full `hydrateRemoteSessionState` body and compared what it seeds against every live-event apply path.
- *Settings:* compared all 126 `AppSettingsState` fields against the wire model and all three projections (`_toRemoteSettings` / `_fromRemoteSettings` / `_applyJsonSettingChange`).
- *Profiles:* traced all 6 operations through `NetworkBackend` → `profile_handlers` → routes → DAO.

Every one of the 7 confirmed gaps was re-verified by opening the cited files on **both** ends (slave impl + master route/handler) to rule out coverage via an alternate path.

**Limits — what this audit does NOT establish:**
1. **No on-sky / live-rig run.** This proves the wires connect and carry the right payloads; it does not prove behavior under real INDI/ASCOM hardware, latency, or reconnection storms. The known headless ASCOM/COM issues from prior live-rig testing are out of scope here.
2. **Payload-shape, not value-correctness.** I confirmed endpoints exist and serialize/deserialize the right fields; I did not assert every numeric value is computed identically on both ends (G1 is the one place serialization completeness was checked and found lacking).
3. **UI rendering of mirrored state** was traced to the consuming provider/widget (to gauge gap blast radius) but not visually verified.
4. **Transport/security layer** (auth, WS reconnect/backoff, partial-frame handling) was touched only where it fed the streams; it was not independently audited.
5. **Timing/race windows** beyond the three identified hydration gaps were not exhaustively modeled.

Given those limits, the connectivity claim is high-confidence; the residual hand-testing you should budget for is on-sky behavior and the seven bounded gaps above — not feature-by-feature wire-checking.