//! Stage 4 of a monitor tick: announce each dispatch and run its action.

use super::actions::custom_branch::CustomBranches;
use super::actions::{
    autofocus, cloud, custom_branch, dither, meridian_flip, park, recenter, recovery, science,
    ActionFlow, Rig,
};
use super::policy::{Dispatch, NotifyEpisodes};
use super::*;

/// Whether the monitor goes on after a tick.
pub(super) enum Flow {
    Next,
    /// A trigger ended the run; these are the firings acted on.
    Terminate(Vec<(String, RecoveryAction)>),
}

/// Runs dispatched actions. Owns the handles the handlers are given and the
/// run-long bookkeeping a handler keeps between firings.
pub(super) struct Dispatcher {
    pub(super) run: RunControl,
    pub(super) rig: Rig,
    pub(super) decisions: DecisionLog,
    park: ParkSignals,
    pub(super) flip_failure: FlipFailureLatch,
    custom: CustomBranches,
    pub(super) trigger_manager: Arc<RwLock<TriggerManager>>,
    pub(super) tracking_limit_hold: Option<super::tracking_limit::TrackingLimitHold>,
    pub(super) recovery_tx: mpsc::Sender<crate::recovery::RecoveryCause>,
    pub(super) action_in_flight: Arc<AtomicBool>,
    skip_to_next_target: Arc<AtomicBool>,
    skip_to_node: Arc<StdRwLock<Option<NodeId>>>,
    cloud_motion: Arc<RwLock<CloudMotionSnapshot>>,
    transparency_backup: Arc<RwLock<Option<crate::node::context::TransparencyBackupPlan>>>,
    /// Firings of no-recovery `Retry` triggers, against their allowance.
    retry_attempts: HashMap<String, u32>,
    notify_episodes: NotifyEpisodes,
    recenter_failure_told: bool,
    /// Every firing acted on, returned when the monitor ends.
    fired: Vec<(String, RecoveryAction)>,
}

impl Dispatcher {
    pub(super) async fn new(
        run: &Run,
        custom_branch_context: ExecutionContext,
        recovery_requests: mpsc::Sender<crate::recovery::RecoveryCause>,
    ) -> Self {
        let frame_watch_config = run
            .plan
            .sequence
            .as_ref()
            .map(|s| crate::frame_watch::FrameWatchConfig::from_metadata(&s.metadata))
            .unwrap_or_default();
        if frame_watch_config.use_first_frame_reference {
            // The frame-watch trigger replaces the built-in pixel threshold;
            // otherwise that trigger would pull framing back to catalog coords.
            // Keep explicitly customized pixel triggers, including callers
            // that reuse the built-in ID with different settings.
            let mut manager = run.triggers.write().await;
            let is_default = manager
                .standard(StandardTrigger::DriftLimit)
                .is_some_and(|trigger| {
                    matches!(trigger.trigger_type, TriggerType::DriftLimit { max_pixels } if max_pixels == 30.0)
                        && matches!(trigger.recovery_action, RecoveryAction::Recenter)
                        && trigger.cooldown_secs == Some(120)
                });
            if is_default {
                manager.remove_trigger(StandardTrigger::DriftLimit.id());
            }
        }
        let trigger_state = run.triggers.read().await.state();
        Self {
            run: run.control.clone(),
            rig: Rig {
                shared: custom_branch_context.run.clone(),
                trigger_state,
                runtime_config: run.config.clone(),
            },
            decisions: run.decisions.clone(),
            park: run.teardown.park_signals(),
            flip_failure: run.outside_failures.meridian_flip.clone(),
            custom: CustomBranches {
                branches: run.plan.custom_recovery_branches.clone(),
                sequence: run.plan.sequence.clone(),
                context: custom_branch_context,
            },
            trigger_manager: run.triggers.clone(),
            tracking_limit_hold: None,
            recovery_tx: recovery_requests,
            action_in_flight: run.teardown.trigger_action_in_flight.clone(),
            skip_to_next_target: run.skip_to_next_target.clone(),
            skip_to_node: run.skip_to_node.clone(),
            cloud_motion: run.sky.cloud_motion.clone(),
            transparency_backup: run.sky.transparency_backup.clone(),
            retry_attempts: HashMap::new(),
            notify_episodes: NotifyEpisodes::default(),
            recenter_failure_told: false,
            fired: Vec::new(),
        }
    }

