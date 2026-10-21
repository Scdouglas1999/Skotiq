use super::*;

/// Set once the two event bridges below are running, so a second call cannot
/// stand up a second copy of them.
///
/// Every caller treats this as "make sure events are flowing" and calls it
/// unconditionally — the Dart bridge does it at the top of `sequencerStart()`,
/// and the headless and remote entry points reach the same place. Without the
/// latch each call spawns another pair of supervised tasks, each with its own
/// receiver on the executor's broadcast channel, so every sequencer event
/// reaches the UI once per run started in this launch. `spawn_supervised_restart`
/// is a bare `tokio::spawn` with no registry, so the task name does not dedupe.
///
/// Latching for the process lifetime is safe because the executor is a
/// `OnceLock` singleton whose broadcast sender is created in
/// `SequenceExecutor::new()` and never replaced — the loops can only see
/// `Closed` at process teardown, and the supervisor's restart-on-panic keeps
/// them alive through anything short of that.
pub(crate) static SEQUENCER_EVENT_BRIDGES_STARTED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Subscribe to sequencer events and forward them to the main event stream
pub async fn api_sequencer_subscribe_events() -> Result<(), SkotiqError> {
    // Validate the executor is reachable before spawning the supervisor so a
    // bad caller still gets an error synchronously. Drop the lock immediately
    // — the supervisor takes a fresh one on every restart.
    {
        let _executor = get_sequence_executor().read().await;
    }

    if SEQUENCER_EVENT_BRIDGES_STARTED
        .compare_exchange(
            false,
            true,
            std::sync::atomic::Ordering::SeqCst,
            std::sync::atomic::Ordering::SeqCst,
        )
        .is_err()
    {
        tracing::debug!("[EVENT_SUB] Sequencer event bridges already running; no-op");
        return Ok(());
    }

    let state = get_state().clone();

    tracing::info!("[EVENT_SUB] Sequencer event subscription started");

    // The event bridge MUST stay alive for the lifetime of the UI; losing
    // it silently means the user sees zero sequencer updates with no error.
    // Supervise with restart-on-panic and exponential backoff.
    crate::util::supervisor::spawn_supervised_restart(
        "sequencer_event_bridge",
        crate::util::supervisor::RestartPolicy::DEFAULT,
        move || {
            let state = state.clone();
            async move {
                let mut rx = {
                    let executor = get_sequence_executor().read().await;
                    executor.subscribe()
                };
                tracing::info!("[EVENT_SUB] Event listener task spawned");
                run_sequencer_event_loop(&mut rx, &state).await;
            }
        },
        Some(|msg: &str| {
            tracing::error!(
                target: "supervisor",
                "sequencer_event_bridge exhausted restart budget; UI will stop receiving sequencer events. Last panic: {msg}"
            );
        }),
    );

    // Replay Debug — parallel supervisor that pumps the
    // executor's structured-decision broadcast channel onto the
    // unified SkotiqEvent stream as `SequencerEvent::DecisionLogged`.
    // Runs as a sibling task to the main event loop because the two
    // channels live on independent broadcast::channel instances on the
    // executor — joining them in one select! would couple their lag
    // policies. We supervise restart so a panic on the decision side
    // does not bring the main loop down.
    let decision_state = get_state().clone();
    crate::util::supervisor::spawn_supervised_restart(
        "sequencer_decision_bridge",
        crate::util::supervisor::RestartPolicy::DEFAULT,
        move || {
            let state = decision_state.clone();
            async move {
                let mut rx = {
                    let executor = get_sequence_executor().read().await;
                    executor.subscribe_decisions()
                };
                tracing::info!("[DECISION_SUB] Decision listener task spawned");
                run_decision_event_loop(&mut rx, &state).await;
            }
        },
        Some(|msg: &str| {
            tracing::error!(
                target: "supervisor",
                "sequencer_decision_bridge exhausted restart budget; replay log will stop populating. Last panic: {msg}"
            );
        }),
    );

    Ok(())
}

