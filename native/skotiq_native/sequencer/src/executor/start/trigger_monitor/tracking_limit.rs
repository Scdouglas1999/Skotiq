//! Adopt an unexpected stop near the meridian before ordinary tracking or
//! guide-star recovery can restart the mount into its limit. The monitor
//! keeps polling safety throughout; its flip action owns the actual move.
//! Under the default [`crate::TrackingLimitPolicy::FlipEarly`] that move comes
//! at once; otherwise the hold waits for the configured flip window.

use super::{dispatch::Dispatcher, *};
use crate::triggers::{tracking_limit_flip_threshold, tracking_limit_recovery_candidate, RunHold};
use std::time::Duration;

/// How long a hold may outlast the moment its flip was due before it gives up
/// and hands the run to the operator.
const HOLD_OVERRUN: Duration = Duration::from_secs(15 * 60);
/// Hour angle advances this many sidereal seconds per solar second.
const SIDEREAL_RATE: f64 = 1.002_737_909;

pub(super) struct TrackingLimitHold {
    target: (Option<f64>, Option<f64>),
    deadline: tokio::time::Instant,
    /// When an operator pause began. Paused time does not count against the
    /// deadline: the hold resumes where it was.
    paused_at: Option<tokio::time::Instant>,
    /// The last tick the run was running, where a pause is counted from.
    last_running: tokio::time::Instant,
    /// The deadline already accounts for a refused early flip.
    refusal_seen: bool,
}

/// Seconds until a waiting hold's flip comes due at `hour_angle`.
fn secs_until_window(config: &crate::MeridianFlipConfig, hour_angle: f64) -> f64 {
    (tracking_limit_flip_threshold(config) - hour_angle).max(0.0) * 3600.0 / SIDEREAL_RATE
}

fn relative_to_meridian(hour_angle: f64) -> String {
    let minutes = (hour_angle * 60.0).abs().round();
    if hour_angle < 0.0 {
        format!("{minutes:.0} min before the meridian")
    } else {
        format!("{minutes:.0} min past the meridian")
    }
}