    pub(super) fn into_fired(self) -> Vec<(String, RecoveryAction)> {
        self.fired
    }

    /// Run this tick's dispatches in order.
    pub(super) async fn run_tick(&mut self, mode: RunMode, dispatches: Vec<Dispatch>) -> Flow {
        // Tell the pre-frame meridian gate what this tick decided, so a frame
        // that starts after a hold does not race the flip the first running
        // tick fires.
        let flip_dispatching = dispatches.iter().any(|dispatch| {
            !dispatch.fired.notify_only
                && !dispatch.fired.end_without_parking
                && matches!(dispatch.fired.action, RecoveryAction::MeridianFlip(_))
        });
        self.rig
            .trigger_state
            .write()
            .await
            .record_evaluation(mode, flip_dispatching);

        for dispatch in dispatches {
            if self.run.is_cancelled() {
                break;
            }
            if let Flow::Terminate(fired) = self.dispatch(dispatch, None).await {
                return Flow::Terminate(fired);
            }
        }
        Flow::Next
    }

    /// Run an action the frame watch decided on, the way a fired trigger's
    /// action runs.
    pub(super) async fn run_synthetic(
        &mut self,
        trigger_id: &str,
        trigger_name: &str,
        fired: FiredTriggerAction,
    ) -> Flow {
        self.dispatch(
            Dispatch {
                trigger_id: trigger_id.to_string(),
                trigger_name: trigger_name.to_string(),
                fired,
                cooldown_secs: None,
            },
            None,
        )
        .await
    }

    /// Recenter to a measured reference through the normal trigger/camera claim.
    pub(super) async fn run_frame_recenter(
        &mut self,
        trigger_id: &str,
        trigger_name: &str,
        reference: recenter::FrameReference,
    ) -> Flow {
        self.dispatch(
            Dispatch {
                trigger_id: trigger_id.to_string(),
                trigger_name: trigger_name.to_string(),
                fired: FiredTriggerAction {
                    action: RecoveryAction::Recenter,
                    end_without_parking: false,
                    notify_only: false,
                },
                cooldown_secs: None,
            },
            Some(reference),
        )
        .await
    }

    /// Finish a probe's return while the caller retains its imaging-train claim.
    pub(super) async fn recenter_holding_claim(
        &mut self,
        id: &str,
        name: &str,
        _claim: &mut TriggerCameraClaim,
    ) -> Flow {
        self.announce(
            id,
            name,
            &RecoveryAction::Recenter,
            "Recenter",
            format!("{name} fired: recenter"),
            None,
        );
        let autofocus = self
            .rig
            .runtime_config
            .read()
            .autofocus
            .clone()
            .unwrap_or_default();
        let slew_ctx = self
            .rig
            .instruction_context(self.rig.target().await, &self.run);
        let ctx =
            crate::meridian_flip_executor::FlipContext::for_instruction(&slew_ctx, Some(autofocus))
                .await;
        let config = self
            .trigger_manager
            .read()
            .await
            .meridian_flip_config()
            .cloned()
            .unwrap_or_default();
        let failure_action = config.failure_action;
        let result = if let Some(ctx) = ctx {
            let mut recovery = crate::meridian_flip_executor::MeridianFlipExecutor::in_run(
                config,
                self.rig.shared.clone(),
            );
            let slew = crate::instructions::execute_slew(
                &crate::SlewConfig {
                    use_target_coords: true,
                    custom_ra: None,
                    custom_dec: None,
                },
                &slew_ctx,
                None,
            )
            .await;
            if slew.status != NodeStatus::Success {
                Err(format!(
                    "Return slew failed: {}",
                    slew.message.unwrap_or_default()
                ))
            } else {
                recovery.recover_target(&ctx).await
            }
        } else {
            Err("Target recovery requires a mount, camera and target coordinates".into())
        };
        if let Err(problem) = result {
            if !self.run.is_cancelled() {
                let message = format!("{name}: target acquisition failed ({problem}). Applying the configured recovery failure action; the obstruction has not been learned.");
                self.flip_failure.latch(|| message.clone());
                match failure_action {
                    crate::FlipFailureAction::PauseAndAlert => {
                        self.run.held(message.clone());
                        self.run.pause(Some(message));
                    }
                    crate::FlipFailureAction::AbortAndPark => {
                        self.run.error(message);
                        meridian_flip::abort_and_park(&self.rig, &self.run, &mut self.park).await;
                        self.fired.push((id.into(), RecoveryAction::ParkAndAbort));
                        return Flow::Terminate(terminate_with(
                            &self.run.is_cancelled,
                            std::mem::take(&mut self.fired),
                            "Probe recovery failed: AbortAndPark",
                        ));
                    }
                }
            }
        }
        self.fired.push((id.into(), RecoveryAction::Recenter));
        Flow::Next
    }

