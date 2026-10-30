//! The frame watch's stage of a monitor tick (see [`crate::frame_watch`]).
//!
//! Every saved light frame the run reports is read back, measured and plate
//! solved by a worker task while the next frame exposes. Each tick takes the
//! finished measurements, judges them, reports them to the app's frame
//! record, holds autofocus while the frames are no good to focus on, and acts
//! between frames: a recenter for a frame off target, a notice for a run of
//! starless frames, a probe frame higher in the sky to tell trees from cloud,
//! and for a confirmed obstruction the next target that is clear or the end
//! of the night. None of it pauses or parks the run on a frame's quality.

use super::actions::TargetSnapshot;
use super::dispatch::{Dispatcher, Flow};
use super::*;
use crate::frame_watch::next_target::{after_obstruction, AfterObstruction};
use crate::frame_watch::{
    assess, FrameAssessed, FrameObservation, FrameVerdict, FrameWatch, FrameWatchConfig,
    FrameWatchEvent, HorizonObstructionReport, HorizonPoint, Pointing, SolveOutcome, WatchAction,
};
use std::collections::VecDeque;

pub(crate) use crate::executor::OBSTRUCTION_TRIGGER_ID;

/// Failed guide-star recoveries at one pointing that count as lost guiding
/// for a frame, even while the guider reports a star again.
const GUIDE_STALL_MIN_FAILURES: usize = 2;

/// How far apart, in degrees of altitude and azimuth, those failures may be.
const GUIDE_STALL_MAX_SPREAD_DEG: f64 = 1.0;

/// Whether a frame saved now was taken with guiding lost: the star is lost,
/// the run gave guiding up, or guide-star recovery keeps failing with the
/// mount at one place in the sky (something in the way, not cloud passing).
fn guiding_lost(state: &crate::triggers::TriggerState) -> bool {
    state.guiding.star_lost()
        || state.guiding.is_unguided()
        || state.guide_recovery.as_ref().is_some_and(|stall| {
            stall.stalled_at_one_pointing(GUIDE_STALL_MIN_FAILURES, GUIDE_STALL_MAX_SPREAD_DEG)
        })
}

/// Trigger id of a recenter the frame watch asks for.
pub(crate) const TARGET_DRIFT_TRIGGER_ID: &str = "target_drift";

/// Trigger id of the recenter back onto the target after a probe that found
/// cloud.
pub(crate) const PROBE_RETURN_TRIGGER_ID: &str = "obstruction_probe_return";

/// Trigger id of a skip to the next target past an obstruction.
pub(crate) const OBSTRUCTION_SKIP_TRIGGER_ID: &str = "obstruction_skip";

/// How much higher than the obstructed target the probe frame looks.
const PROBE_ALTITUDE_GAIN_DEG: f64 = 15.0;

/// Highest altitude a probe is sent to.
const PROBE_MAX_ALTITUDE_DEG: f64 = 80.0;

/// Exposure of the probe frame.
const PROBE_EXPOSURE_SECS: f64 = 10.0;

/// Recenters asked for in a row without a frame landing back on target
/// before the watch stops asking until one does.
const MAX_RECENTERS_WITHOUT_SUCCESS: u32 = 3;

/// Measurements kept so a confirmed obstruction can re-mark the frames that
/// led up to it.
const RECENT_FRAMES: usize = 16;

/// Reads back and measures a saved frame: (path, hint RA, hint Dec), degrees.
pub(super) type Measurer = Arc<
    dyn Fn(
            String,
            Option<f64>,
            Option<f64>,
        ) -> futures::future::BoxFuture<'static, Result<assess::MeasuredFrame, String>>
        + Send
        + Sync,
>;

/// A saved frame waiting to be measured.
struct FrameJob {
    observation: FrameObservation,
}

pub(super) struct FrameWatchStage {
    events: broadcast::Receiver<ExecutorEvent>,
    jobs: mpsc::UnboundedSender<FrameJob>,
    measured: mpsc::UnboundedReceiver<FrameObservation>,
    watch: FrameWatch,
    sequence: Option<SequenceDefinition>,
    recent: VecDeque<FrameAssessed>,
    /// The clock exposure starts and recenters are compared on.
    clock: tokio::time::Instant,
    recenters_without_success: u32,
    recenter_limit_told: bool,
    pending_frames: usize,
    autofocus_hold_told: bool,
    /// Each target id's name and coordinates, as they were while it was
    /// current.
    frame_targets: std::collections::HashMap<String, FrameTarget>,
    verified_pointing: Option<(f64, f64, String)>,
}

