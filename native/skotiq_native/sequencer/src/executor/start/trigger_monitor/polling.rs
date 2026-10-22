//! Stage 1 of a monitor tick: read the devices and publish what they report
//! into the trigger state the evaluation reads.

use super::*;

/// Reads the rig once per tick. Owns the cross-tick latches that rate-limit
/// its warnings and the cadences of the slower polls.
pub(super) struct DevicePoller {
    device_ops: SharedDeviceOps,
    trigger_manager: Arc<RwLock<TriggerManager>>,
    runtime_config: Arc<StdRwLock<RuntimeConfig>>,
    events: broadcast::Sender<ExecutorEvent>,
    mount_id: Option<String>,
    focuser_id: Option<String>,
    dome_id: Option<String>,
    /// The previous safety poll failed, so its warning is not repeated.
    safety_poll_last_was_error: bool,
    last_safety_poll_at: Option<std::time::Instant>,
    last_mount_poll_at: Option<std::time::Instant>,
    /// The stale-verdict warning has been given for the current stale spell.
    verdict_stale_warned: bool,
    /// The "no observing site" warning is given once per run.
    altitude_warned_no_location: bool,
}

/// How this tick's safety-cadence polls are configured.
struct SafetyCadence {
    fail_mode: SafetyFailMode,
    poll_now: bool,
    verdict_staleness_secs: u64,
}

impl DevicePoller {
    pub(super) fn new(
        device_ops: SharedDeviceOps,
        trigger_manager: Arc<RwLock<TriggerManager>>,
        runtime_config: Arc<StdRwLock<RuntimeConfig>>,
        events: broadcast::Sender<ExecutorEvent>,
        rig: &TriggerActionContext,
    ) -> Self {
        Self {
            device_ops,
            trigger_manager,
            runtime_config,
            events,
            mount_id: rig.mount_id.clone(),
            focuser_id: rig.focuser_id.clone(),
            dome_id: rig.dome_id.clone(),
            safety_poll_last_was_error: false,
            last_safety_poll_at: None,
            last_mount_poll_at: None,
            verdict_stale_warned: false,
            altitude_warned_no_location: false,
        }
    }

    /// Poll every device and publish the readings. `executor_state` is the
    /// state this tick was taken in; it decides whether a tracking-loss edge
    /// may be consumed.
    pub(super) async fn poll(&mut self, executor_state: ExecutorState) {
        let cadence = self.safety_cadence();
        let is_safe = self.poll_safety(&cadence).await;
        // One guider poll serves both the RMS the GuidingFailed trigger judges
        // and the is-guiding reading GuideStarLost keys off, so one failure
        // has one error policy.
        let guide_status =
            bounded_poll("guider_get_status", self.device_ops.guider_get_status()).await;
        let humidity = if cadence.poll_now {
            Some(
                bounded_poll(
                    "weather_get_humidity",
                    self.device_ops.weather_get_humidity(None),
                )
                .await,
            )
        } else {
            None
        };
        let guiding_rms = guide_status
            .as_ref()
            .ok()
            .filter(|status| status.is_guiding)
            .map(|status| status.rms_total);
        let (verdict_stale_unsafe, stale_verdict_dropped) = self
            .publish_environment(
                is_safe,
                guiding_rms,
                humidity,
                cadence.verdict_staleness_secs,
                cadence.fail_mode,
            )
            .await;
        if let Some(msg) = weather_verdict_stale_warning(
            verdict_stale_unsafe,
            cadence.verdict_staleness_secs,
            &mut self.verdict_stale_warned,
        ) {
            tracing::warn!("{}", msg);
            let _ = self.events.send(ExecutorEvent::Error { message: msg });
        }
        if stale_verdict_dropped {
            let message =
                stale_verdict_dropped_message(cadence.verdict_staleness_secs, cadence.fail_mode);
            tracing::warn!("{}", message);
            let _ = self.events.send(ExecutorEvent::Warning { message });
        }
        self.poll_mount(executor_state).await;
        self.poll_focuser_temperature(cadence.poll_now).await;
        self.poll_dome(cadence.poll_now).await;
        self.publish_guider_status(guide_status).await;
    }

