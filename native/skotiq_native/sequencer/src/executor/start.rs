//! [`SequenceExecutor::start`] — the run supervisor: preflight, the spawned
//! executor future, the command handler, the checkpoint streamer, the
//! recovery driver, the trigger monitor, and the join/finalize tail.

use super::*;

mod calibration_run;
mod checkpoint_stream;
mod command_handler;
mod explicit_end;
pub(crate) mod night_end;
mod preflight;
mod progress_callback;
mod recovery_driver;
mod run_setup;
mod trigger_monitor;

use checkpoint_stream::{run_checkpoint_stream, CheckpointStreamArgs};
use command_handler::{run_command_handler, CommandHandlerArgs};
use preflight::PreflightOutcome;
use progress_callback::{build_progress_callback, ProgressCallbackArgs};
use recovery_driver::{run_recovery_driver, RecoveryDriverArgs};
use trigger_monitor::{run_trigger_monitor_poll_loop, TriggerMonitorArgs};

/// The run's terminal message: the verdict the ROOT node returned, named after
/// the root node.
///
/// The verb follows the status the root actually reported, and the run's
/// `state` is derived from that same status
/// ([`executor_state_for_result`]), so the two can never contradict each
/// other on `/api/sequencer/status`.
fn terminal_verdict_message(result: NodeStatus, root_display_name: &str) -> String {
    let verb = match result {
        NodeStatus::Success => "Completed",
        NodeStatus::Failure => "Failed",
        NodeStatus::Cancelled => "Cancelled",
        NodeStatus::Skipped => "Skipped",
        // Not reachable: `result` is the terminal status of the root node.
        // Kept exhaustive so a new NodeStatus variant fails to compile here
        // rather than silently reporting the wrong verb.
        NodeStatus::Pending | NodeStatus::Running => "Finished",
    };
    format!("{}: {}", verb, root_display_name)
}

