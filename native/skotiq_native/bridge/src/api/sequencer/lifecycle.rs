use super::*;

/// Load a sequence from JSON
pub async fn api_sequencer_load_json(json: String) -> Result<(), SkotiqError> {
    tracing::info!("Loading sequence from JSON");

    let definition: SequenceDefinition = serde_json::from_str(&json)
        .map_err(|e| SkotiqError::InvalidInput(format!("Failed to parse sequence JSON: {}", e)))?;

    let mut executor = get_sequence_executor().write().await;
    executor
        .load_sequence(definition)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to load sequence: {}", e)))?;

    tracing::info!("Sequence loaded successfully");
    Ok(())
}

/// Load a sequence from a definition struct
pub async fn api_sequencer_load(definition: SequenceDefinitionApi) -> Result<(), SkotiqError> {
    tracing::info!("Loading sequence: {}", definition.name);

    // Convert API nodes to internal nodes
    let nodes: Result<Vec<NodeDefinition>, SkotiqError> = definition
        .nodes
        .iter()
        .map(|n| {
            let node_type: NodeType = serde_json::from_str(&n.config_json)
                .map_err(|e| SkotiqError::InvalidInput(format!("Invalid node config: {}", e)))?;

            Ok(NodeDefinition {
                id: n.id.clone(),
                name: n.name.clone(),
                node_type,
                enabled: n.enabled,
                children: n.children.clone(),
            })
        })
        .collect();

    let internal_definition = SequenceDefinition {
        id: definition.id,
        name: definition.name,
        description: definition.description,
        nodes: nodes?,
        root_node_id: definition.root_node_id,
        metadata: std::collections::HashMap::new(),
    };

    let mut executor = get_sequence_executor().write().await;
    executor
        .load_sequence(internal_definition)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to load sequence: {}", e)))?;

    Ok(())
}

/// Seed the executor's observing site from app settings when nothing has
/// pushed one yet.
///
/// The executor's `latitude`/`longitude` is what every frame's `OBJCTALT` /
/// `AIRMASS` cards and the `captured_images.mount_altitude` column are derived
/// from. Without this seed a run that starts before Dart's
/// `sequencerUpdateLocation` push lands writes frames whose FITS header carries
/// AIRMASS — the writer falls back to app settings, see
/// `sequencer_ops::context_altitude_pointing` — while the database row for the
/// same frame has a NULL altitude, because the row is stamped from the
/// sequencer's context and nothing folds the writer's fallback back into it. The
/// AAVSO exporter reads the row, and submits `na` in the AMASS column for frames
/// whose own header knows the answer.
///
/// Fills in rather than overwrites: a location explicitly pushed for this run
/// stays authoritative.
pub(crate) async fn seed_executor_site_from_settings(
    executor: &mut skotiq_sequencer::SequenceExecutor,
) {
    if executor.latitude.is_some() && executor.longitude.is_some() {
        return;
    }
    if let Ok(Some(site)) = get_state().get_observer_location() {
        executor
            .update_location(Some(site.latitude), Some(site.longitude))
            .await;
    }
}

/// Start the sequence executor
pub async fn api_sequencer_start() -> Result<(), SkotiqError> {
    tracing::info!("Starting sequence execution");

    let mut executor = get_sequence_executor().write().await;
    seed_executor_site_from_settings(&mut executor).await;
    executor
        .start()
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to start sequence: {}", e)))?;

    // Publish event
    get_state().publish_event(create_event_auto_id(
        EventSeverity::Info,
        EventCategory::Sequencer,
        EventPayload::Sequencer(SequencerEvent::Started {
            sequence_name: "Sequence".to_string(),
        }),
    ));

    Ok(())
}

/// Pause the sequence executor
pub async fn api_sequencer_pause() -> Result<(), SkotiqError> {
    tracing::info!("Pausing sequence execution");

    let executor = get_sequence_executor().read().await;
    executor
        .pause()
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to pause sequence: {}", e)))?;

    get_state().publish_event(create_event_auto_id(
        EventSeverity::Info,
        EventCategory::Sequencer,
        EventPayload::Sequencer(SequencerEvent::Paused),
    ));

    Ok(())
}

