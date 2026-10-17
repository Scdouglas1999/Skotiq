# Slave Local-Store Read Audit — Skotiq2

*Branch: `feature/v5-living-sky` · 2026-06-21 · scope: features that read the local SQLite/in-memory store directly and therefore render empty/wrong on a remote-client slave*

---

## 1. Executive Summary

**This bug class is widespread, not rare.** A focused sweep of six subsystems found **27 confirmed slave-breaking read sites**, plus 2 surfaces that are correctly host-only-by-design and 1 that is already remote-aware. Every confirmed issue shares the same root cause: a provider/service reads `databaseProvider` (always a live, **locally-empty** `SkotiqDatabase` on a slave — see `database_provider.dart:24-28`) or an in-memory `StateNotifier` fed only by the local capture loop, with **no `backend is NetworkBackend` branch**. On a remote client those rows live only on the master, so the surface silently renders empty/zero — and crucially **looks structurally correct**, so the gap is easy to miss in casual testing.

**How worried should we be: moderately-to-quite worried, but the remediation is mostly mechanical.** The severity is tempered by three facts:

1. **The correct pattern already exists and is proven.** `allDbTargetsProvider`, `allSessionsProvider`, `allDbImagesProvider`, `targetProgressProvider`, and `dbSessionImagesProvider` all branch on `backend is NetworkBackend` and poll the master via `_pollRemote*`. These are exemplars to copy, not research problems.
2. **For a meaningful chunk of issues the remote transport already exists and is simply unwired** — the master serves the data, the `NetworkBackend` client method is implemented, but no provider consumes it. These are *wiring-only* fixes (high ROI). The clearest case: `sequenceRunsProvider` (the candidate report wrongly claimed no endpoint existed; `fetchSequenceRuns()` / `GET /api/sequence-runs` is live).
3. **The remainder need a new master REST endpoint** before the client branch can be added (projects, goals, constraints, horizons, observing-lists, observation-logs).

**Worry concentration:** The scheduler/autopilot cluster is the most alarming, because it does not merely render empty — it **silently produces wrong behavior**. On a slave the autopilot evaluates candidates with **zero constraints and zero custom horizons applied** (high), so targets behind a tree-line or violating a moon/altitude limit get scheduled and imaged anyway. That is a correctness failure, not a cosmetic one. The other surfaces (run history, dark library, notes, polar history, observing lists, profile delete) are blank-screen / write-to-nowhere defects — bad UX and data loss on edits, but not silently-wrong telescope automation.

**Net:** the class is real and broad, but it is a *consistent, well-patterned* defect with a known fix shape. The two highest-leverage actions are (a) fix the scheduler constraint/horizon/goal gating before any unattended slave-driven imaging, and (b) sweep the already-built-but-unwired remote endpoints into their providers.

---

## 2. Areas Swept

| Area | Breaks-on-slave | Suspect (→confirmed) | Intentional / host-only | Already remote-aware |
|---|---|---|---|---|
| Scheduler + Planner + Projects | 6 | 1 → confirmed | 0 | 0 |
| Sequencer | 3 | 0 | 2 | 0 |
| Imaging + Capture + Dashboard | 2 | 2 → confirmed | 0 | 0 |
| Equipment + Devices | 3 | 0 | 0 | 0 |
| Analytics + Sessions + Progress | 2 | 0 | 0 | 0 |
| Guiding/Safety/Polar/Flat/Narrator | 4 | 2 → confirmed | 1 (Night Narrator) | 1 (Transients) |
| **Totals** | **20** | **7** | **3** | **1** |

Notes:
- All 7 "suspect" findings were promoted to **confirmed breaks-on-slave** under verification, so the operative confirmed count is **27**.
- "Intentional / host-only" = sequencer run-history surfaces where `SequenceRepository` deliberately throws (`"run history lives on the host"`, `"the host owns its version history"`) and the Night Narrator (host-side event generation, not a stored-data read). These are acceptable *if* the slave shows an explicit "lives on the host" state rather than a silent empty list — see the recommendation below.
- The 2 sequencer "intentional-host-only" entries overlap conceptually with the **confirmed** `sequenceRunsProvider` break: the *History tab being empty* is tolerable as host-only, but the same provider also blanks the dashboard "Last night" recap and morning report, where empty is a genuine defect — hence it is confirmed.

