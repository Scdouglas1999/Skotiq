//! The run's progress callback: folds every `ProgressUpdate` from the node
//! tree into the shared `SequenceProgress` and publishes it to subscribers.

use super::*;

/// What an exposure node of the plan takes.
#[derive(Debug, Clone)]
pub(crate) struct ExposureNodePlan {
    pub planned_secs: f64,
    pub filter: Option<String>,
    pub frame_type: crate::FrameType,
}

pub(super) struct ProgressCallbackArgs {
    pub exposure_node_metadata: Arc<HashMap<NodeId, ExposureNodePlan>>,
    pub node_frame_progress: Arc<StdRwLock<HashMap<NodeId, u32>>>,
    pub node_integration_credited: Arc<StdRwLock<HashMap<NodeId, f64>>>,
    pub node_names: Arc<StdRwLock<HashMap<NodeId, String>>>,
    pub run_state: RunCell,
    pub start_time: std::time::Instant,
    pub started_nodes: Arc<StdRwLock<std::collections::HashSet<NodeId>>>,
    pub target_node_metadata: Arc<HashMap<NodeId, (String, f64, f64)>>,
}

pub(super) fn build_progress_callback(
    args: ProgressCallbackArgs,
) -> crate::node::context::ProgressCallback {
    let ProgressCallbackArgs {
        exposure_node_metadata,
        node_frame_progress,
        node_integration_credited,
        node_names,
        run_state,
        start_time,
        started_nodes,
        target_node_metadata,
    } = args;
    let event_tx_clone = run_state.events().clone();
    // The percent each running node last reported, which a status report
    // that does not move the step is published at. A report from a node the
    // run never entered is not a step's progress and is not published.
    let node_percent: StdRwLock<HashMap<NodeId, f64>> = StdRwLock::new(HashMap::new());
    // The words of the status report each running node last published. A
    // step that repeats itself (a poll restating the same wait) goes out to
    // clients once.
    let node_last_status: StdRwLock<HashMap<NodeId, String>> = StdRwLock::new(HashMap::new());
    Arc::new(move |mut update: ProgressUpdate| {
        let mut repeated_status = false;
        if let (Some(instruction), Some(detail)) = (&update.instruction, &update.detail) {
            let mut percents = node_percent.write();
            let mut last_status = node_last_status.write();
            match update.progress_percent {
                Some(percent) => {
                    percents.insert(update.node_id.clone(), percent);
                    last_status.remove(&update.node_id);
                }
                None => {
                    update.progress_percent = percents.get(&update.node_id).copied();
                    let words = format!("{instruction}\n{}", detail.detail_text());
                    repeated_status = last_status
                        .get(&update.node_id)
                        .is_some_and(|last| *last == words);
                    last_status.insert(update.node_id.clone(), words);
                }
            }
        }
        run_state.update_progress(|prog| {
            prog.current_node_id = Some(update.node_id.clone());
            // Move the name with the id (see `node_names` above). Unknown
            // until the node's entry message has been seen, in which case
            // we publish None rather than the PREVIOUS node's name — a
            // missing name is honest, a stale one is not.
            prog.current_node_name = node_names.read().get(&update.node_id).cloned();
            prog.current_node_status = Some(update.status);
            // `legacy_message` synthesises the UI's message
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
                    // A step starts at 0 %, which its status reports go out at
                    // until it reports a percent of its own.
                    node_percent.write().insert(update.node_id.clone(), 0.0);
                    // A node names itself on its entry update. A message-less
                    // update names nothing: the seeded map holds the authored
                    // name, so a name is only ever confirmed, never replaced
                    // by a placeholder.
                    let parsed_name = update.node_name.clone().or_else(|| update.message.clone());
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
                        frame_type: exposure_node_metadata
                            .get(&update.node_id)
                            .map(|plan| plan.frame_type),
                    });
                    // Entering a target's subtree IS the target change.
                    // Emitted from the same one-shot entry branch as
                    // NodeStarted so a Loop that re-enters the target
                    // re-announces it, and so the announcement can
                    // never precede the node actually running.
                    if let Some((target_name, ra, dec)) = target_node_metadata.get(&update.node_id)
                    {
                        let _ = event_tx_clone.send(ExecutorEvent::TargetStarted {
                            name: target_name.clone(),
                            ra: *ra,
                            dec: *dec,
                        });
                    }
                }
            } else if matches!(
                update.status,
                NodeStatus::Success
                    | NodeStatus::Failure
                    | NodeStatus::Cancelled
                    | NodeStatus::Skipped
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
                node_percent.write().remove(&update.node_id);
                node_last_status.write().remove(&update.node_id);
                let mut started = started_nodes.write();
                let was_started = started.remove(&update.node_id);
                // Announce the node's terminal status, exactly once, and only
                // for a node we actually announced as started. `RuntimeNode::execute`
                // emits the terminal `ProgressUpdate` for every node it ran —
                // leaf AND container, the root sequence node included.
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
                NodeStatus::Success
                    | NodeStatus::Failure
                    | NodeStatus::Cancelled
                    | NodeStatus::Skipped
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
                let last = frame_progress.entry(update.node_id.clone()).or_insert(0);
                if current > *last {
                    let previous = *last;
                    prog.completed_exposures =
                        prog.completed_exposures.saturating_add(current - *last);
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
                        .or_else(|| metadata.as_ref().map(|plan| plan.planned_secs));
                    if let Some(secs) = recorded_secs {
                        let credited = f64::from(current - previous) * secs;
                        prog.completed_integration_secs += credited;
                        *node_integration_credited
                            .write()
                            .entry(update.node_id.clone())
                            .or_insert(0.0) += credited;
                    }

                    if let Some(plan) = metadata {
                        let duration_secs = recorded_secs.unwrap_or(plan.planned_secs);
                        exposure_started_event = Some(ExecutorEvent::ExposureStarted {
                            frame: current,
                            total,
                            filter: plan.filter,
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
                }

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
                    prog.estimated_remaining_secs =
                        Some(avg_secs_per_exposure * f64::from(remaining));
                } else {
                    prog.estimated_remaining_secs = Some(0.0);
                }
            } else {
                prog.estimated_remaining_secs = None;
            }

            if let (false, Some(instruction), Some(percent), Some(detail)) = (
                repeated_status,
                update.instruction.as_ref(),
                update.progress_percent,
                update.detail.as_ref(),
            ) {
                tracing::debug!(
                "[PROGRESS_CB] NodeProgress: node_id={}, instruction={}, progress={}%, detail={}",
                update.node_id,
                instruction,
                percent,
                detail.detail_text()
            );
                let _ = event_tx_clone.send(ExecutorEvent::NodeProgress {
                    node_id: update.node_id.clone(),
                    instruction: instruction.clone(),
                    progress_percent: percent,
                    detail: Box::new(detail.clone()),
                });
            }

            // `ProgressUpdated` carries a boxed `SequenceProgress`
            // so the enum stays small (see `ExecutorEvent` doc-comment).
            let _ = event_tx_clone.send(ExecutorEvent::ProgressUpdated(Box::new(prog.clone())));
        })
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
            exposure_node_metadata: Arc::new(HashMap::new()),
            node_frame_progress: Arc::new(StdRwLock::new(HashMap::new())),
            node_integration_credited: Arc::new(StdRwLock::new(HashMap::new())),
            node_names: Arc::new(StdRwLock::new(HashMap::new())),
            run_state: RunCell::new(tx),
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

        cb(ProgressUpdate::node_entry(
            "node-1".to_string(),
            "Take Exposures",
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
            cb(ProgressUpdate::node_entry(id.to_string(), id));
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
            cb(ProgressUpdate::node_entry("n".to_string(), "n"));
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
            cb(ProgressUpdate::node_entry("body".to_string(), "body"));
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

    /// A report that does not move the step goes out as the step's progress
    /// at the percent the step last reported, so its bar does not drop.
    #[test]
    fn a_status_report_is_published_at_the_steps_last_percent() {
        let (cb, mut rx, _started) = callback_with_channel();
        cb(ProgressUpdate::node_entry(
            "burst".to_string(),
            "Take Exposures",
        ));
        cb(ProgressUpdate::instruction_progress(
            "burst".to_string(),
            "Exposure",
            40.0,
            ProgressDetail::Generic("frame 2".to_string()),
        ));
        drain(&mut rx);
        cb(ProgressUpdate::status(
            "burst".to_string(),
            "Exposure",
            "Holding the next exposure",
        ));
        let published: Vec<f64> = drain(&mut rx)
            .iter()
            .filter_map(|e| match e {
                ExecutorEvent::NodeProgress {
                    node_id,
                    progress_percent,
                    ..
                } if node_id == "burst" => Some(*progress_percent),
                _ => None,
            })
            .collect();
        assert_eq!(published, vec![40.0]);
    }

    /// A step that restates the same status goes out once; a new status, or
    /// the same one after a reading, goes out again.
    #[test]
    fn a_repeated_status_report_is_published_once() {
        let (cb, mut rx, _started) = callback_with_channel();
        cb(ProgressUpdate::node_entry("tgt".to_string(), "Target"));
        drain(&mut rx);
        let say = |words: &str| cb(ProgressUpdate::status("tgt".to_string(), "Target", words));
        say("Waiting for M 31: time ≥ 21:00");
        say("Waiting for M 31: time ≥ 21:00");
        say("Waiting for M 31 to clear the altitude floor");
        cb(ProgressUpdate::instruction_progress(
            "tgt".to_string(),
            "Target",
            10.0,
            ProgressDetail::Generic("Slewing".to_string()),
        ));
        say("Waiting for M 31 to clear the altitude floor");
        let published: Vec<String> = drain(&mut rx)
            .iter()
            .filter_map(|e| match e {
                ExecutorEvent::NodeProgress { detail, .. } => Some(detail.detail_text()),
                _ => None,
            })
            .collect();
        assert_eq!(
            published,
            vec![
                "Waiting for M 31: time ≥ 21:00",
                "Waiting for M 31 to clear the altitude floor",
                "Slewing",
                "Waiting for M 31 to clear the altitude floor",
            ]
        );
    }
}