/// Resume the sequence executor
pub async fn api_sequencer_resume() -> Result<(), SkotiqError> {
    tracing::info!("Resuming sequence execution");

    let executor = get_sequence_executor().read().await;
    executor
        .resume()
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to resume sequence: {}", e)))?;

    get_state().publish_event(create_event_auto_id(
        EventSeverity::Info,
        EventCategory::Sequencer,
        EventPayload::Sequencer(SequencerEvent::Resumed),
    ));

    Ok(())
}

/// Stop the sequence executor. `origin` names the CALLER — `None` /
/// `"operator"` for a human, `"scheduler"` for the autopilot — so the
/// executor can record an autopilot stop as the system event it is
/// instead of operator evidence.
pub async fn api_sequencer_stop(origin: Option<String>) -> Result<(), SkotiqError> {
    tracing::info!(origin = origin.as_deref(), "Stopping sequence execution");

    let mut executor = get_sequence_executor().write().await;
    let run_id = executor.active_sequence_run_id();
    executor
        .stop_with_origin(origin.as_deref())
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to stop sequence: {}", e)))?;

    // tear down any active LiveStacking broadcast so a
    // stopped sequence does not leave a stale `/broadcast` page
    // advertising itself as live. Same lifecycle the rest of the
    // sequencer-singleton state (TriggerState, BudgetRegistry, …)
    // already follows on stop.
    if skotiq_sequencer::broadcast::deactivate().is_some() {
        tracing::info!("LiveStacking broadcast deactivated on sequence stop");
    }

    // Dual-rig — stop any piggybacking secondary capture loop so a stopped
    // primary sequence doesn't leave the secondary camera exposing forever.
    if let Err(e) = crate::api::secondary_rig::api_secondary_rig_stop().await {
        tracing::warn!("Failed to stop secondary rig on sequence stop: {}", e);
    }

    get_state().publish_event(create_event_auto_id(
        EventSeverity::Info,
        EventCategory::Sequencer,
        EventPayload::Sequencer(SequencerEvent::Stopped {
            sequence_run_id: run_id,
        }),
    ));

    Ok(())
}

/// Skip to the next instruction
pub async fn api_sequencer_skip() -> Result<(), SkotiqError> {
    tracing::info!("Skipping current instruction");

    let executor = get_sequence_executor().read().await;
    executor
        .skip()
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to skip: {}", e)))?;

    Ok(())
}

/// Jump execution to a specific node id, marking preceding siblings as
/// Skipped. Honoured on the next container's
/// tree-walk step; the currently-running instruction (e.g. an exposure burst)
/// completes before the jump takes effect. Returns an error if the executor
/// is not running (caller should gate the UI button on execution state).
pub async fn api_sequencer_skip_to_node(node_id: String) -> Result<(), SkotiqError> {
    tracing::info!("Skipping execution to node: {}", node_id);

    let executor = get_sequence_executor().read().await;
    executor
        .skip_to_node(node_id)
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to skip to node: {}", e)))?;

    Ok(())
}

/// Reset the sequence executor
pub async fn api_sequencer_reset() -> Result<(), SkotiqError> {
    tracing::info!("Resetting sequence executor");

    let mut executor = get_sequence_executor().write().await;
    executor.reset().await;

    Ok(())
}

/// Dart side reports the verdict of a plugin-dispatched
/// node back to the Rust executor. Routes to
/// `ExecutorCommand::PluginNodeFinished`. The Rust instruction node
/// awaiting on the matching pending oneshot unblocks with Success or
/// Failure based on `success`.
///
/// `structured_detail_json` is an optional opaque JSON payload the plugin
/// author emits as the node's final progress event. Invalid JSON is
/// logged at warn and dropped (the verdict still applies).
///
/// Returns an error if the executor is not currently running — the
/// caller should treat that as a stale reply (the run was cancelled
/// between dispatch and reply) and drop the result.
pub async fn api_sequencer_plugin_node_finished(
    node_id: String,
    success: bool,
    message: Option<String>,
    structured_detail_json: Option<String>,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "[PLUGIN] api_sequencer_plugin_node_finished: node={}, success={}, message={:?}",
        node_id,
        success,
        message,
    );
    let executor = get_sequence_executor().read().await;
    executor
        .plugin_node_finished(node_id, success, message, structured_detail_json)
        .await
        .map_err(|e| {
            SkotiqError::OperationFailed(format!("Failed to deliver plugin node verdict: {}", e))
        })?;
    Ok(())
}