---

## 3. Confirmed Issues — Prioritized Fix List

Severity legend: **HIGH** = silently-wrong automation or a hard functional block; **MED** = blank/stale user-facing surface or write-to-nowhere; **LOW** = degraded convenience, still functional.

### HIGH

**H1 — Autopilot evaluates candidates with zero constraints & zero custom horizons**
`scheduler_provider.dart:251-258`
- *Symptom on slave:* The candidate loader reads `target_constraints` and `horizon_profiles` from the empty local DB. Every candidate is scored with **no** altitude/moon/visibility gating and **no** custom horizons. Targets that should be excluded (behind an obstruction, violating moon-separation/altitude) are scheduled and imaged. Silently wrong, not empty.
- *Minimal fix:* Add master REST endpoints for `target_constraints` + `horizon_profiles`; add `_fetchRemoteConstraints/_fetchRemoteHorizons` on `NetworkBackend` (mirror `_fetchRemoteTargets`); branch `load()` on `backend is NetworkBackend`. Local/master path unchanged.

**H2 — Integration goals invisible on slave; autopilot ranks with zero goals**
`integration_goal_service.dart:239-241` (+ `watchAll`/`listAll`/`listForTarget`/`capturedFrameCount`)
- *Symptom on slave:* `integrationGoalServiceProvider` is hardcoded to `databaseProvider`. Goals editor is blank (and edits write to the dead local DB); project/target progress shows no goal lines and 0 captured counts; the autopilot sees every target as having zero goals, so nothing accrues toward completion and ranking/dwell is wrong.
- *Minimal fix:* Make the service host-aware like its siblings (`CalibrationLibraryService`, `DefectMapService` use `NetworkBackend? get _remote`). Add an `integration_goals` REST surface (list/listForTarget/upsert/delete/capturedFrameCount) and branch the provider to a remote-backed impl when `backend is NetworkBackend`. Captured-frame counts must come from the host's `captured_images`.

