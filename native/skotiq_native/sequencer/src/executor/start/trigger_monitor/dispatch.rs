//! Stage 4 of a monitor tick: announce each dispatch and run its action.

use super::actions::custom_branch::CustomBranches;
use super::actions::meridian_flip::FlipFailureLatch;
use super::actions::{
    autofocus, cloud, custom_branch, dither, meridian_flip, park, recenter, recovery, science,
    ActionFlow, DecisionLog, ParkSignals, Rig, RunControl,
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
    flip_failure: FlipFailureLatch,
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
    pub(super) async fn new(args: TriggerMonitorArgs) -> Self {
        let frame_watch_config = args
            .sequence_for_custom_recovery_triggers
            .as_ref()
            .map(|s| crate::frame_watch::FrameWatchConfig::from_metadata(&s.metadata))
            .unwrap_or_default();
        if frame_watch_config.use_first_frame_reference {
            // The frame-watch trigger replaces the built-in pixel threshold;
            // otherwise that trigger would pull framing back to catalog coords.
            // Keep explicitly customized pixel triggers, including callers
            // that reuse the built-in ID with different settings.
            let mut manager = args.trigger_manager.write().await;
            let is_default = manager.get_trigger("drift_limit").is_some_and(|trigger| {
                matches!(trigger.trigger_type, TriggerType::DriftLimit { max_pixels } if max_pixels == 30.0)
                    && matches!(trigger.recovery_action, RecoveryAction::Recenter)
                    && trigger.cooldown_secs == Some(120)
            });
            if is_default {
                manager.remove_trigger("drift_limit");
            }
        }
        let trigger_state = args.trigger_manager.read().await.state();
        Self {
            run: RunControl {
                events: args.event_tx_clone2,
                is_cancelled: args.is_cancelled_clone,
                is_paused: args.is_paused_for_triggers,
                executor_state: args.state_clone,
                progress: args.progress_for_triggers,
            },
            rig: Rig {
                device_ops: args.device_ops_for_triggers,
                context: args.trigger_action_context,
                trigger_state,
                runtime_config: args.runtime_config,
            },
            decisions: DecisionLog {
                tx: args.decision_tx_for_lifecycle,
                run_id: args.active_run_id_for_decisions,
            },
            park: ParkSignals {
                park_and_abort: args.park_and_abort_for_triggers,
                done: args.park_and_abort_done_for_triggers,
                execution_quiesced: args.execution_quiesced_for_triggers,
            },
            flip_failure: FlipFailureLatch {
                failed: args.meridian_flip_failed_for_triggers,
                failure: args.meridian_flip_failure_for_triggers,
            },
            custom: CustomBranches {
                branches: args.custom_recovery_branches_for_triggers,
                sequence: args.sequence_for_custom_recovery_triggers,
                context: args.custom_recovery_context_for_triggers,
            },
            trigger_manager: args.trigger_manager,
            tracking_limit_hold: None,
            recovery_tx: args.recovery_request_tx,
            action_in_flight: args.trigger_action_in_flight_for_triggers,
            skip_to_next_target: args.skip_to_next_target_for_triggers,
            skip_to_node: args.skip_to_node_for_recovery,
            cloud_motion: args.cloud_motion_for_recovery,
            transparency_backup: args.transparency_backup_for_recovery,
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
        self.announce(id, name, &RecoveryAction::Recenter, "Recenter");
        let target = self.rig.target().await;
        let autofocus = self
            .rig
            .runtime_config
            .read()
            .autofocus
            .clone()
            .unwrap_or_default();
        let ctx = build_trigger_flip_context(
            &self.rig.context,
            TriggerFlipTarget {
                name: target.name.clone().unwrap_or_else(|| "target".into()),
                ra_hours: target.ra_hours,
                dec_degrees: target.dec_degrees,
            },
            Some(self.run.is_cancelled.clone()),
            Some(self.rig.trigger_state.clone()),
            Some(autofocus),
            target.filter.clone(),
        );
        let slew_ctx = self.rig.instruction_context(target, &self.run);
        let config = self
            .trigger_manager
            .read()
            .await
            .meridian_flip_config()
            .cloned()
            .unwrap_or_default();
        let failure_action = config.failure_action;
        let result = if let Some(ctx) = ctx {
            let mut recovery = crate::meridian_flip_executor::MeridianFlipExecutor::new(
                config,
                self.rig.device_ops.clone(),
            )
            .with_executor_event_tx(self.run.events.clone());
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
                self.run.error(message.clone());
                match failure_action {
                    crate::FlipFailureAction::PauseAndAlert => self.run.pause(Some(message)).await,
                    crate::FlipFailureAction::AbortAndPark => {
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
        let FiredTriggerAction {
            action,
            end_without_parking,
            notify_only,
        } = fired;
        self.announce(&trigger_id, &trigger_name, &action, &action_str);

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
        if let Some(history) = state.guiding_rms_history.as_mut() {
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
        self.decisions.send(crate::decision::DecisionEvent::new(
            crate::decision::DecisionCategory::TriggerFired,
            format!("Trigger {} fired → {}", trigger_name, action_str),
            serde_json::json!({
                "trigger_id": trigger_id,
                "trigger_name": trigger_name,
                "action": action_str,
            }),
        ));
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
                    decisions: &self.decisions,
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
                    decisions: &self.decisions,
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