    async fn dispatch(
        &mut self,
        dispatch: Dispatch,
        reference: Option<recenter::FrameReference>,
    ) -> Flow {
        if dispatch.fired.notify_only {
            self.continue_without_guide_star(&dispatch.trigger_id).await;
        }
        // A notify-only trigger tells the operator once per episode.
        if dispatch.fired.notify_only && !self.notify_episodes.is_new_episode(&dispatch) {
            tracing::debug!(
                "Trigger '{}' still firing; the operator was already told",
                dispatch.trigger_name
            );
            return Flow::Next;
        }
        let Dispatch {
            trigger_id,
            trigger_name,
            fired,
            ..
        } = dispatch;
        let action_str = fired.wire_label();
        let summary = fired.decision_summary(&trigger_name);
        let stop = fired
            .parks_and_ends_run()
            .then(|| crate::decision::RunStop::Trigger {
                trigger_id: trigger_id.clone(),
                trigger_name: trigger_name.clone(),
            });
        let FiredTriggerAction {
            action,
            end_without_parking,
            notify_only,
        } = fired;
        self.announce(
            &trigger_id,
            &trigger_name,
            &action,
            &action_str,
            summary,
            stop,
        );

        // A notice drives nothing: no in-flight guard, no camera claim.
        if notify_only {
            let message = {
                // Manager before state, the order every other path takes.
                let manager = self.trigger_manager.read().await;
                let state = self.rig.trigger_state.read().await;
                quality_trigger_notice(&trigger_name, &trigger_id, &manager, &state)
            };
            tracing::warn!("{}", message);
            self.run.warning(message);
            return Flow::Next;
        }

        // Keeps the run supervisor polling this monitor until the action is
        // done, whichever way it exits.
        let action_in_flight = self.action_in_flight.clone();
        let _action_in_flight = TriggerActionInFlightGuard::new(&action_in_flight);
        // Every camera-driving action waits for the frame in flight and holds
        // the imaging train; the guard releases on every exit.
        let mut camera_claim =
            TriggerCameraClaim::acquire(&self.rig.trigger_state, &self.run.is_cancelled, &action)
                .await;

        let flow = self
            .run_action(
                &trigger_id,
                &trigger_name,
                &action,
                end_without_parking,
                &mut camera_claim,
                reference,
            )
            .await;
        match flow {
            ActionFlow::Finished => {
                camera_claim.release().await;
                self.fired.push((trigger_id, action));
                Flow::Next
            }
            ActionFlow::NotRun => {
                camera_claim.release().await;
                Flow::Next
            }
            ActionFlow::Terminate { recorded, reason } => {
                self.fired.push((trigger_id, recorded));
                Flow::Terminate(terminate_with(
                    &self.run.is_cancelled,
                    std::mem::take(&mut self.fired),
                    reason,
                ))
            }
        }
    }

    /// A lost guide star that only notifies leaves the run imaging unguided:
    /// dithers are skipped and guiding RMS is not judged, and guiding is
    /// started on a fresh star before the next light frame, then retried on
    /// the unguided interval until it holds.
    async fn continue_without_guide_star(&self, trigger_id: &str) {
        let is_guide_star_lost = matches!(
            self.trigger_manager
                .read()
                .await
                .get_trigger(trigger_id)
                .map(|trigger| &trigger.trigger_type),
            Some(TriggerType::GuideStarLost)
        );
        if !is_guide_star_lost {
            return;
        }
        let mut state = self.rig.trigger_state.write().await;
        state.guiding.lose_star_and_continue_unguided();
        if let Some(history) = state.latches.guiding_rms_history.as_mut() {
            history.clear();
        }
    }