/// A target's name, RA and Dec (degrees).
type FrameTarget = (Option<String>, Option<f64>, Option<f64>);

impl FrameWatchStage {
    /// Start the measuring worker. `events` is a fresh subscription to the
    /// run's event stream.
    pub(super) fn new(
        events: broadcast::Receiver<ExecutorEvent>,
        device_ops: SharedDeviceOps,
        sequence: Option<SequenceDefinition>,
    ) -> Self {
        let measurer: Measurer = Arc::new(move |path, ra, dec| {
            let device_ops = device_ops.clone();
            Box::pin(async move { assess::measure_saved_frame(&device_ops, &path, ra, dec).await })
        });
        Self::with_measurer(events, measurer, sequence)
    }

    pub(super) fn with_measurer(
        events: broadcast::Receiver<ExecutorEvent>,
        measurer: Measurer,
        sequence: Option<SequenceDefinition>,
    ) -> Self {
        let config = sequence
            .as_ref()
            .map(|s| FrameWatchConfig::from_metadata(&s.metadata))
            .unwrap_or_default();
        let (jobs, mut job_rx) = mpsc::unbounded_channel::<FrameJob>();
        let (measured_tx, measured) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(job) = job_rx.recv().await {
                let mut observation = job.observation;
                match measurer(
                    observation.save_path.clone(),
                    observation.target_ra_deg,
                    observation.target_dec_deg,
                )
                .await
                {
                    Ok(measured) => {
                        observation.solve = measured.solve;
                        observation.background_adu = measured.background_adu;
                        observation.field_short_side_arcmin = measured.field_short_side_arcmin;
                    }
                    Err(e) => tracing::warn!(
                        "[FRAME_WATCH] {} could not be measured: {}",
                        observation.save_path,
                        e
                    ),
                }
                if measured_tx.send(observation).is_err() {
                    break;
                }
            }
        });
        Self {
            events,
            jobs,
            measured,
            watch: FrameWatch::new(config),
            sequence,
            recent: VecDeque::new(),
            clock: tokio::time::Instant::now(),
            recenters_without_success: 0,
            recenter_limit_told: false,
            pending_frames: 0,
            autofocus_hold_told: false,
            frame_targets: std::collections::HashMap::new(),
            verified_pointing: None,
        }
    }

    /// One tick: queue newly saved frames, judge the measured ones and act.
    /// Returns the run's end when a confirmed obstruction ended the night.
    pub(super) async fn tick(
        &mut self,
        dispatcher: &mut Dispatcher,
        mode: RunMode,
    ) -> Option<Vec<(String, RecoveryAction)>> {
        self.queue_saved_frames(dispatcher).await;
        while let Ok(observation) = self.measured.try_recv() {
            self.pending_frames -= 1;
            let verdict = self.watch.observe(&observation);
            if let (Some(ra), Some(dec), Some(side)) = (
                observation.target_ra_deg,
                observation.target_dec_deg,
                observation.pier_side.as_ref(),
            ) {
                if verdict.offset_arcmin.is_some() && !verdict.off_target {
                    self.verified_pointing = Some((ra, dec, side.clone()));
                } else if verdict.off_target {
                    self.verified_pointing = None;
                }
            }
            self.report(dispatcher, &observation, &verdict);
            self.update_autofocus_hold(dispatcher, &verdict).await;
            if verdict.offset_arcmin.is_some() && !verdict.off_target {
                self.recenters_without_success = 0;
                self.recenter_limit_told = false;
            }
            for action in verdict.actions.clone() {
                if let Some(end) = self.act(dispatcher, mode, &observation, action).await {
                    return Some(end);
                }
            }
        }
        self.tell_held_autofocus(dispatcher).await;
        None
    }

    /// Drain final saved frames without moving the rig after the node tree
    /// finishes. Called on monitor ticks, keeping its heartbeat responsive.
    pub(super) async fn finish_tick(&mut self, dispatcher: &Dispatcher) -> bool {
        self.queue_saved_frames(dispatcher).await;
        while let Ok(observation) = self.measured.try_recv() {
            self.pending_frames -= 1;
            let verdict = self.watch.observe(&observation);
            self.report(dispatcher, &observation, &verdict);
        }
        self.pending_frames == 0
    }

    async fn queue_saved_frames(&mut self, dispatcher: &Dispatcher) {
        loop {
            let event = match self.events.try_recv() {
                Ok(event) => event,
                Err(broadcast::error::TryRecvError::Lagged(missed)) => {
                    tracing::warn!(
                        "[FRAME_WATCH] {} run events were missed; frames saved in them are \
                         not measured",
                        missed
                    );
                    continue;
                }
                Err(_) => return,
            };
            let ExecutorEvent::NodeProgress {
                structured_detail: Some(detail),
                ..
            } = event
            else {
                continue;
            };
            let (path, accepted, reason, hfr, eccentricity, star_count, capture) = match *detail {
                ProgressDetail::FrameAccepted {
                    save_path: Some(path),
                    hfr,
                    eccentricity,
                    star_count,
                    capture,
                    ..
                } => (path, true, None, hfr, eccentricity, star_count, capture),
                ProgressDetail::FrameRejected {
                    reject_path,
                    reason,
                    hfr,
                    eccentricity,
                    star_count,
                    capture,
                    ..
                } => (
                    reject_path,
                    false,
                    Some(reason),
                    hfr,
                    eccentricity,
                    star_count,
                    capture,
                ),
                _ => continue,
            };
            let is_light = capture.frame_type.eq_ignore_ascii_case("light")
                || capture.frame_type.eq_ignore_ascii_case("snapshot");
            if path.is_empty() || !is_light {
                continue;
            }
            let state = dispatcher.rig.trigger_state.read().await;
            let window = std::time::Duration::from_secs_f64(capture.exposure_secs.max(0.0) + 10.0);
            let (guide_rms, guide_rms_samples) = state
                .guiding_rms_history
                .as_deref()
                .map(|history| assess::guide_rms_over(history, window))
                .unwrap_or((None, 0));
            // A frame saved as its target ended is reported after the run has
            // moved on: judge it against the target it was taken on.
            let (target_name, target_ra_deg, target_dec_deg) = self.frame_target(
                capture.target_id.as_deref(),
                (
                    state.current_target_name.clone(),
                    state.target_ra,
                    state.target_dec,
                ),
            );
            let observation = FrameObservation {
                save_path: path,
                target_name,
                target_id: capture.target_id.clone(),
                filter: state.current_filter.clone(),
                exposure_secs: capture.exposure_secs,
                exposure_started_secs: self.clock.elapsed().as_secs_f64() - capture.exposure_secs,
                accepted_by_grader: accepted,
                grader_reason: reason,
                star_count,
                hfr,
                eccentricity,
                altitude_deg: capture.mount_altitude_deg,
                azimuth_deg: capture.mount_azimuth_deg,
                pier_side: capture.pier_side.clone(),
                solve: SolveOutcome::NotAttempted,
                target_ra_deg,
                target_dec_deg,
                field_short_side_arcmin: None,
                background_adu: None,
                guide_rms,
                guide_rms_samples,
                guiding_lost: guiding_lost(&state),
                mount_not_tracking: state.mount_is_tracking == Some(false),
            };
            drop(state);
            // Until the frame is measured, a grader reject for trailed or lost
            // stars already holds autofocus, so a sweep due at this frame's end
            // does not start on it.
            if let Some(reason) = observation
                .grader_reason
                .as_deref()
                .filter(|_| !observation.accepted_by_grader)
                .and_then(provisional_hold_reason)
            {
                dispatcher.rig.trigger_state.write().await.autofocus_hold = Some(reason);
            }
            if self.jobs.send(FrameJob { observation }).is_ok() {
                self.pending_frames += 1;
            }
        }
    }

    /// The target a frame was taken on: the one its capture names, as first
    /// seen while it was current, else the current one.
    fn frame_target(&mut self, target_id: Option<&str>, current: FrameTarget) -> FrameTarget {
        let Some(id) = target_id else {
            return current;
        };
        let target = self
            .sequence
            .as_ref()
            .and_then(|sequence| sequence.nodes.iter().find(|node| node.id == id))
            .and_then(|node| match &node.node_type {
                crate::NodeType::TargetHeader(header)
                    if current.0.as_deref() != Some(header.target_name.as_str()) =>
                {
                    Some((
                        Some(header.target_name.clone()),
                        Some(header.ra_hours * 15.0),
                        Some(header.dec_degrees),
                    ))
                }
                _ => None,
            })
            .unwrap_or(current);
        self.frame_targets
            .entry(id.to_string())
            .or_insert(target)
            .clone()
    }

    fn report(&mut self, dispatcher: &Dispatcher, obs: &FrameObservation, verdict: &FrameVerdict) {
        let (solved_ra_deg, solved_dec_deg, solved_rotation_deg, solved_pixel_scale) =
            match obs.solve {
                SolveOutcome::Solved {
                    ra_deg,
                    dec_deg,
                    rotation_deg,
                    pixel_scale_arcsec,
                } => (
                    Some(ra_deg),
                    Some(dec_deg),
                    Some(rotation_deg),
                    Some(pixel_scale_arcsec),
                ),
                _ => (None, None, None, None),
            };
        let assessed = FrameAssessed {
            save_path: obs.save_path.clone(),
            filter: obs.filter.clone(),
            exposure_secs: obs.exposure_secs,
            was_accepted: obs.accepted_by_grader,
            solve_attempted: !matches!(obs.solve, SolveOutcome::NotAttempted),
            plate_solved: solved_ra_deg.is_some(),
            solved_ra_deg,
            solved_dec_deg,
            solved_rotation_deg,
            solved_pixel_scale,
            offset_arcmin: verdict.offset_arcmin,
            guide_rms_total: obs.guide_rms,
            guide_rms_samples: obs.guide_rms_samples,
            background_adu: obs.background_adu,
            star_count: obs.star_count,
            altitude_deg: obs.altitude_deg,
            azimuth_deg: obs.azimuth_deg,
            pier_side: obs.pier_side.clone(),
            off_target: verdict.off_target,
            obstructed: verdict.obstructed,
            exclusion_reason: verdict.exclusion_reason.clone(),
        };
        tracing::info!(
            "[FRAME_WATCH] {}: solved={} offset={:?} arcmin stars={:?} ratio={:?} bg={:?} \
             guide_rms={:?} ({} samples){}",
            assessed.save_path,
            assessed.plate_solved,
            assessed.offset_arcmin.map(|o| (o * 10.0).round() / 10.0),
            assessed.star_count,
            verdict.star_ratio.map(|r| (r * 100.0).round() / 100.0),
            assessed.background_adu,
            assessed.guide_rms_total,
            assessed.guide_rms_samples,
            assessed
                .exclusion_reason
                .as_deref()
                .map(|r| format!("; {r}"))
                .unwrap_or_default(),
        );
        dispatcher.run.send(ExecutorEvent::FrameWatch(Box::new(
            FrameWatchEvent::FrameAssessed(assessed.clone()),
        )));
        self.recent.push_back(assessed);
        while self.recent.len() > RECENT_FRAMES {
            self.recent.pop_front();
        }
    }

    async fn act(
        &mut self,
        dispatcher: &mut Dispatcher,
        mode: RunMode,
        obs: &FrameObservation,
        action: WatchAction,
    ) -> Option<Vec<(String, RecoveryAction)>> {
        match action {
            WatchAction::Recenter {
                offset_arcmin,
                limit_arcmin,
                ra_deg,
                dec_deg,
            } => {
                self.recenter(
                    dispatcher,
                    mode,
                    obs,
                    offset_arcmin,
                    limit_arcmin,
                    (ra_deg, dec_deg),
                )
                .await;
                None
            }
            WatchAction::PossibleObstructionOrCloud { at, frames } => {
                let message = format!(
                    "Possible obstruction or cloud at {}: the last {frames} frames of {} kept \
                     less than half of their stars. Imaging continues and the frames are graded \
                     as usual.",
                    at.describe(),
                    obs.target_name.as_deref().unwrap_or("the target"),
                );
                self.notice(dispatcher, "Possible obstruction or cloud", message, at);
                None
            }
            WatchAction::Recovered { frames } => {
                let message = format!(
                    "Stars are back on {} after {frames} frames that had lost them.",
                    obs.target_name.as_deref().unwrap_or("the target"),
                );
                tracing::info!("[FRAME_WATCH] {}", message);
                dispatcher.run.warning(message);
                None
            }
            WatchAction::Probe { onset } => {
                if !mode.is_running() {
                    // Probed for again on the next collapsed frame.
                    self.watch.probe_result(false);
                    return None;
                }
                let flight = dispatcher.action_in_flight.clone();
                let _flight = TriggerActionInFlightGuard::new(&flight);
                let mut claim = TriggerCameraClaim::acquire(
                    &dispatcher.rig.trigger_state,
                    &dispatcher.run.is_cancelled,
                    &RecoveryAction::Recenter,
                )
                .await;
                if dispatcher.run.is_cancelled() {
                    return None;
                }
                match self.probe(dispatcher, onset).await {
                    Err(problem) => {
                        // Not knowing is not cloud and not trees: carry on, and
                        // probe again on a later collapsed frame.
                        self.watch.probe_result(false);
                        let message = format!(
                            "Possible obstruction at {}: the check of the sky higher up did not \
                             run ({problem}). Imaging continues on {}.",
                            onset.describe(),
                            obs.target_name.as_deref().unwrap_or("the target"),
                        );
                        self.notice(dispatcher, "Obstruction check failed", message, onset);
                        self.recenter_after_probe(dispatcher, &mut claim).await
                    }
                    Ok(stars_found) => match self.watch.probe_result(stars_found) {
                        Some(WatchAction::Obstruction { onset, learned }) => {
                            self.obstruction(dispatcher, obs, onset, learned, &mut claim)
                                .await
                        }
                        _ => {
                            let message = format!(
                                "The sky above {} was starless too, so the lost stars look like \
                                 cloud, not an obstruction. Imaging continues on {}.",
                                onset.describe(),
                                obs.target_name.as_deref().unwrap_or("the target"),
                            );
                            self.notice(dispatcher, "Cloud, not an obstruction", message, onset);
                            self.recenter_after_probe(dispatcher, &mut claim).await
                        }
                    },
                }
            }
            WatchAction::Obstruction { onset, learned } => {
                if !mode.is_running() {
                    return None;
                }
                let flight = dispatcher.action_in_flight.clone();
                let _flight = TriggerActionInFlightGuard::new(&flight);
                let mut claim = TriggerCameraClaim::acquire(
                    &dispatcher.rig.trigger_state,
                    &dispatcher.run.is_cancelled,
                    &RecoveryAction::Recenter,
                )
                .await;
                if dispatcher.run.is_cancelled() {
                    return None;
                }
                self.obstruction(dispatcher, obs, onset, learned, &mut claim)
                    .await
            }
        }
    }

    async fn recenter(
        &mut self,
        dispatcher: &mut Dispatcher,
        mode: RunMode,
        obs: &FrameObservation,
        offset_arcmin: f64,
        limit_arcmin: f64,
        reference: (f64, f64),
    ) {
        let clock = self.clock;
        let done_at = move || clock.elapsed().as_secs_f64();
        if !mode.is_running() {
            self.watch.recentered(done_at());
            return;
        }
        if self.recenters_without_success >= MAX_RECENTERS_WITHOUT_SUCCESS {
            if !self.recenter_limit_told {
                self.recenter_limit_told = true;
                let message = format!(
                    "{} is still {offset_arcmin:.1} arcmin from the target after \
                     {MAX_RECENTERS_WITHOUT_SUCCESS} recenters. No more recenters are tried \
                     until a frame lands back on target; off-target frames do not count as \
                     integration.",
                    file_label(&obs.save_path)
                );
                tracing::warn!("[FRAME_WATCH] {}", message);
                dispatcher.run.warning(message);
            }
            self.watch.recentered(done_at());
            return;
        }
        let (Some(target_ra_deg), Some(target_dec_deg)) = (obs.target_ra_deg, obs.target_dec_deg)
        else {
            self.watch.recentered(done_at());
            return;
        };
        self.recenters_without_success += 1;
        let reference_label = if self.watch.config().use_first_frame_reference {
            "the first frame"
        } else {
            "the target"
        };
        let message = format!(
            "{} is {offset_arcmin:.1} arcmin from {reference_label} (limit {limit_arcmin:.1} arcmin). \
             Recentering before the next frame; frames this far off do not count as \
             integration.",
            file_label(&obs.save_path)
        );
        tracing::warn!("[FRAME_WATCH] {}", message);
        dispatcher.run.warning(message);
        let _ = dispatcher
            .run_frame_recenter(
                TARGET_DRIFT_TRIGGER_ID,
                "Recenter after drift",
                super::actions::recenter::FrameReference {
                    target_ra_deg,
                    target_dec_deg,
                    ra_deg: reference.0,
                    dec_deg: reference.1,
                },
            )
            .await;
        self.watch.recentered(done_at());
    }

    /// Point higher in the sky at the obstruction's azimuth and take one
    /// solve frame. `Ok(true)` when it solved (the sky there has stars),
    /// `Ok(false)` when the solver found nothing, and `Err` when the check
    /// could not be made.
    async fn probe(
        &mut self,
        dispatcher: &mut Dispatcher,
        onset: Pointing,
    ) -> Result<bool, String> {
        let rig = &dispatcher.rig;
        let run = &dispatcher.run;
        let (lat, lon) = {
            let rc = rig.runtime_config.read();
            (
                rc.latitude.or(rig.context.latitude),
                rc.longitude.or(rig.context.longitude),
            )
        };
        let (Some(lat), Some(lon)) = (lat, lon) else {
            return Err("no observer location is set".to_string());
        };
        let altitude = (onset.altitude_deg + PROBE_ALTITUDE_GAIN_DEG).min(PROBE_MAX_ALTITUDE_DEG);
        let (ra_hours, dec_deg) = alt_az_to_ra_dec(altitude, onset.azimuth_deg, lat, lon);
        let message = format!(
            "Checking the sky higher up (alt {altitude:.1}°, az {:.1}°) to tell an obstruction \
             from cloud.",
            onset.azimuth_deg
        );
        tracing::info!("[FRAME_WATCH] {}", message);
        run.warning(message);
        let probe_ctx = rig.instruction_context(
            TargetSnapshot {
                name: Some("Obstruction check".to_string()),
                ra_hours: Some(ra_hours),
                dec_degrees: Some(dec_deg),
                filter: None,
            },
            run,
        );
        let slew = crate::instructions::execute_slew(
            &crate::SlewConfig {
                use_target_coords: false,
                custom_ra: Some(ra_hours),
                custom_dec: Some(dec_deg),
            },
            &probe_ctx,
            None,
        )
        .await;
        let outcome = if slew.status != NodeStatus::Success {
            Err(format!(
                "the slew failed: {}",
                slew.message.unwrap_or_default()
            ))
        } else {
            let center = crate::instructions::execute_center(
                &crate::CenterConfig {
                    use_target_coords: false,
                    custom_ra: Some(ra_hours),
                    custom_dec: Some(dec_deg),
                    accuracy_arcsec: 3600.0,
                    max_attempts: 1,
                    exposure_duration: PROBE_EXPOSURE_SECS,
                    filter: None,
                },
                &probe_ctx,
                None,
            )
            .await;
            if center.status == NodeStatus::Success {
                Ok(true)
            } else if crate::instructions::center_did_not_converge(&center) {
                Ok(false)
            } else {
                Err(center.message.unwrap_or_default())
            }
        };
        outcome
    }

    /// Back onto the target after a probe that found cloud: slew, then the
    /// usual recenter.
    async fn recenter_after_probe(
        &mut self,
        dispatcher: &mut Dispatcher,
        claim: &mut TriggerCameraClaim,
    ) -> Option<Vec<(String, RecoveryAction)>> {
        let flow = dispatcher
            .recenter_holding_claim(PROBE_RETURN_TRIGGER_ID, "Back on target", claim)
            .await;
        self.watch.recentered(self.clock.elapsed().as_secs_f64());
        match flow {
            Flow::Next => None,
            Flow::Terminate(fired) => Some(fired),
        }
    }

    async fn obstruction(
        &mut self,
        dispatcher: &mut Dispatcher,
        obs: &FrameObservation,
        onset: Pointing,
        learned: bool,
        claim: &mut TriggerCameraClaim,
    ) -> Option<Vec<(String, RecoveryAction)>> {
        let pointing = obs
            .target_ra_deg
            .zip(obs.target_dec_deg)
            .zip(obs.pier_side.clone())
            .map(|((ra, dec), side)| (ra, dec, side));
        if pointing.is_none() || self.verified_pointing != pointing {
            self.watch.discard_unverified_obstruction();
            let message = "Target pointing has not been verified on this pier side. The apparent obstruction will not be saved to the horizon; acquisition must be recovered first.".to_string();
            self.notice(
                dispatcher,
                "Unverified target pointing",
                message.clone(),
                onset,
            );
            return self.recenter_after_probe(dispatcher, claim).await;
        }
        let (lat, lon) = {
            let rc = dispatcher.rig.runtime_config.read();
            (
                rc.latitude.or(dispatcher.rig.context.latitude),
                rc.longitude.or(dispatcher.rig.context.longitude),
            )
        };
        let next = match (lat, lon) {
            (Some(lat), Some(lon)) => after_obstruction(
                self.sequence.as_ref(),
                obs.target_name.as_deref(),
                self.watch.config(),
                lat,
                lon,
                chrono::Utc::now(),
            ),
            _ => AfterObstruction::NextTarget(None),
        };
        // Ending the night on one probe could be a gap in passing cloud.
        // Unless an earlier night saw this obstruction, it is checked again
        // with a new run of starless frames and a new probe first.
        if matches!(next, AfterObstruction::EndOfNight)
            && !learned
            && !self.watch.confirm_before_ending()
        {
            let message = format!(
                "Possible obstruction: {} looks blocked from {} on and no other target in \
                 the plan is up and clear. Imaging continues; the sky is checked once more \
                 before the night is ended.",
                obs.target_name.as_deref().unwrap_or("the target"),
                onset.describe()
            );
            self.notice(dispatcher, "Obstruction to be confirmed", message, onset);
            return self.recenter_after_probe(dispatcher, claim).await;
        }
        // The frames that led up to the confirmation are obstructed too.
        let reason = crate::frame_watch::classify::obstructed_reason(onset);
        for path in self.watch.streak_paths() {
            if let Some(frame) = self.recent.iter_mut().find(|f| f.save_path == path) {
                frame.obstructed = true;
                frame.exclusion_reason = Some(reason.clone());
                dispatcher.run.send(ExecutorEvent::FrameWatch(Box::new(
                    FrameWatchEvent::FrameAssessed(frame.clone()),
                )));
            }
        }
        if !learned {
            self.watch.learn(HorizonPoint::from(onset));
        }

        let target = obs.target_name.as_deref().unwrap_or("the target");
        let seen = if learned {
            "where an obstruction was learned before"
        } else {
            "and the sky higher up has stars"
        };
        let (action, message) = match &next {
            AfterObstruction::NextTarget(Some(name)) => (
                "next_target",
                format!(
                    "Obstruction: {target} is blocked from {} on ({seen}). Moving on to {name}; \
                     this patch of sky is saved to the site's horizon.",
                    onset.describe()
                ),
            ),
            AfterObstruction::NextTarget(None) => (
                "next_target",
                format!(
                    "Obstruction: {target} is blocked from {} on ({seen}). Moving on to the \
                     next target; this patch of sky is saved to the site's horizon.",
                    onset.describe()
                ),
            ),
            AfterObstruction::EndOfNight => (
                "end_of_night",
                format!(
                    "Obstruction: {target} is blocked from {} on ({seen}) and no other target \
                     in the plan is up and clear. Imaging is over for the night; the \
                     end-of-night steps run now. This patch of sky is saved to the site's \
                     horizon.",
                    onset.describe()
                ),
            ),
        };
        tracing::warn!("[FRAME_WATCH] {}", message);
        dispatcher.run.warning(message.clone());
        if let Err(e) = dispatcher
            .rig
            .device_ops
            .send_notification("warning", "Obstruction", &message, None)
            .await
        {
            tracing::warn!(
                "[FRAME_WATCH] The obstruction notification was not sent: {}",
                e
            );
        }
        dispatcher
            .decisions
            .send(crate::decision::DecisionEvent::new(
                crate::decision::DecisionCategory::SystemEvent,
                "Obstruction confirmed".to_string(),
                serde_json::json!({
                    "target": obs.target_name,
                    "altitude_deg": onset.altitude_deg,
                    "azimuth_deg": onset.azimuth_deg,
                    "learned_before": learned,
                    "action": action,
                }),
            ));
        dispatcher.run.send(ExecutorEvent::FrameWatch(Box::new(
            FrameWatchEvent::HorizonObstruction(HorizonObstructionReport {
                altitude_deg: onset.altitude_deg,
                azimuth_deg: onset.azimuth_deg,
                target_name: obs.target_name.clone(),
                latitude: lat,
                longitude: lon,
                verdict: "obstruction".to_string(),
                action: action.to_string(),
                message,
            }),
        )));

        match next {
            AfterObstruction::NextTarget(_) => {
                let _ = dispatcher
                    .run_synthetic(
                        OBSTRUCTION_SKIP_TRIGGER_ID,
                        "Obstruction",
                        FiredTriggerAction {
                            action: RecoveryAction::NextTarget,
                            end_without_parking: false,
                            notify_only: false,
                        },
                    )
                    .await;
                None
            }
            AfterObstruction::EndOfNight => {
                // Parked or not as the operator set for the end of the night.
                let park_before_dawn = dispatcher
                    .rig
                    .runtime_config
                    .read()
                    .park_policy
                    .park_before_dawn;
                match dispatcher
                    .run_synthetic(
                        OBSTRUCTION_TRIGGER_ID,
                        "Obstruction",
                        FiredTriggerAction {
                            action: RecoveryAction::ParkAndAbort,
                            end_without_parking: !park_before_dawn,
                            notify_only: false,
                        },
                    )
                    .await
                {
                    Flow::Terminate(fired) => Some(fired),
                    Flow::Next => None,
                }
            }
        }
    }

    fn notice(&self, dispatcher: &Dispatcher, summary: &str, message: String, at: Pointing) {
        tracing::warn!("[FRAME_WATCH] {}", message);
        dispatcher.run.warning(message);
        dispatcher
            .decisions
            .send(crate::decision::DecisionEvent::new(
                crate::decision::DecisionCategory::SystemEvent,
                summary.to_string(),
                serde_json::json!({
                    "altitude_deg": at.altitude_deg,
                    "azimuth_deg": at.azimuth_deg,
                }),
            ));
    }

    async fn update_autofocus_hold(&mut self, dispatcher: &Dispatcher, verdict: &FrameVerdict) {
        let mut state = dispatcher.rig.trigger_state.write().await;
        let was_held = state.autofocus_hold.is_some();
        state.autofocus_hold = verdict.degraded.clone();
        if was_held && state.autofocus_hold.is_none() {
            let wanted = std::mem::take(&mut state.autofocus_wanted_while_held);
            drop(state);
            if self.autofocus_hold_told && wanted {
                let message =
                    "Frames have recovered; the autofocus that was waiting runs now.".to_string();
                tracing::info!("[FRAME_WATCH] {}", message);
                dispatcher.run.warning(message);
            }
            self.autofocus_hold_told = false;
        }
    }

    /// Tell the operator once per hold that an autofocus is waiting.
    async fn tell_held_autofocus(&mut self, dispatcher: &Dispatcher) {
        if self.autofocus_hold_told {
            return;
        }
        let reason = {
            let state = dispatcher.rig.trigger_state.read().await;
            match (&state.autofocus_hold, state.autofocus_wanted_while_held) {
                (Some(reason), true) => reason.clone(),
                _ => return,
            }
        };
        self.autofocus_hold_told = true;
        let message = format!(
            "Autofocus is due but waits: {reason}, and a sweep on those stars would move focus \
             the wrong way. It runs once a frame comes back clean."
        );
        tracing::warn!("[FRAME_WATCH] {}", message);
        dispatcher.run.warning(message);
    }
}

