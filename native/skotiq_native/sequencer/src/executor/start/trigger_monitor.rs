//! The run's trigger monitor: one poll cycle per second over the safety,
//! meridian, autofocus and scheduling triggers, driving each fired trigger's
//! recovery action to completion before the next poll.

use super::*;

/// Everything the poll loop reads from the run it belongs to.
pub(super) struct TriggerMonitorArgs {
    pub active_run_id_for_decisions: Arc<StdRwLock<Option<i64>>>,
    pub cloud_motion_for_recovery: Arc<RwLock<CloudMotionSnapshot>>,
    pub custom_recovery_branches_for_triggers: Arc<HashMap<String, String>>,
    pub custom_recovery_context_for_triggers: ExecutionContext,
    pub decision_tx_for_lifecycle: crate::decision::DecisionSender,
    pub device_ops_for_triggers: SharedDeviceOps,
    pub event_tx_clone2: broadcast::Sender<ExecutorEvent>,
    pub execution_quiesced_for_triggers: watch::Receiver<bool>,
    pub heartbeat_tx: watch::Sender<u64>,
    pub is_cancelled_clone: Arc<AtomicBool>,
    pub is_paused_for_triggers: Arc<AtomicBool>,
    pub meridian_flip_failed_for_triggers: Arc<AtomicBool>,
    pub meridian_flip_failure_for_triggers: Arc<StdRwLock<Option<String>>>,
    pub park_and_abort_done_for_triggers: watch::Sender<bool>,
    pub park_and_abort_for_triggers: Arc<AtomicBool>,
    pub progress_for_triggers: Arc<StdRwLock<SequenceProgress>>,
    pub recovery_request_tx: mpsc::Sender<crate::recovery::RecoveryCause>,
    pub runtime_config: Arc<StdRwLock<RuntimeConfig>>,
    pub sequence_for_custom_recovery_triggers: Option<SequenceDefinition>,
    pub skip_to_next_target_for_triggers: Arc<AtomicBool>,
    pub skip_to_node_for_recovery: Arc<StdRwLock<Option<NodeId>>>,
    pub state_clone: Arc<RwLock<ExecutorState>>,
    pub transparency_backup_for_recovery:
        Arc<RwLock<Option<crate::node::context::TransparencyBackupPlan>>>,
    pub trigger_action_context: TriggerActionContext,
    pub trigger_action_in_flight_for_triggers: Arc<AtomicBool>,
    pub trigger_manager: Arc<RwLock<TriggerManager>>,
    pub triggers_enabled: bool,
}