**H3 — `sequenceRunsProvider` blanks the dashboard recap / morning report / History tab**
`sequence_stats_provider.dart:285` (also `:291` family)
- *Symptom on slave:* Unconditional `watchAllRuns()` on the empty local DB → "No runs yet" on the standby "Last night" recap (`last_night_recap_card.dart:22`), the morning report vanishes (`cockpit_morning_report.dart:14`), and the sequencer History tab is empty (`history_tab.dart:45,89`) even after a full night on the master.
- *Minimal fix:* **Wiring-only — the transport already exists.** `NetworkBackend.fetchSequenceRuns()` (`GET /api/sequence-runs`, `remote_database_plugin_operations.dart:6`) returns `RemotePage<RemoteSequenceRun>` carrying every field the consumers read. Add `_pollRemoteRuns(backend)` in `database_provider.dart` (mirror `_pollRemoteSessions`), map `RemoteSequenceRun → SequenceRun`, and branch `sequenceRunsProvider`/`sequenceRunsForSequenceProvider` on `backend is NetworkBackend`. *(The candidate report's claim that no endpoint exists is wrong.)*

### MEDIUM

**M1 — Project-scoped autopilot goes "Nothing eligible" the moment a project is active**
`scheduler_provider.dart:230-241` — INNER JOIN on local `project_targets` yields zero rows on a slave; flows up to `schedulerPreviewDecisionProvider`/`schedulerPreviewRankingProvider` (`:564-587`). *Fix:* new `GET projects/{id}/scheduler-candidates` master endpoint + remote branch in `load()`; or, if out of scope, scope project autopilot to the master and gray the project selector on a slave.

**M2 — Per-target constraints editor empty; slave edits write to nowhere**
`target_constraint_service.dart:158-164` — provider bound to `databaseProvider`; constraints editor (`target_constraints_editor.dart:118,128`) shows nothing and edits never reach the host. *Fix:* master `target_constraints` REST endpoint (list/by-target + mutations) + branch `targetConstraintsStreamProvider`/the service on `backendProvider`.

**M3 — Planner "Projects" tab shows empty list & no campaign progress**
`project_service.dart:395-400`, `planning_provider.dart:130-174` — local-only `projects`/`project_targets`; tab rendered unconditionally (`_projects_tab.dart:74`). *Fix:* master endpoints for projects/project_targets + server-computed roll-up; `_pollRemoteProjects` feeding `projectListProvider`/`projectProgressProvider`/`activeProjectProgressProvider`.

**M4 — Target progress shows "No integration goals set" / 0% despite correct frame counts**
`target_progress_provider.dart:11-16` — images are remote-branched but goals come from the empty local `integrationGoalServiceProvider` (`target_progress_service.dart:51`). Downstream of H2. *Fix:* once goals are remote-pollable, pass host goals into `TargetProgressService.forTarget` (parallel to the existing optional `capturedImages` param).

**M5 — Run-dashboard "Filter Integration" stuck at 0 during a mirrored run**
`run_dashboard_providers.dart:224` — `imagesDao.getImagesForSession(sessionId)` direct. *Fix:* branch on `backend is NetworkBackend` → `backend.getSessionImageRows(sessionId)` (`imaging_profile_operations.dart:378`, already exists), keep polling.

**M6 — Pre-flight falsely reports every dark/bias frame missing**
`preflight_rules.dart:120-121` — `DarkLibraryCoverageRule` reads `darkLibraryServiceProvider.getAllEntries()` (local), registered unconditionally (`sequence_validation.dart:373`). On a slave it marks all coverage missing and can block the run. *Fix:* branch on `backend is NetworkBackend` → `listDarks()` (`remote_calibration_catalog_operations.dart:82`) / `fetchDarkLibrary()`; interim, neutralize the rule on a remote client rather than emitting a false warning.

**M7 — Quick-Start wizard target search returns nothing**
`quick_start_wizard_dialog.dart:419` — `targetsDao.searchTargets(query)` direct, errors swallowed. *Fix:* branch to `backend.searchTargets(query)` (`domain_operations.dart:33`, exists) or filter the already-remote-aware `allDbTargetsProvider` client-side.

**M8 — Cockpit "Recent Frames" / capture strip empty while master images**
`imaging_provider.dart:290` — in-memory `sessionImagesProvider` populated only by the local capture loop (`imaging_service.dart:569`); master-driven frames never reach it. *Fix:* source the strip from session-filtered `allDbImagesProvider` (already remote-aware) for slave-initiated + master frames.

**M9 — Cockpit "Session Vitals" tile reads idle mid-run**
`sequence_stats_provider.dart:277` — `liveSequenceStatsProvider` written only by the local executor; the remote sync handler mirrors state/progress but not vitals. *Fix:* extend `SequencerStatus` wire model with the vitals counters and reconstruct `SequenceRunStats` in `_applySequencerStatus` (`remote_sync_handler.dart:1218`) — reuses the existing status poll, no new endpoint.

**M10 — Profile delete is impossible on a slave**
`equipment_screen.dart:342-345` — `_deleteProfile` reads the row via local `equipmentProfilesDaoProvider.getProfileById` → null → throws *before* the remote-aware `profileService.deleteProfile()` runs. *Fix:* resolve the row from `sortedProfilesProvider` (host-polled, already carries `name`/`isActive` for the undo snackbar).

**M11 — Undo-restore of an active profile silently fails to re-activate on master**
`equipment_screen.dart:439-444` — `dao.setActiveProfile(restoredId)` writes only the local DB. *Fix:* `ref.read(equipmentProfilesProvider.notifier).setActiveProfile(restoredId)` (already NetworkBackend-branched, `profiles_provider.dart:808-819`).

**M12 — Filter focus offsets / temperature model render empty on slave**
`filter_offset_provider.dart:114-117` (service `focus_model_service.dart:333-344`) — reads per-profile JSON under `getApplicationDocumentsDirectory()/Skotiq/focus_models`, which lives only on the master's disk; a *separate* store from the SQLite `filterFocusOffsets` that does sync. *Fix:* branch `_loadOffsetsForActiveProfile` on `NetworkBackend` → `backend.getFocusModel()` (the endpoint `FocusModelSettings` already uses); gate the local-JSON path on the non-network case. (Repo already calls the local path "orphaned … empty over the network" at `focus_model_settings.dart:12-15`.)

**M13 — Session Report mount/errors/warnings silently zero on slave**
`session_report_service.dart:458` (`_findRelatedSequenceRuns → _sequenceRunsDao.getAllRuns()`) — frame counts/integration are remote-aware, but autofocus runs, meridian flips, dithers, trigger fires, and the error/warning lists read the empty local `sequence_runs`. A confident-but-false "no flips, no errors" report. *Fix:* once a remote run accessor exists (H3), route related runs through it; interim, short-circuit those sections to "unavailable on companion". Also resolve target names via the remote target list, not `targetsDao.getAllTargets()`.

**M14 — Entire observing-lists / favorites subsystem empty on slave**
`observing_list_provider.dart:8-35` — `observingListsDaoProvider` local-only, **no remote endpoint exists at all**. Blanks the planetarium Lists tab (`lists_tab.dart`), object-info "add to list" (`supporting_widgets.dart:354`), planner candidate add-to-list (`_candidate_list.dart:336`), Settings > Observing Lists, and the sky-chart list markers; slave edits write to nowhere. *Fix:* add a host observing-lists endpoint + `NetworkBackend.getObservingLists()/getObservingListItems()` + `_pollRemoteObservingLists`, and branch the read providers; route `ObservingListNotifier` writes to the host too. Stopgap: gate the Lists tab + add-to-list UI host-only. *(M14 subsumes the per-consumer findings in `lists_tab.dart`, `supporting_widgets.dart`, `_candidate_list.dart` — fix the provider and they all clear.)*

**M15 — Dark Library settings panel & calibration coverage empty on slave**
`dark_library_provider.dart:22-51` — all five entries/stats/groups providers stream off the local DAO; feeds `dark_library_settings.dart:26-28`, `calibration_settings.dart:68`, and the readiness gate (`readiness_provider.dart:90`). *Fix:* branch on `NetworkBackend` → `listDarks()` (host handler `dark_library_handlers.dart` already serves it); stats/groups fix transitively.

**M16 — Observation-log "already observed" markers vanish; log panel empty**
`observation_log_provider.dart:13-31,199-223` — local-only; `observedCatalogIdsProvider` feeds the planetarium markers (`planetarium_shell.dart:62`, `layouts.dart:52,354`). **No remote endpoint exists.** *Fix:* add `/api/observation-logs` (rows + observed catalog IDs) + a `_pollRemote` branch. *(Note: candidate's `recentObservationLogsProvider` does not exist in the codebase.)*

**M17 — Polar-alignment history & "last alignment" empty on slave**
`polar_alignment_provider.dart:704-734` — three family providers read the local DAO; blanks `_history_panel.dart:165` and the Smart Night dialog (`smart_night_dialog.dart:519`). *Fix:* **endpoint already live** — branch on `NetworkBackend` → `fetchPolarAlignmentHistory()` (`remote_database_plugin_operations.dart:50`; server route `db_read_routes.dart:42`), currently zero consumers.

**M18 — All notes surfaces empty on slave**
`notes_provider.dart:25-57` — `notesServiceProvider = NotesService(databaseProvider)`; blanks the sequencer Notes panel, target/global notes dialogs, per-run notes, replay-debug. *Fix:* **endpoint already live** — branch on `NetworkBackend` → `fetchNotesJournal()` (`remote_database_plugin_operations.dart:20`, `GET /api/notes-journal`), map `RemoteNotesJournalEntry → JournalNote`. Writes need a follow-on remote path or host-only gating.

**M19 — Flat Wizard records calibrations into the slave's throwaway DB**
`action_buttons.dart:120,343` — `db.flatHistoryDao.recordCalibration()` writes local; master's flat library never learns from remote flat sessions. *Fix:* branch on `NetworkBackend` → `backend.recordFlat(...)` (`remote_calibration_catalog_operations.dart:274`, exists, unconsumed).

### LOW

**L1 — Science HUD contextual nudges never appear on slave**
`science_hud.dart:541` — `_huddedImagesProvider` runs the exact query that `dbSessionImagesProvider` (`analytics_screen/session_tab.dart:315`) already wraps in a `NetworkBackend` branch, but omits it; the "moving-object detection?" / "narrowband ratios?" offers stay hidden. *Fix:* copy the `_pollRemoteSessionImages` branch or route through `imagingRecordsRepository.watchImagesForSession`.

**L2 — Constellation follow-the-night drops local-mapped-but-unjoined suggestions**
`constellation_provider.dart:42-61` — `localTargetsResolver` calls `targetsDao.getAllTargets()` directly; joined hub targets still surface, but local-mapped-unjoined suggestions disappear and labels/coords degrade. *Fix:* one-liner — resolve via `allDbTargetsProvider.future` (already host-polled). *(Severity downgraded from the candidate's "returns nothing" — the card is not fully empty.)*

**L3 — Flat Wizard loses learned-exposure smart-start on slave**
`flat_wizard_provider.dart:79-90` — `getSuggestedExposure` reads the local DAO → null per filter; wizard still works with manual entry. *Fix:* branch on `NetworkBackend` → `listFlats(filter, profileId, limit:5)` averaged, falling back to the local DAO. (Pairs with M19.)

---

## 4. Reuse-These Good Patterns (already remote-aware)

These are the canonical exemplars — every fix above should imitate one of them rather than invent a new shape:

- **`database_provider.dart` `_pollRemote*` family** — `allDbTargetsProvider` / `allSessionsProvider` / `allDbImagesProvider` branch `if (backend is NetworkBackend) return _pollRemote…(backend)` and poll the master on a fixed tick. *The* template for any list/stream provider.
- **`targetProgressProvider`** (`target_progress_provider.dart:33,41,57`) — branches on `NetworkBackend` and passes host-fetched `capturedImages` into a service via an *optional parameter*, leaving the service backend-agnostic. The model for injecting remote data into an existing service (use this shape for goals in M4).
- **`dbSessionImagesProvider`** (`analytics_screen/session_tab.dart:315`) with **`_pollRemoteSessionImages`** (`session_detail_dialog.dart:369`) — a per-session 10s poll over `getSessionImageRows`; reuse directly for L1 and M5.
- **`SequenceRepository`** (`sequence_repository.dart:1004-1018`) — branches to `listFullSequences/listFullTemplates` and, where a domain is deliberately host-only, **throws an explicit message** (`"run history lives on the host"`). This is the right pattern for surfaces that *should* stay host-only: fail loud with a "lives on the host" state instead of silently rendering empty.
- **Host-aware services** — `TargetLibraryService`, `CalibrationLibraryService` (`:62-66`), `DefectMapService` (`:23-25`): `NetworkBackend? get _remote => backendProvider is NetworkBackend ? backend : null;` with each method delegating to `_remote` when non-null. The template for H2/M2 (service-level, not provider-level, branching).
- **`activeTransientAlertsProvider`** (`transient_alert_provider.dart:250-257`) and **`equipmentProfilesProvider.setActiveProfile`** (`profiles_provider.dart:808-819`) — already correct; cited to confirm the surfaces were checked and that mutation paths can be remote-aware too.

**Cross-cutting recommendation:** a large fraction of MED issues (H3, M17, M18, plus the read halves of M15/M19/L3) are **already-built-but-unwired** remote endpoints — fix these first; they need only a provider branch and a row-mapping, no server work. The endpoint-missing issues (H1, H2, M1, M2, M3, M14, M16) should be batched behind a small set of new master read routes. Finally, audit `databaseProvider` consumers as a standing lint: it is the single load-bearing footgun, since it hands back a live-but-empty DB on a slave instead of throwing.