/// Get the current sequencer state
pub async fn api_sequencer_get_state() -> SequencerState {
    let executor = get_sequence_executor().read().await;
    let progress = executor.get_progress();
    SequencerState::from(progress)
}

// Sequencer checkpoint / crash recovery

/// Checkpoint info returned to Dart
#[derive(Debug, Clone)]
pub struct CheckpointInfoApi {
    pub sequence_name: String,
    pub timestamp: String,
    pub completed_exposures: u32,
    pub completed_integration_secs: f64,
    pub can_resume: bool,
    pub age_seconds: i64,
}

/// Set the checkpoint directory for crash recovery
pub async fn api_sequencer_set_checkpoint_dir(path: String) -> Result<(), SkotiqError> {
    tracing::info!("Setting checkpoint directory to: {}", path);
    let mut executor = get_sequence_executor().write().await;
    executor.set_checkpoint_dir(path);
    Ok(())
}

/// Check if a recoverable checkpoint exists
pub fn api_sequencer_has_checkpoint() -> bool {
    let executor = get_sequence_executor().blocking_read();
    executor.has_recoverable_checkpoint()
}

/// Get info about the current checkpoint
pub fn api_sequencer_get_checkpoint_info() -> Option<CheckpointInfoApi> {
    let executor = get_sequence_executor().blocking_read();
    executor
        .get_checkpoint_info()
        .map(|info| CheckpointInfoApi {
            sequence_name: info.sequence_name,
            timestamp: info.timestamp.to_rfc3339(),
            completed_exposures: info.completed_exposures,
            completed_integration_secs: info.completed_integration_secs,
            can_resume: info.can_resume,
            age_seconds: info.age_seconds,
        })
}

