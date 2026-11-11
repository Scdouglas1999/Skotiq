//! The command handler: drains run-control messages for the life of the run
//! (pause/resume, stop, skip, the recovery buttons, plugin-node replies).

use super::*;

pub(super) async fn run_command_handler(run: Arc<Run>, mut rx: mpsc::Receiver<ExecutorCommand>) {
    let current_recovery = &run.recovery.current;
    let recovery_signals = &run.recovery.signals;
    let resume_notify = &run.resume_notify;
    let skip_step = &run.skip_current_step;
    let skip_to_node = &run.skip_to_node;
    let plugin_node_pending = &run.plugin_node_pending;
    let run = &run.control;
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
                *skip_to_node.write() = Some(node_id.clone());
                run.send(skip_to_node_accepted_event(node_id));
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
        let run = Arc::new(Run::detached(
            Arc::new(crate::device_ops::NullDeviceOps),
            RunCell::starting_in(events_tx, ExecutorState::Running),
        ));
        let task = tokio::spawn(run_command_handler(run.clone(), rx));
        let run = run.control.clone();
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