/// The autofocus hold a grader reject implies before the frame is measured.
fn provisional_hold_reason(grader_reason: &str) -> Option<String> {
    if grader_reason.contains("eccentricity") {
        Some("the last frame's stars were trailed".to_string())
    } else if grader_reason.contains("star count") || grader_reason.contains("no stars") {
        Some("the last frame lost most of its stars".to_string())
    } else {
        None
    }
}

fn file_label(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

#[cfg(test)]
mod guiding_lost_tests {
    use super::guiding_lost;
    use crate::triggers::{GuideRecoveryFailure, GuideRecoveryStall, TriggerState};

    fn stall(pointings: &[(f64, f64)]) -> GuideRecoveryStall {
        GuideRecoveryStall {
            origin: None,
            failures: pointings
                .iter()
                .enumerate()
                .map(|(i, &alt_az)| GuideRecoveryFailure {
                    at_unix: 1_000 + 60 * i as i64,
                    alt_az_deg: Some(alt_az),
                })
                .collect(),
        }
    }

    #[test]
    fn a_guide_recovery_stalled_at_one_pointing_marks_the_frame_guiding_lost() {
        let mut state = TriggerState::new();
        assert!(!guiding_lost(&state));

        state.guide_recovery = Some(stall(&[(64.1, 286.0)]));
        assert!(
            !guiding_lost(&state),
            "one failed attempt is not yet a stall"
        );

        state.guide_recovery = Some(stall(&[(64.1, 286.0), (64.0, 286.3)]));
        assert!(guiding_lost(&state));
    }

    #[test]
    fn failures_spread_across_the_sky_are_not_a_stall() {
        let mut state = TriggerState::new();
        state.guide_recovery = Some(stall(&[(64.0, 286.0), (40.0, 200.0)]));
        assert!(!guiding_lost(&state));
    }
}