/// Replay Debug — bridge loop that publishes every
/// `DecisionEvent` from the executor onto the unified
/// `SkotiqEvent` stream as `SequencerEvent::DecisionLogged`.
/// Pulled out so the supervisor restart factory can call it on every
/// restart.
pub(crate) async fn run_decision_event_loop(
    rx: &mut tokio::sync::broadcast::Receiver<skotiq_sequencer::DecisionEvent>,
    state: &SharedAppState,
) {
    loop {
        let decision = match rx.recv().await {
            Ok(ev) => ev,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                tracing::warn!(
                    "[DECISION_SUB] Lagged behind sequencer decisions; skipped {} events",
                    skipped
                );
                continue;
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                tracing::info!("[DECISION_SUB] Decision channel closed; bridge exiting");
                return;
            }
        };
        let details_json = serde_json::to_string(&decision.details).unwrap_or_else(|err| {
            tracing::warn!(
                "[DECISION_SUB] Failed to serialise decision details to JSON: {}",
                err
            );
            "{}".to_string()
        });
        let payload = SequencerEvent::DecisionLogged {
            timestamp_iso: decision.timestamp.to_rfc3339(),
            category: decision.category.wire_key().to_string(),
            summary: decision.summary,
            details_json,
            node_id: decision.node_id,
            sequence_run_id: decision.sequence_run_id,
        };
        state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::Sequencer,
            EventPayload::Sequencer(payload),
        ));
    }
}

