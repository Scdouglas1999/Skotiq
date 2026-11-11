//! The command handler: drains run-control messages for the life of the run
//! (pause/resume, stop, skip, the recovery buttons, plugin-node replies).

use super::*;

pub(super) struct CommandHandlerArgs {
    pub run: RunControl,
    pub rx: mpsc::Receiver<ExecutorCommand>,
    pub current_recovery: Arc<StdRwLock<Option<crate::recovery::RecoveryContext>>>,
    pub recovery_signals: Arc<crate::recovery::RecoverySignals>,
    pub resume_notify: Arc<tokio::sync::Notify>,
    pub skip_step: Arc<AtomicBool>,
    pub skip_to_node: Arc<StdRwLock<Option<NodeId>>>,
    pub plugin_node_pending: Arc<
        RwLock<
            HashMap<NodeId, tokio::sync::oneshot::Sender<crate::node::context::PluginNodeReply>>,
        >,
    >,
}

pub(super) async fn run_command_handler(args: CommandHandlerArgs) {
    let CommandHandlerArgs {
        run,
        mut rx,
        current_recovery,
        recovery_signals,
        resume_notify,
        skip_step,
        skip_to_node,
        plugin_node_pending,
    } = args;
    while let Some(cmd) = rx.recv().await {
        match cmd {
            ExecutorCommand::Pause => run.pause(None),
            ExecutorCommand::Resume if current_recovery.read().is_some() => {
                // The node tree is frozen by a recovery ladder, not by a
                // pause, and unfreezing it would expose through the fault the
                // ladder is still fixing (a guide star not yet re-acquired).
                // Resume withdraws a pause placed during the ladder and
                // nothing more; Try now and Abort are the controls over the
                // ladder itself.
                run.state.transition(ExecutorState::Recovering);
                run.warning(
                    "Recovery is still running, so the run stays frozen until it \
                     finishes. Use Try now or Abort recovery to act on it."
                        .to_string(),
                );
            }
            ExecutorCommand::Resume => {
                // A node may be parked on `resume_notify.notified()`; we have
                // to wake all waiters *before* flipping is_paused so the
                // resumed branch sees the new state without racing.
                run.is_paused.store(false, Ordering::Relaxed);
                resume_notify.notify_waiters();
                run.state.transition(ExecutorState::Running);
            }
            ExecutorCommand::Stop => {
                run.is_cancelled.store(true, Ordering::Relaxed);
                run.state.transition(ExecutorState::Stopping);
                // Keep the command future alive. Breaking here
                // lets this select! branch win and drops the
                // node-execution future before its hardware
                // cancellation cleanup can abort an exposure.
                // The shared cancellation flag makes execution
                // finish; that branch owns termination.
            }
            ExecutorCommand::Skip => {
                tracing::info!("Skip requested - skipping the current step");
                skip_step.store(true, Ordering::Relaxed);
            }
            ExecutorCommand::SkipToNode(node_id) => {
                // Implement SkipToNode for
                // real. Post the target id into the shared
                // slot; the next iteration of the node tree
                // walk will mark preceding siblings as
                // Skipped and continue executing from the
                // target. The request clears itself when
                // the target subtree is entered (see
                // RuntimeNode::execute_children_sequential).
                //
                // We deliberately accept the request even
                // mid-instruction: the long-running
                // instruction (e.g. an exposure burst)
                // continues to completion, then the parent
                // container observes the skip request and
                // jumps to the target on the NEXT child. A
                // user who wants to interrupt mid-burst
                // sends Stop first, then re-Starts with the
                // sequence trimmed.
                tracing::info!(
                    "[SKIP_TO_NODE] Received request for target node '{}'",
                    node_id
                );
<<<<<<< HEAD
                *skip_to_node.write() = Some(node_id.clone());
                run.send(skip_to_node_accepted_event(node_id));
=======
                *skip_to_node_cmd.write() = Some(node_id.clone());
                let _ = event_tx.send(skip_to_node_accepted_event(node_id));
            }
            ExecutorCommand::UpdateDitherConfig {
                pixels,
                settle_pixels,
                settle_time,
                settle_timeout,
                ra_only,
            } => {
                // write through the shared Arc so the
                // change takes effect on the next dither without
                // requiring a sequence reload.
                {
                    let mut rc = runtime_config.write();
                    rc.dither.pixels = pixels;
                    rc.dither.settle_pixels = settle_pixels;
                    rc.dither.settle_time = settle_time;
                    rc.dither.settle_timeout = settle_timeout;
                    rc.dither.ra_only = ra_only;
                }
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    state_lock.write().await.settings.dither_settle = crate::GuiderSettle {
                        pixels: settle_pixels,
                        time_secs: settle_time,
                        timeout_secs: settle_timeout,
                    };
                }
                tracing::info!(
                "Runtime dither config updated: pixels={}, settle_pixels={}, settle_time={}, settle_timeout={}, ra_only={}",
                pixels, settle_pixels, settle_time, settle_timeout, ra_only
            );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "dither".to_string(),
                });
            }
            ExecutorCommand::UpdateLocation {
                latitude,
                longitude,
            } => {
                // write through the Arc and also push
                // into the trigger state so altitude-aware
                // triggers (AltitudeLimit, MeridianFlip hour-angle
                // calc) read the new value on their next poll.
                {
                    let mut rc = runtime_config.write();
                    rc.latitude = latitude;
                    rc.longitude = longitude;
                }
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.set_observer_location(latitude, longitude);
                }
                tracing::info!(
                    "Runtime location updated: lat={:?}, lon={:?}",
                    latitude,
                    longitude
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "location".to_string(),
                });
            }
            ExecutorCommand::UpdateMaxSunAltitude { degrees } => {
                // The threshold is written through the Arc AND patched into
                // the live trigger state: the daylight gate reads it through
                // the trigger-state handle, so both must agree before the
                // next slew / exposure. A `None`/non-finite push resolves to
                // the DEFAULT (-12°) so the gate never weakens.
                {
                    let mut rc = runtime_config.write();
                    rc.max_sun_altitude_degrees = degrees;
                }
                let effective = match degrees {
                    Some(v) if v.is_finite() => v,
                    _ => crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
                };
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.set_max_sun_altitude_degrees(effective);
                }
                tracing::info!(
                    "Runtime max Sun altitude (W1 daylight gate) updated: {:?} -> effective {:.1}°",
                    degrees,
                    effective
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "max_sun_altitude".to_string(),
                });
            }
            ExecutorCommand::UpdateFilterOffsets { offsets } => {
                // write through the Arc so the next
                // filter change reads the updated offsets.
                let count = offsets.len();
                {
                    let mut rc = runtime_config.write();
                    rc.filter_focus_offsets = offsets;
                }
                tracing::info!("Runtime filter focus offsets updated: {} entries", count);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "filter_offsets".to_string(),
                });
            }
            ExecutorCommand::UpdateDefaultQualityCheck { check } => {
                // write through the shared Arc so the
                // next exposure's instruction context sees the
                // new default. Pre-existing per-node
                // `quality_check` settings still win.
                {
                    let mut rc = runtime_config.write();
                    rc.default_quality_check = check.clone();
                }
                tracing::info!(
                    "Runtime default_quality_check updated (active={})",
                    check.as_ref().map(|c| c.is_active()).unwrap_or(false)
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "default_quality_check".to_string(),
                });
            }
            ExecutorCommand::UpdateRejectFolderPath { path } => {
                // write through the shared Arc so the
                // next reject lands in the new folder.
                {
                    let mut rc = runtime_config.write();
                    rc.reject_folder_path = path.clone();
                }
                tracing::info!("Runtime reject_folder_path updated: {:?}", path);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "reject_folder_path".to_string(),
                });
            }
            ExecutorCommand::UpdateObserverProfile { profile } => {
                // write through the shared Arc so the
                // next FITS save stamps real keywords.
                {
                    let mut rc = runtime_config.write();
                    rc.observer_profile = profile.clone();
                }
                tracing::info!(
                    "Runtime observer_profile updated: observer={:?}, telescope={:?}",
                    profile.observer_name,
                    profile.telescope_name
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "observer_profile".to_string(),
                });
            }
            ExecutorCommand::UpdateAutofocusInterval { every_n_frames } => {
                // write through runtime_config
                // AND patch the live trigger's `every_n_frames`
                // so the next AutofocusInterval evaluation sees
                // the new cadence without a sequence reload.
                {
                    let mut rc = runtime_config.write();
                    rc.autofocus_interval_frames = Some(every_n_frames);
                }
                {
                    let mut mgr = trigger_manager.write().await;
                    if let Some(trigger) =
                        mgr.standard_mut(crate::triggers::StandardTrigger::AutofocusInterval)
                    {
                        if let TriggerType::AutofocusInterval {
                            every_n_frames: live,
                        } = &mut trigger.trigger_type
                        {
                            *live = every_n_frames;
                        }
                    }
                }
                tracing::info!(
                    "Runtime autofocus-interval cadence updated: every {} frames",
                    every_n_frames
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "autofocus_interval".to_string(),
                });