    /// Log the firing, send `TriggerFired`, and record it in the decision log.
    fn announce(
        &self,
        trigger_id: &str,
        trigger_name: &str,
        action: &RecoveryAction,
        action_str: &str,
        summary: String,
        stop: Option<crate::decision::RunStop>,
    ) {
        if matches!(action, RecoveryAction::Continue) {
            tracing::debug!(
                "Trigger fired: {} ({}) - action: {:?}",
                trigger_name,
                trigger_id,
                action
            );
        } else {
            tracing::warn!(
                "Trigger fired: {} ({}) - action: {:?}",
                trigger_name,
                trigger_id,
                action
            );
        }
        self.run.send(ExecutorEvent::TriggerFired {
            trigger_id: trigger_id.to_string(),
            trigger_name: trigger_name.to_string(),
            action: action_str.to_string(),
        });
        let mut row = crate::decision::DecisionEvent::new(
            crate::decision::DecisionCategory::TriggerFired,
            summary,
            serde_json::json!({
                "trigger_id": trigger_id,
                "trigger_name": trigger_name,
                "action": action_str,
            }),
        );
        row.stop = stop;
        self.decisions.send(row);
    }

    async fn run_action(
        &mut self,
        trigger_id: &str,
        trigger_name: &str,
        action: &RecoveryAction,
        end_without_parking: bool,
        camera_claim: &mut TriggerCameraClaim,
        reference: Option<recenter::FrameReference>,
    ) -> ActionFlow {
        let run = &self.run;
        let rig = &self.rig;
        match action {
            RecoveryAction::Pause => {
                recovery::pause(trigger_id, trigger_name, &self.recovery_tx, run).await
            }
            RecoveryAction::Retry { max_attempts } => {
                recovery::retry(
                    trigger_id,
                    trigger_name,
                    *max_attempts,
                    &self.recovery_tx,
                    &mut self.retry_attempts,
                    run,
                )
                .await
            }
            RecoveryAction::PauseAndWaitForClear => {
                recovery::pause_and_wait_for_clear(trigger_name, &self.recovery_tx, run).await
            }
            RecoveryAction::ParkAndAbort if end_without_parking => {
                park::end_without_parking(
                    trigger_id,
                    trigger_name,
                    rig,
                    &self.custom,
                    run,
                    &mut self.park,
                )
                .await
            }
            RecoveryAction::ParkAndAbort => {
                park::park_and_abort(
                    trigger_id,
                    trigger_name,
                    rig,
                    &self.custom,
                    run,
                    &mut self.park,
                )
                .await
            }
            RecoveryAction::NextTarget => {
                tracing::info!("Trigger requested advance to next target");
                self.skip_to_next_target.store(true, Ordering::Relaxed);
                ActionFlow::Finished
            }
            RecoveryAction::Autofocus => {
                autofocus::run(autofocus::AutofocusRequest {
                    trigger_id,
                    trigger_name,
                    rig,
                    run,
                    progress_context: &self.custom.context,
                    camera_claim,
                })
                .await
            }
            RecoveryAction::MeridianFlip(config) => {
                meridian_flip::run(meridian_flip::FlipRequest {
                    config,
                    rig,
                    run,
                    failure: &self.flip_failure,
                    park: &mut self.park,
                    camera_claim,
                })
                .await
            }
            RecoveryAction::Dither(config) => dither::run(trigger_name, config, rig, run).await,
            RecoveryAction::Recenter => {
                recenter::run(recenter::RecenterRequest {
                    trigger_id,
                    trigger_name,
                    rig,
                    run,
                    decisions: &self.decisions,
                    failure_told: &mut self.recenter_failure_told,
                    camera_claim,
                    reference,
                })
                .await
            }
            RecoveryAction::SlewToGapAndContinue => {
                cloud::slew_to_gap(trigger_name, &self.cloud_motion, rig, run).await
            }
            RecoveryAction::SwitchTargetOrFilter => {
                science::switch_target_or_filter(
                    trigger_name,
                    &self.transparency_backup,
                    &self.skip_to_node,
                    rig,
                    run,
                )
                .await
            }
            // A notify-only firing was told to the operator before the
            // in-flight guard; nothing reaches here with it.
            RecoveryAction::Notify => ActionFlow::Finished,
            RecoveryAction::Continue => {
                tracing::debug!(
                    "Trigger '{}' fired with RecoveryAction::Continue (logged and ignored)",
                    trigger_name
                );
                ActionFlow::Finished
            }
            RecoveryAction::CustomBranch => {
                custom_branch::run(trigger_id, trigger_name, &self.custom, run).await
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::actions::TargetSnapshot;
    use super::*;

    async fn dispatcher_for(run: &Run) -> (Dispatcher, ExecutionContext) {
        let (requests, _) = mpsc::channel(4);
        let context = run
            .build_context(std::time::Instant::now(), requests.clone())
            .await;
        (
            Dispatcher::new(run, context.clone(), requests).await,
            context,
        )
    }

    /// A trigger-run instruction runs against the run's own context, so its
    /// decisions reach the run's log, a disconnect it settles reaches the
    /// run's recovery, and its frames carry the run's session and rig.
    #[tokio::test]
    async fn a_trigger_action_runs_against_the_runs_own_context() {
        let (events, _) = broadcast::channel(16);
        let mut run = Run::detached(
            Arc::new(crate::device_ops::NullDeviceOps),
            RunCell::starting_in(events, ExecutorState::Running),
        );
        run.rig = RunRig {
            camera_id: Some("camera".into()),
            mount_id: Some("mount".into()),
            focuser_id: Some("focuser".into()),
            save_path: Some(std::path::PathBuf::from("/captures")),
            ..RunRig::default()
        };
        run.config = crate::executor::RunConfigStore::new(crate::executor::RunConfig {
            latitude: Some(45.0),
            longitude: Some(-122.0),
            filter_focus_offsets: HashMap::from([("Ha".to_string(), 42)]),
            ..crate::executor::RunConfig::default()
        });
        let (dispatcher, context) = dispatcher_for(&run).await;

        let ctx = dispatcher.rig.instruction_context(
            TargetSnapshot {
                name: Some("M31".into()),
                ra_hours: Some(0.71),
                dec_degrees: Some(41.27),
                filter: Some("Ha".into()),
            },
            &dispatcher.run,
        );

        assert_eq!(ctx.target_name.as_deref(), Some("M31"));
        assert_eq!(ctx.target_ra, Some(0.71));
        assert_eq!(ctx.current_filter.as_deref(), Some("Ha"));
        assert!(
            ctx.node_id.is_empty(),
            "a trigger action is not a sequence node"
        );
        assert_eq!(
            ctx.run.identity.session_id, context.run.identity.session_id,
            "one session per run"
        );
        assert!(ctx.run.decision_tx.is_some(), "the run's decision log");
        assert!(ctx.run.recovery_request_tx.is_some(), "the run's recovery");
        assert!(ctx.run.event_tx.is_some(), "the run's event feed");
        assert!(Arc::ptr_eq(
            ctx.run.trigger_state.as_ref().unwrap(),
            &dispatcher.rig.trigger_state
        ));
        assert!(Arc::ptr_eq(
            &ctx.run.device_disconnect_recovery_pending,
            &context.run.device_disconnect_recovery_pending
        ));
        assert_eq!(ctx.run.rig.save_path, run.rig.save_path);
        assert_eq!(ctx.run.rig.latitude, Some(45.0));
        assert_eq!(ctx.run.rig.filter_focus_offsets.get("Ha"), Some(&42));

        // The operator edits the offsets and the site during the run: the next
        // trigger action (a refocus, a dither, a recenter) takes them, the one
        // already running keeps what it started with.
        run.config
            .update(&run.triggers, &run.control.state, |config| {
                config.filter_focus_offsets = HashMap::from([("Ha".to_string(), 120)]);
                config.latitude = Some(46.0);
            })
            .await
            .expect("the settings apply");
        let next = dispatcher.rig.instruction_context(
            TargetSnapshot {
                name: Some("M31".into()),
                ra_hours: Some(0.71),
                dec_degrees: Some(41.27),
                filter: Some("Ha".into()),
            },
            &dispatcher.run,
        );
        assert_eq!(next.run.rig.filter_focus_offsets.get("Ha"), Some(&120));
        assert_eq!(next.run.rig.latitude, Some(46.0));
        assert_eq!(ctx.run.rig.filter_focus_offsets.get("Ha"), Some(&42));
        assert_eq!(
            next.run.identity.session_id, ctx.run.identity.session_id,
            "a settings change is not a new session"
        );
    }

    /// A dispatcher over the scripted rig, with a target west of the pier
    /// just past the meridian.
    async fn scripted_dispatcher(
        rig: RunRig,
    ) -> (
        Dispatcher,
        Arc<crate::executor::scenario_sim_tests::ScriptedDeviceOps>,
    ) {
        let ops = Arc::new(crate::executor::scenario_sim_tests::ScriptedDeviceOps::new());
        let (events, _) = broadcast::channel(256);
        let mut run = Run::detached(
            ops.clone(),
            RunCell::starting_in(events, ExecutorState::Running),
        );
        let mut manager = TriggerManager::new();
        manager.create_standard_triggers();
        {
            let lock = manager.state();
            let mut state = lock.write().await;
            state.set_target(84.0, -5.0);
            state.target.current_target_name = Some("M42".to_string());
            state.target.current_hour_angle = Some(0.2);
            state.telemetry.weather_safe = true;
        }
        run.triggers = Arc::new(RwLock::new(manager));
        run.rig = rig;
        run.teardown.node_tree_has_ended();
        let (dispatcher, _) = dispatcher_for(&run).await;
        (dispatcher, ops)
    }

    fn firing(action: RecoveryAction) -> Dispatch {
        Dispatch {
            trigger_id: "test".to_string(),
            trigger_name: "Test".to_string(),
            fired: FiredTriggerAction {
                action,
                end_without_parking: false,
                notify_only: false,
            },
            cooldown_secs: None,
        }
    }

    async fn imaging_train_is_free(dispatcher: &Dispatcher) -> bool {
        // A claim given back from a drop under contention is handed to the
        // runtime; let it run.
        tokio::task::yield_now().await;
        dispatcher
            .rig
            .trigger_state
            .read()
            .await
            .imaging_train
            .hold()
            .is_none()
    }

    /// Every way a camera-driving action ends hands the imaging train back to
    /// the capture loop: one that ran, one that was no longer due, and one
    /// that ended the run. A claim left behind holds every later frame for the
    /// claim's expiry.
    #[tokio::test(start_paused = true)]
    async fn a_trigger_action_hands_the_imaging_train_back_however_it_ends() {
        let camera_only = RunRig {
            camera_id: Some("camera".into()),
            mount_id: Some("mount".into()),
            ..RunRig::default()
        };

        // Ran: an autofocus with no focuser is skipped and imaging goes on.
        let (mut dispatcher, _) = scripted_dispatcher(camera_only.clone()).await;
        let flow = dispatcher
            .dispatch(firing(RecoveryAction::Autofocus), None)
            .await;
        assert!(matches!(flow, Flow::Next));
        assert_eq!(dispatcher.fired.len(), 1, "the firing is recorded");
        assert!(
            imaging_train_is_free(&dispatcher).await,
            "after a finished action"
        );

        // Not run: a flip that is no longer due once its turn comes.
        let (mut dispatcher, ops) = scripted_dispatcher(camera_only.clone()).await;
        ops.flip_on_slew.store(true, Ordering::SeqCst);
        ops.flipped.store(true, Ordering::SeqCst);
        let flow = dispatcher
            .dispatch(
                firing(RecoveryAction::MeridianFlip(
                    crate::MeridianFlipConfig::default(),
                )),
                None,
            )
            .await;
        assert!(matches!(flow, Flow::Next));
        assert!(dispatcher.fired.is_empty(), "nothing ran");
        assert!(
            imaging_train_is_free(&dispatcher).await,
            "after an action not run"
        );

        // Ended the run: a flip the mount refuses, under "abort and park".
        let (mut dispatcher, ops) = scripted_dispatcher(camera_only).await;
        ops.flip_on_slew.store(true, Ordering::SeqCst);
        ops.flip_refused.store(true, Ordering::SeqCst);
        dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .meridian
            .request();
        let config = crate::MeridianFlipConfig {
            max_retries: 0,
            settle_time: 0.0,
            guider_settle_time: 0.0,
            failure_action: crate::FlipFailureAction::AbortAndPark,
            ..Default::default()
        };
        let flow = dispatcher
            .dispatch(firing(RecoveryAction::MeridianFlip(config)), None)
            .await;
        assert!(
            matches!(flow, Flow::Terminate(_)),
            "the refused flip ends the run; calls={:?}",
            ops.calls()
        );
        assert!(ops.calls().iter().any(|c| c == "mount_park:mount"));
        assert!(
            imaging_train_is_free(&dispatcher).await,
            "after an action that ended the run"
        );
    }
}