/// Inner event-loop body for [`api_sequencer_subscribe_events`].
/// Pulled out so the supervisor factory can call it on every restart.
pub(crate) async fn run_sequencer_event_loop(
    rx: &mut tokio::sync::broadcast::Receiver<ExecutorEvent>,
    state: &SharedAppState,
) {
    loop {
        let event = match rx.recv().await {
            Ok(ev) => ev,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                tracing::warn!(
                    "[EVENT_SUB] Lagged behind sequencer; skipped {} events",
                    skipped
                );
                continue;
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                tracing::info!("[EVENT_SUB] Sequencer event channel closed; bridge exiting");
                return;
            }
        };
        {
            tracing::debug!(
                "[EVENT_SUB] Received event: {:?}",
                std::mem::discriminant(&event)
            );
            let skotiq_event = match &event {
                ExecutorEvent::StateChanged(s) => {
                    let _state_str = match s {
                        ExecutorState::Running => "running",
                        ExecutorState::Paused => "paused",
                        ExecutorState::Cancelled => "cancelled",
                        ExecutorState::Completed => "completed",
                        _ => continue,
                    };
                    Some(create_event_auto_id(
                        EventSeverity::Info,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(match s {
                            ExecutorState::Paused => SequencerEvent::Paused,
                            ExecutorState::Cancelled => SequencerEvent::Stopped {
                                sequence_run_id: get_sequence_executor()
                                    .read()
                                    .await
                                    .active_sequence_run_id(),
                            },
                            ExecutorState::Completed => SequencerEvent::Completed,
                            _ => continue,
                        }),
                    ))
                }
                ExecutorEvent::DepthGoalCompleted {
                    node_id,
                    filter_name,
                    completion,
                } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::DepthGoalCompleted {
                        node_id: node_id.clone(),
                        filter_name: filter_name.clone(),
                        goal_id: completion.goal_id.clone(),
                        revision: completion.revision,
                        evidence_frames: completion.evidence_frames,
                        confirmation_frames: completion.confirmation_frames,
                        score: completion.score,
                        threshold: completion.threshold,
                    }),
                )),
                ExecutorEvent::NodeStarted { id, name } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::NodeStarted {
                        node_id: id.clone(),
                        node_type: name.clone(),
                    }),
                )),
                ExecutorEvent::NodeCompleted { id, status } => {
                    // `Cancelled` is its own wire value, not a failure. Both
                    // Dart consumers already fold "cancelled" onto
                    // `NodeStatus.skipped`; reporting it as "failed" painted
                    // a stopped run's nodes red and is the kind of untrue
                    // statement this codebase treats as a defect.
                    let status_str = match status {
                        NodeStatus::Success => "success",
                        NodeStatus::Failure => "failed",
                        NodeStatus::Skipped => "skipped",
                        NodeStatus::Cancelled => "cancelled",
                        _ => "failed",
                    };
                    let severity = match status {
                        NodeStatus::Failure => EventSeverity::Warning,
                        _ => EventSeverity::Info,
                    };
                    Some(create_event_auto_id(
                        severity,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(SequencerEvent::NodeCompleted {
                            node_id: id.clone(),
                            status: status_str.to_string(),
                        }),
                    ))
                }
                ExecutorEvent::ProgressUpdated(progress) => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::Progress {
                        current: progress.completed_exposures,
                        total: progress.total_exposures,
                    }),
                )),
                ExecutorEvent::SequenceCompleted => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::Completed),
                )),
                // Must be the TERMINAL `Failed` payload, not the generic
                // `Error` one: the Dart executor treats `Error` as a
                // recoverable mid-run condition, so flattening onto it left
                // the run un-finalized forever (status stuck at 'running',
                // stale active session blocking the next start).
                ExecutorEvent::SequenceFailed { error } => Some(create_event_auto_id(
                    EventSeverity::Error,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::Failed {
                        error: error.clone(),
                    }),
                )),
                // Mid-run reason, so it takes the recoverable `Error` payload
                // rather than the terminal `Failed` one. Without it the real
                // cause of a failure (daylight gate, missing device, refused
                // slew) never left the Rust log.
                ExecutorEvent::InstructionFailed { node_name, message } => {
                    Some(create_event_auto_id(
                        EventSeverity::Error,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(SequencerEvent::Error {
                            message: format!("{}: {}", node_name, message),
                        }),
                    ))
                }
                ExecutorEvent::ExposureStarted {
                    frame,
                    total,
                    filter,
                    duration_secs,
                } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::ExposureStarted {
                        frame: *frame,
                        total: *total,
                        filter: filter.clone(),
                        duration_secs: *duration_secs,
                    }),
                )),
                ExecutorEvent::ExposureCompleted {
                    frame,
                    total,
                    duration_secs,
                } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::ExposureCompleted {
                        frame: *frame,
                        total: *total,
                        duration_secs: *duration_secs,
                    }),
                )),
                ExecutorEvent::TargetStarted { name, ra, dec } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::TargetChanged {
                        target_name: name.clone(),
                        ra: Some(*ra),
                        dec: Some(*dec),
                    }),
                )),
                ExecutorEvent::TargetCompleted { name } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::TargetCompleted {
                        target_name: name.clone(),
                    }),
                )),
                ExecutorEvent::NodeProgress {
                    node_id,
                    instruction,
                    progress_percent,
                    detail,
                    structured_detail,
                } => {
                    tracing::info!(
                        "[EVENT_SUB] NodeProgress received: node={}, instruction={}, progress={}%",
                        node_id,
                        instruction,
                        progress_percent
                    );

                    // when the executor sent a structured payload
                    // (image grading + scheduler + budget paths do
                    // this), publish the typed `SequencerEvent` variant
                    // FIRST so the dashboard panels can consume it
                    // directly. Then fall through to also emit the legacy
                    // `InstructionProgress` for back-compat with subscribers
                    // that haven't migrated.
                    if let Some(detail_box) = structured_detail.as_deref() {
                        // DepthLock ingestion rides the same single
                        // executor subscription: a cheap try_send per saved
                        // light, never a second receiver on the broadcast.
                        if let skotiq_sequencer::ProgressDetail::FrameAccepted {
                            save_path: Some(path),
                            capture,
                            ..
                        } = detail_box
                        {
                            crate::depthlock_service::notify_frame_saved(path, &capture.frame_type);
                        }
                        if let Some((detail_kind, detail_json)) =
                            structured_progress_payload_from_progress_detail(detail_box)
                        {
                            state.publish_event(create_event_auto_id(
                                EventSeverity::Info,
                                EventCategory::Sequencer,
                                EventPayload::Sequencer(
                                    SequencerEvent::InstructionProgressStructured {
                                        node_id: node_id.clone(),
                                        instruction: instruction.clone(),
                                        progress_percent: *progress_percent,
                                        detail_kind,
                                        detail_json,
                                    },
                                ),
                            ));
                        }

                        if let Some(typed) =
                            typed_sequencer_event_from_progress_detail(node_id, detail_box)
                        {
                            state.publish_event(create_event_auto_id(
                                EventSeverity::Info,
                                EventCategory::Sequencer,
                                EventPayload::Sequencer(typed),
                            ));
                        }
                    }

                    Some(create_event_auto_id(
                        EventSeverity::Info,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(SequencerEvent::InstructionProgress {
                            node_id: node_id.clone(),
                            instruction: instruction.clone(),
                            progress_percent: *progress_percent,
                            detail: detail.clone(),
                        }),
                    ))
                }
                ExecutorEvent::Error { message } => Some(create_event_auto_id(
                    EventSeverity::Error,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::Error {
                        message: message.clone(),
                    }),
                )),
                // Same payload, different SEVERITY — which is what every
                // downstream consumer routes on. Reusing the payload keeps the
                // wire format (and the generated FRB bindings) unchanged; Dart
                // reads `SkotiqEvent.severity` to decide whether a message
                // is a run failure or an advisory, exactly as it already does
                // for `MeridianFlipOutcome`.
                ExecutorEvent::Warning { message } => Some(create_event_auto_id(
                    EventSeverity::Warning,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(SequencerEvent::Error {
                        message: message.clone(),
                    }),
                )),
                ExecutorEvent::MeridianFlipOutcome {
                    outcome,
                    target_name,
                    new_pier_side,
                    duration_secs,
                    attempts,
                    failed_steps,
                    error,
                    action_taken,
                } => {
                    // Severity drives the operator-facing escalation paths
                    // (audible alert / push). A failed flip is Critical: the
                    // mount may be on the wrong side of the pier and every
                    // subsequent frame is suspect. A flip that only succeeded
                    // after retries is a Warning — it worked, but the recenter
                    // wobbled and the operator should look at the framing.
                    let severity = match outcome.as_str() {
                        "success" if failed_steps.is_empty() => EventSeverity::Info,
                        "success" => EventSeverity::Warning,
                        "aborted" => EventSeverity::Warning,
                        _ => EventSeverity::Critical,
                    };
                    tracing::info!(
                        "[EVENT_SUB] Meridian flip outcome: {} for '{}' after {} attempt{} \
                         ({} failed step{})",
                        outcome,
                        target_name,
                        attempts,
                        if *attempts == 1 { "" } else { "s" },
                        failed_steps.len(),
                        if failed_steps.len() == 1 { "" } else { "s" }
                    );
                    Some(create_event_auto_id(
                        severity,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(SequencerEvent::MeridianFlipOutcome {
                            outcome: outcome.clone(),
                            target_name: target_name.clone(),
                            new_pier_side: new_pier_side.clone(),
                            duration_secs: *duration_secs,
                            attempts: *attempts,
                            failed_steps: failed_steps.clone(),
                            error: error.clone(),
                            action_taken: action_taken.clone(),
                        }),
                    ))
                }
                ExecutorEvent::TriggerFired {
                    trigger_id,
                    trigger_name,
                    action,
                } => {
                    tracing::info!(
                        "Trigger fired: {} ({}) - {}",
                        trigger_name,
                        trigger_id,
                        action
                    );
                    Some(create_event_auto_id(
                        EventSeverity::Info,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(SequencerEvent::TriggerFired {
                            trigger_id: trigger_id.clone(),
                            trigger_name: trigger_name.clone(),
                            action: action.clone(),
                        }),
                    ))
                }
                ExecutorEvent::RuntimeConfigUpdated { what } => {
                    // Internal housekeeping — logged, never surfaced to the
                    // operator's event feed.
                    //
                    // It must not ride a `SequencerEvent::Error` payload: the
                    // Dart display layer derives an event's title and criticality
                    // from the PAYLOAD type, so an Error payload reads as an error
                    // however benign its severity claims to be. Nothing in Dart
                    // consumes this event and it fires roughly every 30 s, so on
                    // the feed it would only evict the events that matter.
                    tracing::info!("[EVENT_SUB] Runtime config updated: {}", what);
                    None
                }
                // Recovery Mode — dispatch to first-class typed SequencerEvent
                // variants (see `SequencerEvent::Recovery{Started,Progress,
                // Completed,GaveUp}` in `crate::event`) rather than tunnelling
                // through `InstructionProgress` for Dart to string-match.
                // Severity is Critical on entry / GaveUp so the existing
                // critical-event escalation paths (audible alert, push
                // notification) fire without extra wiring.
                ExecutorEvent::RecoveryStarted { context } => Some(create_event_auto_id(
                    EventSeverity::Critical,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(recovery_event_started(context.as_ref())),
                )),
                ExecutorEvent::RecoveryProgress { context } => Some(create_event_auto_id(
                    EventSeverity::Warning,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(recovery_event_progress(context.as_ref())),
                )),
                ExecutorEvent::RecoveryCompleted { context } => Some(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(recovery_event_completed(context.as_ref())),
                )),
                ExecutorEvent::RecoveryGaveUp {
                    context,
                    aborted_by_user,
                } => Some(create_event_auto_id(
                    EventSeverity::Critical,
                    EventCategory::Sequencer,
                    EventPayload::Sequencer(recovery_event_gave_up(
                        context.as_ref(),
                        *aborted_by_user,
                    )),
                )),
                // A run's autofocus reaches the focus panel exactly as one
                // started by hand: the same focuser property, the same
                // payload. Its outcome rides a sibling property, since no
                // call returns it to Dart.
                ExecutorEvent::AutofocusProgress { focuser_id, detail } => {
                    state.publish_equipment_event(
                        crate::event::EquipmentEvent::PropertyChanged {
                            device_type: "focuser".to_string(),
                            device_id: focuser_id.clone(),
                            property: "AutofocusProgress".to_string(),
                            value: detail.clone(),
                        },
                        EventSeverity::Info,
                    );
                    None
                }
                ExecutorEvent::AutofocusFinished {
                    focuser_id,
                    status,
                    message,
                    result_json,
                } => {
                    let result = result_json
                        .as_deref()
                        .and_then(|json| serde_json::from_str::<serde_json::Value>(json).ok());
                    let value = serde_json::json!({
                        "status": status,
                        "message": message,
                        "result": result,
                    });
                    state.publish_equipment_event(
                        crate::event::EquipmentEvent::PropertyChanged {
                            device_type: "focuser".to_string(),
                            device_id: focuser_id.clone(),
                            property: "AutofocusFinished".to_string(),
                            value: value.to_string(),
                        },
                        EventSeverity::Info,
                    );
                    None
                }
                // translate the Rust executor's plugin-
                // node request into the typed sequencer event Dart
                // subscribes to. The Dart `SequenceExecutor` consumes
                // this, dispatches to `PluginNodeExecutor.run`, and
                // calls `api_sequencer_plugin_node_finished` to reply.
                ExecutorEvent::PluginNodeRequested {
                    node_id,
                    plugin_id,
                    node_type_id,
                    config_json,
                    display_name,
                    timeout_secs,
                } => {
                    tracing::info!(
                        "[EVENT_SUB] PluginNodeRequested received: node={} ({}/{})",
                        node_id,
                        plugin_id,
                        node_type_id,
                    );
                    Some(create_event_auto_id(
                        EventSeverity::Info,
                        EventCategory::Sequencer,
                        EventPayload::Sequencer(SequencerEvent::PluginNodeRequested {
                            node_id: node_id.clone(),
                            plugin_id: plugin_id.clone(),
                            node_type_id: node_type_id.clone(),
                            config_json: config_json.clone(),
                            display_name: display_name.clone(),
                            timeout_secs: *timeout_secs,
                        }),
                    ))
                }
            };

            if let Some(e) = skotiq_event {
                state.publish_event(e);
            }
        }
    }
}