>>>>>>> 9aab79a51 (Split TriggerState into parts; reset and checkpoint follow from the part)
            }
            ExecutorCommand::RecoveryTryNow => {
                // Recovery Mode — flag the signal bus
                // so the next recovery driver tick fires an
                // immediate attempt instead of waiting for
                // the retry interval. Safe to issue from any
                // state; the driver only consumes the flag
                // while inside a recovery loop, so a stray
                // TryNow in Running is a documented no-op
                // (the operator sees the toast confirmation
                // and nothing else).
                recovery_signals.request_try_now();
                tracing::info!("[RECOVERY] TryNow requested by operator");
                run.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "recovery_try_now".to_string(),
                });
            }
            ExecutorCommand::RecoveryAbort => {
                // Recovery Mode — flag the signal bus.
                // The recovery driver checks `take_abort()`
                // on every tick and exits the loop with a
                // GaveUp transition.
                recovery_signals.request_abort();
                tracing::info!("[RECOVERY] Abort requested by operator");
                run.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "recovery_abort".to_string(),
                });
            }
            ExecutorCommand::PluginNodeFinished {
                node_id,
                success,
                message,
                structured_detail_json,
            } => {
                // resolve the oneshot the
                // matching `PluginNodeInstruction::execute`
                // is awaiting. A stray finish (no pending
                // entry) is logged at warn and dropped;
                // it means either the Dart side replied
                // twice for the same node id, or the
                // executor torch-down already cleaned up
                // the entry on timeout. Either case is
                // benign for the rest of the run.
                let sender = {
                    let mut pending = plugin_node_pending.write().await;
                    pending.remove(&node_id)
                };
                let parsed_detail = structured_detail_json
                    .as_deref()
                    .and_then(|json| {
                        if json.is_empty() {
                            None
                        } else {
                            match serde_json::from_str::<serde_json::Value>(json) {
                                Ok(v) => Some(v),
                                Err(e) => {
                                    tracing::warn!(
                                        "[PLUGIN] PluginNodeFinished structured_detail_json was invalid \
                                         JSON for node {}: {}; payload dropped.",
                                        node_id,
                                        e,
                                    );
                                    None
                                }
                            }
                        }
                    });
                match sender {
                    Some(tx) => {
                        if tx
                            .send(crate::node::context::PluginNodeReply {
                                success,
                                message: message.clone(),
                                structured_detail: parsed_detail,
                            })
                            .is_err()
                        {
                            // Receiver was dropped (timeout
                            // already fired). Log so a
                            // late reply doesn't vanish
                            // silently.
                            tracing::warn!(
                                "[PLUGIN] PluginNodeFinished for node {} arrived after the awaiting future \
                                 had already given up; verdict dropped (success={}, message={:?})",
                                node_id,
                                success,
                                message,
                            );
                        }
                    }
                    None => {
                        tracing::warn!(
                            "[PLUGIN] PluginNodeFinished for unknown node {} (no pending oneshot). \
                             Either the Dart side replied twice, or the request already timed out.",
                            node_id,
                        );
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Handler {
        run: RunControl,
        commands: mpsc::Sender<ExecutorCommand>,
        events: broadcast::Receiver<ExecutorEvent>,
        task: tokio::task::JoinHandle<()>,
    }

    fn running_handler() -> Handler {
        let (events_tx, events) = broadcast::channel(16);
        let (commands, rx) = mpsc::channel(8);
        let run = RunControl {
            state: RunCell::starting_in(events_tx, ExecutorState::Running),
            is_cancelled: Arc::new(AtomicBool::new(false)),
            is_paused: Arc::new(AtomicBool::new(false)),
        };
        let task = tokio::spawn(run_command_handler(CommandHandlerArgs {
            run: run.clone(),
            rx,
            current_recovery: Arc::new(StdRwLock::new(None)),
            recovery_signals: Arc::new(crate::recovery::RecoverySignals::new()),
            resume_notify: Arc::new(tokio::sync::Notify::new()),
            skip_step: Arc::new(AtomicBool::new(false)),
            skip_to_node: Arc::new(StdRwLock::new(None)),
            plugin_node_pending: Arc::new(RwLock::new(HashMap::new())),
        }));
        Handler {
            run,
            commands,
            events,
            task,
        }
    }

    impl Handler {
        /// Send `command` and wait until the handler has taken it and every
        /// command before it.
        async fn send(&self, command: ExecutorCommand) {
            self.commands.send(command).await.unwrap();
            // A second, harmless command is only received once the first has
            // been handled.
            self.commands.send(ExecutorCommand::Skip).await.unwrap();
            while self.commands.capacity() < self.commands.max_capacity() {
                tokio::task::yield_now().await;
            }
        }

        fn state_changes(&mut self) -> Vec<ExecutorState> {
            let mut out = Vec::new();
            while let Ok(event) = self.events.try_recv() {
                if let ExecutorEvent::StateChanged(state) = event {
                    out.push(state);
                }
            }
            out
        }
    }

    /// Stop used to move the executor state and announce it while the
    /// progress snapshot, which is what the status API reports, kept saying
    /// `running` until the run reached its terminal state.
    #[tokio::test]
    async fn stop_reports_stopping_in_the_progress_snapshot() {
        let mut handler = running_handler();
        handler.send(ExecutorCommand::Stop).await;

        assert!(handler.run.is_cancelled());
        assert_eq!(handler.run.state.get(), ExecutorState::Stopping);
        assert_eq!(handler.run.state.progress().state, ExecutorState::Stopping);
        assert_eq!(handler.state_changes(), vec![ExecutorState::Stopping]);
        handler.task.abort();
    }

    #[tokio::test]
    async fn pause_and_resume_are_each_reported_and_announced_once() {
        let mut handler = running_handler();
        handler.send(ExecutorCommand::Pause).await;
        assert_eq!(handler.run.state.progress().state, ExecutorState::Paused);
        assert!(handler.run.is_paused.load(Ordering::Relaxed));

        handler.send(ExecutorCommand::Resume).await;
        assert_eq!(handler.run.state.progress().state, ExecutorState::Running);
        assert!(!handler.run.is_paused.load(Ordering::Relaxed));
        assert_eq!(
            handler.state_changes(),
            vec![ExecutorState::Paused, ExecutorState::Running]
        );
        handler.task.abort();
    }
}
