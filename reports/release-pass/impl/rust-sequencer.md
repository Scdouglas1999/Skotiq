# Impl log — batch `rust-sequencer`

Work order: `reports/release-pass/map/rust-sequencer.md`
Scope: `native/skotiq_native/sequencer/**` (+ minimal bridge call-site fixes for
symbols item 2 removes).

## Items

1. R1 — per-call timeouts + stall watchdog on trigger-monitor device polls
2. R2 + DC1 — wire `update_location` / `update_dither_config` / `update_filter_offsets`;
   delete `ExecutorCommand::Start`; correct the false doc
3. D3 — unify the three solar-position implementations into `src/solar.rs`
4. P1 + P2 — collapse the duplicate `guider_get_status` poll; cadence-gate mount /
   focuser / dome
5. D4 + R4 — move `MeridianFlipOutcome` emission into `MeridianFlipExecutor::execute`
6. D7 + R7 — give the flat wizard a `FrameSavePathRenderer`

## Running log

### Item 3 — D3 solar unification (DONE)
New `sequencer/src/solar.rs` (`sun_equatorial`, `equation_of_time_minutes`,
`sun_altitude_degrees`, `time_of_sun_altitude{,_at}`, `SunCrossing`,
`SUN_ALTITUDE_NEVER_REACHED`). Parity tests written first; the three legacy
implementations are kept verbatim inside the test module as references.
- `node/context.rs::approximate_sun_equatorial_coords` deleted → delegates.
- `instructions.rs::calculate_solar_position` + local `build_utc_naive_time_or_fallback`
  deleted → `calculate_twilight_time` delegates (Setting crossing).
- `triggers.rs::calculate_dawn_time` (Cooper, no equation of time) + local
  `build_utc_naive_time_or_fallback` deleted → delegates (Rising crossing). D2 falls out.
- Found while writing the tests: the legacy polar-case COMMENTS in both callers
  labelled the two `cos_h` branches backwards. The branches were right; only the
  comments lied. Corrected in `solar.rs`, behaviour unchanged.
Proof: `cargo test -p skotiq_sequencer --lib solar::` → 7 passed, 0 failed.
Full lib suite after the change: 766 passed, 0 failed.

### Item 2 — R2 + DC1 (DONE)
- `update_location` / `update_dither_config` / `update_filter_offsets` are now
  `async` and forward their `ExecutorCommand`s (the file's own documented
  two-step contract). `update_location` also patches the trigger state directly
  when idle, since an idle executor has no task to send to.
- `TriggerState::set_observer_location` added: sets lat/lon AND clears
  `dawn_time`, because the monitor only recomputes dawn when the cache is
  missing or past — a site change with a live cache kept the OLD site's dawn.
- `ExecutorCommand::Start` + its arm deleted (no sender anywhere in the workspace).
- Corrected the false doc at `runtime_config.rs:222-227`.
- Bridge call sites made `.await` (7 mechanical edits, no FRB signature change —
  every wrapper was already `pub async fn`).
Proof: new `executor::tests::a_mid_run_location_change_reaches_the_altitude_dawn_and_meridian_inputs`.
Revert-check: with the `UpdateLocation` forward disabled the test fails
"timed out waiting for the pushed New York location" after 15 s; restored → passes.

### Item 6 — D7 + R7 flat-wizard save-path renderer (DONE)
- `InstructionContext::to_template_context()` (instructions.rs) rebuilds the
  `ExecutionContext` a save-path template resolves against, for callers that own
  only an `InstructionContext`.
- `build_save_path_renderer` is now `pub(crate)`.
- New `flat_wizard::capture_converged_flats` builds the renderer and calls
  `execute_exposure_with_renderer`; the filter identity comes from
  `resolve_frame_filter`, the same answer the FITS FILTER card is built from, so
  the filename cannot disagree with the header.
- `execute_exposure` now has no production caller anywhere in `native/`.
Proof: new `instructions::tests::flat_wizard_flats_are_named_by_the_save_path_renderer`.
Revert-check: passing `None` for the renderer makes it fail with
`left: "untargeted_R_0001.fits"` / `right: "Flat_R_0001.fits"`; restored -> passes.
Full flat-wizard-related selection: 12 passed, 0 failed.