/// Stream of sequencer events (separate from main event stream for real-time progress)
#[flutter_rust_bridge::frb(ignore)]
pub fn api_sequencer_event_stream() -> impl futures::Stream<Item = String> {
    let rx = {
        let executor = get_sequence_executor().blocking_read();
        executor.subscribe()
    };

    async_stream::stream! {
        let mut rx = rx;
        loop {
            match rx.recv().await {
                Ok(event) => {
                    if let Ok(json) = serde_json::to_string(&event) {
                        yield json;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    // Update the global dropped event counter
                    let previous_total = TOTAL_DROPPED_EVENTS.fetch_add(n, Ordering::Relaxed);
                    let new_total = previous_total + n;

                    tracing::warn!(
                        "[SEQUENCER_EVENT_STREAM] Event stream lagged! Skipped {} events (total dropped: {}). \
                        Consider increasing buffer size or optimizing event handling.",
                        n, new_total
                    );
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod frame_event_capture_tests {
    use crate::api::sequencer::typed_sequencer_event_from_progress_detail;
    use crate::event::SequencerEvent;
    use skotiq_sequencer::scheduling::FrameCaptureMetadata;
    use skotiq_sequencer::ProgressDetail;

    /// One populated capture payload. Deliberately all-distinct and non-default
    /// so a `Default::default()` in the mapping cannot pass for the real thing.
    fn populated_capture() -> FrameCaptureMetadata {
        FrameCaptureMetadata {
            gain: Some(139),
            offset: Some(21),
            sensor_temp_c: Some(-9.5),
            cooler_power_percent: Some(63.5),
            mount_ra_hours: Some(5.5),
            mount_dec_degrees: Some(-5.25),
            mount_altitude_deg: Some(48.5),
            mount_azimuth_deg: Some(171.25),
            pier_side: Some("West".to_string()),
            focuser_position: Some(31_705),
            focuser_temperature_c: Some(4.25),
            rotator_angle_deg: Some(212.5),
            exposure_secs: 120.0,
            bin_x: 2,
            bin_y: 2,
            frame_type: "Dark".to_string(),
            target_id: Some("tgt-evt".to_string()),
        }
    }

    /// The hop out of the sequencer's own progress payload and onto the typed
    /// FRB event Dart receives.
    ///
    /// A verifier replaced both arms' `capture: capture.into()` with
    /// `Default::default()` and all 1159 bridge tests stayed green — the whole
    /// per-frame metadata path is dead from here on, and `captured_images` goes
    /// back to NULL gain / offset / temperature / pointing, with the FITS file
    /// on disk still carrying every one of them. Nothing else crosses this
    /// boundary, so nothing else can catch it.
    #[test]
    fn accepted_frame_event_forwards_the_capture_payload() {
        let capture = populated_capture();
        let detail = ProgressDetail::FrameAccepted {
            frame: 7,
            total: 10,
            hfr: Some(2.4),
            eccentricity: Some(0.31),
            star_count: Some(412),
            accepted_total: 7,
            rejected_total: 0,
            save_path: Some("/captures/evt_0007.fits".to_string()),
            capture: capture.clone(),
        };

        let event = typed_sequencer_event_from_progress_detail("node-7", &detail)
            .expect("FrameAccepted has a typed bridge variant");

        match event {
            SequencerEvent::FrameAccepted {
                capture: forwarded, ..
            } => assert_eq!(forwarded, (&capture).into()),
            other => panic!("expected FrameAccepted, got {:?}", other),
        }
    }

    #[test]
    fn rejected_frame_event_forwards_the_capture_payload() {
        // A rejected frame is still on disk and still gets a row, so this arm
        // carries exactly the same obligation as the accepted one — and drifted
        // apart from it precisely because nothing held the two together.
        let capture = populated_capture();
        let detail = ProgressDetail::FrameRejected {
            frame: 8,
            total: 10,
            reason: "HFR 4.9 above threshold 3.5".to_string(),
            hfr: Some(4.9),
            eccentricity: Some(0.62),
            star_count: Some(88),
            reject_path: "/captures/Reject/evt_0008.fits".to_string(),
            consecutive_rejects: 1,
            accepted_total: 7,
            rejected_total: 1,
            likely_cause: None,
            evidence: Vec::new(),
            sky_brightness_at_capture: None,
            cloud_cover_at_capture: None,
            wind_at_capture: None,
            guide_rms_at_capture: None,
            sensor_temp_at_capture: None,
            capture: capture.clone(),
        };

        let event = typed_sequencer_event_from_progress_detail("node-7", &detail)
            .expect("FrameRejected has a typed bridge variant");

        match event {
            SequencerEvent::FrameRejected {
                capture: forwarded, ..
            } => assert_eq!(forwarded, (&capture).into()),
            other => panic!("expected FrameRejected, got {:?}", other),
        }
    }
}

#[cfg(test)]
mod event_bridge_idempotence_tests {
    use crate::api::sequencer::{api_sequencer_subscribe_events, get_sequence_executor};

    /// Wait for the executor's event-broadcast receiver count to stop changing,
    /// so the assertion is not racing the supervised task's first `subscribe()`.
    async fn settled_subscriber_count() -> usize {
        let mut last = usize::MAX;
        for _ in 0..40 {
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            let count = get_sequence_executor()
                .read()
                .await
                .event_subscriber_count();
            if count == last {
                return count;
            }
            last = count;
        }
        last
    }

    /// The Dart bridge calls `sequencerSubscribeEvents()` at the top of EVERY
    /// `sequencerStart()`, and the headless API reaches the same entry point, so
    /// a second run in one app launch called this a second time. Each call
    /// spawned two fresh supervised tasks, each with its own receiver on the
    /// executor's broadcast channel and each republishing everything onto the
    /// unified event stream — which is why one failed node produced two
    /// identical Critical toasts and two Session Report lines.
    ///
    /// Asserts the RECEIVER count on the executor, not a call counter: the
    /// defect is a second live listener, and only that number can tell whether
    /// events are being duplicated.
    #[tokio::test]
    async fn subscribing_again_does_not_add_a_second_event_listener() {
        api_sequencer_subscribe_events()
            .await
            .expect("first subscribe should succeed");
        let after_first = settled_subscriber_count().await;
        assert_eq!(
            after_first, 1,
            "the bridge should hold exactly one listener after the first subscribe"
        );

        // What a second sequence run in the same app launch does.
        api_sequencer_subscribe_events()
            .await
            .expect("second subscribe should still succeed");
        api_sequencer_subscribe_events()
            .await
            .expect("third subscribe should still succeed");

        assert_eq!(
            settled_subscriber_count().await,
            1,
            "re-subscribing must not stand up another listener; a second one \
             duplicates every sequencer event on the way to the UI"
        );
    }
}