impl SequenceExecutor {
    /// Start executing the sequence.
    ///
    /// Re-invocable within one app launch: a finished run parks the executor in
    /// a terminal state (`Completed`, `Failed`, `Cancelled`), and an explicit
    /// start from there means "run it again", so preflight recycles to `Idle`
    /// and the run proceeds. Every sequence of a night starts without a restart.
    ///
    /// Non-terminal busy states (`Running`, `Paused`, `Stopping`, `Recovering`)
    /// are refused: those are genuine conflicts where resetting would abandon a
    /// live run.
    pub async fn start(&mut self) -> Result<(), String> {
        let PreflightOutcome {
            device_ops,
            unreachable_instruction_names,
        } = self.preflight_start().await?;

        let custom_recovery_branches = self.prepare_sequence_recovery_triggers().await?;

        self.is_cancelled.store(false, Ordering::Relaxed);

        let (tx, rx) = mpsc::channel::<ExecutorCommand>(32);
        self.command_tx = Some(tx);
        let (run_completion_tx, run_completion_rx) = oneshot::channel();
        self.run_completion_rx = Some(run_completion_rx);

        self.set_state(ExecutorState::Running).await;

        self.prepare_run_triggers().await;
        // The checkpoint's node states (Smart Exposure counts, budgets) belong
        // to the resume `resume_from_checkpoint` prepared, and to no other run.
        // Kept for the life of the process, every later fresh start restored
        // them from an old checkpoint.
        let checkpoint_to_restore = if std::mem::take(&mut self.resume_prepared) {
            self.current_checkpoint.take()
        } else {
            self.current_checkpoint = None;
            None
        };

        let state = self.state.clone();
        let progress = self.progress.clone();
        let event_tx = self.event_tx.clone();
        let is_cancelled = self.is_cancelled.clone();
        let mut root_node = self
            .root_node
            .take()
            .ok_or("No root node available - sequence may not be properly loaded".to_string())?;
        // The run's terminal message names the ROOT, so its name is taken here,
        // before the tree is moved into the execution future.
        let root_display_name = root_node.name().to_string();

        let camera_id = self.camera_id.clone();
        let mount_id = self.mount_id.clone();
        let focuser_id = self.focuser_id.clone();
        let filterwheel_id = self.filterwheel_id.clone();
        let rotator_id = self.rotator_id.clone();
        let dome_id = self.dome_id.clone();
        let cover_calibrator_id = self.cover_calibrator_id.clone();
        let save_path = self.save_path.clone();
        let latitude = self.latitude;
        let longitude = self.longitude;
        let trigger_action_context = TriggerActionContext {
            camera_id: camera_id.clone(),
            mount_id: mount_id.clone(),
            focuser_id: focuser_id.clone(),
            filterwheel_id: filterwheel_id.clone(),
            rotator_id: rotator_id.clone(),
            dome_id: dome_id.clone(),
            cover_calibrator_id: cover_calibrator_id.clone(),
            save_path: save_path.clone(),
            latitude,
            longitude,
            filter_focus_offsets: self.filter_focus_offsets.clone(),
        };
        let exposure_node_metadata: HashMap<NodeId, (f64, Option<String>)> = self
            .sequence
            .as_ref()
            .map(|sequence| {
                sequence
                    .nodes
                    .iter()
                    .filter_map(|node| match &node.node_type {
                        NodeType::TakeExposure(config) => Some((
                            node.id.clone(),
                            (config.duration_secs, config.filter.clone()),
                        )),
                        _ => None,
                    })
                    .collect()
            })
            // Why: `self.sequence` is `Option<Sequence>`; None means no
            // sequence has been loaded yet (executor in initial state). An empty metadata
            // HashMap is the correct sentinel — there are simply no TakeExposure nodes to
            // index, so the trigger-action-context cannot reference any.
            .unwrap_or_default();

        // The authored display name of every node that has one, read once at
        // start from the same `SequenceDefinition` the tree was built from.
        //
        // The progress callback used to learn these names ONLY by parsing the
        // one-shot "Executing: <name>" lifecycle message, and substituted the
        // literal string "Unknown" — cached, so it could not recover — when a
        // node re-entered that branch on a message-less update. See the
        // `node_names` map it seeds, below.
        //
        // An empty name is skipped rather than indexed: a node the operator
        // never named has no display name to publish, and caching "" would
        // print a blank where a client renders the field.
        let node_display_names: HashMap<NodeId, String> = self
            .sequence
            .as_ref()
            .map(|sequence| {
                sequence
                    .nodes
                    .iter()
                    .filter(|node| !node.name.trim().is_empty())
                    .map(|node| (node.id.clone(), node.name.clone()))
                    .collect()
            })
            .unwrap_or_default();

        // Which node ids are targets, and what target they name. Read once at
        // start from the same `SequenceDefinition` the tree was built from, so
        // the identity that reaches subscribers is the node id — never a
        // display name.
        //
        // `ExecutorEvent::TargetStarted` existed and the bridge already mapped
        // it to `SequencerEvent::TargetChanged`, but NOTHING in this crate ever
        // constructed it: the variant had zero producers, so Dart's
        // `currentTarget` stayed null for every run ever executed. Everything
        // keyed off it then silently fell through to its fallback — most
        // visibly `sequence_runs.stats_json.targetBreakdown`, which bucketed a
        // whole night under the SEQUENCE's name ("New Sequence") while the
        // frames on disk and the FITS `OBJECT` card said the target's ("New
        // Target"). The run record disagreed with the files it had written.
        let target_node_metadata: HashMap<NodeId, (String, f64, f64)> = self
            .sequence
            .as_ref()
            .map(|sequence| {
                sequence
                    .nodes
                    .iter()
                    .filter_map(|node| match &node.node_type {
                        NodeType::TargetHeader(config) | NodeType::TargetGroup(config) => {
                            // An unnamed target is deliberately NOT indexed: the
                            // save-path resolver labels those frames
                            // "untargeted", and inventing a name here (the node's
                            // display label, say) would put a third spelling on
                            // the wire.
                            if config.target_name.trim().is_empty() {
                                None
                            } else {
                                Some((
                                    node.id.clone(),
                                    (
                                        config.target_name.clone(),
                                        config.ra_hours,
                                        config.dec_degrees,
                                    ),
                                ))
                            }
                        }
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default();

        let trigger_manager = self.trigger_manager.clone();
        let triggers_enabled = self.triggers_enabled;
        let safety_fail_mode = self.safety_fail_mode;
        let filter_focus_offsets = self.filter_focus_offsets.clone();
        let sequence_for_custom_recovery = self.sequence.clone();
        let custom_recovery_branches = Arc::new(custom_recovery_branches);

        // seed runtime config from the executor's configured
        // values so the first read sees what `set_*()` was given before
        // start() was called. The shared Arc is cloned for the spawned task
        // and the command handler so writes propagate to readers.
        {
            let mut rc = self.runtime_config.write();
            rc.latitude = self.latitude;
            rc.longitude = self.longitude;
            rc.filter_focus_offsets = self.filter_focus_offsets.clone();
            rc.safety_fail_mode = self.safety_fail_mode;
        }
        let runtime_config = self.runtime_config.clone();

        // Recovery Mode — clone the shared signal + history handles
        // for the spawned executor task. The signals atomic is cloned so
        // the operator pressing "Try Now" / "Abort" mid-loop is visible to
        // the trigger-monitor closure that drives the recovery state
        // machine; the `current_recovery` slot is what the bridge layer
        // reads to surface the live context to subscribers that joined
        // mid-loop (rare but possible — a remote phone reconnecting).
        let recovery_signals_clone = self.recovery_signals.clone();
        let current_recovery_clone = self.current_recovery.clone();
        let recovery_history_clone = self.recovery_history.clone();
        // Replay Debug — clone the decision sender + active run id
        // handle into the spawned executor task so every instruction
        // node, the trigger-monitor closure, and the recovery driver
        // can publish DecisionEvents.
        let decision_tx_for_ctx = self.decision_tx.clone();
        let decision_tx_for_lifecycle = self.decision_tx.clone();
        let active_run_id_for_ctx = self.active_sequence_run_id.clone();
        let active_run_id_for_decisions = self.active_sequence_run_id.clone();
        let decision_logging_enabled_for_emits = self.decision_logging_enabled.clone();
        // pre-clone the shared adaptive-swap Arc slots OUTSIDE
        // the spawned task so the future doesn't capture `self` (which
        // would bind to the `&mut self` borrow of `start()`).
        let shared_conditions_score_for_ctx = self.shared_conditions_score.clone();
        let shared_adaptive_swap_state_for_ctx = self.shared_adaptive_swap_state.clone();
        // Arm the signal bus so any stale TryNow / Abort left over from a
        // previous run doesn't pre-fire the very first recovery. The
        // `arm()` call increments the entry counter so the Dart side can
        // distinguish "this is a new recovery loop" from "still the same
        // one" via the counter.
        self.recovery_signals.arm();

        // share the *same* CheckpointManager Arc between the
        // executor and the streaming-checkpoint task so they cannot diverge
        // (info_cache must be consistent for `has_recoverable_checkpoint`).
        let streaming_checkpoint_manager: Option<Arc<crate::checkpoint::CheckpointManager>> =
            self.checkpoint_manager.clone();
        // Separate Arc clone for the terminal completion handler. On normal
        // completion we mark the checkpoint inactive so the next launch does
        // NOT show a stale "resume?" banner. `streaming_checkpoint_manager`
        // above is moved into the streaming-checkpoint task, so the completion
        // path needs its own handle to the *same* manager (shared info_cache).
        let completion_checkpoint_manager: Option<Arc<crate::checkpoint::CheckpointManager>> =
            self.checkpoint_manager.clone();
        // Third Arc clone for the ExecutionContext, so wizards that own
        // step-level resume state (mosaic panels) write their slots
        // through the SAME manager as the streaming task instead of
        // discarding them into a NullCheckpointSink.
        let context_checkpoint_manager: Option<Arc<crate::checkpoint::CheckpointManager>> =
            self.checkpoint_manager.clone();
        let depth_goal_ops = self.depth_goal_ops.clone();
        let streaming_sequence = self.sequence.clone();
        let streaming_camera_id = self.camera_id.clone();
        let streaming_mount_id = self.mount_id.clone();
        let streaming_focuser_id = self.focuser_id.clone();
        let streaming_filterwheel_id = self.filterwheel_id.clone();
        let streaming_rotator_id = self.rotator_id.clone();
        let streaming_save_path = self.save_path.clone();
        let streaming_latitude = self.latitude;
        let streaming_longitude = self.longitude;

        let is_paused = Arc::new(AtomicBool::new(false));
        // Shared with the recovery driver (incremented when a cycle completes)
        // and with the node tree, so an instruction can tell "recovery already
        // finished" from "no driver ever engaged". See
        // `ExecutionContext::recovery_generation`.
        let recovery_generation = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let skip_to_next_target = Arc::new(AtomicBool::new(false));
        // Recovery Mode — channel by which the trigger-monitor posts
        // recoverable failures to the dedicated recovery-driver task. The
        // monitor sets `is_paused` while a recovery is in flight (so the
        // node tree freezes) and pushes the cause into this channel; the
        // driver reads it, transitions state to Recovering, runs the
        // retry loop, and on success flips `is_paused` back off so the
        // node tree resumes from where it stopped.
        //
        // Bounded channel: only one recovery may be in flight at a time;
        // back-pressure on `try_send` is the documented way the monitor
        // sees "already recovering, drop the duplicate trigger".
        let (recovery_request_tx, recovery_request_rx) =
            mpsc::channel::<crate::recovery::RecoveryCause>(4);
        // Shared "SkipToNode target" slot. Set by the
        // ExecutorCommand::SkipToNode handler, consumed by the node tree
        // during execution (see RuntimeNode::execute_children_sequential).
        let skip_to_node: Arc<StdRwLock<Option<NodeId>>> = Arc::new(StdRwLock::new(None));
        let resume_notify = Arc::new(tokio::sync::Notify::new());

        // pull the budget snapshot from the most-recently
        // loaded checkpoint (if any) so the spawned task can apply it
        // after constructing the ExecutionContext. Cloning a snapshot is
        // cheap (it's just Vec<BudgetState>).
        let budget_snapshot_to_restore = checkpoint_to_restore
            .as_ref()
            .map(|cp| cp.budget_states.clone());

        // pull the SmartExposure resume map from the
        // most-recently loaded checkpoint. Each entry restores a single
        // SmartExposure node's per-filter completed counts +
        // current_plan_index so a crashed mid-rotation run resumes on the
        // correct filter at the correct frame index. An empty / missing
        // map is a no-op (fresh run).
        let smart_exposure_snapshot_to_restore = checkpoint_to_restore
            .as_ref()
            .map(|cp| cp.smart_exposure_states.clone());

        let is_paused_clone = is_paused.clone();
        let recovery_generation_clone = recovery_generation.clone();
        let recovery_driver_generation = recovery_generation.clone();
        let skip_to_next_target_clone = skip_to_next_target.clone();
        let skip_to_node_clone = skip_to_node.clone();
        let resume_notify_clone = resume_notify.clone();
        let exposure_node_metadata = Arc::new(exposure_node_metadata);
        let target_node_metadata = Arc::new(target_node_metadata);
        let trigger_action_context = trigger_action_context.clone();

        // Clones used by the panic-supervision shell *outside* the executed
        // future. A bare `tokio::spawn` would silently swallow any panic in
        // the executor loop — the sequence would just stop with no event and
        // no log. We need at least `state`, `progress`, and `event_tx` to
        // survive the panic so we can report `SequenceFailed` to the UI.
        let supervisor_state = state.clone();
        let supervisor_progress = progress.clone();
        let supervisor_event_tx = event_tx.clone();
        tokio::spawn(async move {
            let executor_future = async move {
                let start_time = std::time::Instant::now();

                // The trigger monitor needs its own handle because the original
                // moves into the ExecutionContext used by the instruction tree.
                let device_ops_for_triggers = device_ops.clone();

                let mut context = ExecutionContext::new("root".to_string(), device_ops)
                    // Install the decision broadcast sender + shared
                    // active-run-id slot so every instruction node, scheduler,
                    // recovery driver, and exposure grader can publish
                    // DecisionEvents without further plumbing.
                    .with_decision_sender(
                        decision_tx_for_ctx.clone(),
                        active_run_id_for_ctx.clone(),
                    );
                // clone the shared cloud-motion snapshot handle
                // so the trigger-monitor task can read it for
                // `SlewToGapAndContinue` without holding the trigger-state
                // lock. The Arc<RwLock> inside ExecutionContext is shared with
                // every parallel branch and with the UpdateCloudMotion command
                // handler, so reads here see the latest pushed snapshot.
                let cloud_motion_for_recovery = context.cloud_motion_snapshot.clone();
                // pre-clone the adaptive-exposure shared
                // Arc handles so the command-handler closure captures
                // them by value (avoiding the immutable-borrow-of-
                // `context` problem that fights `&mut context` in the
                // parallel root_node.execute below).
                let sky_brightness_for_cmd = context.current_sky_brightness_mag.clone();
                let default_adaptive_for_cmd = context.default_adaptive_exposure.clone();
                // share the pending-plugin-node map with
                // the command handler so a `PluginNodeFinished` reply can
                // resolve the matching oneshot without borrowing `context`
                // (which is exclusively held by `root_node.execute`
                // below).
                let plugin_node_pending_for_cmd = context.plugin_node_pending.clone();
                // share the defect-map Arc with the
                // command handler so an `UpdateDefectMap` command can
                // mutate the live state without re-borrowing `context`.
                let defect_map_apply_for_cmd = context.defect_map_apply.clone();
                // Science — pre-clone the transparency-tracking
                // Arc handles so the command handler can push fresh
                // samples / backup plans into the shared ExecutionContext
                // without re-borrowing `context` (which is held by the
                // parallel root_node.execute below). The
                // `*_for_recovery` clones flow into the trigger
                // monitor's `SwitchTargetOrFilter` handler.
                let transparency_for_cmd = context.current_transparency.clone();
                let transparency_backup_for_cmd = context.transparency_backup_plan.clone();
                let transparency_backup_for_recovery = context.transparency_backup_plan.clone();
                // adaptive sky-conditions swap. The composite
                // ConditionsScore slot is mirrored into the shared
                // ExecutionContext so the TargetScheduler reads it without
                // taking the trigger-state lock; `_for_cmd` is the handle
                // the command channel writes through.
                // Bind the per-run context slots to the executor-level
                // shared slots so idle-time pushes (received before
                // `start()`) carry into the run and so the dashboard JSON
                // getter reads from one place. The Arc swap is cheap and
                // happens once per run.
                context.current_conditions_score = shared_conditions_score_for_ctx.clone();
                context.adaptive_swap_state = shared_adaptive_swap_state_for_ctx.clone();
                let conditions_score_for_cmd = context.current_conditions_score.clone();
                let skip_to_node_for_recovery = context.skip_to_node.clone();
                context.is_cancelled = is_cancelled.clone();
                context.is_paused = is_paused_clone;
                // Wizard step-level resume (mosaic panels) persists through
                // this manager; `None` when no checkpoint dir was set, in
                // which case the wizard falls back to a null sink.
                context.checkpoint_manager = context_checkpoint_manager;
                context.depth_goal_ops = depth_goal_ops;
                context.recovery_generation = recovery_generation_clone;
                // Dual-rig — pick up the process-wide dither barrier if a
                // secondary capture loop is armed, so the primary's dither
                // call sites coordinate with it. `None` (single-rig) makes
                // every dither a plain pass-through.
                context.dither_barrier = crate::dual_rig::active_barrier();
                context.skip_to_next_target = skip_to_next_target_clone;
                // Wire shared SkipToNode slot into the
                // execution context so the node tree sees commands posted
                // by the executor command handler.
                context.skip_to_node = skip_to_node_clone;
                context.resume_notify = resume_notify_clone;
                context.camera_id = camera_id;
                context.mount_id = mount_id;
                context.focuser_id = focuser_id;
                context.filterwheel_id = filterwheel_id;
                context.rotator_id = rotator_id;
                context.dome_id = dome_id;
                context.cover_calibrator_id = cover_calibrator_id;
                context.save_path = save_path;
                context.latitude = latitude;
                context.longitude = longitude;
                context.safety_fail_mode = Arc::new(parking_lot::RwLock::new(safety_fail_mode));
                context.filter_focus_offsets = filter_focus_offsets;
                // Hand the event_tx to the execution context so instructions
                // (e.g. execute_exposure) can surface ExecutorEvent::Error
                // for FITS-save failures and other instruction-level errors
                // that must reach UI subscribers, not just the log.
                context.event_tx = Some(event_tx.clone());
                context.recovery_request_tx = Some(recovery_request_tx.clone());
                // The trigger state owns HFR baseline and exposure counts; instructions
                // (autofocus, exposures) feed it through the context so triggers can fire.
                context.trigger_state = Some(trigger_manager.read().await.state());

                // seed the session-static FITS-header fields from the
                // runtime config. A fresh `session_id` is minted per start()
                // so `SK-SESID` uniquely identifies the run; ExecutionContext::new
                // already generates one in tests, but we MUST replace it here so
                // the value reflects the current production start (not a value
                // generated when this executor instance was first constructed,
                // which could be hours / days ago).
                context.session_id = uuid::Uuid::new_v4().to_string();
                // Native daylight gate — copy the configured max Sun altitude
                // out of the (non-Send) parking_lot guard so it can be seeded
                // into the shared trigger state across an `.await` below. The
                // field is `Option<f64>`; a never-pushed (`None`) or non-finite
                // value resolves to the DEFAULT (-12°, nautical darkness) so the
                // native gate is never weaker than the Dart gate it backstops.
                // A pushed `SchedulerConfig.maxSunAltitudeDegrees` is used
                // verbatim.
                let max_sun_altitude_degrees = match runtime_config.read().max_sun_altitude_degrees
                {
                    Some(v) if v.is_finite() => v,
                    _ => crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
                };
                context.max_sun_altitude_degrees = max_sun_altitude_degrees;
                if let Some(ts_lock) = &context.trigger_state {
                    // Seed the trigger state so the gate (which reads through the
                    // InstructionContext's trigger-state handle, not the
                    // ExecutionContext) sees the configured threshold.
                    ts_lock
                        .write()
                        .await
                        .set_max_sun_altitude_degrees(max_sun_altitude_degrees);
                }
                {
                    let rc = runtime_config.read();
                    context.observer_name = rc.observer_profile.observer_name.clone();
                    context.site_elevation_m = rc.observer_profile.site_elevation_m;
                    context.camera_make = rc.observer_profile.camera_make.clone();
                    context.camera_model = rc.observer_profile.camera_model.clone();
                    context.telescope_name = rc.observer_profile.telescope_name.clone();
                    context.telescope_focal_length_mm =
                        rc.observer_profile.telescope_focal_length_mm;
                    context.telescope_aperture_mm = rc.observer_profile.telescope_aperture_mm;
                    context.default_quality_check = rc.default_quality_check.clone();
                    context.reject_folder_path = rc.reject_folder_path.clone();
                    context.device_retry = rc.device_retry.clone();
                }
                // seed the global adaptive-exposure
                // fallback so a node without its own `adaptive_exposure`
                // block still inherits it. The shared Arc<RwLock> field
                // is written outside the sync `runtime_config.read()`
                // scope because the tokio RwLock write is async.
                {
                    let initial = runtime_config.read().default_adaptive_exposure.clone();
                    let mut slot = context.default_adaptive_exposure.write().await;
                    *slot = initial;
                }
                // seed the defect-map application state
                // from runtime_config so a sequence started after the
                // user has already toggled "Apply during capture" on
                // immediately gets per-frame correction (without waiting
                // for the next push from the UI). `None` is the
                // canonical disabled state.
                {
                    let initial = runtime_config.read().defect_map_apply.clone();
                    let mut slot = context.defect_map_apply.write().await;
                    *slot = initial;
                }
                // seed per-target carry-over integration into
                // the BudgetRegistry. The map is drained out of the
                // runtime config (cloned then cleared) so a subsequent
                // start() without an explicit re-seed begins fresh
                // rather than re-applying stale prior-session totals.
                //
                // This runs AFTER `restore_snapshot` so an explicit
                // "Resume" handoff decision overrides the pre-pause
                // checkpoint state — the operator has expressed an
                // intent that supersedes whatever the executor parked
                // on disk. `Restart` writes an empty map so a target
                // that was previously carried-over is now zeroed.
                {
                    let carry_over: HashMap<String, HashMap<String, f64>> = {
                        let mut rc = runtime_config.write();
                        std::mem::take(&mut rc.pending_integration_carry_over)
                    };
                    if !carry_over.is_empty() {
                        for (target_id, per_filter) in carry_over.into_iter() {
                            tracing::info!(
                                "Seeding integration carry-over for target_id={} \
                                 ({} filter entries)",
                                target_id,
                                per_filter.len()
                            );
                            context
                                .budget_registry
                                .seed_carry_over(&target_id, per_filter)
                                .await;
                        }
                    }
                }
                tracing::info!(
                    "Executor started: session_id={}, observer={:?}, telescope={:?}, grading_active={}",
                    context.session_id,
                    context.observer_name,
                    context.telescope_name,
                    context
                        .default_quality_check
                        .as_ref()
                        .map(|c| c.is_active())
                        .unwrap_or(false)
                );
                // Replay Debug — emit the "sequence started"
                // lifecycle decision so the replay feed has a stable
                // anchor for the run.
                emit_lifecycle_decision(
                    &decision_tx_for_lifecycle,
                    &active_run_id_for_decisions,
                    &decision_logging_enabled_for_emits,
                    "started",
                    serde_json::json!({
                        "session_id": context.session_id.clone(),
                        "grading_active": context
                            .default_quality_check
                            .as_ref()
                            .map(|c| c.is_active())
                            .unwrap_or(false),
                    }),
                );

                // restore per-target integration-budget
                // accounting from the checkpoint, if any. An empty snapshot
                // (no checkpoint loaded, or pre-budget checkpoint) is a
                // no-op which matches the documented backwards-compat
                // behaviour: resume with zero credited per-filter
                // integration and the budget runtime begins crediting from
                // there.
                if let Some(snapshot) = budget_snapshot_to_restore {
                    context.budget_registry.restore_snapshot(snapshot).await;
                }

                // restore the SmartExposure per-node
                // resume map from the checkpoint. Each entry seeds the
                // in-memory `smart_exposure_states` map under
                // ExecutionContext so the next time a SmartExposure node's
                // `execute()` runs, `load_or_init_checkpoint` finds the
                // persisted per-filter counts + plan index and resumes
                // rotation where the previous run left off. Empty / missing
                // map is a no-op (fresh run).
                if let Some(snapshot) = smart_exposure_snapshot_to_restore {
                    if !snapshot.is_empty() {
                        let mut states = context.smart_exposure_states.write().await;
                        for (node_id, state) in snapshot {
                            states.insert(node_id, state);
                        }
                        drop(states);
                    }
                }

                let progress_clone = progress.clone();
                let event_tx_clone = event_tx.clone();
                // NodeStarted must emit exactly once per "entry" into a node; this set
                // guards against the progress callback firing multiple Running updates
                // for the same node within a single visit. Cleared on terminal status
                // so loop bodies emit a fresh NodeStarted each iteration.
                let started_nodes =
                    Arc::new(StdRwLock::new(std::collections::HashSet::<NodeId>::new()));
                // Display name per node id, learned from the one-shot
                // "Executing: <name>" entry message.
                //
                // `current_node_id` is rewritten by EVERY progress update but
                // `current_node_name` was only written on a node's first
                // Running transition, so the two fields drifted apart and
                // together named a node that does not exist. Seen on the live
                // rig: `GET /api/sequencer/status` answered
                // `"currentNodeId":"391bd28d-…"` (the ROOT container) with
                // `"currentNodeName":"Expose 2x2s light"` (a leaf) once the run
                // ended, because the root's own terminal update moved the id and
                // left the name behind. A client that highlights
                // `currentNodeId` on its canvas highlights the wrong node. The
                // pair is identity; keep it atomic.
                //
                // SEEDED from the `SequenceDefinition` this run was built from,
                // rather than learned only from that entry message. The
                // message-parse is a fragile way to learn a name the executor
                // already holds, and when it produced nothing the callback
                // substituted the literal string "Unknown" and CACHED it, so
                // the name could not recover for the rest of the node's life.
                // On the owner's rig `GET /api/sequencer/status` answered
                // `"currentNodeName":"Unknown"` for minutes at a stretch during
                // a Smart Exposure node: that node delegates each burst under
                // its OWN node id, every burst ends with a terminal Success
                // that clears the id from `started_nodes`, and the very next
                // update — `ProgressUpdate::instruction_progress`, which
                // carries no message at all — was then read as a fresh entry
                // with no name. With the authored name already in the map the
                // parse can only ever confirm it.
                let node_names = Arc::new(StdRwLock::new(node_display_names.clone()));
                // completed_exposures must be monotonic per node so the global counter
                // never decreases — e.g. when a loop body restarts, its frame count
                // must not reset back to zero from the UI's perspective.
                let node_frame_progress = Arc::new(StdRwLock::new(std::collections::HashMap::<
                    NodeId,
                    u32,
                >::new()));
                let node_pending_exposure_completion = Arc::new(StdRwLock::new(
                    std::collections::HashMap::<NodeId, u32>::new(),
                ));
                // Integration already credited per FRAME for each node, so the
                // burst's closing one-shot can add only what is left over. Crediting
                // per frame is what makes a run interrupted part-way through a node
                // carry its seconds — an unattended night is one long exposure node
                // per filter, so a lump credit at node completion offers the operator
                // a resume dialog reading "0m integration" after six hours of imaging.
                //
                // The one-shot stays because `exposure_node_metadata` only carries
                // TakeExposure nodes — a producer with no per-frame duration (smart
                // exposure) still needs its whole burst counted at the end.
                //
                // Crediting per frame instead of removing the one-shot outright,
                // because `exposure_node_metadata` only carries TakeExposure
                // nodes — a producer with no per-frame duration (smart exposure)
                // still needs its whole burst counted at the end.
                let node_integration_credited = Arc::new(StdRwLock::new(
                    std::collections::HashMap::<NodeId, f64>::new(),
                ));
                let exposure_node_metadata = exposure_node_metadata.clone();
                let target_node_metadata = target_node_metadata.clone();
                context.progress_callback = Some(build_progress_callback(ProgressCallbackArgs {
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
                }));

                // ParkAndAbort runs inside the trigger monitor while node
                // execution and the command/checkpoint futures are polled in
                // parallel. Keep cancellation-aware peers alive until the
                // safe-state sweep completes; otherwise the outer select!
                // could drop the trigger monitor after node cleanup but before
                // park/close.
                let park_and_abort_in_progress = Arc::new(AtomicBool::new(false));
                let (execution_quiesced_tx, execution_quiesced_rx) = watch::channel(false);
                let (park_and_abort_done_tx, park_and_abort_done_rx) = watch::channel(false);

                let is_paused_cmd = is_paused.clone();
                let skip_to_next_target_cmd = skip_to_next_target.clone();
                // Command-handler-side clone for posting
                // SkipToNode requests into the shared slot.
                let skip_to_node_cmd = skip_to_node.clone();
                let resume_notify_cmd = resume_notify.clone();
                // The status API reads the progress snapshot, so every command
                // that changes the executor's state has to stamp it there too.
                let progress_for_commands = progress.clone();
                // Recovery Mode — command-handler-side clone so the
                // RecoveryTryNow / RecoveryAbort handlers can fire the
                // signal bus without grabbing the shared executor lock.
                let recovery_signals_cmd = recovery_signals_clone.clone();
                let safety_fail_mode_for_cmd = context.safety_fail_mode.clone();
                let command_handler = run_command_handler(CommandHandlerArgs {
                    cloud_motion_for_recovery: cloud_motion_for_recovery.clone(),
                    conditions_score_for_cmd,
                    current_recovery_for_cmd: current_recovery_clone.clone(),
                    default_adaptive_for_cmd,
                    defect_map_apply_for_cmd,
                    event_tx: event_tx.clone(),
                    is_cancelled: is_cancelled.clone(),
                    is_paused_cmd,
                    plugin_node_pending_for_cmd,
                    progress_for_commands,
                    recovery_signals_cmd,
                    resume_notify_cmd,
                    rx,
                    runtime_config: runtime_config.clone(),
                    safety_fail_mode_for_cmd,
                    skip_to_next_target_cmd,
                    skip_to_node_cmd,
                    sky_brightness_for_cmd,
                    state: state.clone(),
                    transparency_backup_for_cmd,
                    transparency_for_cmd,
                    trigger_manager: trigger_manager.clone(),
                });

                let streaming_filter_focus_offsets = context.filter_focus_offsets.clone();
                let streaming_runtime_config = runtime_config.clone();
                // clone the budget registry handle for the
                // streaming checkpoint task. The registry is `Arc<RwLock<...>>`
                // internally so the clone shares the same allocation as the
                // executor's main context.
                let streaming_budget_registry = context.budget_registry.clone();
                // clone the SmartExposure state map handle
                // for the streaming checkpoint task. Same pattern as the
                // budget registry: the inner Arc is shared so the streaming
                // task sees the up-to-date per-filter counts the
                // SmartExposure instruction writes between batches.
                let streaming_smart_exposure_states = context.smart_exposure_states.clone();

                let custom_recovery_context = context.clone();
                // ParkAndAbort is driven by the trigger-monitor future while
                // the node tree executes in parallel. The two watch channels
                // form a handshake:
                //
                //   cancel -> node cleanup/abort -> quiesced -> park/close -> done
                //
                // The execution future remains pending after node cleanup while
                // a ParkAndAbort sweep is active. This prevents the outer
                // select! from choosing completed execution and dropping the
                // trigger monitor halfway through the hardware-safe-state work.
                // Subscribed BEFORE the tree runs so every complaint a failing
                // run emits is seen, and followed as the run goes: a receiver
                // drained only at the end kept the last 256 events of the
                // night and lost any fault further back.
                let failure_collector =
                    crate::executor::failure_cause::FailureCollector::spawn(event_tx.subscribe());
                let park_and_abort_for_execution = park_and_abort_in_progress.clone();
                let mut park_and_abort_done_rx = park_and_abort_done_rx;
                let park_and_abort_done_for_checkpoint = park_and_abort_done_rx.clone();
                let execution = async {
                    let result = root_node.execute(&mut context).await;
                    let _ = execution_quiesced_tx.send(true);
                    if park_and_abort_for_execution.load(Ordering::Acquire) {
                        if let Err(error) = park_and_abort_done_rx.wait_for(|done| *done).await {
                            tracing::warn!(
                                "Park-and-abort handshake: the completion signal was dropped \
                                 before the safe-state sweep reported done ({}); ending \
                                 execution without waiting — verify the rig is parked",
                                error
                            );
                        }
                    }
                    result
                };

                let state_clone = state.clone();
                let event_tx_clone2 = event_tx.clone();
                let is_cancelled_clone = is_cancelled.clone();
                let park_and_abort_for_triggers = park_and_abort_in_progress.clone();
                let execution_quiesced_for_triggers = execution_quiesced_rx;
                let park_and_abort_done_for_triggers = park_and_abort_done_tx;
                let is_paused_for_triggers = is_paused.clone();
                let skip_to_next_target_for_triggers = skip_to_next_target.clone();
                // The trigger monitor needs the progress snapshot so a
                // trigger-driven pause updates the value
                // `sequencer_get_status()` actually reads (`progress.state`),
                // not only the internal executor state.
                let progress_for_triggers = progress.clone();
                // Set for the duration of a trigger recovery action (meridian
                // flip, dither, autofocus, …) so the run cannot resolve while
                // one is still in flight. Without it the node tree finishing
                // dropped the whole `trigger_monitor` future mid-await,
                // silently orphaning an in-progress flip retry ladder.
                let trigger_action_in_flight = Arc::new(AtomicBool::new(false));
                let trigger_action_in_flight_for_triggers = trigger_action_in_flight.clone();
                let trigger_action_in_flight_for_watchdog = trigger_action_in_flight.clone();
                // One beat per completed monitor iteration. See
                // `trigger_monitor_stall_watchdog`.
                let (heartbeat_tx, heartbeat_rx) = watch::channel(0_u64);
                let event_tx_for_watchdog = event_tx.clone();
                // Latched when a meridian flip failed outright, so the run's
                // terminal verdict is a Failure rather than a silent success.
                let meridian_flip_failed = Arc::new(AtomicBool::new(false));
                let meridian_flip_failed_for_triggers = meridian_flip_failed.clone();
                // What the failed flip said, for the run's failure reason. The
                // flip is not a node, so the tree carries on past its complaint
                // and the failure chain counts it as survived.
                let meridian_flip_failure: Arc<StdRwLock<Option<String>>> =
                    Arc::new(StdRwLock::new(None));
                let meridian_flip_failure_for_triggers = meridian_flip_failure.clone();
                let progress_for_checkpoint = progress.clone();
                let state_for_checkpoint = state.clone();
                let is_cancelled_for_checkpoint = is_cancelled.clone();
                let trigger_manager_for_checkpoint = trigger_manager.clone();
                let streaming_triggers_enabled = triggers_enabled;
                let park_and_abort_for_checkpoint = park_and_abort_in_progress.clone();
                let streaming_checkpoint_task = run_checkpoint_stream(CheckpointStreamArgs {
                    is_cancelled_for_checkpoint,
                    park_and_abort_done_for_checkpoint,
                    park_and_abort_for_checkpoint,
                    progress_for_checkpoint,
                    state_for_checkpoint,
                    streaming_budget_registry,
                    streaming_camera_id,
                    streaming_checkpoint_manager,
                    streaming_filter_focus_offsets,
                    streaming_filterwheel_id,
                    streaming_focuser_id,
                    streaming_latitude,
                    streaming_longitude,
                    streaming_mount_id,
                    streaming_rotator_id,
                    streaming_runtime_config,
                    streaming_save_path,
                    streaming_sequence,
                    streaming_smart_exposure_states,
                    streaming_triggers_enabled,
                    trigger_manager_for_checkpoint,
                });

                // ============================================================
                // Recovery Mode — driver task
                // ============================================================
                //
                // Runs alongside the trigger monitor and listens on the
                // `recovery_request_rx` channel for `RecoveryCause` postings
                // from the trigger monitor (and, future, instruction nodes).
                // When a request arrives:
                //
                //   1. Flip executor state Running -> Recovering and emit
                //      `RecoveryStarted`.
                //   2. Freeze the node tree by setting `is_paused` so any
                //      in-flight instruction waits at its next pause check.
                //   3. (Optionally) stop mount tracking per
                //      `RecoveryRuntimeConfig.stop_tracking_during_recovery`.
                //   4. Loop:
                //         - Wait for `retry_interval_secs` OR `TryNow` OR
                //           `Abort` OR `is_cancelled`.
                //         - On Abort: exit with GaveUp(aborted_by_user=true).
                //         - On Cancelled: exit (Stop / sequence aborted).
                //         - Otherwise: bump `attempt_count`, attempt the
                //           recovery action, evaluate the outcome.
                //         - On Success: emit RecoveryCompleted, flip back to
                //           Running, unfreeze the tree.
                //         - On Failure: stay in loop; check exhaustion
                //           (attempts or time budget).
                //
                // Why a dedicated task vs running inside the trigger monitor:
                // the trigger monitor already runs the failure-detection
                // poll loop and per-trigger recovery actions. Putting the
                // recovery loop inline would interleave detection and
                // recovery on the same 1Hz cadence — meaning a long retry
                // wait would block detection of OTHER triggers (e.g. a
                // weather-unsafe event during a guide-loss recovery).
                // Separating them lets the trigger monitor keep watching
                // while the recovery driver drives its loop on its own
                // cadence.
                // set when the recovery loop gives up due to a real
                // (non-operator-abort) failure. Checked after the main
                // `select!` so the run reports `Failed` instead of the benign
                // `Cancelled` the node-tree cancellation would otherwise win.
                let recovery_gave_up =
                    std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
                let recovery_driver_gave_up = recovery_gave_up.clone();
                let recovery_driver_state = state.clone();
                let recovery_driver_progress = progress.clone();
                let recovery_driver_event_tx = event_tx.clone();
                let recovery_driver_is_paused = is_paused.clone();
                // Replay Debug — clone the decision channel + active
                // run id into the recovery driver closure so the
                // `RecoveryEntered` lifecycle decision fires alongside the
                // existing `ExecutorEvent::RecoveryStarted` event.
                let recovery_driver_decision_tx = decision_tx_for_lifecycle.clone();
                let recovery_driver_active_run_id = active_run_id_for_decisions.clone();
                let recovery_driver_is_cancelled = is_cancelled.clone();
                let recovery_driver_signals = recovery_signals_clone.clone();
                let recovery_driver_runtime = runtime_config.clone();
                let recovery_driver_current = current_recovery_clone.clone();
                let recovery_driver_history = recovery_history_clone.clone();
                let recovery_driver_device_ops = device_ops_for_triggers.clone();
                let recovery_driver_mount_id = trigger_action_context.mount_id.clone();
                let recovery_driver_device_ids = trigger_action_context.connected_device_ids();
                // ids used to leave hardware safe if recovery
                // exhausts on an unattended night (park mount, close cover/dome).
                let recovery_driver_dome_id = trigger_action_context.dome_id.clone();
                let recovery_driver_cover_id = trigger_action_context.cover_calibrator_id.clone();
                let recovery_driver_trigger_mgr = trigger_manager.clone();
                let recovery_driver = run_recovery_driver(RecoveryDriverArgs {
                    recovery_driver_active_run_id,
                    recovery_driver_cover_id,
                    recovery_driver_current,
                    recovery_driver_decision_tx,
                    recovery_driver_device_ids,
                    recovery_driver_device_ops,
                    recovery_driver_dome_id,
                    recovery_driver_event_tx,
                    recovery_driver_gave_up,
                    recovery_driver_generation,
                    recovery_driver_history,
                    recovery_driver_is_cancelled,
                    recovery_driver_is_paused,
                    recovery_driver_mount_id,
                    recovery_driver_progress,
                    recovery_driver_runtime,
                    recovery_driver_signals,
                    recovery_driver_state,
                    recovery_driver_trigger_mgr,
                    recovery_driver_trigger_context: trigger_action_context.clone(),
                    recovery_request_rx,
                });

                let custom_recovery_branches_for_triggers = custom_recovery_branches.clone();
                let sequence_for_custom_recovery_triggers = sequence_for_custom_recovery.clone();
                let custom_recovery_context_for_triggers = custom_recovery_context.clone();

                let trigger_monitor_poll_loop = run_trigger_monitor_poll_loop(TriggerMonitorArgs {
                    active_run_id_for_decisions: active_run_id_for_decisions.clone(),
                    cloud_motion_for_recovery: cloud_motion_for_recovery.clone(),
                    custom_recovery_branches_for_triggers,
                    custom_recovery_context_for_triggers,
                    decision_tx_for_lifecycle: decision_tx_for_lifecycle.clone(),
                    device_ops_for_triggers,
                    event_tx_clone2,
                    execution_quiesced_for_triggers,
                    heartbeat_tx,
                    is_cancelled_clone,
                    is_paused_for_triggers,
                    meridian_flip_failed_for_triggers,
                    meridian_flip_failure_for_triggers,
                    park_and_abort_done_for_triggers,
                    park_and_abort_for_triggers,
                    progress_for_triggers,
                    recovery_request_tx,
                    runtime_config: runtime_config.clone(),
                    sequence_for_custom_recovery_triggers,
                    skip_to_next_target_for_triggers,
                    skip_to_node_for_recovery,
                    state_clone,
                    transparency_backup_for_recovery,
                    trigger_action_context,
                    trigger_action_in_flight_for_triggers,
                    trigger_manager: trigger_manager.clone(),
                    triggers_enabled,
                });

                // A hung poll is indistinguishable from a healthy monitor to the
                // join below, so the watchdog turns "stalled" into "exited" — the
                // one shape the fail-closed handler downstream can act on.
                let trigger_monitor = async {
                    tokio::pin!(trigger_monitor_poll_loop);
                    tokio::select! {
                        fired = &mut trigger_monitor_poll_loop => fired,
                        () = trigger_monitor_stall_watchdog(
                            heartbeat_rx,
                            trigger_action_in_flight_for_watchdog,
                            std::time::Duration::from_secs(TRIGGER_MONITOR_STALL_TIMEOUT_SECS),
                        ) => {
                            let message = format!(
                                "Safety monitoring stalled: the trigger monitor has not \
                                 completed a poll cycle in {TRIGGER_MONITOR_STALL_TIMEOUT_SECS}s, \
                                 so weather, altitude, drift, tracking-loss, dome and meridian \
                                 protection are no longer being enforced. A device driver is \
                                 most likely not returning."
                            );
                            tracing::error!("{}", message);
                            let _ = event_tx_for_watchdog.send(ExecutorEvent::Error { message });
                            Vec::new()
                        }
                    }
                };

                // Fail-closed safety: an unattended sequence depends on the trigger
                // monitor to enforce weather / altitude / drift limits. If it exits
                // for any reason other than normal cancellation, continuing to
                // expose would leave the rig unmonitored — so we cancel everything.
                //
                // Every non-execution branch first cancels and then DRAINS the
                // execution future; dropping it here bypasses the active
                // instruction's cancellation branch and lets a camera exposure keep
                // integrating after Stop has been reported as confirmed.
                tokio::pin!(execution);
                // Pinned (not consumed by value) so the quiesce loop below can
                // keep driving the monitor after this select! resolves. See
                // `TriggerActionInFlightGuard`.
                tokio::pin!(trigger_monitor);
                let result = tokio::select! {
                    _ = command_handler => {
                        is_cancelled.store(true, Ordering::Release);
                        (&mut execution).await
                    },
                    result = &mut execution => result,
                    _ = streaming_checkpoint_task => {
                        is_cancelled.store(true, Ordering::Release);
                        (&mut execution).await
                    },
                    // Recovery Mode — the driver task only ever
                    // exits when the recovery_request_tx side is closed
                    // (sequence ending), so a clean exit is a Cancelled
                    // outcome. The driver intentionally holds itself open
                    // by recv-looping; we keep it in the select! so a
                    // panic here surfaces in the same way as any other
                    // task panic (caught by the supervisor catch_unwind).
                    _ = recovery_driver => {
                        is_cancelled.store(true, Ordering::Release);
                        (&mut execution).await
                    },
                    _triggers = &mut trigger_monitor => {
                        if triggers_enabled && !is_cancelled.load(Ordering::Relaxed) {
                            tracing::error!(
                                "Safety monitoring (trigger monitor) exited unexpectedly! \
                                 Cancelling sequence to prevent unmonitored execution."
                            );
                            is_cancelled.store(true, Ordering::Relaxed);
                            let _ = event_tx.send(ExecutorEvent::Error {
                                message: "Safety monitoring failed — sequence aborted. \
                                          The trigger monitor exited unexpectedly."
                                    .to_string(),
                            });
                            let _ = (&mut execution).await;
                            NodeStatus::Failure
                        } else {
                            (&mut execution).await
                        }
                    },
                };

                // A trigger recovery action may still be running: the node tree
                // finishing does NOT mean the rig is settled. The canonical
                // case is a meridian flip whose retry ladder is mid-sleep —
                // dropping `trigger_monitor` here abandoned the flip with the
                // mount parked between pier sides and let the run report a
                // clean `completed`. Keep driving the monitor until the action
                // resolves so its outcome (success / degraded / failed, plus
                // any AbortAndPark safing) is actually applied.
                //
                // On a cancel/stop the flip polls the same `is_cancelled` token
                // and unwinds within a couple of hundred milliseconds, so this
                // wait does not delay an operator Stop.
                if trigger_action_in_flight.load(Ordering::Acquire) {
                    tracing::warn!(
                        "Node tree finished while a trigger recovery action is still \
                         running; waiting up to {}s for it to complete before ending the run",
                        TRIGGER_ACTION_QUIESCE_MAX_SECS
                    );
                    let deadline = tokio::time::Instant::now()
                        + std::time::Duration::from_secs(TRIGGER_ACTION_QUIESCE_MAX_SECS);
                    while trigger_action_in_flight.load(Ordering::Acquire) {
                        tokio::select! {
                            _ = &mut trigger_monitor => break,
                            _ = tokio::time::sleep_until(deadline) => {
                                let message = format!(
                                    "A trigger recovery action was still running {}s after the \
                                     sequence finished and was abandoned. The mount may not be \
                                     in the state the sequence expected — verify it manually.",
                                    TRIGGER_ACTION_QUIESCE_MAX_SECS
                                );
                                tracing::error!("{}", message);
                                let _ = event_tx.send(ExecutorEvent::Error { message });
                                break;
                            }
                            _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
                        }
                    }
                    tracing::info!("In-flight trigger recovery action quiesced; ending run");
                }

                // when recovery exhausted on a real failure it set
                // `is_cancelled` to unwind the node tree, so the `execution`
                // branch of the select! above resolves to `Cancelled` and would
                // otherwise overwrite the `Failed` state the recovery driver
                // set — the run would be reported as a benign cancellation in
                // the UI / session report. Coerce it back to `Failure` so the
                // give-up is recorded as the failure it actually is.
                let result = if recovery_gave_up.load(Ordering::Relaxed)
                    && !matches!(result, NodeStatus::Failure)
                {
                    NodeStatus::Failure
                } else {
                    result
                };

                // Same reasoning for a meridian flip that failed outright. The
                // mount did not end up where the sequence assumed, so every
                // frame taken after the failed flip is suspect. Reporting
                // `completed` there is the silent-data-loss case this whole
                // path exists to prevent — a flip that exhausted its retries
                // makes the RUN a failure even if the node tree walked to the
                // end. A flip that merely retried and then succeeded is NOT
                // coerced; it is recorded as a degraded-but-successful flip.
                let result = if meridian_flip_failed.load(Ordering::Acquire)
                    && !matches!(result, NodeStatus::Failure)
                {
                    tracing::error!(
                        "Sequence finished with {:?} but a meridian flip FAILED during the \
                         run; recording the run as a failure",
                        result
                    );
                    NodeStatus::Failure
                } else {
                    result
                };

                // A tree that walked to the end but contains instructions the
                // executor structurally cannot reach did NOT do what the
                // sequence says it does. Reporting `completed` there is the
                // same silent-data-loss class as the failed-flip coercion
                // above: the operator sees a green Completed badge over a run
                // that skipped most of its work.
                let mut unreachable_failure_reason: Option<String> = None;
                let result = if !unreachable_instruction_names.is_empty()
                    && matches!(result, NodeStatus::Success | NodeStatus::Skipped)
                {
                    let message = unreachable_instructions_message(&unreachable_instruction_names);
                    tracing::error!(
                        "Sequence finished with {:?} but never executed part of its tree; \
                         recording the run as a failure. {}",
                        result,
                        message
                    );
                    let _ = event_tx.send(ExecutorEvent::Error {
                        message: message.clone(),
                    });
                    unreachable_failure_reason = Some(message);
                    NodeStatus::Failure
                } else {
                    result
                };

                let final_state = executor_state_for_result(result);

                // The terminal message is the run's own verdict, composed from
                // the status the ROOT returned (after the coercions above), so
                // `message` and `state` can never disagree on
                // `/api/sequencer/status`.
                //
                // It used to be whatever progress update happened to land last,
                // and the tree keeps emitting after the root reaches its
                // terminal status: a night that finished cleanly answered
                // `state: "completed"` with `message: "Autofocus: step 0/9 HFR
                // 2.11 (100%)"` — the last update a filter-change autofocus had
                // queued — and a night cut short by a skip request answered
                // `state: "completed"`, 8 frames, `message: "Skipped: Night
                // root"`.
                let verdict = terminal_verdict_message(result, &root_display_name);

                *state.write().await = final_state;
                {
                    let mut prog = progress.write();
                    prog.state = final_state;
                    prog.message = Some(verdict);
                    prog.elapsed_secs = start_time.elapsed().as_secs_f64();
                }

                match result {
                    NodeStatus::Success | NodeStatus::Skipped => {
                        // Mark the checkpoint inactive on graceful completion.
                        // Without this the on-disk checkpoint stays `is_active`
                        // forever, so `has_recoverable_checkpoint()` keeps
                        // returning true and the UI shows a stale "resume?"
                        // banner after every successful night. We use
                        // `mark_completed()` (not `clear()`) so the file is
                        // preserved with `is_active=false` /
                        // `executor_state=Completed` for the post-session report;
                        // the next `start()` overwrites it. A failure to write is
                        // logged loudly (it would silently reintroduce the stale
                        // banner) but does not change the run's Success outcome.
                        if let Some(mgr) = &completion_checkpoint_manager {
                            if let Err(e) = mgr.mark_completed() {
                                tracing::error!(
                                    "Failed to mark checkpoint completed after a normal \
                                     sequence finish: {} — a stale 'resume?' banner may \
                                     appear on next launch",
                                    e
                                );
                            } else {
                                tracing::debug!(
                                    "Checkpoint marked completed on normal sequence finish"
                                );
                            }
                        }
                        let _ = event_tx.send(ExecutorEvent::SequenceCompleted);
                        // Replay Debug — terminal lifecycle decision.
                        emit_lifecycle_decision(
                            &decision_tx_for_lifecycle,
                            &active_run_id_for_decisions,
                            &decision_logging_enabled_for_emits,
                            "completed",
                            serde_json::json!({
                                "elapsed_secs": start_time.elapsed().as_secs_f64(),
                                "final_state": format!("{:?}", final_state),
                            }),
                        );
                    }
                    NodeStatus::Failure => {
                        // "Sequence failed" told the operator nothing: the run
                        // that died on the daylight gate carried the real
                        // reason in its log while the toast, the Session
                        // Report and the persisted `errorMessages` all showed
                        // the placeholder.
                        //
                        // Choosing the MOST RECENT failure was the next
                        // placeholder. A dying run cancels its node tree and
                        // every device operation still in flight reports the
                        // cancellation as a failure of its own, so the newest
                        // complaint is always the teardown. The owner's
                        // 2026-09-15 run lost guiding, trailed three frames,
                        // tripped the reject limit and was abandoned — and
                        // reported "Change Filter: Operation cancelled",
                        // logged one second after the abandonment. See
                        // `executor::failure_cause` for the rule that replaced
                        // it: the structural refusal if there is one, else the
                        // FIRST fault, never a cancelled cleanup step.
                        let mut failure_report =
                            failure_collector.finish(unreachable_failure_reason).await;
                        // A run the failed flip made a failure, with no later
                        // fault of its own, failed because of the flip.
                        if failure_report.cause.is_none()
                            && meridian_flip_failed.load(Ordering::Acquire)
                        {
                            failure_report.cause = meridian_flip_failure.read().clone();
                        }
                        if failure_report.cascade.len() > 1 {
                            tracing::info!(
                                "Run failure cascade ({} links, cause first): {}",
                                failure_report.cascade.len(),
                                failure_report.cascade.join(" | ")
                            );
                        }
                        let reason = failure_report.cause;
                        // The verdict composed above is "Failed: <root name>" —
                        // it names the container the operator never configured
                        // and gives no reason at all, and it is verbatim what
                        // `GET /api/sequencer/status` returns as `message`. A
                        // night that died on an unevaluable target trigger
                        // therefore answered "Failed: Night root" to every
                        // remote client and morning operator while the real
                        // refusal sat in the Rust log. When the run HAS a
                        // reason, that reason is the honest terminal message.
                        // When it has none, the verdict is left in place rather
                        // than replaced with a second placeholder.
                        if let Some(reason) = reason.as_deref() {
                            progress.write().message = Some(reason.to_string());
                        }
                        let error = reason.unwrap_or_else(|| "Sequence failed".to_string());
                        let _ = event_tx.send(ExecutorEvent::SequenceFailed {
                            error: error.clone(),
                        });
                        emit_lifecycle_decision(
                            &decision_tx_for_lifecycle,
                            &active_run_id_for_decisions,
                            &decision_logging_enabled_for_emits,
                            "failed",
                            serde_json::json!({
                                "elapsed_secs": start_time.elapsed().as_secs_f64(),
                                "error": error,
                            }),
                        );
                    }
                    NodeStatus::Cancelled => {
                        let _ = event_tx.send(ExecutorEvent::Error {
                            message: "Sequence cancelled".into(),
                        });
                        emit_lifecycle_decision(
                            &decision_tx_for_lifecycle,
                            &active_run_id_for_decisions,
                            &decision_logging_enabled_for_emits,
                            "cancelled",
                            serde_json::json!({
                                "elapsed_secs": start_time.elapsed().as_secs_f64(),
                            }),
                        );
                    }
                    _ => {}
                }

                let _ = event_tx.send(ExecutorEvent::StateChanged(final_state));
            };

            // Catch any panic inside the executor future: a silently-dead
            // sequencer must not read as a running one. Restarting node
            // execution after a panic is not safe (device state is unknown
            // and `root_node` has been consumed by move), so the policy is:
            // log + emit SequenceFailed + move state to Failed.
            if let Err(panic_payload) = AssertUnwindSafe(executor_future).catch_unwind().await {
                let panic_msg = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                    (*s).to_string()
                } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                    s.clone()
                } else {
                    "Unknown panic".to_string()
                };
                tracing::error!(
                    target: "supervisor",
                    "sequencer_executor panicked; sequence aborted: {panic_msg}"
                );

                *supervisor_state.write().await = ExecutorState::Failed;
                {
                    let mut prog = supervisor_progress.write();
                    prog.state = ExecutorState::Failed;
                }
                let _ = supervisor_event_tx.send(ExecutorEvent::SequenceFailed {
                    error: format!("Sequencer panicked: {panic_msg}"),
                });
                let _ =
                    supervisor_event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Failed));
            }
            let _ = run_completion_tx.send(());
        });

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The terminal message states what the ROOT did. Reporting a night that
    /// imaged as "Skipped" — or one that failed as "Completed" — is the same
    /// class of lie whichever direction it points in, and every remote client
    /// renders this string next to `state`.
    #[test]
    fn the_terminal_verdict_follows_the_status_the_root_returned() {
        assert_eq!(
            terminal_verdict_message(NodeStatus::Success, "Night root"),
            "Completed: Night root"
        );
        assert_eq!(
            terminal_verdict_message(NodeStatus::Skipped, "Night root"),
            "Skipped: Night root"
        );
        assert_eq!(
            terminal_verdict_message(NodeStatus::Failure, "Night root"),
            "Failed: Night root"
        );
        assert_eq!(
            terminal_verdict_message(NodeStatus::Cancelled, "Night root"),
            "Cancelled: Night root"
        );
    }
}