pub(super) async fn run_trigger_monitor_poll_loop(
    args: TriggerMonitorArgs,
) -> Vec<(String, RecoveryAction)> {
    let TriggerMonitorArgs {
        active_run_id_for_decisions,
        cloud_motion_for_recovery,
        custom_recovery_branches_for_triggers,
        custom_recovery_context_for_triggers,
        decision_tx_for_lifecycle,
        device_ops_for_triggers,
        event_tx_clone2,
        mut execution_quiesced_for_triggers,
        heartbeat_tx,
        is_cancelled_clone,
        is_paused_for_triggers,
        meridian_flip_failed_for_triggers,
        meridian_flip_failure_for_triggers,
        park_and_abort_done_for_triggers,
        park_and_abort_for_triggers,
        progress_for_triggers,
        recovery_request_tx,
        runtime_config,
        sequence_for_custom_recovery_triggers,
        skip_to_next_target_for_triggers,
        skip_to_node_for_recovery,
        state_clone,
        transparency_backup_for_recovery,
        trigger_action_context,
        trigger_action_in_flight_for_triggers,
        trigger_manager,
        triggers_enabled,
    } = args;
    if !triggers_enabled {
        // Hold this task open so the `try_join!` below still waits on the
        // other branches; an immediate return would short-circuit them.
        std::future::pending::<()>().await;
        return Vec::new();
    }

    let explicit_end = sequence_for_custom_recovery_triggers
        .as_ref()
        .is_some_and(super::explicit_end::owns_dawn_end);

    let mut check_interval = tokio::time::interval(std::time::Duration::from_secs(1));
    let mut fired_triggers: Vec<(String, RecoveryAction)> = Vec::new();

    // Tracks whether the previous safety poll already failed. Used to
    // rate-limit the per-mode warning so a permanently offline safety
    // device does not flood the log every second. See SafetyFailMode
    // dispatch below.
    let mut safety_poll_last_was_error = false;
    let mut last_safety_poll_at: Option<std::time::Instant> = None;
    let mount_poll_interval = std::time::Duration::from_secs(MOUNT_POLL_INTERVAL_SECS);
    let mut last_mount_poll_at: Option<std::time::Instant> = None;
    let mut heartbeat: u64 = 0;

    // Subsystem 2 step 3 (stale-verdict observability): rate-limit
    // latch for the "weather verdict feed stale; holding paused
    // fail-closed" warning. Set true after we emit the warning so a
    // dead Dart feed does not flood the event stream every poll;
    // cleared the moment a fresh verdict push lands (detected via
    // the verdict-staleness predicate returning false again).
    let mut verdict_stale_warned = false;

    // Rate-limit sentinel for the
    // "AltitudeLimit cannot evaluate because location is not
    // configured" warning. Set once per session on first
    // detection so the log is not flooded by a permanently
    // unconfigured rig.
    let mut altitude_warned_no_location = false;

    // Tracks per-trigger Retry attempt counts so we can escalate after
    // exhausting `max_attempts`. Keyed by trigger ID.
    let mut retry_attempts: HashMap<String, u32> = HashMap::new();

    // When each notify-only trigger last fired, so a condition that keeps
    // holding is told once. Keyed by trigger ID. See `notify_episode_gap`.
    let mut notify_episodes: HashMap<String, std::time::Instant> = HashMap::new();

    // Whether the operator has been told about the current run of DriftLimit
    // recenters that could not solve; a recenter that succeeds ends the run.
    let mut recenter_failure_told = false;

    // Streaming-checkpoint cadence belongs to an independent task spawned
    // alongside this monitor (see streaming_checkpoint_task), so checkpoint
    // saves keep running while triggers_enabled = false.

    // The MountTrackingLost / OnTrackingLimitHit baseline
    // (`mount_tracking_expected`) is armed lazily in the poll block
    // below — only once the mount is OBSERVED tracking — rather than
    // assumed here at startup, so a not-yet-tracking mount cannot
    // self-cancel the sequence. See mount_tracking_poll_verdict.

    loop {
        check_interval.tick().await;

        // Proof of life for the stall watchdog. Beat before the
        // state gate so a paused run still reports a live monitor.
        heartbeat = heartbeat.wrapping_add(1);
        let _ = heartbeat_tx.send(heartbeat);

        // A PAUSED run still has a telescope under the open sky.
        //
        // This gate used to `continue` on every non-`Running` state, which meant
        // a pause switched off weather, dawn, altitude and dome-shutter
        // evaluation for as long as it lasted. That is why the recovery
        // escalation refused to leave a run paused and parked the mount
        // instead — it was choosing between two defects. So: while Paused the
        // monitor keeps polling and keeps evaluating, but only safety-class
        // triggers may act (see `is_safety_class_trigger`), and only by
        // parking (see `may_act_during_hold`); an autofocus, dither, flip,
        // recentre or recovery ladder must never drive hardware under a hold a
        // human placed to inspect the rig, nor lift it.
        //
        // `Recovering` is held the same way. It used to be skipped on the
        // grounds that the recovery driver owns the hardware for its ladder,
        // but that ladder runs for up to 90 minutes, and a lost guide star is
        // most often cloud: rain arriving mid-ladder went unwatched, with no
        // weather, dawn or shutter evaluation at all. Only a park-and-abort may
        // act there, which ends the ladder with the run. Stopping / Failed /
        // Completed / Idle are skipped as before — nothing there to protect or
        // to conflict with.
        let current_state = *state_clone.read().await;
        let paused_safety_only = match current_state {
            ExecutorState::Running => false,
            ExecutorState::Paused | ExecutorState::Recovering => true,
            _ => continue,
        };

        if is_cancelled_clone.load(Ordering::Relaxed) {
            break;
        }

        let (current_safety_fail_mode, safety_check_interval, verdict_staleness_secs) = {
            let rc = runtime_config.read();
            (
                rc.safety_fail_mode,
                std::time::Duration::from_secs(effective_safety_check_interval_secs(
                    rc.safety_check_interval_secs,
                )),
                effective_weather_verdict_staleness_secs(rc.weather_verdict_staleness_secs),
            )
        };
        let should_poll_safety = last_safety_poll_at
            .map(|last| last.elapsed() >= safety_check_interval)
            .unwrap_or(true);

        // Poll weather/safety status and update trigger state. Each
        // SafetyFailMode variant has a distinct, observable behaviour:
        // - FailClosed: poll errors mark the run unsafe so WeatherUnsafe
        //   fires the configured park-and-abort path. Recommended for
        //   unattended runs.
        // - FailOpen: poll errors are treated as safe so the sequence
        //   keeps running. Intended for daytime / shutdown sequences
        //   where the safety device is intentionally unavailable. The
        //   warning is rate-limited (only once per error transition) so
        //   logs do not flood when the device is permanently offline.
        // - WarnOnly: poll errors do NOT change weather_safe (last good
        //   reading wins), but a one-shot Error event is emitted so the
        //   UI can alert the operator. Existing safe/unsafe state is
        //   preserved.
        let is_safe = if should_poll_safety {
            last_safety_poll_at = Some(std::time::Instant::now());
            match bounded_poll(
                "safety_is_safe",
                device_ops_for_triggers.safety_is_safe(None),
            )
            .await
            {
                Ok(safe) => {
                    if safety_poll_last_was_error {
                        tracing::info!(
                            "Safety poll recovered (mode: {:?})",
                            current_safety_fail_mode
                        );
                        safety_poll_last_was_error = false;
                    }
                    Some(safe)
                }
                Err(e) => {
                    // Cross-language parity (architecture-unification
                    // 2026-06-05): the fail-mode → no-data resolution is
                    // the SINGLE shared truth table in
                    // `crate::safety_fail_mode_no_data_resolution`, mirrored
                    // by the Dart `noDataFailModeResolution`. Do NOT inline a
                    // per-mode match here — it would let the two sides drift.
                    match safety_fail_mode_no_data_resolution(current_safety_fail_mode) {
                        NoDataResolution::Unsafe => {
                            if !safety_poll_last_was_error {
                                tracing::warn!(
                                    "Safety poll error: {} - treating as unsafe (FailClosed)",
                                    e
                                );
                                safety_poll_last_was_error = true;
                            }
                            Some(false)
                        }
                        NoDataResolution::Safe => {
                            if !safety_poll_last_was_error {
                                tracing::warn!(
                                    "Safety poll error: {} - treating as safe (FailOpen). \
                         Sequence will continue. Do not use FailOpen for \
                         unattended runs.",
                                    e
                                );
                                safety_poll_last_was_error = true;
                            }
                            Some(true)
                        }
                        NoDataResolution::Preserve => {
                            if !safety_poll_last_was_error {
                                tracing::warn!(
                                    "Safety poll error: {} - WarnOnly mode, leaving \
                         weather_safe unchanged and emitting alert",
                                    e
                                );
                                let _ = event_tx_clone2.send(ExecutorEvent::Error {
                                    message: format!(
                                        "Safety poll failed: {}. WarnOnly mode keeps the \
                             previous safety state — operator attention required.",
                                        e
                                    ),
                                });
                                safety_poll_last_was_error = true;
                            }
                            None
                        }
                    }
                }
            }
        } else {
            None
        };

        // One guider poll per tick serves both consumers: the RMS
        // the GuidingFailed trigger evaluates, and the is_guiding
        // latch GuideStarLost keys off. One poll means one error
        // policy for one failure, and the fail-closed one wins
        // (see the guide-star block below).
        let guide_status = bounded_poll(
            "guider_get_status",
            device_ops_for_triggers.guider_get_status(),
        )
        .await;
        let guiding_rms = guide_status
            .as_ref()
            .ok()
            .filter(|status| status.is_guiding)
            .map(|status| status.rms_total);

        // Poll humidity from the weather/safety
        // device on the same cadence as safety_is_safe. The
        // default `weather_get_humidity` implementation returns
        // Ok(None) for backends that don't expose humidity —
        // those silently leave `state.current_humidity` alone
        // (which is correct: HumidityThreshold can't evaluate
        // without data).
        let humidity_result = if should_poll_safety {
            Some(
                bounded_poll(
                    "weather_get_humidity",
                    device_ops_for_triggers.weather_get_humidity(None),
                )
                .await,
            )
        } else {
            None
        };

        // Subsystem 2 step 3 (stale-verdict observability): evaluated
        // on EVERY loop tick (not gated by should_poll_safety) so a
        // verdict that goes stale between safety polls is detected
        // promptly. Pure read; never mutates or clears the verdict.
        let verdict_stale_unsafe;

        {
            let manager = trigger_manager.read().await;
            let trigger_state = manager.state();
            let mut state = trigger_state.write().await;
            // WarnOnly returns None to mean "preserve previous reading" — that
            // is the contract that distinguishes it from FailOpen/FailClosed.
            if let Some(safe) = is_safe {
                state.weather_safe = safe;
            }

            verdict_stale_unsafe = state.is_weather_verdict_stale_unsafe(verdict_staleness_secs);

            // Only guiding this run started is judged, and only while it is
            // guiding. PHD2 keeps reporting the RMS of its last guiding after
            // it drops to looping, and a guider that lost its star and was
            // given up on reports whatever RMS it last had; judging either
            // would have the guiding triggers act on a guider that is not
            // guiding. A move the run is making is not guiding either.
            let judge_rms =
                state.guiding_enabled && !state.imaging_unguided && state.mount_motion_depth == 0;
            if let Some(rms) = guiding_rms.filter(|_| judge_rms) {
                state.update_guiding_rms(rms);
                tracing::trace!("Updated guiding RMS: {:.2}", rms);
            }

            // Feed humidity into trigger state.
            // We deliberately separate "device doesn't report
            // humidity" (Ok(None)) from "query failed" (Err) so
            // a transient driver glitch leaves the previous
            // reading in place rather than overwriting it with
            // garbage. Match the safety-poll rate-limited
            // logging policy.
            match humidity_result {
                Some(Ok(Some(h))) => {
                    state.update_humidity(h);
                    tracing::trace!("Updated humidity from weather device: {:.1}%", h);
                }
                Some(Ok(None)) => {
                    // Device exists but doesn't expose humidity.
                    // Nothing to do — HumidityThreshold needs a
                    // real value to evaluate. Trace level only:
                    // logging every tick would flood the log.
                }
                Some(Err(e)) => {
                    tracing::trace!("weather_get_humidity error: {} (trigger state retained)", e);
                }
                None => {}
            }

            // Seed observer location from device_ops the first time it
            // becomes available (mobile rigs configure it after mount
            // connect) so altitude/dawn triggers can evaluate.
            if state.observer_latitude.is_none() {
                if let Some((lat, lon)) = device_ops_for_triggers.get_observer_location() {
                    state.observer_latitude = Some(lat);
                    state.observer_longitude = Some(lon);
                    tracing::debug!(
                        "Observer location set for dawn/altitude triggers: {}, {}",
                        lat,
                        lon
                    );
                }
            }

            // Compute (or refresh) dawn_time whenever a location is known
            // but there is no valid UPCOMING dawn cached. The
            // UpdateLocation command sets `observer_latitude` directly, so
            // keying the computation off the `is_none()` branch above would
            // leave dawn_time None on a normally-configured rig and the
            // DawnApproaching trigger could never fire. `calculate_dawn_time`
            // returns the NEXT dawn, so recomputing once the cached value has
            // passed keeps the protection alive on a multi-night run.
            if let (Some(lat), Some(lon)) = (state.observer_latitude, state.observer_longitude) {
                let now = chrono::Utc::now().timestamp();
                let needs_refresh = match state.dawn_time {
                    None => true,
                    Some(t) => t <= now,
                };
                if needs_refresh {
                    let new_dawn = crate::triggers::calculate_dawn_time(lat, lon);
                    state.dawn_time = Some(new_dawn);
                    tracing::debug!(
                        "dawn_time computed for ({}, {}): {} (next astronomical twilight)",
                        lat,
                        lon,
                        new_dawn
                    );
                }
            }

            // Compute where the active TARGET is, so the
            // AltitudeLimit and MeridianFlip triggers have
            // something to evaluate. Inputs: target RA/Dec (set
            // when a TargetHeader node enters), observer lat/lon
            // (seeded above or by UpdateLocation), and current
            // UTC time.
            //
            // Three "can't evaluate" cases:
            //   1. No target set yet (sequence hasn't entered
            //      any TargetHeader node).
            //   2. No observer location (user has not
            //      configured the profile; UpdateLocation
            //      hasn't fired).
            //   3. Both — same outcome.
            //
            // For case (2), emit a one-shot warning so the
            // operator sees that these triggers are dead until
            // location is supplied. The `&&` guard makes it
            // impossible to fire on (1) alone (no point warning
            // before any target has been entered).
            match target_sky_state(
                state.target_ra,
                state.target_dec,
                state.observer_latitude,
                state.observer_longitude,
                chrono::Utc::now(),
            ) {
                Some(sky) => {
                    state.current_altitude = Some(sky.altitude_degrees);
                    state.update_hour_angle(sky.hour_angle_hours);
                    tracing::trace!(
                        "Computed target sky state: altitude {:.2}°, hour angle {:+.4}h",
                        sky.altitude_degrees,
                        sky.hour_angle_hours
                    );
                }
                None => {
                    // Nothing to compute from. Drop whatever was
                    // published before rather than let the altitude
                    // and meridian triggers keep evaluating it: a
                    // checkpoint resume restores both values, and a
                    // number computed for another target at another
                    // hour is exactly the input this loop exists to
                    // stop feeding them.
                    state.current_altitude = None;
                    state.current_hour_angle = None;

                    // A target with no location is worth saying out
                    // loud — altitude and meridian protection are
                    // then INACTIVE, which is a user-visible
                    // ExecutorEvent::Warning rather than a log line.
                    // A WARNING, not an error: the run proceeds and
                    // normally finishes; it is protection that is
                    // missing, not the sequence. Sent as `Error` it
                    // produced a red "Critical - Sequencer" toast, a
                    // "Sequence failed / Sequence aborted" toast and
                    // push, and pushed a healthy run into `recovering`
                    // 0.1 s after Start.
                    // Gated by a one-shot sentinel so a permanently
                    // unconfigured location does not flood the event
                    // stream every second. No target at all is
                    // silent: that is the ordinary "wait for a
                    // TargetHeader" state.
                    if state.target_ra.is_some()
                        && state.target_dec.is_some()
                        && !altitude_warned_no_location
                    {
                        let msg = "AltitudeLimit and meridian-flip triggers need \
                             an observing site, but observer location is not set \
                             — altitude and meridian-flip protection are \
                             INACTIVE. Set location in Profile to enable.";
                        tracing::warn!("{}", msg);
                        let _ = event_tx_clone2.send(ExecutorEvent::Warning {
                            message: msg.to_string(),
                        });
                        altitude_warned_no_location = true;
                    }
                }
            }
        }

        // Subsystem 2 step 3 (stale-verdict observability): a pushed
        // Some(true)=UNSAFE verdict whose Dart feed has gone silent
        // is HELD fail-closed — the sequence stays paused, which is
        // the correct safe behaviour and is NOT cleared here. But an
        // indefinite hold must not be SILENT: when the unsafe verdict
        // is stale we emit ONE loud warning (rate-limited via the
        // latch) so the operator knows the hold is sustained by a dead
        // feed rather than fresh data. The latch clears as soon as a
        // fresh push lands (predicate returns false again), so a feed
        // that recovers and re-degrades will warn again. The gate +
        // rate-limit + message live in `weather_verdict_stale_warning`
        // so they are unit-tested without the full executor task.
        if let Some(msg) = weather_verdict_stale_warning(
            verdict_stale_unsafe,
            verdict_staleness_secs,
            &mut verdict_stale_warned,
        ) {
            tracing::warn!("{}", msg);
            let _ = event_tx_clone2.send(ExecutorEvent::Error { message: msg });
        }

        let should_poll_mount = last_mount_poll_at
            .map(|last| last.elapsed() >= mount_poll_interval)
            .unwrap_or(true);

        if let (Some(mount_id), true) = (&trigger_action_context.mount_id, should_poll_mount) {
            last_mount_poll_at = Some(std::time::Instant::now());
            let tracking_result = bounded_poll(
                "mount_is_tracking",
                device_ops_for_triggers.mount_is_tracking(mount_id),
            )
            .await;
            let slewing_result = bounded_poll(
                "mount_is_slewing",
                device_ops_for_triggers.mount_is_slewing(mount_id),
            )
            .await;
            let parked_result = bounded_poll(
                "mount_is_parked",
                device_ops_for_triggers.mount_is_parked(mount_id),
            )
            .await;
            let pier_side_result = bounded_poll(
                "mount_side_of_pier",
                device_ops_for_triggers.mount_side_of_pier(mount_id),
            )
            .await;

            let manager = trigger_manager.read().await;
            let trigger_state = manager.state();
            let mut state = trigger_state.write().await;

            // A failed tracking query is treated as a connection problem
            // rather than "tracking dropped" so we don't park-and-abort
            // on a transient driver glitch — actual loss is reported as
            // Ok(false), which the branch below handles distinctly.
            match &tracking_result {
                // Under a hold the tracking-loss edge is left for the first
                // poll after the operator resumes. Nothing may act on it here
                // (see `may_act_during_hold`), and taking the reading now
                // would consume the edge: the latch clears on the next poll,
                // so a run resumed on a mount the operator left untracked
                // would expose with nothing restoring tracking.
                Ok(_) if paused_safety_only => {
                    state.mount_status_query_failed = false;
                }
                Ok(is_tracking) => {
                    state.mount_status_query_failed = false;

                    // Lazily arm the "tracking expected" baseline on the
                    // first observed Ok(true) and edge-detect a genuine
                    // true → false loss against it. `state.mount_is_tracking`
                    // still holds the PREVIOUS poll's reading here — it is
                    // updated below, after this check.
                    let (mount_tracking_expected, tracking_just_lost) = mount_tracking_poll_verdict(
                        state.mount_tracking_expected,
                        *is_tracking,
                        state.mount_is_tracking,
                        state.mount_tracking_lost,
                    );
                    state.set_mount_tracking_expected(mount_tracking_expected);
                    if tracking_just_lost {
                        tracing::warn!("Mount tracking lost during sequence!");
                        state.mount_tracking_lost = true;

                        // OnTrackingLimitHit waits `tracking_limit_wait_minutes`
                        // before flipping; we stamp the detection time here so
                        // the wait period is measured from when the loss was
                        // first observed, not from when the trigger eventually
                        // evaluates (which happens on its own cadence).
                        if state.tracking_limit_detected_at.is_none() {
                            state.tracking_limit_detected_at = Some(chrono::Utc::now().timestamp());
                            tracing::info!("Tracking limit detection timestamp recorded");
                        }
                    }
                    // Tracking resumed before the wait elapsed — clear the
                    // detection timestamp so a future loss starts the wait
                    // window fresh instead of inheriting stale state.
                    if *is_tracking && state.tracking_limit_detected_at.is_some() {
                        tracing::info!("Mount tracking resumed, cancelling tracking limit wait");
                        state.reset_tracking_limit_detection();
                    }

                    state.mount_is_tracking = Some(*is_tracking);
                }
                Err(e) => {
                    tracing::warn!(
                        "Mount status query failed: {} - possible connection loss",
                        e
                    );
                    state.mount_status_query_failed = true;
                }
            }

            if let Ok(slewing) = slewing_result {
                state.mount_slewing = Some(slewing);
            }
            if let Ok(parked) = parked_result {
                state.mount_parked = Some(parked);
            }

            // Two PierSide enums exist: meridian::PierSide is the
            // internal calculation type, crate::PierSide is the
            // event-stream wire format. They mirror each other but
            // are distinct types so the geometry code cannot leak
            // into FRB-exposed events.
            if let Ok(pier_side) = pier_side_result {
                let ps = match pier_side {
                    crate::meridian::PierSide::East => crate::PierSide::East,
                    crate::meridian::PierSide::West => crate::PierSide::West,
                    crate::meridian::PierSide::Unknown => crate::PierSide::Unknown,
                };
                state.update_pier_side(ps);
            }

            // The mount is NOT asked for its coordinates here. The hour angle
            // every MeridianFlip method evaluates is the TARGET's (computed
            // above, once per tick, from the target's own RA) — recomputing it
            // from `mount_get_coordinates` asked a different question and
            // answered it with whatever the mount was pointing at, including
            // its parked home position before the run's first slew. See
            // `monitoring::target_sky_state`.
        }

        // TemperatureShift refocus must key off a temperature
        // that actually tracks the optical train's thermal
        // expansion — i.e. the FOCUSER temperature probe (or an
        // ambient sensor). The cooled-CAMERA sensor temperature
        // is regulated to a fixed setpoint, so it never drifts;
        // feeding it here meant the trigger could never fire and
        // focus drifted soft over a full night. We now read the
        // focuser's temperature probe. `Ok(None)` means the
        // focuser has no probe — we deliberately do NOT fall back
        // to the regulated camera temperature (that would
        // resurrect the silent no-fire bug); the trigger simply
        // stays inert, which is the honest "no temperature source
        // available" outcome.
        //
        // Polled on the safety cadence rather than every tick: the
        // optical train's temperature moves on minute timescales and
        // the TemperatureShift threshold is in whole degrees, so a
        // 1 Hz probe read bought nothing and cost a driver round-trip
        // a second.
        if let (Some(focuser_id), true) = (&trigger_action_context.focuser_id, should_poll_safety) {
            match bounded_poll(
                "focuser_get_temperature",
                device_ops_for_triggers.focuser_get_temperature(focuser_id),
            )
            .await
            {
                Ok(Some(temp)) => {
                    let manager = trigger_manager.read().await;
                    let trigger_state = manager.state();
                    let mut state = trigger_state.write().await;
                    state.update_temperature(temp);
                    tracing::trace!("Updated focuser temperature: {:.1}°C", temp);
                }
                Ok(None) => {
                    tracing::trace!(
                        "Focuser '{}' reports no temperature probe; \
                         TemperatureShift trigger remains inert (no fallback \
                         to regulated camera temperature)",
                        focuser_id
                    );
                }
                Err(e) => {
                    tracing::warn!(
                        "Focuser temperature query failed: {} - leaving \
                         TemperatureShift trigger state unchanged",
                        e
                    );
                }
            }
        }

        // The shutter shares the safety cadence, which is the cadence
        // every other "is the rig still safe to expose" question is
        // asked on.
        if let (Some(dome_id), true) = (&trigger_action_context.dome_id, should_poll_safety) {
            if let Ok(status) = bounded_poll(
                "dome_get_shutter_status",
                device_ops_for_triggers.dome_get_shutter_status(dome_id),
            )
            .await
            {
                let manager = trigger_manager.read().await;
                let trigger_state = manager.state();
                let mut state = trigger_state.write().await;
                state.update_dome_status(status.clone());
                if status != "Open" && state.dome_shutter_open_expected {
                    tracing::warn!("Dome shutter not open during sequence: {}", status);
                }
            }
        }

        // GuideStarLost cannot be derived from RMS alone (a settled guider
        // can report low RMS for one cycle before noticing the star is gone),
        // so the same poll's `is_guiding` gives the trigger a definitive
        // signal independent of the RMS path above.
        {
            let manager = trigger_manager.read().await;
            let trigger_state = manager.state();
            let mut tstate = trigger_state.write().await;
            match guide_status {
                // The run is moving the mount itself (slew, center, sync,
                // flip): the guide star leaving the guide frame is what a move
                // does, not a lost star.
                _ if tstate.mount_motion_depth > 0 => {
                    tstate.set_guide_star_lost(false);
                }
                Ok(status) => {
                    if status.is_guiding {
                        // A guider seen guiding does NOT arm the star-lost
                        // trigger by itself: only guiding this run started
                        // does (see `set_guiding_enabled`). A guider left
                        // guiding by the previous run or by the operator armed
                        // it here, and the first slew then "lost" that star.
                        tstate.set_guide_star_lost(false);
                        // The run went on unguided after the guide-star
                        // recovery ran out; the guider is guiding again (the
                        // operator restarted it, or it found a star), so the
                        // steps that need it get it back, and this run's
                        // guiding is armed again.
                        if std::mem::take(&mut tstate.imaging_unguided) {
                            tstate.set_guiding_enabled(true);
                            tracing::info!(
                                "[GUIDING] The guider is guiding again; dithers and guiding \
                                 checks resume"
                            );
                        }
                    } else if tstate.guiding_enabled {
                        // Guiding was active and is now not -> star lost.
                        tstate.set_guide_star_lost(true);
                    } else {
                        // Idle guider before any guiding has started: not lost.
                        tstate.set_guide_star_lost(false);
                    }
                }
                Err(_) => {
                    // If we can't reach the guider, treat as lost when guiding expected
                    if tstate.guiding_enabled {
                        tstate.set_guide_star_lost(true);
                    }
                }
            }
        }

        // Recovery actions below take their own write locks on trigger_state;
        // holding the trigger_manager lock during them would deadlock the
        // trigger evaluators that share the same Arc. Snapshot the fired
        // triggers into an owned Vec and drop the lock before dispatching.
        let park_policy = runtime_config.read().park_policy;
        let fired_with_names: Vec<(String, String, FiredTriggerAction, Option<u64>)> = {
            let mut manager = trigger_manager.write().await;
            let mut dropped_under_hold: Vec<String> = Vec::new();
            let fired = manager.check_all().await;
            let stop_on_quality_problems = manager.state().read().await.stop_on_quality_problems;
            let fired_with_names: Vec<_> = fired
                .into_iter()
                .filter(|(id, _)| !(explicit_end && id == "dawn_approaching"))
                // The operator's park and quality settings first, so the hold
                // filter below judges what the trigger will actually do.
                .map(|(trigger_id, action)| {
                    let fired = apply_quality_policy(
                        &trigger_id,
                        apply_park_policy(&trigger_id, action, park_policy),
                        stop_on_quality_problems,
                    );
                    (trigger_id, fired)
                })
                // While paused, drop everything that is not protecting the rig
                // itself. Filtering here rather than inside the dispatch keeps
                // the guarantee in one readable place.
                //
                // A dropped firing is re-armed below. `Trigger::check` starts
                // the cooldown whenever it returns true, so a firing nobody
                // acted on used to spend it: on the rig (2026-10-21) the flip
                // fired at 05:31:57 and 05:41:58 under an operator pause, the
                // run resumed at 05:47:34 with the flip still cooling down
                // until 05:51:57, the next frame went ahead, and the night
                // lost its flip. Re-armed, the trigger fires on the first
                // running tick after the hold, as if the hold had not been
                // there. `was_firing` stays set across the hold, so a trigger
                // that keeps firing under it is still logged once.
                .filter(|(trigger_id, fired)| {
                    if !paused_safety_only {
                        return true;
                    }
                    match manager.get_trigger(trigger_id) {
                        Some(trigger) => {
                            let allowed = is_safety_class_trigger(&trigger.trigger_type)
                                && may_act_during_hold(&fired.action);
                            if !allowed {
                                tracing::debug!(
                                    "Trigger '{}' fired while the run is paused; it is not a \
                                     safety-class trigger with a protective action, so it is \
                                     not acted on until the run resumes",
                                    trigger_id
                                );
                                dropped_under_hold.push(trigger_id.clone());
                            }
                            allowed
                        }
                        // A trigger that fired and was removed in the same tick
                        // cannot be classified, and an unclassifiable trigger
                        // must not drive hardware under a hold.
                        None => false,
                    }
                })
                .map(|(trigger_id, fired)| {
                    let trigger = manager.get_trigger(&trigger_id);
                    let trigger_name = trigger
                        .map(|t| t.name.clone())
                        // Why: `get_trigger` returns Option;
                        // None would only occur if a trigger fired and was
                        // simultaneously removed via the same manager — race
                        // tolerated for diagnostic naming. Using the id as the
                        // display name preserves traceability.
                        .unwrap_or_else(|| trigger_id.clone());
                    let cooldown_secs = trigger.and_then(|t| t.cooldown_secs);
                    (trigger_id, trigger_name, fired, cooldown_secs)
                })
                .collect();
            for trigger_id in &dropped_under_hold {
                manager.rearm_after_hold(trigger_id);
            }
            fired_with_names
        };

        let trigger_state_for_actions = {
            let manager = trigger_manager.read().await;
            manager.state()
        };

        // Tell the pre-frame meridian gate what this tick decided: whether the
        // triggers had a running evaluation, and whether a flip is now on its
        // way. A frame that starts after a hold must not race the flip the
        // first running tick fires (see `wait_for_meridian_flip_window`).
        {
            let flip_dispatching = fired_with_names.iter().any(|(_, _, fired, _)| {
                !fired.notify_only
                    && !fired.end_without_parking
                    && matches!(fired.action, RecoveryAction::MeridianFlip(_))
            });
            let mut state = trigger_state_for_actions.write().await;
            state.last_evaluation_running = Some(!paused_safety_only);
            state.meridian_flip_dispatch_pending = flip_dispatching;
        }

        for (trigger_id, trigger_name, fired, cooldown_secs) in fired_with_names {
            // A notify-only trigger tells the operator once per episode: a
            // firing that follows the last one within the trigger's cooldown
            // plus a margin is the same condition still holding, and says
            // nothing new.
            if fired.notify_only {
                let now = std::time::Instant::now();
                let same_episode = notify_episodes.get(&trigger_id).is_some_and(|last| {
                    now.duration_since(*last) < notify_episode_gap(cooldown_secs)
                });
                notify_episodes.insert(trigger_id.clone(), now);
                if same_episode {
                    tracing::debug!(
                        "Trigger '{}' still firing; the operator was already told",
                        trigger_name
                    );
                    continue;
                }
            }
            let action_str = fired.wire_label();
            let FiredTriggerAction {
                action,
                end_without_parking,
                notify_only,
            } = fired;

            tracing::warn!(
                "Trigger fired: {} ({}) - action: {:?}",
                trigger_name,
                trigger_id,
                action
            );

            let _ = event_tx_clone2.send(ExecutorEvent::TriggerFired {
                trigger_id: trigger_id.clone(),
                trigger_name: trigger_name.clone(),
                action: action_str.clone(),
            });

            // Replay Debug — capture the trigger
            // firing as a structured decision so the
            // replay timeline surfaces "HFR drift fired,
            // ran Autofocus" without needing to join
            // event log + trigger config.
            {
                let decision_event = crate::decision::DecisionEvent::new(
                    crate::decision::DecisionCategory::TriggerFired,
                    format!("Trigger {} fired → {}", trigger_name, action_str),
                    serde_json::json!({
                        "trigger_id": trigger_id,
                        "trigger_name": trigger_name,
                        "action": action_str,
                    }),
                );
                let mut stamped = decision_event;
                stamped.sequence_run_id = *active_run_id_for_decisions.read();
                let _ = decision_tx_for_lifecycle.send(stamped);
            }

            // A notice drives nothing: no in-flight guard, no camera claim.
            if notify_only {
                let message = {
                    // Manager before state, the order every other path takes.
                    let manager = trigger_manager.read().await;
                    let state = trigger_state_for_actions.read().await;
                    quality_trigger_notice(&trigger_name, &trigger_id, &manager, &state)
                };
                tracing::warn!("{}", message);
                let _ = event_tx_clone2.send(ExecutorEvent::Warning { message });
                continue;
            }

            // Mark the whole action dispatch as in-flight. The
            // guard clears on drop so the many `return
            // terminate_with(...)` early exits below cannot
            // leak the flag and let the run resolve out from
            // under a sleeping meridian-flip retry ladder. See
            // `TriggerActionInFlightGuard`.
            let _action_in_flight =
                TriggerActionInFlightGuard::new(&trigger_action_in_flight_for_triggers);

            // Every trigger action that drives the camera takes
            // the capture loop's claim BEFORE it starts, not just
            // autofocus: a flip firing one millisecond into a 15 s
            // light restarts the same sensor for its plate solve,
            // and the burst then files the solve frame as that
            // light. See `camera_driving_trigger_action`.
            //
            // The claim is a GUARD, not a flag, because the
            // dispatch below exits three different ways (falling
            // out of the match, `continue`, and several `return
            // terminate_with(...)`), and a missed release blocks
            // every frame until the claim's ten-minute expiry. See
            // `TriggerCameraClaim`.
            let mut camera_claim = TriggerCameraClaim::acquire(
                &trigger_state_for_actions,
                &is_cancelled_clone,
                &action,
            )
            .await;

            match &action {
                RecoveryAction::Pause => {
                    // Recovery Mode — promote recovery-eligible Pause
                    // triggers to a visible recovery loop. The mapping lives in
                    // `trigger_recovery_cause` so the Retry arm below asks the
                    // same question and cannot drift from this one. Other Pause
                    // triggers (operator-defined custom watchdogs,
                    // FilterChange, etc.) keep the legacy "pause for operator"
                    // behaviour because they don't have an automatic retry
                    // semantic.
                    let recovery_cause = trigger_recovery_cause(&trigger_id);

                    if let Some(cause) = recovery_cause {
                        // Try to post a recovery request.
                        // The channel is bounded(4) so a
                        // back-pressure send means "we are
                        // already recovering or queued";
                        // we drop the duplicate trigger
                        // and log it. The driver task
                        // serialises recoveries by
                        // consuming one cause at a time.
                        match recovery_request_tx.try_send(cause.clone()) {
                            Ok(()) => {
                                tracing::info!(
                                    "[RECOVERY] Trigger '{}' promoted to recovery request ({:?})",
                                    trigger_name,
                                    cause
                                );
                            }
                            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                                tracing::warn!(
                                    "[RECOVERY] Recovery channel full; dropping duplicate request from '{}'",
                                    trigger_name
                                );
                            }
                            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                                // Driver task ended — fall
                                // back to the legacy Pause
                                // behaviour so the
                                // sequence still stops.
                                is_paused_for_triggers.store(true, Ordering::Relaxed);
                                *state_clone.write().await = ExecutorState::Paused;
                                // The status API is built from the progress snapshot, not from
                                // this lock. Stamping only the lock is what let a paused run
                                // keep reporting `running` — see mirror_paused_into_progress.
                                progress_for_triggers.write().state = ExecutorState::Paused;
                                let _ = event_tx_clone2
                                    .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                            }
                        }
                    } else {
                        // Legacy Pause path — same as the
                        // pre-Wave-4 implementation.
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                    }
                }
                RecoveryAction::ParkAndAbort if end_without_parking => {
                    // "Park before dawn" is off: end the run as the dawn rule
                    // does, and leave the mount, cover and dome as they are.
                    // The node tree is cancelled first so the exposure in
                    // flight is aborted rather than cut off.
                    cancel_and_wait_for_execution(
                        &is_cancelled_clone,
                        &mut execution_quiesced_for_triggers,
                    )
                    .await;
                    let message = format!(
                        "{trigger_name}: the run has ended. The mount was not parked and the \
                         cover and dome were not closed, because Park before dawn is off. \
                         The mount may still be tracking."
                    );
                    tracing::warn!("{}", message);
                    let _ = event_tx_clone2.send(ExecutorEvent::Error { message });
                    fired_triggers.push((trigger_id, action));
                    return terminate_with(
                        &is_cancelled_clone,
                        fired_triggers,
                        "Dawn Approaching without parking",
                    );
                }
                RecoveryAction::ParkAndAbort => {
                    // Stop node execution BEFORE moving or
                    // closing hardware. In particular, an
                    // exposure instruction observes the shared
                    // cancellation flag, aborts the camera
                    // integration, and only then lets the
                    // execution future report quiescence.
                    park_and_abort_for_triggers.store(true, Ordering::Release);
                    cancel_and_wait_for_execution(
                        &is_cancelled_clone,
                        &mut execution_quiesced_for_triggers,
                    )
                    .await;

                    // Guiding is independent device state, not
                    // owned by the exposure future. Quiesce it
                    // explicitly before parking the mount.
                    if let Err(error) = device_ops_for_triggers.guider_stop().await {
                        // An unguided rig has nothing to stop, so
                        // that is not a failure to report. Emitting
                        // it raised a CRITICAL "failed to stop
                        // guiding" toast next to the real abort
                        // reason on every unguided ParkAndAbort —
                        // observed live on a weather abort — which
                        // buries the cause the operator needs.
                        if crate::device_ops::is_no_guider_configured(&error) {
                            tracing::debug!("ParkAndAbort: no guider to stop ({})", error);
                        } else {
                            let msg = format!(
                                "ParkAndAbort: failed to stop guiding before parking: {}",
                                error
                            );
                            tracing::error!("{}", msg);
                            let _ = event_tx_clone2.send(ExecutorEvent::Error { message: msg });
                        }
                    }

                    // `device_ops::park_and_close_safe_state` is the
                    // single source of truth for the park → close
                    // cover → close dome sweep, shared with node.rs's
                    // Recovery::ParkAndAbort path; the retry count (1)
                    // and delay (2 s) are parameters so tuning them
                    // needs no call-site edit. The returned outcome
                    // drives the operator-facing error events.
                    if trigger_action_context.mount_id.is_some() {
                        tracing::warn!(
                            "ParkAndAbort: parking mount '{}' (max_retries=1, retry_delay=2s)",
                            trigger_action_context.mount_id.as_deref().unwrap_or("?")
                        );
                    } else {
                        tracing::warn!("ParkAndAbort: no mount configured, cannot park");
                    }
                    if let Some(cover_id) = &trigger_action_context.cover_calibrator_id {
                        tracing::warn!("ParkAndAbort: closing cover '{}'", cover_id);
                    }
                    if let Some(dome_id) = &trigger_action_context.dome_id {
                        tracing::warn!("ParkAndAbort: closing dome shutter '{}'", dome_id);
                    }

                    let safe_state = crate::device_ops::park_and_close_safe_state(
                        &device_ops_for_triggers,
                        trigger_action_context.mount_id.as_deref(),
                        trigger_action_context.cover_calibrator_id.as_deref(),
                        trigger_action_context.dome_id.as_deref(),
                        1,
                        2.0,
                    )
                    .await;

                    // Every step's verdict is LOGGED as well as broadcast. The
                    // event stream has no subscriber on a headless run, and
                    // `park_and_close_safe_state` only logs the park internally
                    // (via `try_park_with_retry`) — a failed cover or dome close
                    // used to leave no record anywhere, so an unattended weather
                    // abort could end with the scope under an open roof and a
                    // clean log. The give-up and escalation copies of this sweep
                    // already log first; this one now matches them.
                    match &safe_state.park {
                        Some(park_outcome) if !park_outcome.success => {
                            // Surface the park-specific failure
                            // in the event stream so the UI can
                            // distinguish "couldn't park, mount
                            // may be unsafe" from a generic
                            // ParkAndAbort termination.
                            let msg = format!(
                                "ParkAndAbort: mount park FAILED after {} attempt{}: {}. \
                                 Mount may be in an unsafe position — manual intervention required.",
                                park_outcome.attempts_made,
                                if park_outcome.attempts_made == 1 { "" } else { "s" },
                                park_outcome
                                    .last_error
                                    .clone()
                                    .unwrap_or_else(|| "unknown error".to_string()),
                            );
                            tracing::error!("{}", msg);
                            let _ = event_tx_clone2.send(ExecutorEvent::Error { message: msg });
                        }
                        None => {
                            let msg = "ParkAndAbort fired but no mount is configured; the rig cannot be parked automatically.".to_string();
                            tracing::error!("{}", msg);
                            let _ = event_tx_clone2.send(ExecutorEvent::Error { message: msg });
                        }
                        _ => {}
                    }

                    if let (Some(cover_id), Some(e)) = (
                        &trigger_action_context.cover_calibrator_id,
                        &safe_state.cover_close_error,
                    ) {
                        let msg = format!(
                            "ParkAndAbort: failed to close cover '{}': {}. \
                             Optics may be left exposed — manual intervention required.",
                            cover_id, e
                        );
                        tracing::error!("{}", msg);
                        let _ = event_tx_clone2.send(ExecutorEvent::Error { message: msg });
                    }
                    if let (Some(dome_id), Some(e)) = (
                        &trigger_action_context.dome_id,
                        &safe_state.dome_close_error,
                    ) {
                        let msg = format!(
                            "ParkAndAbort: failed to close dome '{}': {} — \
                             scope may be exposed under an open roof. Manual intervention required.",
                            dome_id, e
                        );
                        tracing::error!("{}", msg);
                        let _ = event_tx_clone2.send(ExecutorEvent::Error { message: msg });
                    }

                    let _ = park_and_abort_done_for_triggers.send(true);
                    fired_triggers.push((trigger_id, action));
                    return terminate_with(
                        &is_cancelled_clone,
                        fired_triggers,
                        "RecoveryAction::ParkAndAbort",
                    );
                }
                RecoveryAction::NextTarget => {
                    tracing::info!("Trigger requested advance to next target");
                    skip_to_next_target_for_triggers.store(true, Ordering::Relaxed);
                }
                RecoveryAction::Autofocus => {
                    // Autofocus drives the camera itself, so it
                    // must not start on top of a frame the
                    // capture loop is already exposing. It did:
                    // the autofocus began its own exposures
                    // 0.35 s after a 10 s light started, and the
                    // capture loop's download then failed with
                    // "No exposure is available to download",
                    // failing the exposure node and — through
                    // the sequential parent — the whole run, at
                    // frame 25 of every run.
                    //
                    // The claim is taken above the match now
                    // (`camera_driving_trigger_action`), so
                    // every camera-driving action inherits it
                    // rather than only this one, and
                    // `camera_claim` hands it back on whichever
                    // exit this arm takes.
                    tracing::info!("Executing autofocus as trigger recovery action");
                    match autofocus_trigger_skip_reason(
                        trigger_action_context.camera_id.as_ref(),
                        trigger_action_context.focuser_id.as_ref(),
                    ) {
                        None => {
                            let (target_name, target_ra, target_dec, current_filter) = {
                                let ts = trigger_state_for_actions.read().await;
                                (
                                    ts.current_target_name.clone(),
                                    ts.target_ra.map(|ra| ra / 15.0),
                                    ts.target_dec,
                                    ts.current_filter.clone(),
                                )
                            };

                            let af_ctx = build_trigger_autofocus_context(
                                &trigger_action_context,
                                target_name,
                                target_ra,
                                target_dec,
                                current_filter,
                                is_cancelled_clone.clone(),
                                device_ops_for_triggers.clone(),
                                trigger_state_for_actions.clone(),
                                &runtime_config,
                                Some(event_tx_clone2.clone()),
                            );

                            // Use the operator's real autofocus tuning
                            // (seeded at start() from the sequence's
                            // Autofocus node, or pushed via runtime
                            // config). Falling back to library defaults
                            // here would mean trigger-fired refocus
                            // ignores the user's step size / exposure /
                            // backlash — so warn loudly if that happens.
                            let af_config = {
                                match runtime_config.read().autofocus.clone() {
                                    Some(cfg) => cfg,
                                    None => {
                                        tracing::warn!(
                                            "Trigger autofocus running with LIBRARY DEFAULTS \
                                             (no Autofocus node / profile AF config available) — \
                                             focus quality may suffer on a non-default rig"
                                        );
                                        crate::AutofocusConfig::default()
                                    }
                                }
                            };
                            let progress_context = custom_recovery_context_for_triggers.clone();
                            let progress_node_id = format!("trigger:{trigger_id}:autofocus");
                            // Same synthetic id the progress
                            // closure below publishes under, so
                            // the terminal event names the node
                            // the sweep reported against.
                            let completed_node_id = progress_node_id.clone();
                            // Name the interlude before it starts
                            // reporting progress.
                            //
                            // A synthesised trigger node has no
                            // entry in the tree, so nothing emits
                            // the "Executing: <name>" lifecycle
                            // message the progress callback reads
                            // display names out of — and its
                            // fallback published the literal word
                            // "Unknown" as the current node for the
                            // whole sweep, on every surface, while
                            // the id beside it spelled out
                            // `trigger:hfr_degraded:autofocus`. The
                            // trigger knows exactly what this is, so
                            // it says so, in the same shape a tree
                            // node uses; "Unknown" stays reserved
                            // for work nobody can name.
                            progress_context.send_progress(ProgressUpdate::lifecycle(
                                progress_node_id.clone(),
                                NodeStatus::Running,
                                format!("Executing: Autofocus ({trigger_name})"),
                            ));
                            // Take the autofocus gate here rather than inside
                            // the sweep, so a refocus turned away by another
                            // autofocus (an Autofocus node dispatched on the
                            // same tick, a manual sweep, a backlash
                            // calibration) is told apart from one that ran and
                            // failed. It moved nothing and says nothing about
                            // focus; judged as a failure it once reached the old
                            // AbortAndPark failure action and parked the rig. The stale-focus
                            // latch is kept, so the trigger asks again once
                            // its cooldown has passed.
                            let Some(af_admission) = crate::instructions::try_admit_autofocus_run()
                            else {
                                camera_claim.release().await;
                                let message = format!(
                                    "Trigger '{trigger_name}' asked for an autofocus while another \
                                     autofocus held the camera and focuser. This refocus was \
                                     skipped; the trigger will ask again."
                                );
                                tracing::warn!("{}", message);
                                let _ = event_tx_clone2.send(ExecutorEvent::NodeCompleted {
                                    id: completed_node_id,
                                    status: NodeStatus::Skipped,
                                });
                                let _ = event_tx_clone2.send(ExecutorEvent::Warning { message });
                                fired_triggers.push((trigger_id, action));
                                continue;
                            };
                            let total_steps =
                                af_config.steps_out.saturating_mul(2).saturating_add(1);
                            let progress_fn = move |progress: f64, detail_str: String| {
                                let (step, hfr) = parse_autofocus_detail(&detail_str);
                                progress_context.send_progress(
                                    ProgressUpdate::instruction_progress(
                                        progress_node_id.clone(),
                                        "Autofocus",
                                        progress,
                                        ProgressDetail::Autofocus {
                                            step: step.unwrap_or(0),
                                            total_steps,
                                            current_hfr: hfr,
                                        },
                                    ),
                                );
                            };
                            // Recorded so the decision row can
                            // name the focus the run kept when
                            // the sweep does not converge.
                            let position_before_af = read_focuser_position(
                                &device_ops_for_triggers,
                                trigger_action_context.focuser_id.as_ref(),
                            )
                            .await;

                            let af_result = crate::instructions::execute_autofocus_admitted(
                                &af_config,
                                &af_ctx,
                                Some(&progress_fn),
                                af_admission,
                            )
                            .await;

                            // A sweep that left the guider dead is held
                            // below. Freeze the node tree BEFORE handing the
                            // camera back: the capture loop is waiting for the
                            // train past its pause check, and released first
                            // it started one more full unguided light in the
                            // gap while this arm was still judging the sweep.
                            if af_result.status == NodeStatus::Failure
                                && !is_cancelled_clone.load(Ordering::Relaxed)
                                && autofocus_trigger_failure_cost(af_result.data.as_ref())
                                    == AutofocusTriggerFailureCost::EveryFrameUnguided
                            {
                                is_paused_for_triggers.store(true, Ordering::Relaxed);
                            }

                            // Hand the camera back the moment the sweep
                            // is done — success or failure — so the
                            // capture loop resumes on its next frame
                            // instead of waiting for the release after
                            // the match.
                            camera_claim.release().await;

                            // Publish the sweep's verdict.
                            //
                            // A trigger-fired refocus streamed
                            // Autofocus progress under the
                            // synthetic node id above and then
                            // simply stopped: subscribers saw a
                            // sweep begin and never learned
                            // whether it worked, so a night of
                            // periodic refocusing left the run
                            // record showing none at all. The
                            // status is the sweep's own, so a
                            // cancelled sweep reports cancelled
                            // rather than being flattened to a
                            // failure.
                            let _ = event_tx_clone2.send(ExecutorEvent::NodeCompleted {
                                id: completed_node_id,
                                status: af_result.status,
                            });

                            if af_result.status == NodeStatus::Success {
                                if let Some(best_hfr) = af_result.hfr_values.first() {
                                    let mut ts = trigger_state_for_actions.write().await;
                                    ts.update_hfr(*best_hfr);
                                    ts.reset_baseline_hfr();
                                    ts.mark_autofocus_performed();
                                }
                            } else if af_result.status == NodeStatus::Cancelled
                                || is_cancelled_clone.load(Ordering::Relaxed)
                            {
                                // The run is being stopped. A sweep the stop
                                // cut short is not a failed autofocus, and
                                // judging it as one once sent an operator's
                                // Stop down the old AbortAndPark failure
                                // action: park the mount, close cover and dome.
                                tracing::info!(
                                    "Trigger autofocus '{}' ended by the run stopping; not \
                                     judging it as a failed refocus",
                                    trigger_name
                                );
                            } else {
                                // How the frames measure against the run's good
                                // HFR, for the operator's notice: slightly soft
                                // frames stack and deconvolve fine, frames past
                                // the tolerance need a look. The reference must
                                // be read BEFORE `reset_baseline_hfr` overwrites
                                // it with the degraded value.
                                let verdict = {
                                    let ts = trigger_state_for_actions.read().await;
                                    autofocus_failure_verdict(
                                        ts.baseline_hfr,
                                        ts.current_hfr,
                                        af_config.failure_hfr_tolerance_ratio,
                                    )
                                };

                                // Reset the HFR baseline to the current degraded
                                // value so the trigger doesn't keep firing with a stale
                                // baseline from before the failed autofocus attempt.
                                {
                                    let mut ts = trigger_state_for_actions.write().await;
                                    ts.reset_baseline_hfr();
                                    // The run carries on from here on every
                                    // path that does not end it, so the cadence
                                    // anchor has to advance too: the interval
                                    // trigger carries no time cooldown, and an
                                    // unmoved anchor re-fires the sweep that
                                    // just failed after every single frame.
                                    ts.mark_autofocus_attempted();
                                    tracing::warn!(
                                    "Autofocus failed — HFR baseline reset to current value ({:?}) \
                                     and the interval cadence anchor advanced so the failed sweep \
                                     does not re-fire on every subsequent frame",
                                    ts.baseline_hfr
                                );
                                }

                                // `autofocus_origin_restored` is absent (not
                                // `false`) when the run bailed before it ever
                                // moved the focuser — e.g. admission rejected
                                // because another autofocus held the equipment —
                                // so only an explicit `false` means the motor was
                                // left off its origin.
                                let origin_restored = af_result
                                    .data
                                    .as_ref()
                                    .and_then(|data| data.get("autofocus_origin_restored"))
                                    .and_then(|value| value.as_bool());
                                let position_after_af = read_focuser_position(
                                    &device_ops_for_triggers,
                                    trigger_action_context.focuser_id.as_ref(),
                                )
                                .await;
                                // Why: autofocus result's `message` is
                                // Option<String> — only populated when the focus
                                // pipeline reports a specific diagnostic. The
                                // generic fallback stands in when no specific
                                // signal came back; the failure itself is already
                                // encoded in the result's status.
                                let failure_cost =
                                    autofocus_trigger_failure_cost(af_result.data.as_ref());
                                let reason = af_result
                                    .message
                                    .unwrap_or_else(|| "autofocus did not converge".to_string());

                                if failure_cost == AutofocusTriggerFailureCost::EveryFrameUnguided {
                                    // The sweep stopped the guider and could not
                                    // prove it back. Continuing here is what cost
                                    // a clear night: three 180 s lights, every one
                                    // trailed past the grader's limit, zero
                                    // accepted. Halt semantics are an operator
                                    // PAUSE — the node tree freezes, the burst
                                    // loop's between-frame gate stops the next
                                    // exposure, and nothing is moved or closed.
                                    // Pausing is reversible by one button; parking
                                    // is not, and a dead guider is not evidence
                                    // about who is standing at the telescope.
                                    //
                                    // Safety-class triggers keep evaluating while
                                    // Paused (see `paused_safety_only` in the
                                    // monitor's state gate), so this hold is safe
                                    // to leave in place unattended without the
                                    // run parking on its own initiative.
                                    //
                                    // It is decided before the focus verdict, not
                                    // after: judged on HFR alone, a dead guider
                                    // with acceptable focus kept imaging unguided.
                                    let mut hold = autofocus_trigger_unguided_hold(
                                        &trigger_id,
                                        &trigger_name,
                                        &reason,
                                        position_after_af,
                                    );
                                    hold.decision.sequence_run_id =
                                        *active_run_id_for_decisions.read();
                                    let _ = decision_tx_for_lifecycle.send(hold.decision);
                                    tracing::error!("{}", hold.operator_message);

                                    // Drop the stale-focus latch so the trigger
                                    // does not re-fire the moment the operator
                                    // resumes and immediately re-stop the guider.
                                    {
                                        let mut ts = trigger_state_for_actions.write().await;
                                        ts.clear_autofocus_invalidation();
                                    }

                                    is_paused_for_triggers.store(true, Ordering::Relaxed);
                                    *state_clone.write().await = ExecutorState::Paused;
                                    // The status API reads the progress snapshot,
                                    // not this lock — stamping only the lock is
                                    // what let a paused run report `running`. See
                                    // mirror_paused_into_progress.
                                    {
                                        let mut prog = progress_for_triggers.write();
                                        prog.state = ExecutorState::Paused;
                                        prog.message = Some(
                                            "Paused: autofocus left the guider stopped".to_string(),
                                        );
                                    }
                                    let _ = event_tx_clone2
                                        .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                                    let _ = event_tx_clone2.send(ExecutorEvent::Error {
                                        message: hold.operator_message,
                                    });

                                    fired_triggers.push((trigger_id, action));
                                    continue;
                                }

                                // A failed autofocus never parks, closes or ends
                                // the run, however the frames measure (owner
                                // decision 2026-10-06: "Failed AF should never
                                // park the rig, just notify the user").
                                // `execute_autofocus` has already returned the
                                // focuser to its pre-sweep position; imaging
                                // carries on there and the operator is told. The
                                // decision row is what raises the app's
                                // "Autofocus failed — continuing" notification.
                                // The cause goes out as a Warning, not an Error:
                                // every sequencer Error is a "Sequence failed"
                                // notification, and this run has not failed.
                                let focus_note = match verdict {
                                    AutofocusOutcome::KeepImaging { .. } => format!(
                                        " {}, so frames will be slightly soft until focus is \
                                         retried.",
                                        verdict.describe()
                                    ),
                                    AutofocusOutcome::TooSoft { .. } => format!(
                                        " {}: frames may be soft enough to be rejected — check \
                                         focus.",
                                        verdict.describe()
                                    ),
                                    AutofocusOutcome::Unmeasurable => String::new(),
                                };
                                let mut continuation = autofocus_trigger_continuation(
                                    &trigger_id,
                                    &trigger_name,
                                    &reason,
                                    position_before_af,
                                    position_after_af,
                                    origin_restored,
                                );
                                continuation.decision.sequence_run_id =
                                    *active_run_id_for_decisions.read();
                                let _ = decision_tx_for_lifecycle.send(continuation.decision);
                                let message =
                                    format!("{}{}", continuation.operator_message, focus_note);
                                tracing::warn!("{}", message);
                                let _ = event_tx_clone2.send(ExecutorEvent::Warning { message });
                            }
                        }
                        Some(missing) => {
                            // No camera and/or no focuser: the autofocus
                            // action is not merely failing, it is
                            // IMPOSSIBLE, and a run cannot be held hostage
                            // by a recovery it can never perform — pausing
                            // here strands an unattended run at the next
                            // node boundary with no frames and no terminal
                            // event. Report the real missing device, drop
                            // the stale-focus latch so the trigger stops
                            // re-forcing on every evaluation tick, and let
                            // imaging continue. `start()` disarms these
                            // triggers up front when there is no focuser;
                            // this arm is the backstop for a device that
                            // disappears mid-run.
                            //
                            // This branch takes no exposures, so
                            // `camera_claim` must be released here or after
                            // the match: a missed release blocks the capture
                            // loop until the claim's ten-minute expiry.
                            tracing::warn!(
                                "Autofocus trigger '{}' fired but {} configured; \
                                 skipping the refocus and continuing the run",
                                trigger_name,
                                missing
                            );
                            {
                                let mut ts = trigger_state_for_actions.write().await;
                                ts.clear_autofocus_invalidation();
                            }
                            let _ = event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{trigger_name}' asked for an autofocus but {missing} \
                                     configured for this run. The refocus was skipped and imaging \
                                     continues — focus is not being corrected automatically."
                                ),
                            });
                        }
                    }
                }
                RecoveryAction::Retry { max_attempts } => {
                    // A trigger firing is not a failed node, so there is no
                    // operation for `Retry` to re-run here. What this arm used
                    // to do was increment a counter, log "requested retry
                    // attempt N/M", and let the run carry on exposing — so a
                    // trigger that fires precisely because a device has stopped
                    // working bought the run three more frames' worth of damage
                    // before anything happened. On the owner's 2026-09-14 run
                    // that was three 180 s lights, all rejected, while
                    // 'Guiding Failure' counted 1/3, 2/3, 3/3.
                    //
                    // Where the trigger maps to a first-class RecoveryCause,
                    // hand it to the recovery driver on the FIRST firing
                    // instead. The driver freezes the node tree (so no further
                    // frame starts), runs a real attempt ladder for that cause
                    // — for guiding that is an actual re-acquisition, not a
                    // status re-read — and honours the operator's retry budget,
                    // which is what `max_attempts` was pretending to be.
                    if let Some(cause) = trigger_recovery_cause(&trigger_id) {
                        match recovery_request_tx.try_send(cause.clone()) {
                            Ok(()) => {
                                tracing::warn!(
                                    "[RECOVERY] Trigger '{}' fired with a Retry action and maps \
                                     to {:?}; handing it to the recovery driver so the node tree \
                                     freezes instead of exposing through the failure",
                                    trigger_name,
                                    cause
                                );
                            }
                            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                                // Already recovering or queued — the node tree
                                // is frozen either way, which is the guarantee
                                // this arm owes the run.
                                tracing::warn!(
                                    "[RECOVERY] Recovery channel full; dropping duplicate \
                                     request from '{}'",
                                    trigger_name
                                );
                            }
                            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                                // Driver task ended. Fall back to a plain hold:
                                // the run must still stop taking frames.
                                tracing::error!(
                                    "[RECOVERY] Recovery driver is gone; pausing the run for \
                                     trigger '{}' rather than exposing through the failure",
                                    trigger_name
                                );
                                is_paused_for_triggers.store(true, Ordering::Relaxed);
                                *state_clone.write().await = ExecutorState::Paused;
                                {
                                    let mut prog = progress_for_triggers.write();
                                    prog.state = ExecutorState::Paused;
                                    prog.message = Some(format!("Paused: {} fired", trigger_name));
                                }
                                let _ = event_tx_clone2
                                    .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                                let _ = event_tx_clone2.send(ExecutorEvent::Error {
                                    message: format!(
                                        "Trigger '{}' fired and automatic recovery is not \
                                         available. The run is paused — no further frames will \
                                         be taken until you resume.",
                                        trigger_name
                                    ),
                                });
                            }
                        }
                    } else {
                        // No automatic recovery exists for this trigger, so the
                        // only honest thing the count can mean is "how many
                        // firings the operator is willing to tolerate before the
                        // run stops". Say that, rather than claiming a retry
                        // that never happens.
                        let attempts = retry_attempts.entry(trigger_id.clone()).or_insert(0);
                        if *attempts < *max_attempts {
                            *attempts += 1;
                            tracing::warn!(
                                "Trigger '{}' fired {}/{} times; it has no automatic recovery, \
                                 so the run continues until the {} allowed firing{} are used",
                                trigger_name,
                                attempts,
                                max_attempts,
                                max_attempts,
                                if *max_attempts == 1 { "" } else { "s" }
                            );
                        } else {
                            tracing::error!(
                                "Trigger '{}' fired more than its {} allowed times; pausing \
                                 sequence",
                                trigger_name,
                                max_attempts
                            );
                            is_paused_for_triggers.store(true, Ordering::Relaxed);
                            *state_clone.write().await = ExecutorState::Paused;
                            // The status API is built from the progress snapshot, not from
                            // this lock. Stamping only the lock is what let a paused run
                            // keep reporting `running` — see mirror_paused_into_progress.
                            {
                                let mut prog = progress_for_triggers.write();
                                prog.state = ExecutorState::Paused;
                                prog.message =
                                    Some(format!("Paused: {} kept firing", trigger_name));
                            }
                            let _ = event_tx_clone2
                                .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                            let _ = event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' fired more than the {} times allowed; sequence \
                                     paused",
                                    trigger_name, max_attempts
                                ),
                            });
                        }
                    }
                }
                RecoveryAction::MeridianFlip(config) => {
                    // An operator's request is consumed here whatever happens
                    // next: it asked for this flip, not for every later one.
                    let requested = std::mem::take(
                        &mut trigger_state_for_actions
                            .write()
                            .await
                            .meridian_flip_requested,
                    );
                    // The flip waited for the imaging train, and the mount may
                    // have moved meanwhile -- a target change fires this on the
                    // new target's hour angle against the old pointing's pier
                    // side, and the next Center or Slew node then lands on the
                    // post-flip side. Re-read the pier side and ask again.
                    if let Some(mount_id) = trigger_action_context.mount_id.as_deref() {
                        let fresh_pier = match bounded_poll(
                            "mount_side_of_pier",
                            device_ops_for_triggers.mount_side_of_pier(mount_id),
                        )
                        .await
                        {
                            Ok(crate::meridian::PierSide::East) => Some(crate::PierSide::East),
                            Ok(crate::meridian::PierSide::West) => Some(crate::PierSide::West),
                            Ok(crate::meridian::PierSide::Unknown) => {
                                Some(crate::PierSide::Unknown)
                            }
                            Err(_) => None,
                        };
                        let hour_angle = {
                            let mut ts = trigger_state_for_actions.write().await;
                            if let Some(pier) = fresh_pier {
                                ts.update_pier_side(pier);
                            }
                            ts.current_hour_angle
                        };
                        let pier_now =
                            fresh_pier.or(trigger_state_for_actions.read().await.pier_side);
                        // A requested flip waives the window threshold but
                        // not the pre-flip side, so it is re-asked that way.
                        let still_due = if requested {
                            hour_angle
                                .is_some_and(|ha| crate::triggers::on_pre_flip_side(ha, pier_now))
                        } else {
                            crate::triggers::flip_still_due(config, hour_angle, pier_now)
                        };
                        if !still_due {
                            tracing::info!(
                                "[MERIDIAN] Flip no longer due when its turn came (hour angle {:?}h, \
                                 pier side {:?}); the mount is already on the post-flip side",
                                hour_angle,
                                pier_now
                            );
                            camera_claim.release().await;
                            continue;
                        }
                    }
                    tracing::info!(
                        "[MERIDIAN] Trigger fired - executing meridian flip{}",
                        if requested {
                            " (requested by the operator)"
                        } else {
                            ""
                        }
                    );

                    let (target_name, target_ra, target_dec, current_filter) = {
                        let ts = trigger_state_for_actions.read().await;
                        (
                            ts.current_target_name
                                .clone()
                                // Why: target name is a
                                // display/log label; the load-bearing trigger
                                // outputs are `target_ra` and `target_dec`
                                // which propagate as Option below and gate
                                // the meridian-flip-context construction.
                                .unwrap_or_else(|| "Unknown".to_string()),
                            ts.target_ra.map(|ra| ra / 15.0), // Convert degrees to hours
                            ts.target_dec,
                            ts.current_filter.clone(),
                        )
                    };
                    let autofocus_config = runtime_config.read().autofocus.clone();

                    if let Some(flip_ctx) = build_trigger_flip_context(
                        &trigger_action_context,
                        TriggerFlipTarget {
                            name: target_name.clone(),
                            ra_hours: target_ra,
                            dec_degrees: target_dec,
                        },
                        Some(is_cancelled_clone.clone()),
                        Some(trigger_state_for_actions.clone()),
                        autofocus_config,
                        current_filter,
                    ) {
                        let mut flip_executor =
                            crate::meridian_flip_executor::MeridianFlipExecutor::new(
                                config.clone(),
                                device_ops_for_triggers.clone(),
                            )
                            // The executor emits the
                            // MeridianFlipOutcome verdict itself, so
                            // it needs the run's event stream.
                            .with_executor_event_tx(event_tx_clone2.clone())
                            .with_decision_tx(
                                decision_tx_for_lifecycle.clone(),
                                active_run_id_for_decisions.clone(),
                            );

                        let flip_result = flip_executor.execute(&flip_ctx).await;
                        // Hand the camera back the moment the
                        // flip is done — success or failure —
                        // so the capture loop resumes on its
                        // next frame instead of waiting out the
                        // claim's ten-minute expiry. Mirrors
                        // the autofocus arm.
                        camera_claim.release().await;
                        // Snapshot the attempt count before the
                        // match consumes the result — a flip that
                        // only succeeded on retry #3 is DEGRADED
                        // and the operator must be told.
                        let flip_attempts = flip_executor.attempts_made();
                        match flip_result {
                            crate::meridian_flip_executor::FlipResult::Success {
                                new_pier_side,
                                duration_secs,
                            } => {
                                tracing::info!(
                                "[MERIDIAN] Flip completed successfully: new pier side {:?}, took {:.1}s",
                                new_pier_side, duration_secs
                            );

                                // The verdict that reaches the Dart run
                                // vitals is emitted by
                                // MeridianFlipExecutor::execute, so the
                                // node-driven path reports flips too.
                                let mut ts = trigger_state_for_actions.write().await;
                                ts.mark_flip_performed();
                            }
                            crate::meridian_flip_executor::FlipResult::Failed {
                                error,
                                action_taken,
                            } => {
                                tracing::error!(
                                    "[MERIDIAN] Flip failed: {} (action: {:?})",
                                    error,
                                    action_taken
                                );

                                // Latch the failure so the run's
                                // terminal verdict cannot be a silent
                                // `completed` (mirrors how
                                // `recovery_gave_up` coerces the
                                // result to Failure).
                                meridian_flip_failed_for_triggers.store(true, Ordering::Release);
                                meridian_flip_failure_for_triggers
                                    .write()
                                    .get_or_insert_with(|| {
                                        format!(
                                            "Meridian flip for '{}' failed after {} attempt{}: {}",
                                            target_name,
                                            flip_attempts,
                                            if flip_attempts == 1 { "" } else { "s" },
                                            error
                                        )
                                    });

                                match action_taken {
                                    crate::FlipFailureAction::PauseAndAlert => {
                                        // "Pause & Alert" must be
                                        // OBSERVABLE, and
                                        // `sequencer_get_status()` reads
                                        // `progress.state` rather than the
                                        // executor state — so mirror the
                                        // operator-pause path: state +
                                        // progress + a reason banner.
                                        let pause_message = format!(
                                            "Meridian flip for '{}' FAILED after {} \
                                         attempt{}: {}. Sequence paused — the \
                                         mount may be on the wrong side of the \
                                         pier; verify framing before resuming.",
                                            target_name,
                                            flip_attempts,
                                            if flip_attempts == 1 { "" } else { "s" },
                                            error
                                        );
                                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                                        *state_clone.write().await = ExecutorState::Paused;
                                        // The status API is built from the progress snapshot, not from
                                        // this lock. Stamping only the lock is what let a paused run
                                        // keep reporting `running` — see mirror_paused_into_progress.
                                        progress_for_triggers.write().state = ExecutorState::Paused;
                                        {
                                            let mut prog = progress_for_triggers.write();
                                            prog.state = ExecutorState::Paused;
                                            prog.message = Some(pause_message);
                                        }
                                        // No separate `Error` event:
                                        // the Critical-severity
                                        // `MeridianFlipOutcome` emitted
                                        // above IS the verdict, and
                                        // emitting both would record the
                                        // same failure twice in the run's
                                        // errorMessages.
                                        let _ = event_tx_clone2.send(ExecutorEvent::StateChanged(
                                            ExecutorState::Paused,
                                        ));
                                    }
                                    crate::FlipFailureAction::AbortAndPark => {
                                        // The flip itself failed, so the mount may be
                                        // anywhere between sides. Park before we exit
                                        // to avoid leaving it tracking into a limit
                                        // — matches the ParkAndAbort policy above.
                                        // First cancel and drain
                                        // the concurrently-running
                                        // node tree so a camera
                                        // integration cannot remain
                                        // active while we park.
                                        park_and_abort_for_triggers.store(true, Ordering::Release);
                                        cancel_and_wait_for_execution(
                                            &is_cancelled_clone,
                                            &mut execution_quiesced_for_triggers,
                                        )
                                        .await;
                                        if let Err(error) =
                                            device_ops_for_triggers.guider_stop().await
                                        {
                                            let msg = format!(
                                                "FlipFailure AbortAndPark: failed to stop \
                                                 guiding before parking: {}",
                                                error
                                            );
                                            tracing::error!("{}", msg);
                                            let _ = event_tx_clone2
                                                .send(ExecutorEvent::Error { message: msg });
                                        }
                                        // `try_park_with_retry` gives a flaky
                                        // driver at least one retry before this
                                        // gives up, and surfaces a park-specific
                                        // failure to the event stream.
                                        if let Some(mount_id) = &trigger_action_context.mount_id {
                                            tracing::warn!("FlipFailure AbortAndPark: parking mount '{}' (max_retries=1, retry_delay=2s)", mount_id);
                                            let park_outcome =
                                                crate::device_ops::try_park_with_retry(
                                                    &device_ops_for_triggers,
                                                    mount_id,
                                                    1,
                                                    2.0,
                                                )
                                                .await;
                                            if !park_outcome.success {
                                                let _ = event_tx_clone2.send(
                                                ExecutorEvent::Error {
                                                    message: format!(
                                                        "FlipFailure AbortAndPark: mount park FAILED after {} attempt{}: {}. \
                                                         Mount may be in an unsafe position — manual intervention required.",
                                                        park_outcome.attempts_made,
                                                        if park_outcome.attempts_made == 1 {
                                                            ""
                                                        } else {
                                                            "s"
                                                        },
                                                        park_outcome
                                                            .last_error
                                                            .unwrap_or_else(|| {
                                                                "unknown error".to_string()
                                                            }),
                                                    ),
                                                },
                                            );
                                            }
                                        }

                                        let _ = park_and_abort_done_for_triggers.send(true);
                                        fired_triggers.push((
                                            trigger_id.clone(),
                                            RecoveryAction::ParkAndAbort,
                                        ));
                                        return terminate_with(
                                            &is_cancelled_clone,
                                            fired_triggers,
                                            "FlipFailureAction::AbortAndPark",
                                        );
                                    }
                                }
                            }
                            crate::meridian_flip_executor::FlipResult::Aborted { reason } => {
                                // The verdict itself comes from
                                // MeridianFlipExecutor::execute.
                                tracing::warn!("[MERIDIAN] Flip aborted: {}", reason);
                            }
                        }
                    } else {
                        // A flip trigger that fires and then
                        // cannot run is a safety event, not a
                        // log line: the mount is past the
                        // meridian and nothing is going to move
                        // it. Surface it so the run records
                        // WHY no flip happened.
                        let message = format!(
                            "Meridian flip trigger fired for '{}' but the flip \
                             could not be executed: mount not connected or \
                             target coordinates not set. The mount is past the \
                             meridian and was NOT flipped.",
                            target_name
                        );
                        tracing::error!("[MERIDIAN] {}", message);
                        meridian_flip_failed_for_triggers.store(true, Ordering::Release);
                        meridian_flip_failure_for_triggers
                            .write()
                            .get_or_insert_with(|| message.clone());
                        let _ = event_tx_clone2.send(ExecutorEvent::Error { message });
                        // No flip ran, so nothing used the
                        // camera: hand the claim straight back
                        // rather than holding the capture loop
                        // for the claim's ten-minute expiry.
                        camera_claim.release().await;
                    }
                }
                RecoveryAction::Dither(dither_config) => {
                    // implement the standard
                    // DitherInterval recovery. Build an instruction
                    // context (the trigger action context already
                    // carries every device id, save path,
                    // location, filter offsets, and an
                    // is_cancelled token). The dither runs
                    // asynchronously here; we update
                    // last_dither_frame on success so the
                    // DitherInterval cadence stays correct.
                    //
                    // prefer the runtime config over
                    // the trigger-embedded default if the user
                    // updated it via UpdateDitherConfig. The
                    // trigger config still wins for `pattern`/
                    // `grid_size` because those are not exposed
                    // by UpdateDitherConfig.
                    let effective_config = {
                        let rc = runtime_config.read();
                        // The runtime config has Default values
                        // (zero) until UpdateDitherConfig fires,
                        // so prefer the trigger-embedded config
                        // when the runtime side has not been
                        // explicitly set (pixels==0). Otherwise
                        // the runtime override wins so the user's
                        // last UpdateDitherConfig is honoured.
                        if rc.dither.pixels > 0.0 {
                            crate::DitherConfig {
                                pixels: rc.dither.pixels,
                                settle_pixels: rc.dither.settle_pixels,
                                settle_time: rc.dither.settle_time,
                                settle_timeout: rc.dither.settle_timeout,
                                ra_only: rc.dither.ra_only,
                                // pattern/grid_size are not
                                // surfaced by UpdateDitherConfig
                                // so the trigger value still wins.
                                pattern: dither_config.pattern,
                                grid_size: dither_config.grid_size,
                            }
                        } else {
                            dither_config.clone()
                        }
                    };
                    tracing::info!(
                    "[DITHER] Trigger '{}' fired - executing dither (pixels={}, settle_pixels={})",
                    trigger_name,
                    effective_config.pixels,
                    effective_config.settle_pixels,
                );
                    let (target_name, target_ra, target_dec, current_filter) = {
                        let ts = trigger_state_for_actions.read().await;
                        (
                            ts.current_target_name.clone(),
                            ts.target_ra.map(|ra| ra / 15.0),
                            ts.target_dec,
                            ts.current_filter.clone(),
                        )
                    };
                    let dither_ctx = build_trigger_autofocus_context(
                        &trigger_action_context,
                        target_name,
                        target_ra,
                        target_dec,
                        current_filter,
                        is_cancelled_clone.clone(),
                        device_ops_for_triggers.clone(),
                        trigger_state_for_actions.clone(),
                        &runtime_config,
                        Some(event_tx_clone2.clone()),
                    );
                    let dither_result =
                        crate::instructions::execute_dither(&effective_config, &dither_ctx, None)
                            .await;
                    match classify_dither_result(
                        dither_result.status,
                        dither_result.message.as_deref(),
                    ) {
                        DitherTriggerOutcome::Performed => {
                            let mut ts = trigger_state_for_actions.write().await;
                            ts.mark_dither_performed();
                        }
                        DitherTriggerOutcome::SkippedNoGuider => {
                            // An unguided rig cannot dither, and that is not a
                            // failure — the same skippable-no-op treatment the
                            // dither NODE, ParkAndAbort and the meridian
                            // pause/resume already give this marker.
                            //
                            // Marking it performed matters as much as the log
                            // level: the interval only resets here, so leaving
                            // it unmarked kept the trigger permanently due and
                            // it re-fired on EVERY exposure. Measured on an
                            // unguided dark run, 12 frames produced 12
                            // identical WARNs for a condition that cannot
                            // change mid-run.
                            let mut ts = trigger_state_for_actions.write().await;
                            ts.mark_dither_performed();
                            tracing::debug!(
                                "[DITHER] Trigger '{}' skipped - no guider configured",
                                trigger_name
                            );
                        }
                        DitherTriggerOutcome::Failed => {
                            tracing::warn!(
                                "[DITHER] Trigger-initiated dither failed: {:?}",
                                dither_result.message
                            );
                        }
                    }
                }
                RecoveryAction::Recenter => {
                    // re-slew to the target and
                    // plate-solve as the DriftLimit recovery. The
                    // existing `execute_center` instruction
                    // already does plate-solve + sync + slew loop;
                    // we reuse it so behaviour matches an
                    // explicit Center node.
                    tracing::info!(
                        "[DRIFT] Trigger '{}' fired - executing recenter",
                        trigger_name
                    );
                    let (target_name, target_ra, target_dec, current_filter) = {
                        let ts = trigger_state_for_actions.read().await;
                        (
                            ts.current_target_name.clone(),
                            ts.target_ra.map(|ra| ra / 15.0),
                            ts.target_dec,
                            ts.current_filter.clone(),
                        )
                    };
                    if target_ra.is_none() || target_dec.is_none() {
                        tracing::error!(
                        "[DRIFT] Recenter requested but no target RA/Dec set; pausing for operator intervention"
                    );
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        // Nothing exposed; release the claim.
                        camera_claim.release().await;
                    } else {
                        let recenter_ctx = build_trigger_autofocus_context(
                            &trigger_action_context,
                            target_name,
                            target_ra,
                            target_dec,
                            current_filter,
                            is_cancelled_clone.clone(),
                            device_ops_for_triggers.clone(),
                            trigger_state_for_actions.clone(),
                            &runtime_config,
                            Some(event_tx_clone2.clone()),
                        );
                        let center_config = crate::CenterConfig {
                            use_target_coords: true,
                            custom_ra: None,
                            custom_dec: None,
                            accuracy_arcsec: 10.0,
                            max_attempts: 3,
                            exposure_duration: 5.0,
                            filter: None,
                        };
                        let result = crate::instructions::execute_center(
                            &center_config,
                            &recenter_ctx,
                            None,
                        )
                        .await;
                        // Solve exposures are done; release the
                        // capture loop immediately rather than
                        // sitting out the claim's expiry.
                        camera_claim.release().await;
                        let stop_on_quality_problems = trigger_state_for_actions
                            .read()
                            .await
                            .stop_on_quality_problems;
                        if result.status == NodeStatus::Success {
                            recenter_failure_told = false;
                        } else if crate::instructions::center_did_not_converge(&result)
                            && !stop_on_quality_problems
                        {
                            // The solver could not solve or converge (cloud, a
                            // sparse field): a judgment, not a fault. The frames
                            // carry on where the mount points and the operator
                            // is told once per run of failed recenters (owner
                            // decision 2026-10-06: only a risk to the hardware
                            // stops a run by itself). This used to pause the run
                            // until someone resumed it.
                            let problem = format!(
                                "{}. The mount stays where the last correction put it.",
                                result
                                    .message
                                    .as_deref()
                                    .unwrap_or("Recenter did not converge")
                            );
                            if recenter_failure_told {
                                tracing::warn!("[DRIFT] Recenter failed again: {}", problem);
                            } else {
                                recenter_failure_told = true;
                                let continuation = crate::executor::quality_problem_continuation(
                                    &format!("{trigger_name} recenter"),
                                    &problem,
                                    serde_json::json!({ "trigger_id": trigger_id }),
                                );
                                tracing::warn!("[DRIFT] {}", continuation.operator_message);
                                let mut decision = continuation.decision;
                                decision.sequence_run_id = *active_run_id_for_decisions.read();
                                let _ = decision_tx_for_lifecycle.send(decision);
                                let _ = event_tx_clone2.send(ExecutorEvent::Warning {
                                    message: continuation.operator_message,
                                });
                            }
                        } else {
                            tracing::warn!(
                                "[DRIFT] Recenter failed: {:?} - pausing sequence",
                                result.message
                            );
                            is_paused_for_triggers.store(true, Ordering::Relaxed);
                            *state_clone.write().await = ExecutorState::Paused;
                            // The status API is built from the progress snapshot, not from
                            // this lock. Stamping only the lock is what let a paused run
                            // keep reporting `running` — see mirror_paused_into_progress.
                            progress_for_triggers.write().state = ExecutorState::Paused;
                            let _ = event_tx_clone2
                                .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                            let _ = event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "DriftLimit recenter failed: {}",
                                    // Why: recenter-result
                                    // message is Option<String>; the failure
                                    // is already encoded in `result.success`
                                    // (we are in the `false` branch). Empty
                                    // string for the diagnostic suffix is
                                    // safe — the prefix conveys the failure.
                                    result.message.unwrap_or_default()
                                ),
                            });
                        }
                    }
                }
                RecoveryAction::PauseAndWaitForClear => {
                    // pause the sequence and
                    // promote the pause to a recovery
                    // RecoveryCause::WeatherUnsafe so the
                    // dashboard banner, audible alert, and
                    // recovery driver all light up.
                    // `CloudOpeningIn` triggers wired to
                    // `Continue` (or any recovery the user
                    // wires) will fire when the analyzer
                    // sees an opening; the executor's
                    // legacy auto-resume path handles the
                    // actual unpause via the user's
                    // `autoResumeEnabled` flag in
                    // WeatherSafetyNotifier.
                    tracing::warn!(
                        "[CLOUD] Trigger '{}' fired - pausing sequence (PauseAndWaitForClear)",
                        trigger_name
                    );
                    let cause = crate::recovery::RecoveryCause::WeatherUnsafe;
                    match recovery_request_tx.try_send(cause.clone()) {
                        Ok(()) => {
                            tracing::info!(
                                "[RECOVERY] PauseAndWaitForClear requested ({:?})",
                                cause
                            );
                        }
                        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                            tracing::warn!(
                                "[RECOVERY] Recovery channel full; falling back to plain Pause"
                            );
                            is_paused_for_triggers.store(true, Ordering::Relaxed);
                            *state_clone.write().await = ExecutorState::Paused;
                            // The status API is built from the progress snapshot, not from
                            // this lock. Stamping only the lock is what let a paused run
                            // keep reporting `running` — see mirror_paused_into_progress.
                            progress_for_triggers.write().state = ExecutorState::Paused;
                            let _ = event_tx_clone2
                                .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        }
                        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                            // Driver task ended — same
                            // fallback as the legacy Pause
                            // path.
                            is_paused_for_triggers.store(true, Ordering::Relaxed);
                            *state_clone.write().await = ExecutorState::Paused;
                            // The status API is built from the progress snapshot, not from
                            // this lock. Stamping only the lock is what let a paused run
                            // keep reporting `running` — see mirror_paused_into_progress.
                            progress_for_triggers.write().state = ExecutorState::Paused;
                            let _ = event_tx_clone2
                                .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        }
                    }
                }
                RecoveryAction::SlewToGapAndContinue => {
                    // slew the mount to the
                    // analyzer-reported clear-sky direction.
                    // No clear direction reported => fall
                    // back to PauseAndWaitForClear (we
                    // refuse to silently no-op when the
                    // user explicitly wanted to move away
                    // from the clouds).
                    let snapshot = {
                        let slot = cloud_motion_for_recovery.read().await;
                        slot.clone()
                    };
                    let Some((alt_deg, az_deg)) = snapshot.predicted_clear_sky_direction else {
                        tracing::warn!(
                            "[CLOUD] SlewToGapAndContinue fired but no clear-sky direction reported; falling back to PauseAndWaitForClear"
                        );
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' requested SlewToGapAndContinue but the cloud-motion analyzer has not reported a clear sky direction. Sequence paused.",
                                    trigger_name,
                                ),
                            });
                        fired_triggers.push((trigger_id, action));
                        continue;
                    };

                    // Need observer location to convert
                    // alt/az -> RA/Dec.
                    let (lat, lon) = {
                        let rc = runtime_config.read();
                        (rc.latitude, rc.longitude)
                    };
                    let (Some(lat), Some(lon)) = (
                        lat.or(trigger_action_context.latitude),
                        lon.or(trigger_action_context.longitude),
                    ) else {
                        tracing::error!(
                            "[CLOUD] SlewToGapAndContinue cannot proceed: observer location not set"
                        );
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: "SlewToGapAndContinue requested but observer location is not configured. Sequence paused.".to_string(),
                            });
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        fired_triggers.push((trigger_id, action));
                        continue;
                    };

                    let (ra_hours, dec_deg) = alt_az_to_ra_dec(alt_deg, az_deg, lat, lon);
                    tracing::info!(
                        "[CLOUD] SlewToGapAndContinue: clear sky at alt={:.1}°, az={:.1}° -> RA={:.4}h, Dec={:.4}°",
                        alt_deg,
                        az_deg,
                        ra_hours,
                        dec_deg
                    );

                    // Build an instruction context that
                    // targets the gap coordinates.
                    let slew_ctx = build_trigger_autofocus_context(
                        &trigger_action_context,
                        Some("Cloud Gap".to_string()),
                        Some(ra_hours),
                        Some(dec_deg),
                        None,
                        is_cancelled_clone.clone(),
                        device_ops_for_triggers.clone(),
                        trigger_state_for_actions.clone(),
                        &runtime_config,
                        Some(event_tx_clone2.clone()),
                    );
                    let slew_config = crate::SlewConfig {
                        use_target_coords: false,
                        custom_ra: Some(ra_hours),
                        custom_dec: Some(dec_deg),
                    };
                    let result =
                        crate::instructions::execute_slew(&slew_config, &slew_ctx, None).await;
                    if result.status != NodeStatus::Success {
                        tracing::warn!(
                            "[CLOUD] Slew to gap failed: {:?} - pausing sequence",
                            result.message
                        );
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        let _ = event_tx_clone2.send(ExecutorEvent::Error {
                            message: format!(
                                "SlewToGapAndContinue failed: {}",
                                result.message.unwrap_or_default()
                            ),
                        });
                    } else {
                        tracing::info!("[CLOUD] Slew to gap completed; sequence continues");
                    }
                }
                RecoveryAction::SwitchTargetOrFilter => {
                    // Science — transparency-adaptive
                    // recovery. Consult the operator's
                    // pre-configured backup plan; apply
                    // filter swap and/or skip-to-target as
                    // configured. No plan + no fields set
                    // => fall back to PauseAndWaitForClear
                    // ("no silent fallbacks":
                    // we tell the operator why we're not
                    // doing anything).
                    let plan_snapshot = {
                        let slot = transparency_backup_for_recovery.read().await;
                        slot.clone()
                    };
                    let Some(plan) = plan_snapshot else {
                        tracing::warn!(
                            "[SCIENCE] SwitchTargetOrFilter fired but no backup plan configured; falling back to PauseAndWaitForClear"
                        );
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' requested SwitchTargetOrFilter but no transparency backup plan was configured. Sequence paused. Set a backup filter or backup target in the science settings before re-running.",
                                    trigger_name,
                                ),
                            });
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        fired_triggers.push((trigger_id, action));
                        continue;
                    };
                    if plan.backup_filter.is_none() && plan.backup_target_id.is_none() {
                        tracing::warn!(
                            "[SCIENCE] SwitchTargetOrFilter: backup plan has neither filter nor target; falling back to PauseAndWaitForClear"
                        );
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' requested SwitchTargetOrFilter but the configured backup plan is empty. Sequence paused.",
                                    trigger_name,
                                ),
                            });
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        fired_triggers.push((trigger_id, action));
                        continue;
                    }
                    tracing::warn!(
                        "[SCIENCE] Trigger '{}' fired SwitchTargetOrFilter: filter={:?}, target={:?}, desc={:?}",
                        trigger_name,
                        plan.backup_filter,
                        plan.backup_target_id,
                        plan.description,
                    );
                    // 1. If a backup target node id is set,
                    //    request a skip-to-node so the executor
                    //    walks past the current target and
                    //    enters the backup target's subtree.
                    if let Some(node_id) = &plan.backup_target_id {
                        *skip_to_node_for_recovery.write() = Some(node_id.clone());
                        tracing::info!(
                            "[SCIENCE] Requested skip-to-node '{}' for transparency backup",
                            node_id
                        );
                    }
                    // 2. If a backup filter is set, drive a
                    //    ChangeFilter through the standard
                    //    instruction context so the filter
                    //    wheel actually moves. Use a
                    //    standalone instruction context here
                    //    (the running root_node.execute is
                    //    holding `&mut context` so we cannot
                    //    re-borrow it).
                    if let Some(filter_name) = &plan.backup_filter {
                        let inst_ctx = build_trigger_autofocus_context(
                            &trigger_action_context,
                            None,
                            None,
                            None,
                            None,
                            is_cancelled_clone.clone(),
                            device_ops_for_triggers.clone(),
                            trigger_state_for_actions.clone(),
                            &runtime_config,
                            Some(event_tx_clone2.clone()),
                        );
                        let filter_cfg = crate::FilterConfig {
                            filter_name: filter_name.clone(),
                            filter_index: None,
                            timeout_secs: None,
                        };
                        let result = crate::instructions::execute_filter_change(
                            &filter_cfg,
                            &inst_ctx,
                            None,
                        )
                        .await;
                        if result.status != NodeStatus::Success {
                            tracing::warn!(
                                "[SCIENCE] Backup filter change to '{}' failed: {:?}",
                                filter_name,
                                result.message,
                            );
                            let _ = event_tx_clone2
                                .send(ExecutorEvent::Error {
                                    message: format!(
                                        "SwitchTargetOrFilter: backup filter '{}' could not be selected: {}",
                                        filter_name,
                                        result
                                            .message
                                            .unwrap_or_default()
                                    ),
                                });
                        } else {
                            tracing::info!("[SCIENCE] Switched to backup filter '{}'", filter_name);
                        }
                    }
                }
                // A notify-only firing (`Notify`, or a quality trigger under the
                // default policy) told the operator and moved on above, before
                // the in-flight guard; nothing reaches here with it.
                RecoveryAction::Notify => {}
                RecoveryAction::Continue => {
                    // explicit no-op handler so the
                    // match is exhaustive on every variant. The
                    // user wants the trigger logged-and-ignored
                    // (this is the FilterChange standard trigger's
                    // behaviour).
                    tracing::info!(
                        "Trigger '{}' fired with RecoveryAction::Continue (logged and ignored)",
                        trigger_name
                    );
                }
                RecoveryAction::CustomBranch => {
                    let Some(recovery_node_id) = custom_recovery_branches_for_triggers
                        .get(&trigger_id)
                        .cloned()
                    else {
                        tracing::error!(
                            "Trigger '{}' fired CustomBranch but no recovery branch was registered",
                            trigger_name
                        );
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' requested Custom Branch recovery, but no branch was registered. Sequence paused.",
                                    trigger_name
                                ),
                            });
                        fired_triggers.push((trigger_id, action));
                        continue;
                    };

                    let Some(sequence) = sequence_for_custom_recovery_triggers.as_ref() else {
                        tracing::error!(
                            "Trigger '{}' fired CustomBranch but no loaded sequence snapshot is available",
                            trigger_name
                        );
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' requested Custom Branch recovery, but the sequence snapshot was unavailable. Sequence paused.",
                                    trigger_name
                                ),
                            });
                        fired_triggers.push((trigger_id, action));
                        continue;
                    };

                    let node_map: HashMap<&str, &NodeDefinition> =
                        sequence.nodes.iter().map(|n| (n.id.as_str(), n)).collect();
                    let Some(recovery_def) = node_map.get(recovery_node_id.as_str()) else {
                        tracing::error!(
                            "Trigger '{}' fired CustomBranch but recovery node '{}' was not found",
                            trigger_name,
                            recovery_node_id
                        );
                        is_paused_for_triggers.store(true, Ordering::Relaxed);
                        *state_clone.write().await = ExecutorState::Paused;
                        // The status API is built from the progress snapshot, not from
                        // this lock. Stamping only the lock is what let a paused run
                        // keep reporting `running` — see mirror_paused_into_progress.
                        progress_for_triggers.write().state = ExecutorState::Paused;
                        let _ = event_tx_clone2
                            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                        let _ =
                            event_tx_clone2.send(ExecutorEvent::Error {
                                message: format!(
                                    "Trigger '{}' requested Custom Branch node '{}', but it was not found. Sequence paused.",
                                    trigger_name,
                                    recovery_node_id
                                ),
                            });
                        fired_triggers.push((trigger_id, action));
                        continue;
                    };

                    let mut branch_node = build_runtime_node_from_map(recovery_def, &node_map);
                    let mut branch_context = custom_recovery_context_for_triggers.clone();
                    branch_context.node_id = recovery_node_id.clone();

                    tracing::warn!(
                        "Trigger '{}' executing CustomBranch recovery node '{}'",
                        trigger_name,
                        recovery_node_id
                    );
                    let result = crate::node::logic::recovery::execute_custom_branch_children(
                        &mut branch_node,
                        &mut branch_context,
                    )
                    .await;

                    match result {
                        NodeStatus::Success | NodeStatus::Skipped => {
                            tracing::info!(
                                "CustomBranch recovery node '{}' completed with {:?}",
                                recovery_node_id,
                                result
                            );
                        }
                        NodeStatus::Cancelled => {
                            fired_triggers.push((trigger_id, action));
                            return terminate_with(
                                &is_cancelled_clone,
                                fired_triggers,
                                "RecoveryAction::CustomBranch cancelled",
                            );
                        }
                        NodeStatus::Pending | NodeStatus::Running | NodeStatus::Failure => {
                            tracing::error!(
                                "CustomBranch recovery node '{}' failed with {:?}; pausing sequence",
                                recovery_node_id,
                                result
                            );
                            is_paused_for_triggers.store(true, Ordering::Relaxed);
                            *state_clone.write().await = ExecutorState::Paused;
                            // The status API is built from the progress snapshot, not from
                            // this lock. Stamping only the lock is what let a paused run
                            // keep reporting `running` — see mirror_paused_into_progress.
                            progress_for_triggers.write().state = ExecutorState::Paused;
                            let _ = event_tx_clone2
                                .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
                            let _ = event_tx_clone2.send(
                                ExecutorEvent::Error {
                                    message: format!(
                                        "Custom Branch recovery '{}' failed after trigger '{}'. Sequence paused.",
                                        recovery_node_id,
                                        trigger_name
                                    ),
                                },
                            );
                        }
                    }

                    fired_triggers.push((trigger_id, action));
                    continue;
                }
            }

            // The single release point every arm that falls out
            // of the match reaches, the autofocus arm's
            // device-missing branch included. Arms that finish
            // with the camera earlier release above so the next
            // frame starts immediately; `Drop` is the backstop for
            // the `continue` and `return terminate_with(...)`
            // exits.
            camera_claim.release().await;

            fired_triggers.push((trigger_id, action));
        }
    }

    fired_triggers
}
