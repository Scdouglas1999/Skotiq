//! Adopt an unexpected stop near the meridian before ordinary tracking or
//! guide-star recovery can restart the mount. The monitor continues polling
//! safety throughout the wait; its existing flip action owns the actual move.

use super::{dispatch::Dispatcher, *};
use crate::triggers::{tracking_limit_flip_threshold, tracking_limit_recovery_candidate, RunHold};
use std::time::Duration;

pub(super) struct TrackingLimitHold {
    target: (Option<f64>, Option<f64>),
    deadline: tokio::time::Instant,
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
        if let Some(hold) = &self.tracking_limit_hold {
            // An operator pause takes priority over the automatic hold. Keep
            // the hold latched so Resume cannot bypass it.
            if executor_state != ExecutorState::Running {
                return;
            }
            self.run.hold_node_tree();
            let problem = if (state.target_ra, state.target_dec) != hold.target {
                Some("The target changed during tracking-limit recovery.")
            } else if state.mount_parked == Some(true) {
                Some("The mount was parked during tracking-limit recovery.")
            } else if state.mount_slewing == Some(true) {
                Some("The mount started moving during tracking-limit recovery.")
            } else if config.is_none() {
                Some("Automatic meridian flipping was disabled during tracking-limit recovery.")
            } else if !state.meridian.has_flipped() && tokio::time::Instant::now() >= hold.deadline
            {
                Some("The tracking-limit hold exceeded its expected flip time.")
            } else {
                None
            };
            if let Some(problem) = problem {
                self.run
                    .pause(Some(format!(
                        "{problem} Sequence paused; tracking has not been restarted."
                    )))
                    .await;
                return;
            }
            if state.meridian.has_flipped() {
                // A successful slew is not enough to release frames onto a
                // stationary mount. Re-read the driver after the full flip.
                let tracking = match self.rig.context.mount_id.as_deref() {
                    Some(id) => {
                        bounded_poll(
                            "mount_is_tracking",
                            self.rig.device_ops.mount_is_tracking(id),
                        )
                        .await
                    }
                    None => Err("No mount configured".to_string()),
                };
                if !matches!(tracking, Ok(true)) {
                    self.run.pause(Some("The meridian flip finished but tracking is not confirmed. Sequence paused.".to_string())).await;
                    return;
                }
                {
                    let mut state = self.rig.trigger_state.write().await;
                    state.run.end_hold();
                    state.reset_tracking_limit_detection();
                    state.set_mount_tracking_expected(true);
                    state.mount_is_tracking = Some(true);
                }
                self.tracking_limit_hold = None;
                // A pause arriving during the device query must not be lifted.
                if *self.run.executor_state.read().await == ExecutorState::Running
                    && !self.run.is_cancelled()
                {
                    self.run.is_paused.store(false, Ordering::Relaxed);
                    self.run.progress.write().message =
                        Some("Tracking-limit recovery completed; imaging resumes.".to_string());
                }
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
                self.run.pause(Some("Tracking-limit recovery requires an enabled meridian flip. Sequence paused.".into())).await;
            }
            return;
        };
        let threshold = tracking_limit_flip_threshold(&config);
        let Some(hour_angle) = state.current_hour_angle.filter(|ha| ha.is_finite()) else {
            self.run
                .pause(Some(
                    "Tracking-limit recovery lost the target hour angle. Sequence paused.".into(),
                ))
                .await;
            return;
        };
        let wait_secs = ((threshold - hour_angle).max(0.0) * 3600.0 / 1.002737909).max(
            if config.trigger_method == crate::MeridianTriggerMethod::OnTrackingLimitHit {
                config.tracking_limit_wait_minutes.max(0.0) * 60.0
            } else {
                0.0
            },
        );
        if !wait_secs.is_finite() {
            return;
        }
        self.tracking_limit_hold = Some(TrackingLimitHold {
            target: (state.target_ra, state.target_dec),
            deadline: tokio::time::Instant::now() + Duration::from_secs_f64(wait_secs + 900.0),
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
                self.run
                    .pause(Some(format!(
                        "Could not stop guiding for tracking-limit recovery: {error}"
                    )))
                    .await;
                return;
            }
            self.rig
                .trigger_state
                .write()
                .await
                .guiding
                .guiding_stopped_by_motion();
        }
        let message = format!(
            "Mount tracking stopped near the meridian. Holding exposures and guiding until the flip window ({:.0} min past transit, about {:.0} min away); tracking stays off until the flip.",
            threshold * 60.0, wait_secs / 60.0,
        );
        tracing::warn!("[MERIDIAN] {}", message);
        self.run.progress.write().message = Some(message.clone());
        self.run.warning(message);
    }
}

#[cfg(test)]
mod tests {
    use super::super::policy::{select_dispatches, DispatchPolicy};
    use super::*;
    use crate::device_ops::DeviceOps;
    use crate::executor::scenario_sim_tests::ScriptedDeviceOps;

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
        let tracking = calls
            .iter()
            .position(|c| c == "mount_set_tracking:mount:true")
            .unwrap();
        let center = calls.iter().position(|c| c == "plate_solve").unwrap();
        let guiding = calls.iter().position(|c| c == "guider_start").unwrap();
        assert!(
            slew < tracking && tracking < center && center < guiding,
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
            .contains("exceeded"));
        assert!(!h
            .ops
            .calls()
            .iter()
            .any(|c| c == "mount_set_tracking:mount:true"));
        assert!(h.recovery.try_recv().is_err());
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
}