/// Resume sequence from checkpoint
pub async fn api_sequencer_resume_from_checkpoint() -> Result<(), SkotiqError> {
    tracing::info!("Resuming sequence from checkpoint");
    let mut executor = get_sequence_executor().write().await;

    // Set up device ops before resume - use UnifiedDeviceOps which routes through DeviceManager
    let ops = create_unified_device_ops();
    executor.set_device_ops(ops);

    executor
        .resume_from_checkpoint()
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// Ask the RUNNING sequence to flip at its next safe point.
///
/// The counterpart of [`api_perform_meridian_flip`], which is refused during a
/// run. The flip runs through the run's own meridian trigger: it waits for the
/// frame in flight, then stops guiding, flips, re-centers, refocuses if
/// configured, restarts guiding and settles. Returns once the request is
/// queued; the result arrives as the usual meridian-flip outcome event. An
/// `Err` carries the operator-facing reason the flip cannot run now (target
/// not yet past the meridian, mount parked or not tracking, already flipped,
/// the run paused, ...).
pub async fn api_sequencer_request_meridian_flip() -> Result<(), SkotiqError> {
    let executor = get_sequence_executor().read().await;
    executor
        .request_meridian_flip()
        .await
        .map_err(SkotiqError::OperationFailed)
}

/// Standalone meridian flip — runs the canonical [`MeridianFlipExecutor`]
/// OUTSIDE any running sequence.
///
/// This is what the Dart-side standalone meridian monitor calls to flip an
/// attended non-sequencer session instead of only alerting while the mount
/// tracks into the pier. It runs the same engine with the same timeouts,
/// altitude check, re-center and refocus semantics as the in-sequence path.
///
/// Refuses while the sequence executor is Running/Paused/Stopping/
/// Recovering — two engines commanding one mount is how pier crashes
/// happen; the in-sequence trigger owns flips there.
#[allow(clippy::too_many_arguments)]
pub async fn api_perform_meridian_flip(
    mount_id: String,
    camera_id: Option<String>,
    focuser_id: Option<String>,
    cover_calibrator_id: Option<String>,
    target_name: String,
    target_ra_hours: f64,
    target_dec_degrees: f64,
    pause_guiding: bool,
    auto_center: bool,
    refocus_after: bool,
    resume_guiding: bool,
    settle_time_secs: f64,
) -> Result<(), SkotiqError> {
    {
        let executor = get_sequence_executor().read().await;
        let state = executor.get_state().await;
        match state {
            ExecutorState::Idle
            | ExecutorState::Completed
            | ExecutorState::Failed
            | ExecutorState::Cancelled => {}
            ExecutorState::Running
            | ExecutorState::Paused
            | ExecutorState::Stopping
            | ExecutorState::Recovering => {
                return Err(SkotiqError::OperationFailed(format!(
                    "Cannot run a standalone meridian flip while the sequencer is {:?} — \
                     the in-sequence meridian trigger owns flips during a sequence.",
                    state
                )));
            }
        }
    }

    tracing::info!(
        "[MERIDIAN] Standalone flip requested for '{}' (RA {:.4}h, Dec {:.4}°, mount {})",
        target_name,
        target_ra_hours,
        target_dec_degrees,
        mount_id
    );

    let config = skotiq_sequencer::MeridianFlipConfig {
        pause_guiding,
        auto_center,
        refocus_after,
        resume_guiding,
        settle_time: settle_time_secs,
        ..Default::default()
    };

    let ctx = skotiq_sequencer::FlipContext {
        target_name: target_name.clone(),
        target_ra_hours,
        target_dec_degrees,
        mount_id,
        camera_id,
        focuser_id,
        cover_calibrator_id,
        cancellation_token: None,
        trigger_state: None,
        autofocus_config: None,
        simulate: false,
    };

    let ops = create_unified_device_ops();
    let mut flip_executor = skotiq_sequencer::MeridianFlipExecutor::new(config, ops);
    match flip_executor.execute(&ctx).await {
        skotiq_sequencer::FlipResult::Success {
            new_pier_side,
            duration_secs,
        } => {
            tracing::info!(
                "[MERIDIAN] Standalone flip for '{}' completed: pier {:?}, {:.1}s",
                target_name,
                new_pier_side,
                duration_secs
            );
            Ok(())
        }
        skotiq_sequencer::FlipResult::Failed {
            error,
            action_taken,
        } => Err(SkotiqError::OperationFailed(format!(
            "Meridian flip failed: {} (configured failure action: {:?})",
            error, action_taken
        ))),
        skotiq_sequencer::FlipResult::Aborted { reason } => Err(SkotiqError::OperationFailed(
            format!("Meridian flip aborted: {}", reason),
        )),
    }
}

/// Save current execution state as checkpoint
pub async fn api_sequencer_save_checkpoint() -> Result<(), SkotiqError> {
    tracing::info!("Saving checkpoint");
    let executor = get_sequence_executor().read().await;
    executor
        .save_checkpoint()
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// Clear/discard checkpoint (call when sequence completes normally or user discards)
pub fn api_sequencer_clear_checkpoint() -> Result<(), SkotiqError> {
    tracing::info!("Clearing checkpoint");
    let executor = get_sequence_executor().blocking_read();
    executor
        .clear_checkpoint()
        .map_err(|e| SkotiqError::OperationFailed(e))
}

#[cfg(test)]
mod executor_site_tests {
    use crate::api::get_state;
    use crate::api::sequencer::{api_sequencer_start, get_sequence_executor};
    use crate::storage::ObserverLocation;

    /// A run must not be able to start without the site the app already knows.
    ///
    /// The executor's latitude/longitude is the ONLY input to the altitude
    /// stamped on every frame's `captured_images` row, and until this seeding
    /// existed the only writer was Dart's `sequencerUpdateLocation`. A run
    /// started before that push produced files with AIRMASS (the FITS writer
    /// has its own fallback to app settings) and rows without it — and the
    /// AAVSO exporter reads the row, so it submitted `na` for frames whose own
    /// header knew the answer.
    #[tokio::test]
    async fn starting_a_run_seeds_the_site_from_app_settings() {
        let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
            .lock()
            .await;
        {
            // The gap under test: nothing has pushed a location for this run.
            get_sequence_executor()
                .write()
                .await
                .update_location(None, None)
                .await;
        }
        get_state()
            .set_observer_location(Some(ObserverLocation {
                latitude: 41.5,
                longitude: -71.25,
                elevation: 30.0,
            }))
            .expect("test site should be settable");

        // No sequence is loaded, so the start itself fails. That is fine and is
        // the point: the site has to be in place BEFORE the run can begin, so
        // the seeding must not be conditional on the start succeeding.
        let _ = api_sequencer_start().await;

        let executor = get_sequence_executor().read().await;
        assert_eq!(
            (executor.latitude, executor.longitude),
            (Some(41.5), Some(-71.25)),
            "the run started with no observing site even though app settings had one"
        );
    }
}