    fn safety_cadence(&self) -> SafetyCadence {
        let rc = self.runtime_config.read();
        let interval = std::time::Duration::from_secs(effective_safety_check_interval_secs(
            rc.safety_check_interval_secs,
        ));
        SafetyCadence {
            fail_mode: rc.safety_fail_mode,
            poll_now: self
                .last_safety_poll_at
                .map(|last| last.elapsed() >= interval)
                .unwrap_or(true),
            verdict_staleness_secs: effective_weather_verdict_staleness_secs(
                rc.weather_verdict_staleness_secs,
            ),
        }
    }

    /// The safety monitor's verdict, or `None` to keep the previous reading
    /// (no poll this tick, or a WarnOnly poll error). A poll error resolves by
    /// the shared fail-mode table `safety_fail_mode_no_data_resolution`, which
    /// the Dart side mirrors; its warning is given once per error spell.
    async fn poll_safety(&mut self, cadence: &SafetyCadence) -> Option<bool> {
        if !cadence.poll_now {
            return None;
        }
        self.last_safety_poll_at = Some(std::time::Instant::now());
        let error = match bounded_poll("safety_is_safe", self.device_ops.safety_is_safe(None)).await
        {
            Ok(safe) => {
                if self.safety_poll_last_was_error {
                    tracing::info!("Safety poll recovered (mode: {:?})", cadence.fail_mode);
                    self.safety_poll_last_was_error = false;
                }
                return Some(safe);
            }
            Err(e) => e,
        };
        let first_error = !std::mem::replace(&mut self.safety_poll_last_was_error, true);
        match safety_fail_mode_no_data_resolution(cadence.fail_mode) {
            NoDataResolution::Unsafe => {
                if first_error {
                    tracing::warn!(
                        "Safety poll error: {} - treating as unsafe (FailClosed)",
                        error
                    );
                }
                Some(false)
            }
            NoDataResolution::Safe => {
                if first_error {
                    tracing::warn!(
                        "Safety poll error: {} - treating as safe (FailOpen). \
                         Sequence will continue. Do not use FailOpen for \
                         unattended runs.",
                        error
                    );
                }
                Some(true)
            }
            NoDataResolution::Preserve => {
                if first_error {
                    tracing::warn!(
                        "Safety poll error: {} - WarnOnly mode, leaving \
                         weather_safe unchanged and emitting alert",
                        error
                    );
                    let _ = self.events.send(ExecutorEvent::Error {
                        message: format!(
                            "Safety poll failed: {}. WarnOnly mode keeps the \
                             previous safety state — operator attention required.",
                            error
                        ),
                    });
                }
                None
            }
        }
    }