### Item 1 — R1 per-call timeouts + stall watchdog (DONE)
- `bounded_poll(what, fut)` + `TRIGGER_POLL_TIMEOUT_SECS = 10` wraps every
  production device poll in the trigger monitor: `safety_is_safe`,
  `weather_get_humidity`, `guider_get_status`, the five mount calls,
  `focuser_get_temperature`, `dome_get_shutter_status`. A timed-out poll is
  reported as a poll FAILURE, which every caller's `Err` arm and the
  `SafetyFailMode` ladder already handle.
- `trigger_monitor_stall_watchdog` + a `watch<u64>` heartbeat beaten once per
  loop iteration (before the pause gate, so a paused run still beats). The
  monitor future is wrapped in a `select!` against the watchdog, so a stall
  resolves the future and the existing fail-closed join arm cancels the run;
  the watchdog emits its own precise Error naming the cause first.
  `TRIGGER_MONITOR_STALL_TIMEOUT_SECS = 180`, and the watchdog holds off while
  `trigger_action_in_flight` is set (a flip retry ladder holds the loop for
  minutes by design).
Proof (4 tests):
- `executor::tests::a_hung_device_poll_is_reported_as_a_failure_instead_of_parking_the_monitor`
  (drives a real run against a mock whose `mount_is_tracking` is
  `pending()` forever) — passes in 10.01 s.
  Revert-check: with the `mount_is_tracking` bound removed it FAILS after 40 s
  ("the monitor never got past the hung mount poll"); restored -> passes.
- `a_device_poll_that_never_answers_is_reported_as_a_poll_failure`
- `the_stall_watchdog_fires_only_once_the_monitor_stops_beating`
- `the_stall_watchdog_holds_off_while_a_trigger_action_is_in_flight`

### Item 4 — P1 + P2 poll cadences (DONE)
- P1/R6: one `guider_get_status` per tick feeds both the RMS update and the
  `is_guiding` latch. The two contradictory error policies collapse to the
  fail-closed one (an unreachable guider is a lost star when guiding was
  expected, and no RMS update).
- P2: the five mount calls now run on `MOUNT_POLL_INTERVAL_SECS = 5`;
  `focuser_get_temperature` and `dome_get_shutter_status` moved onto the
  existing `should_poll_safety` cadence (default 30 s).
- Per-tick device round-trips with a full rig: 9 -> 1 (the guider), with the
  mount block every 5 s and the safety/weather/focuser/dome block every 30 s.

### Item 5 — D4 + R4 (verified inherited, plus the missing end-to-end test)
`MeridianFlipExecutor::execute` announces the verdict itself and both call
sites inherit it (trigger path's three emissions deleted; node path already
wires `with_executor_event_tx`). Re-proved the node path end to end:
- New `instructions::tests::a_node_driven_meridian_flip_reports_its_outcome_to_the_run`
  drives `execute_meridian_flip` and asserts exactly one `MeridianFlipOutcome`.
  Revert-check: with `announce_outcome` removed from `execute` it FAILS
  ("left: 0, right: 1", node returned Failure); restored -> passes.
- `ScriptedDomeRotatorOps::with_observer_location` added so the flip node can
  get past its site-configured precondition (`get_observer_location` now
  answers from the script instead of delegating to `NullDeviceOps`' `None`).

### Item 2 — re-verified
`ExecutorCommand::Start` has zero senders across `native/ packages/ apps/
tools/` (fresh grep). Bridge builds clean against the `async update_*`
signatures (`cargo build -p skotiq_bridge` -> Finished).

### Item 3 — re-verified
`cargo test -p skotiq_sequencer --lib solar::` -> 7 passed, 0 failed
(parity against all three legacy implementations, kept verbatim in the tests).

## Gate results

- `cargo test -p skotiq_sequencer --lib` -> **775 passed, 0 failed** (30.47 s)
- `cargo build -p skotiq_bridge` -> Finished (no signature drift)
- `cargo fmt -p skotiq_sequencer -- --check` -> clean
- `cargo clippy -p skotiq_sequencer --all-targets` -> 0 warnings

## Not touched (per the work order)

- The mosaic checkpoint-sink question (R5 / DC4) — owner decision.
- No file splits: `start()` was not decomposed, `instructions.rs` not split.
- D5's copy-pasted trigger-monitor ceremony was left alone: its canonical fix
  is defined in terms of the 1.2 split, which this wave forbids.
