# Wave B-fix — batch `sequencing-autopilot`

Items: SEQ-12 (P0), SEQ-13, SEQ-14, SEQ-3, SEQ-15, SEQ-16, SCI-39, SCI-40,
SEQ-6/STATE-VOCAB, SEQ-17, SEQ-18, SEQ-19.

Ladder: failing test first in the owning package, then the fix, then green.

## Log

### Done

- **SEQ-12 (P0)** — `_handleNoEligibleTarget` now only stops a run the autopilot
  itself dispatched (`currentTargetId != null` at entry), and the stop/park is
  explained on the decision `reasoning` the panel renders. Failing test first:
  3 unconditional `stopSequence()` calls with nothing ever dispatched
  (`scheduler_engine_test.dart` → "only stops runs it started"). Green.
- **SEQ-3 / SCI-39 (pre-flight half) / SEQ-16** — new
  `rules/sky_readiness_rules.dart`: `DaylightGateRule` (hard error, the engine
  refuses categorically), `ObserverLocationUnsetRule` (absent site is UNKNOWN
  and pre-flight says so), `MountOffTargetRule`. Registered in
  `defaultRefAwareSequenceValidators`; registry membership is pinned by a test.
  At HEAD no such rule existed, so pre-flight emitted nothing for any of these.
- **SCI-40** — `DarkLibraryCoverageRule` keys on the camera's real sensor
  temperature when `CameraCapabilities.canSetCcdTemperature` is false. Proven
  by reverting the one line: both new tests fail (`temp=-10.0C`), pass after.

- **SCI-39 (root)** — the sequencer treats an exactly-(0,0) observing site as
  UNSET (`node::context::normalized_observer_location`, applied at
  `set_location`, `update_location` and inside `daylight_gate_block_reason`),
  and the gate's abstain path now logs a WARNING naming the missing setting
  instead of a debug line. Proven by neutering the sentinel arm: all 3 Rust
  tests fail (`left: Some(0.0), right: None`), pass restored. Full
  `cargo test -p skotiq_sequencer --lib`: 778 passed.
- **SEQ-14** — root cause is a timezone bug, not an empty-projects path:
  `SkyCalculations.computeTwilight` searched 24 h from the CALLER's noon. On a
  host in UTC with a site at UTC+10 that anchor lands mid-night, so the search
  finds the morning crossing first and returns a dawn EARLIER than its dusk,
  which the forecast reads as `darkHours == 0` — seven "No astronomical
  darkness" cards. The window is now anchored at the SITE's solar noon nearest
  the caller's anchor. Failing test first (probe: dusk 2026-08-12T09:00Z, dawn
  2026-08-11T19:26Z for lat -35 / lon 148).
- **SEQ-13** — `findOrCreateByName` matches on the name only, so re-pointing a
  target left the `targets` row (the only thing the autopilot reads) on the old
  RA/Dec. `_refreshCatalogCoordinates` updates the coordinates at bind time, and
  only the coordinates; an unset (0,0) node never blanks a stored position.
- **SEQ-15** — the toolbar's Slew now locks with its nine neighbours while a run
  owns the mount, asks first when idle (naming the target, its coordinates and
  its altitude, with a below-horizon banner), and logs the command, the outcome
  and a cancellation. Widget tests drive the real toolbar.
- **SEQ-6 / STATE-VOCAB** — one presentation mapping,
  `screens/sequencer/run_status_presentation.dart`; `paused-stopped` reads as
  "Stopped (resumable)". Used by the Session Report header and by both History
  status surfaces (filter chips + row badge).
- **SEQ-18** — the exposure progress card takes the node status; a finished node
  reports every frame it captured instead of falling back to frame 0.
- **SEQ-19** — `builderFilterSource` falls back to the connected wheel when the
  profile has no filters, so the builder stops denying the filter the capture
  path is writing into the filenames.
- **SEQ-17** — the scheduler's list is now "Scheduler queue" everywhere
  (queue table header, autopilot banner copy + button); the builder's Queue tab
  keeps its name (the planetarium's "Add to Target Queue" points at it) and its
  empty state now names real surfaces and distinguishes the two lists.

### Verification

- `skotiq_core`: `test/providers/sequence` + `test/services/scheduler` +
  `test/services/planning` — 672 passed.
- `skotiq_sequencer` (Rust): `cargo test --lib` — 778 passed; `cargo fmt`
  clean.
- `skotiq_app`: every toolbar/history/panel suite touched by this batch —
  24 passed. Analyzer clean over the edited scope in both packages
  (3 pre-existing `clampPanelWidth` deprecation infos in planner remain).

Pre-existing failures OUTSIDE this batch, each proven independent by reverting
the relevant change and re-running:

- `test/screens/planner/captures_*.dart`, `test/screens/sequencer/captures_*` —
  golden pixel diffs (identical 6.97% / 27941px with and without the planner
  copy change). Standing rule: do not regenerate goldens on Linux.
- `test/screens/sequencer/widgets/mosaic_wizard_resume_test.dart` — fails and
  hangs (~10 min) with `_pendingExceptionDetails != null`; still fails with the
  SEQ-13 coordinate refresh disabled, so it is not this batch's.

### Orientation

- `SchedulerEngine._handleNoEligibleTarget` (packages/skotiq_core/lib/src/services/scheduler/scheduler_engine.dart:627)
  calls `_sequenceSink.stopSequence()` on EVERY transient no-eligible tick,
  with no check that the autopilot ever dispatched the run it is stopping.
  That is the SEQ-12 P0 stop call.
- The visible surface for an autopilot reason is the decision `reasoning`
  list (`_ReasoningList` in
  packages/skotiq_app/lib/screens/planner/widgets/scheduler_tab_content/decision_panel.dart);
  `SchedulerStatus.lastError` is rendered nowhere.
- The Rust daylight gate (`instructions::daylight_gate_block_reason`) already
  ABSTAINS when lat/lon are `None`. SCI-39's Null Island comes from the
  persisted native site being `Some(0,0)`, pushed into the executor by
  `seed_executor_site_from_settings`. The sequencer must treat exactly (0,0)
  as unset.