impl Dispatcher {
    pub(super) async fn update_tracking_limit_hold(&mut self, calibration_run: bool) {
        if self.run.is_cancelled() {
            return;
        }
        let executor_state = *self.run.executor_state.read().await;
        let config = {
            let manager = self.trigger_manager.read().await;
            manager.active_meridian_flip_config()
        };
        let state = self.rig.trigger_state.read().await.clone();
        if let Some(hold) = &mut self.tracking_limit_hold {
            // An operator pause takes priority over the automatic hold. Keep
            // the hold latched so Resume cannot bypass it, and stop its clock.
            if executor_state != ExecutorState::Running {
                hold.paused_at.get_or_insert(hold.last_running);
                return;
            }
            if let Some(paused_at) = hold.paused_at.take() {
                hold.deadline += paused_at.elapsed();
            }
            hold.last_running = tokio::time::Instant::now();
            if state.run.early_flip_refused() && !hold.refusal_seen {
                hold.refusal_seen = true;
                if let (Some(config), Some(ha)) = (&config, state.current_hour_angle) {
                    hold.deadline = tokio::time::Instant::now()
                        + Duration::from_secs_f64(secs_until_window(config, ha))
                        + HOLD_OVERRUN;
                }
            }
            self.run.hold_node_tree();
            let flipped = state.meridian.has_flipped();
            let problem = if (state.target_ra, state.target_dec) != hold.target {
                Some("The target changed during tracking-limit recovery.")
            } else if state.mount_parked == Some(true) {
                Some("The mount was parked during tracking-limit recovery.")
            } else if state.mount_slewing == Some(true) && !flipped {
                Some("The mount started moving during tracking-limit recovery.")
            } else if config.is_none() && !flipped {
                Some("Automatic meridian flipping was disabled during tracking-limit recovery.")
            } else if !flipped && tokio::time::Instant::now() >= hold.deadline {
                Some("The mount was not flipped within the expected time.")
            } else {
                None
            };
            if let Some(problem) = problem {
                self.abandon_tracking_limit_hold(problem).await;
                return;
            }
            if flipped {
                self.finish_tracking_limit_hold().await;
            }
            return;
        }

        let handed_off = state.run.hold() == Some(RunHold::TrackingLimit);
        if calibration_run
            || executor_state != ExecutorState::Running
            || (state.run.is_held_by_run() && !handed_off)
            || (!handed_off && !tracking_limit_recovery_candidate(&state))
        {
            return;
        }
        let Some(config) = config else {
            if handed_off {
                self.rig.trigger_state.write().await.run.end_hold();
                let message =
                    "Tracking-limit recovery requires an enabled meridian flip. Sequence paused."
                        .to_string();
                self.run.warning(message.clone());
                self.run.pause(Some(message)).await;
            }
            return;
        };
        let Some(hour_angle) = state.current_hour_angle.filter(|ha| ha.is_finite()) else {
            let message =
                "Tracking-limit recovery lost the target hour angle. Sequence paused.".to_string();
            self.run.warning(message.clone());
            self.run.pause(Some(message)).await;
            return;
        };
        let flip_early = config.tracking_limit_policy == crate::TrackingLimitPolicy::FlipEarly;
        let limit_wait_secs =
            if config.trigger_method == crate::MeridianTriggerMethod::OnTrackingLimitHit {
                config.tracking_limit_wait_minutes.max(0.0) * 60.0
            } else {
                0.0
            };
        let wait_secs = if flip_early {
            limit_wait_secs
        } else {
            secs_until_window(&config, hour_angle).max(limit_wait_secs)
        };
        if !wait_secs.is_finite() {
            return;
        }
        self.tracking_limit_hold = Some(TrackingLimitHold {
            target: (state.target_ra, state.target_dec),
            deadline: tokio::time::Instant::now()
                + Duration::from_secs_f64(wait_secs)
                + HOLD_OVERRUN,
            paused_at: None,
            last_running: tokio::time::Instant::now(),
            refusal_seen: false,
        });
        self.run.hold_node_tree();
        self.rig
            .trigger_state
            .write()
            .await
            .run
            .begin_hold(RunHold::TrackingLimit);
        // Stop corrections against the limit. The flip's normal guider resume
        // restores the run's guiding after its slew and recenter.
        if state.guiding.is_enabled() {
            if let Err(error) = bounded_poll("guider_stop", self.rig.device_ops.guider_stop()).await
            {
                let message =
                    format!("Could not stop guiding for tracking-limit recovery: {error}");
                self.run.warning(message.clone());
                self.run.pause(Some(message)).await;
                return;
            }
            self.rig
                .trigger_state
                .write()
                .await
                .guiding
                .guiding_stopped_by_motion();
        }
        let next = if flip_early {
            "Exposures and guiding are held and the mount flips to the east side now.".to_string()
        } else {
            format!(
                "Exposures and guiding are held until the flip window ({:.0} min past the \
                 meridian, about {:.0} min away); tracking stays off until the flip.",
                tracking_limit_flip_threshold(&config) * 60.0,
                wait_secs / 60.0,
            )
        };
        let message = format!(
            "Mount tracking stopped {} on the west side of the pier, read as the mount's own \
             tracking limit. {next} A frame that was exposing is marked rejected. If you \
             stopped tracking yourself, pause or stop the run.",
            relative_to_meridian(hour_angle),
        );
        tracing::warn!("[MERIDIAN] {}", message);
        self.run.progress.write().message = Some(message.clone());
        self.run.warning(message);
    }

    /// End a hold that cannot finish on its own and hand the run to the
    /// operator. The tracking loss is recorded again, so Resume adopts the
    /// stop afresh instead of imaging on a stopped mount.
    async fn abandon_tracking_limit_hold(&mut self, problem: &str) {
        self.tracking_limit_hold = None;
        {
            let mut state = self.rig.trigger_state.write().await;
            state.run.end_hold();
            let detected = state.tracking.limit_detected_at();
            state.tracking.restore(true, true, detected);
            state.mount_is_tracking = Some(false);
        }
        let message = format!(
            "{problem} Sequence paused; the mount has not been flipped and tracking is off. \
             Resume to try again."
        );
        tracing::warn!("[MERIDIAN] {}", message);
        self.run.warning(message.clone());
        self.run.pause(Some(message)).await;
    }

