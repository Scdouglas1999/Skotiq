//! The run's progress callback: folds every `ProgressUpdate` from the node
//! tree into the shared `SequenceProgress` and publishes it to subscribers.

use super::*;

pub(super) struct ProgressCallbackArgs {
    pub event_tx_clone: broadcast::Sender<ExecutorEvent>,
    pub exposure_node_metadata: Arc<HashMap<NodeId, (f64, Option<String>)>>,
    pub node_frame_progress: Arc<StdRwLock<HashMap<NodeId, u32>>>,
    pub node_integration_credited: Arc<StdRwLock<HashMap<NodeId, f64>>>,
    pub node_names: Arc<StdRwLock<HashMap<NodeId, String>>>,
    pub node_pending_exposure_completion: Arc<StdRwLock<HashMap<NodeId, u32>>>,
    pub progress_clone: Arc<StdRwLock<SequenceProgress>>,
    pub start_time: std::time::Instant,
    pub started_nodes: Arc<StdRwLock<std::collections::HashSet<NodeId>>>,
    pub target_node_metadata: Arc<HashMap<NodeId, (String, f64, f64)>>,
}

pub(super) fn build_progress_callback(
    args: ProgressCallbackArgs,
) -> crate::node::context::ProgressCallback {
    let ProgressCallbackArgs {
        event_tx_clone,
        exposure_node_metadata,
        node_frame_progress,
        node_integration_credited,
        node_names,
        node_pending_exposure_completion,
        progress_clone,
        start_time,
        started_nodes,
        target_node_metadata,
    } = args;
    Arc::new(move |update: ProgressUpdate| {
        let mut prog = progress_clone.write();
        prog.current_node_id = Some(update.node_id.clone());
        // Move the name with the id (see `node_names` above). Unknown
        // until the node's entry message has been seen, in which case
        // we publish None rather than the PREVIOUS node's name — a
        // missing name is honest, a stale one is not.
        prog.current_node_name = node_names.read().get(&update.node_id).cloned();
        prog.current_node_status = Some(update.status);
        // `legacy_message` synthesises the pre-refactor message
        // shape from the structured fields (or returns the raw
        // lifecycle message verbatim), so prog.message preserves
        // its existing UI contract.
        let legacy_message = update.legacy_message();
        prog.message = legacy_message.clone();
        prog.node_statuses
            .insert(update.node_id.clone(), update.status);
        prog.elapsed_secs = start_time.elapsed().as_secs_f64();

        if update.status == NodeStatus::Running {
            let mut started = started_nodes.write();
            if !started.contains(&update.node_id) {
                started.insert(update.node_id.clone());
                // RuntimeNode emits the "Executing: <name>" lifecycle
                // message exactly once at node entry; this is how we
                // pull the display name out for NodeStarted. Subsequent
                // progress events are structured so this branch is the
                // only place we still parse a message.
                //
                // A message-less update names nothing, and this branch used to
                // answer that with the literal "Unknown" — then cache it, so a
                // node whose id re-entered this branch mid-run (a Smart
                // Exposure between bursts; see `node_names` in `start.rs`)
                // reported itself as "Unknown" to every client for the rest of
                // the run. The seeded map already holds the authored name, so
                // the parse only ever CONFIRMS a name and never replaces a
                // known one with a placeholder.
                let parsed_name = update.message.as_ref().map(|m| {
                    if let Some(name) = m.strip_prefix("Executing: ") {
                        name.to_string()
                    } else {
                        m.clone()
                    }
                });
                let node_name = {
                    let mut names = node_names.write();
                    match parsed_name {
                        Some(parsed) => {
                            names.insert(update.node_id.clone(), parsed.clone());
                            parsed
                        }
                        // Unnamed in the definition AND unnamed on the wire:
                        // the node id is the only identity there is, and
                        // saying so beats inventing a display name.
                        None => names
                            .get(&update.node_id)
                            .cloned()
                            .unwrap_or_else(|| update.node_id.clone()),
                    }
                };
                prog.current_node_name = Some(node_name.clone());
                tracing::info!(
                    "[PROGRESS_CB] Emitting NodeStarted: id={}, name={}",
                    update.node_id,
                    node_name
                );
                let _ = event_tx_clone.send(ExecutorEvent::NodeStarted {
                    id: update.node_id.clone(),
                    name: node_name,
                });
                // Entering a target's subtree IS the target change.
                // Emitted from the same one-shot entry branch as
                // NodeStarted so a Loop that re-enters the target
                // re-announces it, and so the announcement can
                // never precede the node actually running.
                if let Some((target_name, ra, dec)) = target_node_metadata.get(&update.node_id) {
                    let _ = event_tx_clone.send(ExecutorEvent::TargetStarted {
                        name: target_name.clone(),
                        ra: *ra,
                        dec: *dec,
                    });
                }
            }
        } else if matches!(
            update.status,
            NodeStatus::Success | NodeStatus::Failure | NodeStatus::Cancelled | NodeStatus::Skipped
        ) {
            // Clearing on terminal status lets a loop body emit a
            // fresh NodeStarted on its next iteration; otherwise the
            // UI would never re-flash the node as active when the
            // loop cycles.
            //
            // The per-node FRAME counters are deliberately NOT reset
            // here: an exposure burst's final update carries both a
            // terminal status AND `current_frame`/`total_frames` (see
            // `expose.rs`, which repeats the last frame number to
            // publish `completed_exposure_secs`). Resetting the
            // counter first made the frame block below see last=0 and
            // re-advance 0 -> N for a burst it had already counted
            // frame-by-frame, so `completed_exposures` counted every
            // burst TWICE (verified on the rig: a 3-frame burst
            // emitted frames 1,2,3 and then 1,2,3 again). That figure
            // is checkpointed, so a resumed run believed it had
            // already taken twice the frames it had. The reset now
            // happens after the frame block.
            let mut started = started_nodes.write();
            let was_started = started.remove(&update.node_id);
            // Announce the node's terminal status, exactly once, and only
            // for a node we actually announced as started. Without this the
            // `NodeStarted` above is never answered: `RuntimeNode::execute`
            // emits the terminal `ProgressUpdate` for every node it ran —
            // leaf AND container, the root sequence node included — but this
            // callback used to swallow it, so every node the run touched
            // stayed `NodeStatus.running` in the UI forever. A finished run
            // then rendered a tree of nodes still claiming to be executing,
            // each with a spinning status icon, which on the Linux embedder
            // (full-window frame per dirty mark) cost ~61 fps and ~43% of a
            // core indefinitely after the run had ended.
            //
            // `started.remove` returning true is the pairing check: it is
            // true only for a node that emitted `NodeStarted`, so a loop
            // body gets one Started/Completed pair per iteration and a node
            // that was never entered gets neither.
            if was_started {
                tracing::info!(
                    "[PROGRESS_CB] Emitting NodeCompleted: id={}, status={:?}",
                    update.node_id,
                    update.status
                );
                let _ = event_tx_clone.send(ExecutorEvent::NodeCompleted {
                    id: update.node_id.clone(),
                    status: update.status,
                });
            }
            // Only Success closes a target. A target node that
            // failed, was cancelled or was skipped did not
            // "complete" it, and `SequencerEvent::TargetCompleted`
            // is rendered to the operator as "Completed target: X".
            if update.status == NodeStatus::Success {
                if let Some((target_name, _, _)) = target_node_metadata.get(&update.node_id) {
                    let _ = event_tx_clone.send(ExecutorEvent::TargetCompleted {
                        name: target_name.clone(),
                    });
                }
            }
            tracing::debug!(
                "[PROGRESS_CB] Cleared node {} from started set (status={:?})",
                update.node_id,
                update.status
            );
        }

        let node_reached_terminal_status = matches!(
            update.status,
            NodeStatus::Success | NodeStatus::Failure | NodeStatus::Cancelled | NodeStatus::Skipped
        );

        if let (Some(current), Some(total)) = (update.current_frame, update.total_frames) {
            let mut exposure_started_event: Option<ExecutorEvent> = None;
            // One ExposureCompleted per frame that finished. A burst
            // can advance by more than one frame at a time (smart
            // exposure reports per BATCH), and Dart adds one frame +
            // one exposure-duration to the run vitals per event, so
            // a batch of N must produce N events to be counted.
            let mut exposure_completed_events: Vec<ExecutorEvent> = Vec::new();
            let metadata = exposure_node_metadata.get(&update.node_id).cloned();

            let mut frame_progress = node_frame_progress.write();
            let mut pending_completion = node_pending_exposure_completion.write();
            let last = frame_progress.entry(update.node_id.clone()).or_insert(0);
            if current > *last {
                let previous = *last;
                prog.completed_exposures = prog.completed_exposures.saturating_add(current - *last);
                *last = current;

                // Credit the frames that just landed, on the same
                // monotonic sighting that advances the frame counter.
                // That guard is what makes `completed_exposures`
                // exactly-once under retries and batched bursts, so
                // the integration riding on it is exactly-once too.
                // Credit the seconds the frames were
                // RECORDED as, not the seconds the node planned.
                // The producer stamps `frame_exposure_secs` from the
                // camera's own bounded report — the same number the
                // FITS header and the `captured_images` row were
                // written from — so this total and the Session
                // Report's row sum are the same figure. Crediting
                // the plan is what let one run read `50s` on one
                // surface and `1m 0s` on three others.
                let recorded_secs = update
                    .frame_exposure_secs
                    .or_else(|| metadata.as_ref().map(|(planned, _)| *planned));
                if let Some(secs) = recorded_secs {
                    let credited = f64::from(current - previous) * secs;
                    prog.completed_integration_secs += credited;
                    *node_integration_credited
                        .write()
                        .entry(update.node_id.clone())
                        .or_insert(0.0) += credited;
                }

                if let Some((planned_secs, filter)) = metadata {
                    let duration_secs = recorded_secs.unwrap_or(planned_secs);
                    exposure_started_event = Some(ExecutorEvent::ExposureStarted {
                        frame: current,
                        total,
                        filter,
                        duration_secs,
                    });
                    // Completion is synthesized from the SAME sighting
                    // that advances the counter, because every producer
                    // reports a frame only AFTER it finished
                    // (`instructions.rs` calls the per-frame callback
                    // right after `completed_exposures += 1`;
                    // smart-exposure emits after `frames_just_taken`).
                    // Waiting for a second sighting of the same frame
                    // number would emit nothing: the next per-frame
                    // callback ADVANCES the number, and the one duplicate
                    // that does exist — the burst's final lifecycle
                    // update — carries a terminal status, so the
                    // terminal-status cleanup a few lines above wipes the
                    // pending marker before this block runs.
                    //
                    // `completed_exposures` is deliberately left on this
                    // branch: it feeds checkpoint/resume, which must
                    // only ever count frames that actually completed.
                    for frame in (previous + 1)..=current {
                        exposure_completed_events.push(ExecutorEvent::ExposureCompleted {
                            frame,
                            total,
                            duration_secs,
                        });
                    }
                }
                // No pending marker is recorded any more, so the
                // duplicate final sighting cannot double-count.
                pending_completion.remove(&update.node_id);
            }

            drop(pending_completion);
            drop(frame_progress);

            if let Some(event) = exposure_started_event {
                let _ = event_tx_clone.send(event);
            }
            for event in exposure_completed_events {
                let _ = event_tx_clone.send(event);
            }
        }

        // Reset the per-node frame counters only AFTER this update's
        // frame numbers have been accounted for, so a burst's final
        // (terminal + frame-bearing) update cannot re-advance from
        // zero. The next loop iteration still starts from a clean
        // counter, which is what the reset is for.
        if node_reached_terminal_status {
            node_frame_progress.write().remove(&update.node_id);
            node_pending_exposure_completion
                .write()
                .remove(&update.node_id);
        }

        if let Some(exposure_secs) = update.completed_exposure_secs {
            // The burst's closing total, minus whatever its frames
            // already contributed above. For a TakeExposure node
            // that ran to completion this is zero; for a producer
            // with no per-frame duration it is the whole burst.
            // Never negative: a node that reported more per-frame
            // than its own total must not claw integration back.
            let already = node_integration_credited
                .write()
                .remove(&update.node_id)
                .unwrap_or(0.0);
            prog.completed_integration_secs += (exposure_secs - already).max(0.0);
        }

        // pluck per-target / per-filter
        // budget progress out of the structured detail so the
        // executor's ProgressUpdated event carries enough
        // information for the dashboard's budget panel
        // without re-querying the registry from Dart.
        if let Some(ProgressDetail::IntegrationBudget {
            target_id,
            filter,
            completed_secs,
            budget_met,
            ..
        }) = update.detail.as_ref()
        {
            prog.integration_by_target_filter
                .entry(target_id.clone())
                .or_default()
                .insert(filter.clone(), *completed_secs);
            if *budget_met {
                prog.targets_with_budget_met.insert(target_id.clone());
            }
        }

        if prog.total_exposures > 0 && prog.completed_exposures > 0 {
            let completed = prog.completed_exposures.min(prog.total_exposures);
            let remaining = prog.total_exposures.saturating_sub(completed);
            if remaining > 0 {
                // Why: completed and remaining are u32 progress counters; u32 -> f64
                // is lossless (f64 mantissa is 53 bits, u32::MAX < 2^32).
                let avg_secs_per_exposure = prog.elapsed_secs / f64::from(completed);
                prog.estimated_remaining_secs = Some(avg_secs_per_exposure * f64::from(remaining));
            } else {
                prog.estimated_remaining_secs = Some(0.0);
            }
        } else {
            prog.estimated_remaining_secs = None;
        }

        // Structured NodeProgress emission. The structured payload
        // (instruction, progress_percent, detail) is read directly
        // from the ProgressUpdate — NO STRING PARSING. Pre-refactor
        // this used `split_once(':')` + `rfind('(')` to recover the
        // fields; that pipeline is gone. The on-wire detail string
        // is rendered from the ProgressDetail via `detail_text()`
        // so the existing FRB / Dart consumers see the same shape.
        if let (Some(instruction), Some(percent), Some(detail)) = (
            update.instruction.as_ref(),
            update.progress_percent,
            update.detail.as_ref(),
        ) {
            let detail_text = detail.detail_text();
            tracing::debug!(
                "[PROGRESS_CB] Emitting structured NodeProgress: node_id={}, instruction={}, progress={}%, detail={}",
                update.node_id,
                instruction,
                percent,
                detail_text
            );
            // the `detail` field stays a string for legacy
            // back-compat (older subscribers parse it). The new
            // `structured_detail` carries the typed payload so the
            // bridge can dispatch typed `SequencerEvent` variants
            // without regex parsing.
            let _ = event_tx_clone.send(ExecutorEvent::NodeProgress {
                node_id: update.node_id.clone(),
                instruction: instruction.clone(),
                progress_percent: percent,
                detail: detail_text,
                structured_detail: Some(Box::new(detail.clone())),
            });
        }

        // `ProgressUpdated` carries a boxed `SequenceProgress`
        // so the enum stays small (see `ExecutorEvent` doc-comment).
        let _ = event_tx_clone.send(ExecutorEvent::ProgressUpdated(Box::new(prog.clone())));
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::progress::ProgressUpdate;

    fn callback_with_channel() -> (
        crate::node::context::ProgressCallback,
        broadcast::Receiver<ExecutorEvent>,
        Arc<StdRwLock<std::collections::HashSet<NodeId>>>,
    ) {
        let (tx, rx) = broadcast::channel(256);
        let started_nodes: Arc<StdRwLock<std::collections::HashSet<NodeId>>> =
            Arc::new(StdRwLock::new(std::collections::HashSet::new()));
        let cb = build_progress_callback(ProgressCallbackArgs {
            event_tx_clone: tx,
            exposure_node_metadata: Arc::new(HashMap::new()),
            node_frame_progress: Arc::new(StdRwLock::new(HashMap::new())),
            node_integration_credited: Arc::new(StdRwLock::new(HashMap::new())),
            node_names: Arc::new(StdRwLock::new(HashMap::new())),
            node_pending_exposure_completion: Arc::new(StdRwLock::new(HashMap::new())),
            progress_clone: Arc::new(StdRwLock::new(SequenceProgress::default())),
            start_time: std::time::Instant::now(),
            started_nodes: started_nodes.clone(),
            target_node_metadata: Arc::new(HashMap::new()),
        });
        (cb, rx, started_nodes)
    }

    fn drain(rx: &mut broadcast::Receiver<ExecutorEvent>) -> Vec<ExecutorEvent> {
        let mut out = Vec::new();
        while let Ok(ev) = rx.try_recv() {
            out.push(ev);
        }
        out
    }

    /// The regression this pins: a node that reports a terminal status must
    /// announce it. Without the `NodeCompleted` send in the terminal branch
    /// the UI hears `NodeStarted` and nothing else, so every node a run
    /// touched — the root container included — stays `running` forever, which
    /// both states something untrue and leaves its status spinner animating
    /// (measured: ~61 fps and ~43% of a core after the run had ended).
    #[test]
    fn terminal_status_emits_node_completed_for_a_started_node() {
        let (cb, mut rx, _started) = callback_with_channel();

        cb(ProgressUpdate::lifecycle(
            "node-1".to_string(),
            NodeStatus::Running,
            "Executing: Take Exposures",
        ));
        cb(ProgressUpdate::lifecycle(
            "node-1".to_string(),
            NodeStatus::Success,
            "Completed: Take Exposures",
        ));

        let events = drain(&mut rx);
        assert!(
            events
                .iter()
                .any(|e| matches!(e, ExecutorEvent::NodeStarted { id, .. } if id == "node-1")),
            "expected a NodeStarted for node-1, got {events:?}"
        );
        let completed: Vec<_> = events
            .iter()
            .filter_map(|e| match e {
                ExecutorEvent::NodeCompleted { id, status } if id == "node-1" => Some(*status),
                _ => None,
            })
            .collect();
        assert_eq!(
            completed,
            vec![NodeStatus::Success],
            "expected exactly one NodeCompleted(Success) for node-1, got {events:?}"
        );
    }

    /// Containers go through the same callback as leaves, so the root
    /// sequence node must be answered too — it is one of the two nodes that
    /// was observed still spinning on a finished run.
    #[test]
    fn every_started_node_is_answered_including_containers() {
        let (cb, mut rx, _started) = callback_with_channel();

        for id in ["root-container", "leaf"] {
            cb(ProgressUpdate::lifecycle(
                id.to_string(),
                NodeStatus::Running,
                format!("Executing: {id}"),
            ));
        }
        // Leaves finish before the container that owns them.
        for id in ["leaf", "root-container"] {
            cb(ProgressUpdate::lifecycle(
                id.to_string(),
                NodeStatus::Success,
                format!("Completed: {id}"),
            ));
        }

        let events = drain(&mut rx);
        let mut answered: Vec<String> = events
            .iter()
            .filter_map(|e| match e {
                ExecutorEvent::NodeCompleted { id, .. } => Some(id.clone()),
                _ => None,
            })
            .collect();
        answered.sort();
        assert_eq!(
            answered,
            vec!["leaf".to_string(), "root-container".to_string()],
            "both the leaf and the container that ran it must report terminal, got {events:?}"
        );
    }

    /// Failure, cancellation and skipping are terminal too — a node that
    /// ends any of those ways has stopped running and must say so.
    #[test]
    fn non_success_terminal_statuses_are_announced_verbatim() {
        for status in [
            NodeStatus::Failure,
            NodeStatus::Cancelled,
            NodeStatus::Skipped,
        ] {
            let (cb, mut rx, _started) = callback_with_channel();
            cb(ProgressUpdate::lifecycle(
                "n".to_string(),
                NodeStatus::Running,
                "Executing: n",
            ));
            cb(ProgressUpdate::lifecycle(
                "n".to_string(),
                status,
                "done: n",
            ));
            let events = drain(&mut rx);
            let reported: Vec<_> = events
                .iter()
                .filter_map(|e| match e {
                    ExecutorEvent::NodeCompleted { status, .. } => Some(*status),
                    _ => None,
                })
                .collect();
            assert_eq!(
                reported,
                vec![status],
                "{status:?} must be reported as itself, not folded onto another status"
            );
        }
    }

    /// The pairing rule: `NodeCompleted` follows a `NodeStarted` we actually
    /// sent. A terminal update for a node that never entered (so never
    /// announced a start) must not invent a completion, and a loop body that
    /// re-enters gets one pair per iteration rather than a doubled tail.
    #[test]
    fn completion_is_paired_with_a_start_never_invented_or_doubled() {
        let (cb, mut rx, _started) = callback_with_channel();

        // Terminal with no preceding Running: nothing to answer.
        cb(ProgressUpdate::lifecycle(
            "never-ran".to_string(),
            NodeStatus::Skipped,
            "Skipped: never-ran",
        ));
        assert!(
            !drain(&mut rx)
                .iter()
                .any(|e| matches!(e, ExecutorEvent::NodeCompleted { .. })),
            "a node that never started must not report a completion"
        );

        // Two loop iterations: two starts, two completions, in order.
        for _ in 0..2 {
            cb(ProgressUpdate::lifecycle(
                "body".to_string(),
                NodeStatus::Running,
                "Executing: body",
            ));
            cb(ProgressUpdate::lifecycle(
                "body".to_string(),
                NodeStatus::Success,
                "Completed: body",
            ));
        }
        let events = drain(&mut rx);
        let lifecycle: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                ExecutorEvent::NodeStarted { id, .. } if id == "body" => Some("start"),
                ExecutorEvent::NodeCompleted { id, .. } if id == "body" => Some("done"),
                _ => None,
            })
            .collect();
        assert_eq!(lifecycle, vec!["start", "done", "start", "done"]);

        // A repeated terminal for an already-answered node adds nothing.
        cb(ProgressUpdate::lifecycle(
            "body".to_string(),
            NodeStatus::Success,
            "Completed: body",
        ));
        assert!(
            !drain(&mut rx)
                .iter()
                .any(|e| matches!(e, ExecutorEvent::NodeCompleted { .. })),
            "a duplicate terminal update must not emit a second completion"
        );
    }
}