    /// Publish the safety verdict, guiding RMS and humidity, seed the site and
    /// dawn, and compute where the target is. Returns whether a pushed UNSAFE
    /// weather verdict has gone stale, which is checked every tick so a dead
    /// feed is noticed between safety polls.
    async fn publish_environment(
        &mut self,
        is_safe: Option<bool>,
        guiding_rms: Option<f64>,
        humidity: Option<Result<Option<f64>, String>>,
        verdict_staleness_secs: u64,
        fail_mode: SafetyFailMode,
    ) -> (bool, bool) {
        let manager = self.trigger_manager.read().await;
        let trigger_state = manager.state();
        let mut state = trigger_state.write().await;
        if let Some(safe) = is_safe {
            state.weather_safe = safe;
        }
        state.safety_fail_mode = fail_mode;
        let stale = state.is_weather_verdict_stale_unsafe(verdict_staleness_secs);
        let stale_verdict_dropped = stale && !stale_unsafe_verdict_holds(fail_mode);
        if stale_verdict_dropped {
            state.weather_verdict_unsafe = None;
            state.weather_verdict_advisory = false;
        }
        let verdict_stale_unsafe = stale && stale_unsafe_verdict_holds(fail_mode);

        // PHD2 keeps reporting its last RMS after it drops to looping, and a
        // run that gave up on its star reports whatever it last had; only
        // guiding this run started, while guiding and not moving, is judged.
        if let Some(rms) = guiding_rms.filter(|_| state.guiding.judges_rms()) {
            state.update_guiding_rms(rms);
            tracing::trace!("Updated guiding RMS: {:.2}", rms);
        }

        // A device without humidity (`Ok(None)`) and a failed query both leave
        // the previous reading in place.
        match humidity {
            Some(Ok(Some(h))) => {
                state.update_humidity(h);
                tracing::trace!("Updated humidity from weather device: {:.1}%", h);
            }
            Some(Err(e)) => {
                tracing::trace!("weather_get_humidity error: {} (trigger state retained)", e);
            }
            Some(Ok(None)) | None => {}
        }

        // Mobile rigs configure the site after the mount connects.
        if state.observer_latitude.is_none() {
            if let Some((lat, lon)) = self.device_ops.get_observer_location() {
                state.observer_latitude = Some(lat);
                state.observer_longitude = Some(lon);
                tracing::debug!(
                    "Observer location set for dawn/altitude triggers: {}, {}",
                    lat,
                    lon
                );
            }
        }

        // Keep an upcoming dawn cached whenever a site is known, so a
        // multi-night run keeps its dawn protection.
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

        // The altitude and meridian triggers evaluate the TARGET's position,
        // from its own coordinates, the site and the clock.
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
                // Nothing to compute from: drop values left by a checkpoint or
                // another target rather than let the triggers judge them.
                state.current_altitude = None;
                state.current_hour_angle = None;

                // A target without a site leaves altitude and meridian
                // protection off. A Warning, not an Error (the run is fine;
                // protection is missing), given once.
                if state.target_ra.is_some()
                    && state.target_dec.is_some()
                    && !self.altitude_warned_no_location
                {
                    let msg = "AltitudeLimit and meridian-flip triggers need \
                         an observing site, but observer location is not set \
                         — altitude and meridian-flip protection are \
                         INACTIVE. Set location in Profile to enable.";
                    tracing::warn!("{}", msg);
                    let _ = self.events.send(ExecutorEvent::Warning {
                        message: msg.to_string(),
                    });
                    self.altitude_warned_no_location = true;
                }
            }
        }
        (verdict_stale_unsafe, stale_verdict_dropped)
    }

    /// Read the mount's tracking, slewing, parked and pier-side state on the
    /// mount cadence. The mount's own coordinates are not read: the meridian
    /// triggers evaluate the target's hour angle, never the mount's pointing.
    async fn poll_mount(&mut self, executor_state: ExecutorState) {
        let Some(mount_id) = self.mount_id.as_deref() else {
            return;
        };
        let interval = std::time::Duration::from_secs(MOUNT_POLL_INTERVAL_SECS);
        if self
            .last_mount_poll_at
            .is_some_and(|last| last.elapsed() < interval)
        {
            return;
        }
        self.last_mount_poll_at = Some(std::time::Instant::now());
        let tracking_result = bounded_poll(
            "mount_is_tracking",
            self.device_ops.mount_is_tracking(mount_id),
        )
        .await;
        let slewing_result = bounded_poll(
            "mount_is_slewing",
            self.device_ops.mount_is_slewing(mount_id),
        )
        .await;
        let parked_result =
            bounded_poll("mount_is_parked", self.device_ops.mount_is_parked(mount_id)).await;
        let pier_side_result = bounded_poll(
            "mount_side_of_pier",
            self.device_ops.mount_side_of_pier(mount_id),
        )
        .await;

        let manager = self.trigger_manager.read().await;
        let trigger_state = manager.state();
        let mut state = trigger_state.write().await;

        // A failed query is a connection problem, not a tracking loss; a real
        // loss reads as Ok(false).
        match &tracking_result {
            Ok(_)
                if !RunMode::new(executor_state, state.run.hold())
                    .is_some_and(RunMode::reads_tracking_edge) =>
            {
                state.mount_status_query_failed = false;
            }
            Ok(is_tracking) => {
                state.mount_status_query_failed = false;
                // `mount_is_tracking` still holds the previous reading here,
                // which the loss edge is detected against.
                if apply_mount_tracking_poll(&mut state, *is_tracking) {
                    tracing::warn!("Mount tracking lost during sequence!");
                    // The tracking-limit wait runs from the first sighting
                    // of the loss, not from when the trigger evaluates it.
                    if state.tracking.record_loss(chrono::Utc::now().timestamp()) {
                        tracing::info!("Tracking limit detection timestamp recorded");
                    }
                }
                // Tracking resumed before the wait elapsed: a future loss
                // starts its wait afresh.
                if *is_tracking && state.tracking.limit_detected_at().is_some() {
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
        if let Ok(pier_side) = pier_side_result {
            state.update_pier_side(wire_pier_side(pier_side));
        }
    }

    /// The focuser's temperature probe feeds Temperature Shift, on the safety
    /// cadence. A regulated camera sensor never drifts, so a focuser without a
    /// probe leaves the trigger inert rather than falling back to it.
    async fn poll_focuser_temperature(&self, poll_now: bool) {
        let (Some(focuser_id), true) = (self.focuser_id.as_deref(), poll_now) else {
            return;
        };
        match bounded_poll(
            "focuser_get_temperature",
            self.device_ops.focuser_get_temperature(focuser_id),
        )
        .await
        {
            Ok(Some(temp)) => {
                let manager = self.trigger_manager.read().await;
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

    /// The dome shutter, on the safety cadence.
    async fn poll_dome(&self, poll_now: bool) {
        let (Some(dome_id), true) = (self.dome_id.as_deref(), poll_now) else {
            return;
        };
        if let Ok(status) = bounded_poll(
            "dome_get_shutter_status",
            self.device_ops.dome_get_shutter_status(dome_id),
        )
        .await
        {
            let manager = self.trigger_manager.read().await;
            let trigger_state = manager.state();
            let mut state = trigger_state.write().await;
            state.update_dome_status(status.clone());
            if status != "Open" && state.dome_shutter_open_expected {
                tracing::warn!("Dome shutter not open during sequence: {}", status);
            }
        }
    }

    /// Guide Star Lost keys off the guider's is-guiding reading rather than
    /// the RMS, which can stay low for a cycle after the star is gone.
    async fn publish_guider_status<E>(&self, guide_status: Result<crate::GuidingStatus, E>) {
        let manager = self.trigger_manager.read().await;
        let trigger_state = manager.state();
        let mut state = trigger_state.write().await;
        let poll = guide_status
            .as_ref()
            .map(|status| status.is_guiding)
            .map_err(|_| ());
        if state.guiding.observe_guider(poll) == GuiderObservation::GuidingAgain {
            tracing::info!(
                "[GUIDING] The guider is guiding again; dithers and guiding checks resume"
            );
        }
    }
}

/// The geometry crate's pier side as the event-stream type. The two are kept
/// distinct so geometry types cannot leak into bridge-exposed events.
pub(super) fn wire_pier_side(side: crate::meridian::PierSide) -> crate::PierSide {
    match side {
        crate::meridian::PierSide::East => crate::PierSide::East,
        crate::meridian::PierSide::West => crate::PierSide::West,
        crate::meridian::PierSide::Unknown => crate::PierSide::Unknown,
    }
}