    /// The flip ran. Release frames only onto a mount that really tracks; a
    /// mount that does not is handed to tracking recovery, which keeps trying.
    async fn finish_tracking_limit_hold(&mut self) {
        let tracking = match self.rig.context.mount_id.as_deref() {
            Some(id) => {
                crate::tracking_check::confirm_mount_tracks(
                    &self.rig.device_ops,
                    id,
                    crate::tracking_check::TRACKING_CHECK_WINDOW,
                )
                .await
            }
            None => Err(crate::tracking_check::NotTracking::Unreadable(
                "no mount is configured".to_string(),
            )),
        };
        self.tracking_limit_hold = None;
        if let Err(why) = tracking {
            {
                let mut state = self.rig.trigger_state.write().await;
                state.run.end_hold();
                state.set_mount_tracking_expected(true);
                state.tracking.mark_lost();
                state.mount_is_tracking = Some(false);
            }
            let message = format!(
                "The meridian flip finished, but the mount is not tracking ({why}). Recovering \
                 tracking before imaging resumes."
            );
            tracing::warn!("[MERIDIAN] {}", message);
            self.run.warning(message.clone());
            self.run.progress.write().message = Some(message);
            if self
                .recovery_tx
                .try_send(crate::recovery::RecoveryCause::MountTrackingLost)
                .is_err()
            {
                self.run
                    .pause(Some(
                        "The mount is not tracking after the meridian flip and tracking recovery \
                         could not start. Sequence paused."
                            .to_string(),
                    ))
                    .await;
            }
            return;
        }
        {
            let mut state = self.rig.trigger_state.write().await;
            state.run.end_hold();
            state.reset_tracking_limit_detection();
            state.set_mount_tracking_expected(true);
            state.mount_is_tracking = Some(true);
        }
        // A pause arriving during the device query must not be lifted.
        if *self.run.executor_state.read().await == ExecutorState::Running
            && !self.run.is_cancelled()
        {
            self.run.is_paused.store(false, Ordering::Relaxed);
            let message =
                "Tracking-limit recovery finished: the mount flipped and tracks again; imaging \
                 resumes."
                    .to_string();
            self.run.progress.write().message = Some(message.clone());
            self.run.warning(message);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::policy::{select_dispatches, DispatchPolicy};
    use super::*;
    use crate::device_ops::DeviceOps;
    use crate::executor::scenario_sim_tests::{ScriptedDeviceOps, SimMount};

    struct Harness {
        dispatcher: Dispatcher,
        ops: Arc<ScriptedDeviceOps>,
        recovery: mpsc::Receiver<crate::recovery::RecoveryCause>,
    }

    impl Harness {
        async fn new() -> Self {
            let ops = Arc::new(ScriptedDeviceOps::new());
            ops.flip_on_slew.store(true, Ordering::Relaxed);
            ops.mount_set_tracking("mount", false).await.unwrap();
            let mut manager = TriggerManager::new();
            manager.create_standard_triggers();
            manager.set_meridian_flip_config(crate::MeridianFlipConfig {
                minutes_past_meridian: 20.0,
                tracking_limit_policy: crate::TrackingLimitPolicy::WaitForFlipWindow,
                auto_center: true,
                max_retries: 0,
                settle_time: 0.0,
                guider_settle_time: 0.0,
                ..Default::default()
            });
            manager.sync_state_from_config().await;
            {
                let lock = manager.state();
                let mut s = lock.write().await;
                s.set_target(180.0, 45.0); // Null solver/mount fixture coordinates
                s.current_hour_angle = Some(-0.55);
                s.current_altitude = Some(83.0);
                s.weather_safe = true;
                s.pier_side = Some(crate::PierSide::West);
                s.mount_is_tracking = Some(false);
                s.mount_slewing = Some(false);
                s.mount_parked = Some(false);
                s.tracking
                    .restore(true, true, Some(chrono::Utc::now().timestamp()));
                s.set_guiding_enabled(true);
                s.set_guide_star_lost(true);
            }
            let (events, _) = broadcast::channel(128);
            let (decisions, _) = broadcast::channel(128);
            let (requests, recovery) = mpsc::channel(4);
            let (done, _) = watch::channel(false);
            let (_, quiesced) = watch::channel(true);
            let (heartbeat, _) = watch::channel(0);
            let dispatcher = Dispatcher::new(TriggerMonitorArgs {
                active_run_id_for_decisions: Arc::new(StdRwLock::new(None)),
                cloud_motion_for_recovery: Arc::new(RwLock::new(CloudMotionSnapshot::default())),
                custom_recovery_branches_for_triggers: Arc::new(HashMap::new()),
                custom_recovery_context_for_triggers: ExecutionContext::new(
                    "root".into(),
                    ops.clone(),
                ),
                decision_tx_for_lifecycle: decisions,
                device_ops_for_triggers: ops.clone(),
                event_tx_clone2: events,
                execution_quiesced_for_triggers: quiesced,
                heartbeat_tx: heartbeat,
                is_cancelled_clone: Arc::new(AtomicBool::new(false)),
                is_paused_for_triggers: Arc::new(AtomicBool::new(false)),
                meridian_flip_failed_for_triggers: Arc::new(AtomicBool::new(false)),
                meridian_flip_failure_for_triggers: Arc::new(StdRwLock::new(None)),
                park_and_abort_done_for_triggers: done,
                park_and_abort_for_triggers: Arc::new(AtomicBool::new(false)),
                progress_for_triggers: Arc::new(StdRwLock::new(SequenceProgress::default())),
                recovery_request_tx: requests,
                runtime_config: Arc::new(StdRwLock::new(RuntimeConfig::default())),
                sequence_for_custom_recovery_triggers: None,
                skip_to_next_target_for_triggers: Arc::new(AtomicBool::new(false)),
                skip_to_node_for_recovery: Arc::new(StdRwLock::new(None)),
                state_clone: Arc::new(RwLock::new(ExecutorState::Running)),
                transparency_backup_for_recovery: Arc::new(RwLock::new(None)),
                trigger_action_context: TriggerActionContext {
                    mount_id: Some("mount".into()),
                    camera_id: Some("camera".into()),
                    ..Default::default()
                },
                trigger_action_in_flight_for_triggers: Arc::new(AtomicBool::new(false)),
                trigger_manager: Arc::new(RwLock::new(manager)),
                triggers_enabled: true,
            })
            .await;
            Self {
                dispatcher,
                ops,
                recovery,
            }
        }

        /// The operator presses Resume.
        async fn resume(&mut self) {
            *self.dispatcher.run.executor_state.write().await = ExecutorState::Running;
            self.dispatcher.run.is_paused.store(false, Ordering::SeqCst);
        }

        fn flip_early(&self) -> crate::MeridianFlipConfig {
            crate::MeridianFlipConfig {
                minutes_past_meridian: 20.0,
                tracking_limit_policy: crate::TrackingLimitPolicy::FlipEarly,
                auto_center: true,
                max_retries: 0,
                settle_time: 0.0,
                guider_settle_time: 0.0,
                ..Default::default()
            }
        }

        async fn use_config(&mut self, config: crate::MeridianFlipConfig) {
            let mut manager = self.dispatcher.trigger_manager.write().await;
            manager.set_meridian_flip_config(config);
            manager.sync_state_from_config().await;
        }

        fn slews(&self) -> usize {
            self.ops.call_count("mount_slew:")
        }

        async fn tick(&mut self) {
            let d = &mut self.dispatcher;
            d.update_tracking_limit_hold(false).await;
            let executor = *d.run.executor_state.read().await;
            let hold = d.rig.trigger_state.read().await.run.hold();
            let mode = RunMode::new(executor, hold).unwrap();
            let dispatches = {
                let mut manager = d.trigger_manager.write().await;
                let fired = manager.check_all().await;
                select_dispatches(
                    &mut manager,
                    fired,
                    mode,
                    DispatchPolicy {
                        explicit_end: false,
                        calibration_run: false,
                        park_policy: ParkPolicy::default(),
                        stop_on_quality_problems: false,
                        weather_advisory_only: false,
                    },
                )
            };
            d.run_tick(mode, dispatches).await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_holds_then_flips_and_resumes() {
        let mut h = Harness::new().await;
        h.tick().await;
        assert!(h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        assert!(
            h.recovery.try_recv().is_err(),
            "guide-star recovery must not own a limit stop"
        );
        assert!(!h
            .ops
            .calls()
            .iter()
            .any(|c| c.starts_with("mount_slew:") || c.ends_with(":true")));
        // The monitor remains free to poll while the target crosses transit.
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.2);
        h.tick().await;
        assert!(!h.ops.calls().iter().any(|c| c.starts_with("mount_slew:")));
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.4);
        h.tick().await;
        h.tick().await; // release the node tree only after verified flip recovery
        assert!(
            h.dispatcher
                .rig
                .trigger_state
                .read()
                .await
                .meridian
                .has_flipped(),
            "{:?}",
            h.ops.calls()
        );
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        let calls = h.ops.calls();
        let slew = calls
            .iter()
            .position(|c| c.starts_with("mount_slew:"))
            .unwrap();
        let tracking_on: Vec<usize> = calls
            .iter()
            .enumerate()
            .filter(|(_, c)| *c == "mount_set_tracking:mount:true")
            .map(|(i, _)| i)
            .collect();
        let center = calls.iter().position(|c| c == "plate_solve").unwrap();
        let guiding = calls.iter().position(|c| c == "guider_start").unwrap();
        // The slew tracks, and tracking is confirmed on the new side before
        // the recenter and the guider.
        assert!(tracking_on[0] < slew, "{calls:?}");
        assert!(
            tracking_on.iter().any(|&i| slew < i && i < center) && center < guiding,
            "{calls:?}"
        );
        assert!(h.recovery.try_recv().is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_handles_each_trigger_method() {
        for method in [
            crate::MeridianTriggerMethod::MinutesBeforeLimit,
            crate::MeridianTriggerMethod::HourAngleThreshold,
            crate::MeridianTriggerMethod::OnTrackingLimitHit,
        ] {
            let mut h = Harness::new().await;
            h.dispatcher
                .trigger_manager
                .write()
                .await
                .set_meridian_flip_config(crate::MeridianFlipConfig {
                    trigger_method: method,
                    tracking_limit_policy: crate::TrackingLimitPolicy::WaitForFlipWindow,
                    hour_angle_threshold: 0.25,
                    tracking_limit_wait_minutes: 2.0,
                    max_retries: 0,
                    settle_time: 0.0,
                    guider_settle_time: 0.0,
                    ..Default::default()
                });
            h.tick().await;
            assert!(!h.ops.calls().iter().any(|c| c.starts_with("mount_slew:")));
            {
                let mut s = h.dispatcher.rig.trigger_state.write().await;
                s.current_hour_angle = Some(0.4);
                apply_mount_tracking_poll(&mut s, false);
            }
            if method == crate::MeridianTriggerMethod::OnTrackingLimitHit {
                h.tick().await;
                assert!(!h.ops.calls().iter().any(|c| c.starts_with("mount_slew:")));
            }
            h.dispatcher
                .rig
                .trigger_state
                .write()
                .await
                .tracking
                .set_limit_detected_at(Some(chrono::Utc::now().timestamp() - 121));
            h.tick().await;
            h.tick().await;
            assert!(
                h.dispatcher
                    .rig
                    .trigger_state
                    .read()
                    .await
                    .meridian
                    .has_flipped(),
                "{method:?}: {:?}",
                h.ops.calls()
            );
            assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_respects_operator_pause_and_stop() {
        let mut h = Harness::new().await;
        h.tick().await;
        h.dispatcher.run.pause(None).await;
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.4);
        h.tick().await;
        assert!(!h.ops.calls().iter().any(|c| c.starts_with("mount_slew:")));
        h.dispatcher.run.is_cancelled.store(true, Ordering::Relaxed);
        h.dispatcher.update_tracking_limit_hold(false).await;
        assert!(!h
            .ops
            .calls()
            .iter()
            .any(|c| c == "mount_set_tracking:mount:true"));
    }
    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_keeps_weather_protection() {
        let mut h = Harness::new().await;
        h.tick().await;
        {
            let mut state = h.dispatcher.rig.trigger_state.write().await;
            state.current_hour_angle = Some(0.4);
            state.weather_safe = false;
        }
        h.tick().await;
        assert!(h.dispatcher.run.is_cancelled());
        let calls = h.ops.calls();
        assert!(calls.iter().any(|c| c == "mount_park:mount"), "{calls:?}");
        assert!(
            !calls.iter().any(|c| c.starts_with("mount_slew:")),
            "{calls:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_keeps_dawn_protection() {
        let mut h = Harness::new().await;
        h.tick().await;
        {
            let mut state = h.dispatcher.rig.trigger_state.write().await;
            state.current_hour_angle = Some(0.4);
            state.dawn_time = Some(chrono::Utc::now().timestamp() + 60);
        }
        h.tick().await;
        assert!(h.dispatcher.run.is_cancelled());
        let calls = h.ops.calls();
        assert!(calls.iter().any(|c| c == "mount_park:mount"), "{calls:?}");
        assert!(
            !calls.iter().any(|c| c.starts_with("mount_slew:")),
            "{calls:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_times_out_without_restarting_tracking() {
        let mut h = Harness::new().await;
        h.tick().await;
        tokio::time::advance(Duration::from_secs(7200)).await;
        h.tick().await;
        assert_eq!(
            *h.dispatcher.run.executor_state.read().await,
            ExecutorState::Paused
        );
        assert!(h
            .dispatcher
            .run
            .progress
            .read()
            .message
            .as_ref()
            .unwrap()
            .contains("not flipped within the expected time"));
        assert!(!h
            .ops
            .calls()
            .iter()
            .any(|c| c == "mount_set_tracking:mount:true"));
        assert!(h.recovery.try_recv().is_err());
        // The hold has ended and handed the run to the operator, with the
        // stop still recorded: Resume adopts it again rather than imaging on
        // a stopped mount, and nothing restarts tracking into the limit.
        assert!(h.dispatcher.tracking_limit_hold.is_none());
        {
            let state = h.dispatcher.rig.trigger_state.read().await;
            assert_eq!(state.run.hold(), None);
            assert!(state.tracking.expected_and_lost());
        }
        h.resume().await;
        h.tick().await;
        assert!(h.dispatcher.tracking_limit_hold.is_some());
        assert!(h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        assert_eq!(
            *h.dispatcher.run.executor_state.read().await,
            ExecutorState::Running
        );
        assert!(!h
            .ops
            .calls()
            .iter()
            .any(|c| c == "mount_set_tracking:mount:true"));
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_does_not_adopt_calibration_or_disabled_flips() {
        let mut h = Harness::new().await;
        h.dispatcher.update_tracking_limit_hold(true).await;
        assert!(h.dispatcher.tracking_limit_hold.is_none());
        h.dispatcher
            .trigger_manager
            .write()
            .await
            .set_all_enabled(false);
        h.dispatcher.update_tracking_limit_hold(false).await;
        assert!(h.dispatcher.tracking_limit_hold.is_none());
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
    }

    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_adopts_a_guide_recovery_handoff() {
        let mut h = Harness::new().await;
        {
            let mut s = h.dispatcher.rig.trigger_state.write().await;
            s.run.begin_hold(RunHold::TrackingLimit);
            // Polling under a hold disarms ordinary tracking-loss detection.
            s.set_mount_tracking_expected(false);
        }
        h.tick().await;
        assert!(h.dispatcher.tracking_limit_hold.is_some());
        assert!(h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.4);
        h.tick().await;
        h.tick().await;
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        assert!(h
            .dispatcher
            .rig
            .trigger_state
            .read()
            .await
            .meridian
            .has_flipped());
    }

    #[test]
    fn tracking_limit_recovery_retains_loss_across_stopped_polls() {
        let mut state = crate::triggers::TriggerState::default();
        state.set_mount_tracking_expected(true);
        state.mount_is_tracking = Some(true);
        assert!(apply_mount_tracking_poll(&mut state, false));
        state.tracking.record_loss(123);
        state.mount_is_tracking = Some(false);
        assert!(!apply_mount_tracking_poll(&mut state, false));
        assert!(state.tracking.expected_and_lost());
        assert_eq!(state.tracking.limit_detected_at(), Some(123));
        assert!(!apply_mount_tracking_poll(&mut state, true));
        assert!(!state.tracking.is_lost());
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_post_flip_guider_neither_wedges_the_hold_nor_flips_twice() {
        let mut h = Harness::new().await;
        h.ops.guider_start_fails.store(true, Ordering::SeqCst);
        let mut events = h.dispatcher.run.events.subscribe();
        h.tick().await;
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.4);
        h.tick().await;
        assert_eq!(h.slews(), 1);
        // The pier side was verified, so the flip counts as done and the run
        // goes on; the guider failure is told, not paused on.
        assert!(h
            .dispatcher
            .rig
            .trigger_state
            .read()
            .await
            .meridian
            .has_flipped());
        assert_eq!(
            *h.dispatcher.run.executor_state.read().await,
            ExecutorState::Running
        );
        h.tick().await;
        assert!(h.dispatcher.tracking_limit_hold.is_none());
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        assert_eq!(h.dispatcher.rig.trigger_state.read().await.run.hold(), None);
        let warnings = drain_warnings(&mut events);
        assert!(
            warnings
                .iter()
                .any(|w| w.contains("After the meridian flip")),
            "{warnings:?}"
        );
        assert!(
            !warnings
                .iter()
                .any(|w| w.contains("wrong side of the pier")),
            "{warnings:?}"
        );
        // Hours later, nothing pauses and nothing flips again.
        tokio::time::advance(Duration::from_secs(7200)).await;
        h.tick().await;
        h.tick().await;
        assert_eq!(h.slews(), 1);
        assert_eq!(
            *h.dispatcher.run.executor_state.read().await,
            ExecutorState::Running
        );
    }

    #[tokio::test(start_paused = true)]
    async fn pausing_past_the_hold_deadline_resumes_into_the_flip() {
        let mut h = Harness::new().await;
        h.tick().await;
        assert!(h.dispatcher.tracking_limit_hold.is_some());
        h.dispatcher.run.pause(None).await;
        tokio::time::advance(Duration::from_secs(4 * 3600)).await;
        h.tick().await;
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.4);
        h.resume().await;
        h.tick().await;
        h.tick().await;
        assert_eq!(h.slews(), 1, "{:?}", h.ops.calls());
        assert!(h
            .dispatcher
            .rig
            .trigger_state
            .read()
            .await
            .meridian
            .has_flipped());
        assert_eq!(
            *h.dispatcher.run.executor_state.read().await,
            ExecutorState::Running
        );
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
    }

    fn drain_warnings(events: &mut broadcast::Receiver<ExecutorEvent>) -> Vec<String> {
        let mut warnings = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let ExecutorEvent::Warning { message } = event {
                warnings.push(message);
            }
        }
        warnings
    }

    /// A mount that stops at its own limit on the west side 33 min before
    /// transit. The mount acknowledges the first two tracking-on
    /// commands without the axes starting, and after the flip slew it keeps
    /// swinging in for 20 s while already reporting the slew done.
    async fn nyx_stopped_before_transit(h: &mut Harness) -> SimMount {
        let config = h.flip_early();
        h.use_config(config).await;
        let mut mount = SimMount::stopped_at(2.3759, 42.3491);
        mount.ignore_tracking_on = 2;
        mount.settle_secs = 20.0;
        h.ops.attach_sim_mount(mount.clone());
        mount
    }

    #[tokio::test(start_paused = true)]
    async fn a_west_side_stop_before_transit_flips_early_and_confirms_tracking() {
        let mut h = Harness::new().await;
        nyx_stopped_before_transit(&mut h).await;
        let mut events = h.dispatcher.run.events.subscribe();
        h.tick().await;
        // One tick: the stop is adopted and the flip runs at once, at HA -0.55.
        assert_eq!(h.slews(), 1, "{:?}", h.ops.calls());
        let calls = h.ops.calls();
        let slew = calls
            .iter()
            .position(|c| c.starts_with("mount_slew:"))
            .unwrap();
        let tracking_on: Vec<usize> = calls
            .iter()
            .enumerate()
            .filter(|(_, c)| *c == "mount_set_tracking:mount:true")
            .map(|(i, _)| i)
            .collect();
        assert!(tracking_on[0] < slew, "the flip slew tracks: {calls:?}");
        // Tracking was re-sent after the slew until the axes followed the sky.
        assert!(
            tracking_on.iter().filter(|&&i| i > slew).count() >= 2,
            "{calls:?}"
        );
        assert!(h.ops.sim_mount().unwrap().axes_tracking());
        // The recenter frame waited for the mount to come to rest, so the
        // first solve worked.
        assert_eq!(h.ops.call_count("plate_solve"), 1, "{calls:?}");
        h.tick().await;
        assert!(h.dispatcher.tracking_limit_hold.is_none());
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        assert!(h
            .dispatcher
            .rig
            .trigger_state
            .read()
            .await
            .meridian
            .has_flipped());
        let warnings = drain_warnings(&mut events);
        assert!(
            warnings
                .iter()
                .any(|w| w.contains("33 min before the meridian")
                    && w.contains("flips to the east side now")),
            "{warnings:?}"
        );
        assert!(
            warnings
                .iter()
                .any(|w| w.contains("Tracking-limit recovery finished")),
            "{warnings:?}"
        );
        assert!(h.recovery.try_recv().is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn a_refused_early_flip_waits_for_the_window_without_tracking_into_the_limit() {
        let mut h = Harness::new().await;
        nyx_stopped_before_transit(&mut h).await;
        // The mount stays on the west side: the east side is out of reach.
        h.ops.flip_refused.store(true, Ordering::SeqCst);
        let mut events = h.dispatcher.run.events.subscribe();
        h.tick().await;
        assert_eq!(h.slews(), 1);
        let warnings = drain_warnings(&mut events);
        assert!(
            warnings.iter().any(|w| w.contains("did not flip early")),
            "{warnings:?}"
        );
        assert!(h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        assert!(h
            .dispatcher
            .rig
            .trigger_state
            .read()
            .await
            .run
            .early_flip_refused());
        // Nothing more happens before the window, even after the old
        // deadline would have passed.
        tokio::time::advance(Duration::from_secs(1800)).await;
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.0);
        h.tick().await;
        assert_eq!(h.slews(), 1);
        assert_eq!(
            *h.dispatcher.run.executor_state.read().await,
            ExecutorState::Running
        );
        // The window opens and the ordinary flip runs, once the trigger's
        // cooldown (wall-clock, not the test clock) is over.
        h.ops.flip_refused.store(false, Ordering::SeqCst);
        h.dispatcher
            .trigger_manager
            .write()
            .await
            .get_trigger_mut("meridian_flip")
            .unwrap()
            .reset_for_new_run();
        h.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .current_hour_angle = Some(0.4);
        h.tick().await;
        h.tick().await;
        assert_eq!(h.slews(), 2);
        assert!(!h.dispatcher.run.is_paused.load(Ordering::Relaxed));
    }

    #[tokio::test(start_paused = true)]
    async fn a_flip_onto_a_mount_that_never_tracks_hands_over_to_tracking_recovery() {
        let mut h = Harness::new().await;
        let mut mount = nyx_stopped_before_transit(&mut h).await;
        mount.ignore_tracking_on = u32::MAX;
        h.ops.attach_sim_mount(mount);
        let mut events = h.dispatcher.run.events.subscribe();
        h.tick().await;
        h.tick().await;
        // Flipped, but frames are not released onto a stopped mount: the
        // tracking recovery takes it, and the run is never told it tracks.
        assert!(h.dispatcher.tracking_limit_hold.is_none());
        assert_eq!(
            h.recovery.try_recv().ok(),
            Some(crate::recovery::RecoveryCause::MountTrackingLost)
        );
        assert!(h.dispatcher.run.is_paused.load(Ordering::Relaxed));
        let warnings = drain_warnings(&mut events);
        assert!(
            warnings
                .iter()
                .any(|w| w.contains("the mount is not tracking")),
            "{warnings:?}"
        );
        assert!(
            !warnings.iter().any(|w| w.contains("tracks again")),
            "{warnings:?}"
        );
    }
}
