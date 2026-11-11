//! Context the trigger-fired recovery actions run against: the device-id
//! snapshot, the autofocus / meridian-flip context builders, the in-flight
//! guard, camera claiming, and the small verdict helpers. Moved verbatim out
//! of `executor/mod.rs`.

use super::*;

/// The devices, save path and site a run was started with.
#[derive(Debug, Clone, Default)]
pub(crate) struct RunRig {
    pub(super) camera_id: Option<String>,
    pub(super) mount_id: Option<String>,
    pub(super) focuser_id: Option<String>,
    pub(super) filterwheel_id: Option<String>,
    pub(super) rotator_id: Option<String>,
    pub(super) dome_id: Option<String>,
    pub(super) cover_calibrator_id: Option<String>,
    pub(super) save_path: Option<PathBuf>,
    pub(super) latitude: Option<f64>,
    pub(super) longitude: Option<f64>,
    pub(super) filter_focus_offsets: HashMap<String, i32>,
}

impl RunRig {
    pub(super) fn connected_device_ids(&self) -> Vec<String> {
        [
            self.camera_id.as_ref(),
            self.mount_id.as_ref(),
            self.focuser_id.as_ref(),
            self.filterwheel_id.as_ref(),
            self.rotator_id.as_ref(),
            self.dome_id.as_ref(),
            self.cover_calibrator_id.as_ref(),
        ]
        .into_iter()
        .flatten()
        .cloned()
        .collect()
    }
}

#[derive(Debug, Clone)]
pub(super) struct SequenceRecoveryTriggerSpec {
    pub(super) node_id: NodeId,
    pub(super) trigger_id: String,
    pub(super) trigger_name: String,
    pub(super) trigger_type: TriggerType,
    pub(super) recovery_action: RecoveryAction,
    pub(super) custom_branch_node_id: Option<NodeId>,
}

pub(super) fn sequence_recovery_trigger_specs(
    sequence: &SequenceDefinition,
) -> Vec<SequenceRecoveryTriggerSpec> {
    sequence
        .nodes
        .iter()
        .filter_map(|node| {
            let NodeType::Recovery(config) = &node.node_type else {
                return None;
            };
            let trigger_type = config.trigger.clone()?;
            Some(SequenceRecoveryTriggerSpec {
                node_id: node.id.clone(),
                trigger_id: crate::triggers::recovery_node_trigger_id(&node.id),
                trigger_name: format!("Recovery: {}", node.name),
                trigger_type,
                recovery_action: config.recovery_action.clone(),
                custom_branch_node_id: matches!(
                    config.recovery_action,
                    RecoveryAction::CustomBranch
                )
                .then(|| node.id.clone()),
            })
        })
        .collect()
}

pub(super) fn build_runtime_node_from_map(
    def: &NodeDefinition,
    node_map: &HashMap<&str, &NodeDefinition>,
) -> RuntimeNode {
    let mut node = RuntimeNode::from_definition(def.clone());

    tracing::debug!(
        "Building node '{}' (id={}) with {} children defined: {:?}",
        def.name,
        def.id,
        def.children.len(),
        def.children
    );

    for child_id in &def.children {
        if let Some(child_def) = node_map.get(child_id.as_str()) {
            tracing::debug!(
                "  Adding child '{}' (id={}) to '{}'",
                child_def.name,
                child_def.id,
                def.name
            );
            let child = build_runtime_node_from_map(child_def, node_map);
            node.add_child(Box::new(child));
        } else {
            tracing::warn!(
                "  Child node '{}' not found in node_map for parent '{}'",
                child_id,
                def.name
            );
        }
    }

    node
}

#[allow(clippy::too_many_arguments)]
pub(super) fn build_trigger_autofocus_context(
    trigger_context: &RunRig,
    target_name: Option<String>,
    target_ra: Option<f64>,
    target_dec: Option<f64>,
    current_filter: Option<String>,
    cancellation_token: Arc<AtomicBool>,
    device_ops: SharedDeviceOps,
    trigger_state: Arc<RwLock<TriggerState>>,
    runtime_config: &RunConfigStore,
    event_tx: Option<broadcast::Sender<ExecutorEvent>>,
) -> crate::instructions::InstructionContext {
    // The live settings, so a change made during the run reaches
    // trigger-run autofocus, dither and recenter. Two cases fall back to the
    // values the run started with: an empty offset map and an unset site.
    // Clearing every offset, or the site, mid-run therefore does not reach
    // these instructions until the next start.
    let (live_offsets, rc_lat, rc_lon) = {
        let rc = runtime_config.read();
        (rc.filter_focus_offsets.clone(), rc.latitude, rc.longitude)
    };
    let filter_focus_offsets = if live_offsets.is_empty() {
        trigger_context.filter_focus_offsets.clone()
    } else {
        live_offsets
    };
    let latitude = rc_lat.or(trigger_context.latitude);
    let longitude = rc_lon.or(trigger_context.longitude);

    crate::instructions::InstructionContext {
        // Trigger-driven recenter is not a sequence node.
        node_id: String::new(),
        target_ra,
        target_dec,
        // Trigger-initiated recenter does not move the rotator; rotation is a
        // CenterTarget concern driven from the TargetHeader. None here keeps
        // the trigger recenter path rotation-agnostic.
        target_rotation: None,
        target_name,
        current_filter,
        current_binning: crate::Binning::One,
        cancellation_token,
        camera_id: trigger_context.camera_id.clone(),
        mount_id: trigger_context.mount_id.clone(),
        focuser_id: trigger_context.focuser_id.clone(),
        filterwheel_id: trigger_context.filterwheel_id.clone(),
        rotator_id: trigger_context.rotator_id.clone(),
        dome_id: trigger_context.dome_id.clone(),
        cover_calibrator_id: trigger_context.cover_calibrator_id.clone(),
        save_path: trigger_context.save_path.clone(),
        latitude,
        longitude,
        device_ops,
        trigger_state: Some(trigger_state),
        filter_focus_offsets,
        // callers pass `Some(event_tx_clone2.clone())` so
        // FITS-save failures and other instruction-level errors fired from
        // trigger-initiated work (autofocus / dither / recenter) reach the
        // executor's event subscribers (UI, logging). Unit tests still pass
        // `None` because they exercise the build helper in isolation.
        event_tx,
        recovery_request_tx: None,
        // Trigger-initiated work is not wrapped by the node-runtime retry path,
        // so this flag is a standalone fresh Arc here.
        device_disconnect_recovery_pending: std::sync::Arc::new(
            std::sync::atomic::AtomicBool::new(false),
        ),
        // Image Grading: trigger-initiated autofocus does not save
        // FITS frames itself, so empty defaults are honest here. If trigger
        // code ever calls save_fits in the future these would need to be
        // wired through the trigger_context snapshot.
        session_id: String::new(),
        target_id: None,
        mosaic_panel: None,
        current_filter_index: None,
        set_temp_c: None,
        bayer_pattern: None,
        observer_name: None,
        site_elevation_m: None,
        camera_make: None,
        camera_model: None,
        telescope_name: None,
        telescope_focal_length_mm: None,
        telescope_aperture_mm: None,
        last_plate_solve: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        hfr_baseline: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        hfr_baseline_samples: std::sync::Arc::new(tokio::sync::RwLock::new(Vec::new())),
        star_count_baselines: Default::default(),
        consecutive_rejects: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        frames_accepted: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        frames_rejected: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        default_quality_check: None,
        reject_folder_path: None,
        // trigger-initiated autofocus does not save
        // FITS frames itself; the defect-map slot starts empty so a
        // future trigger code path that does save_fits will need to
        // wire this through the trigger_context.
        defect_map_apply: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        // Forensics: trigger-initiated work doesn't have the
        // shared forensics history available; start empty Arcs so any
        // grading reached by a future trigger path falls back gracefully.
        forensics_history: std::sync::Arc::new(tokio::sync::RwLock::new(
            std::collections::VecDeque::new(),
        )),
        current_sky_brightness_mag: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        cloud_motion_snapshot: std::sync::Arc::new(tokio::sync::RwLock::new(
            crate::node::context::CloudMotionSnapshot::default(),
        )),
        current_wind_kph: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        current_sensor_temp_c: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        // Replay Debug — trigger-initiated work (autofocus,
        // dither) does not currently emit DecisionEvents (we wire
        // recoveries + scheduler + lifecycle separately), so the
        // sender starts None and emissions from this context are no-
        // ops. A future caller that wants trigger-initiated work to
        // appear in the replay feed can clone the executor's
        // decision_tx into this helper.
        decision_tx: None,
        active_sequence_run_id: std::sync::Arc::new(parking_lot::RwLock::new(None)),
        // Dual-rig — trigger-initiated dither/recenter is not coordinated with
        // the secondary loop in v1 (the secondary only gates on the main-burst
        // dither path); start None.
        dither_barrier: None,
        // The run's retry policy, so a trigger-fired action's filter change
        // retries like the sequence's own.
        device_retry: runtime_config.slots().device_retry.clone(),
        target_light_filters: Vec::new(),
    }
}

/// The target a trigger-initiated meridian flip is being built for.
///
/// Grouped into a struct rather than passed as three positional parameters:
/// `ra_hours` and `dec_degrees` are both `Option<f64>`, so as bare positional
/// arguments they are silently transposable at a call site, and a flip aimed at
/// the transposed coordinates would recentre onto the wrong sky.
pub(super) struct TriggerFlipTarget {
    pub(super) name: String,
    pub(super) ra_hours: Option<f64>,
    pub(super) dec_degrees: Option<f64>,
}

pub(super) fn build_trigger_flip_context(
    trigger_context: &RunRig,
    target: TriggerFlipTarget,
    cancellation_token: Option<Arc<AtomicBool>>,
    trigger_state: Option<Arc<RwLock<TriggerState>>>,
    autofocus_config: Option<crate::AutofocusConfig>,
    current_filter: Option<String>,
) -> Option<crate::meridian_flip_executor::FlipContext> {
    Some(crate::meridian_flip_executor::FlipContext {
        target_name: target.name,
        target_ra_hours: target.ra_hours?,
        target_dec_degrees: target.dec_degrees?,
        mount_id: trigger_context.mount_id.clone()?,
        camera_id: trigger_context.camera_id.clone(),
        focuser_id: trigger_context.focuser_id.clone(),
        cover_calibrator_id: trigger_context.cover_calibrator_id.clone(),
        cancellation_token,
        trigger_state,
        autofocus_config: autofocus_config.map(|config| {
            crate::meridian_flip_executor::PostFlipAutofocusConfig {
                config,
                current_filter,
                filterwheel_id: trigger_context.filterwheel_id.clone(),
                filter_focus_offsets: trigger_context.filter_focus_offsets.clone(),
            }
        }),
        // Trigger-driven flips command the hardware; the dry-run path is the
        // only caller that sets this true.
        simulate: false,
    })
}

/// Cancel node execution and wait until the active node has finished its
/// cancellation cleanup. Exposure instructions use that cleanup window to
/// abort the camera integration, so callers must not move or close hardware
/// until this function returns.
pub(super) async fn cancel_and_wait_for_execution(
    is_cancelled: &Arc<AtomicBool>,
    execution_quiesced: &mut watch::Receiver<bool>,
) {
    is_cancelled.store(true, Ordering::Release);
    if execution_quiesced
        .wait_for(|quiesced| *quiesced)
        .await
        .is_err()
    {
        tracing::warn!(
            "Execution quiescence channel closed while preparing ParkAndAbort; \
             continuing with safe-state shutdown"
        );
    }
}

/// How long the executor will wait for an in-flight trigger recovery action to
/// finish after the node tree has already completed.
///
/// A meridian flip retry ladder is the worst case that has to fit inside this:
/// the shipped default is 3 retries at 30 s / 60 s / 120 s plus four ~1-minute
/// flip attempts, so ~10 minutes of real work. 15 minutes leaves headroom for a
/// slow mount without letting a wedged driver hang the run forever — on expiry
/// we give up loudly rather than waiting silently.
pub(super) const TRIGGER_ACTION_QUIESCE_MAX_SECS: u64 = 15 * 60;

/// How long an in-flight trigger action is given to restore the rig after
/// its end-of-run budget ran out and it was cancelled.
pub(super) const TRIGGER_CLEANUP_BUDGET_SECS: u64 = 300;

/// Cancel cooperatively so in-flight recovery can restore borrowed equipment.
/// A wedged driver still has a finite cleanup budget.
pub(super) async fn cancel_trigger_monitor_with_cleanup<F: std::future::Future>(
    cancelled: &Arc<AtomicBool>,
    monitor: F,
) -> bool {
    cancelled.store(true, Ordering::Release);
    tokio::time::timeout(
        std::time::Duration::from_secs(TRIGGER_CLEANUP_BUDGET_SECS),
        monitor,
    )
    .await
    .is_ok()
}

/// RAII latch marking that a trigger recovery action is executing.
///
/// The trigger monitor is an inline `async` block inside the terminal
/// `tokio::select!`, so when the node-tree future resolves first the monitor is
/// DROPPED wherever it happens to be awaiting. That silently cancelled an
/// in-progress meridian flip: observed live as
/// `"[MERIDIAN] Retry 1/4 scheduled in 30 seconds..."` at 20:47:12 followed by
/// the run reporting `completed` at 20:47:30 and no further meridian log lines
/// ever — the recovery was abandoned mid-ladder with the mount left wherever
/// the failed flip had put it.
///
/// The flag lets the terminal select! keep polling the monitor until the action
/// finishes. It is a guard rather than a plain store/clear pair because the
/// dispatch has many `return terminate_with(...)` early exits that would
/// otherwise leak the flag set forever and stall every subsequent run.
pub(super) struct TriggerActionInFlightGuard<'a> {
    pub(super) flag: &'a Arc<AtomicBool>,
}

impl<'a> TriggerActionInFlightGuard<'a> {
    pub(super) fn new(flag: &'a Arc<AtomicBool>) -> Self {
        flag.store(true, Ordering::Release);
        Self { flag }
    }
}

impl Drop for TriggerActionInFlightGuard<'_> {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::Release);
    }
}

pub(super) fn skip_to_node_accepted_event(node_id: NodeId) -> ExecutorEvent {
    ExecutorEvent::NodeProgress {
        node_id: node_id.clone(),
        instruction: "SkipToNode".to_string(),
        progress_percent: 100.0,
        detail: format!(
            "SkipToNode request accepted: jumping to node '{}'. \
             Current instruction (if any) will finish first.",
            node_id
        ),
        structured_detail: None,
    }
}

/// Which device is missing when a trigger-fired autofocus cannot run at all,
/// or `None` when the rig has both the camera and the focuser it needs.
///
/// The autofocus arm branches on exactly this, and the branch it takes decides
/// whether the arm reaches its release. Naming the decision here keeps the
/// enumeration of "every exit" honest instead of buried in a match inside a
/// closure that no test can reach.
pub(super) fn autofocus_trigger_skip_reason(
    camera_id: Option<&String>,
    focuser_id: Option<&String>,
) -> Option<&'static str> {
    match (camera_id, focuser_id) {
        (Some(_), Some(_)) => None,
        (None, None) => Some("no camera and no focuser are"),
        (None, Some(_)) => Some("no camera is"),
        (Some(_), None) => Some("no focuser is"),
    }
}

/// How the frames a failed autofocus leaves behind measure.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum AutofocusOutcome {
    /// Soft, but inside tolerance — keep imaging.
    KeepImaging { current_hfr: f64, limit: f64 },
    /// Measurably worse than the tolerance allows.
    TooSoft { current_hfr: f64, limit: f64 },
    /// No usable measurement to judge by.
    Unmeasurable,
}

impl AutofocusOutcome {
    pub(super) fn describe(self) -> String {
        match self {
            Self::KeepImaging { current_hfr, limit } => {
                format!("HFR {current_hfr:.2} is within the {limit:.2} limit")
            }
            Self::TooSoft { current_hfr, limit } => {
                format!("HFR {current_hfr:.2} is past the {limit:.2} limit")
            }
            Self::Unmeasurable => "there is no HFR measurement to judge focus by".to_string(),
        }
    }
}

/// Where the focuser is right now, or `None` when the rig has no focuser or the
/// driver will not answer. Used either side of a trigger-fired sweep so the
/// continuation record can name the focus the run kept.
pub(super) async fn read_focuser_position(
    device_ops: &SharedDeviceOps,
    focuser_id: Option<&String>,
) -> Option<i32> {
    device_ops.focuser_get_position(focuser_id?).await.ok()
}

/// How the frames measure after autofocus failed, for the operator's notice.
/// The run carries on whatever this says; it decides only what the operator
/// is told about the frames.
///
/// `reference` is the run's good HFR (the baseline the degradation trigger
/// watches), `current` is what the frames are measuring now, and `ratio` is
/// how many times the reference is still acceptable.
///
/// Without a reference or a current measurement the answer is
/// [`AutofocusOutcome::Unmeasurable`] — deliberately NOT "within tolerance".
/// Telling the operator the frames are fine on the strength of no evidence is
/// how a night fills a disk with donuts nobody was warned about.
pub(super) fn autofocus_failure_verdict(
    reference: Option<f64>,
    current: Option<f64>,
    ratio: f64,
) -> AutofocusOutcome {
    if !ratio.is_finite() || ratio <= 0.0 {
        return AutofocusOutcome::Unmeasurable;
    }
    let (Some(reference), Some(current)) = (reference, current) else {
        return AutofocusOutcome::Unmeasurable;
    };
    if !reference.is_finite() || !current.is_finite() || reference <= 0.0 || current <= 0.0 {
        return AutofocusOutcome::Unmeasurable;
    }
    let limit = reference * ratio;
    if current <= limit {
        AutofocusOutcome::KeepImaging {
            current_hfr: current,
            limit,
        }
    } else {
        AutofocusOutcome::TooSoft {
            current_hfr: current,
            limit,
        }
    }
}

/// Every exit path from the trigger-monitor closure that ends the sequence
/// MUST set `is_cancelled` before returning the fired-triggers vector; this
/// helper enforces that in one place so a future `match` arm cannot regress
/// by forgetting the store.
///
/// `reason` is logged at info level so post-mortem traces can reconstruct
/// which terminating action ran (e.g. `"ParkAndAbort"`,
/// `"FlipFailureAction::AbortAndPark"`).
pub(super) fn terminate_with(
    is_cancelled: &Arc<AtomicBool>,
    triggers: Vec<(String, RecoveryAction)>,
    reason: &str,
) -> Vec<(String, RecoveryAction)> {
    is_cancelled.store(true, Ordering::Relaxed);
    tracing::info!(
        "[TRIGGER_MONITOR] terminating sequence ({}); fired {} trigger{}",
        reason,
        triggers.len(),
        if triggers.len() == 1 { "" } else { "s" }
    );
    triggers
}

/// Replay Debug — emit a `SystemEvent` decision from the executor
/// task's lifecycle hooks (sequence started / completed / failed /
/// cancelled). Free-standing helper so the closures capturing the
/// channel handles can call it without going through `SequenceExecutor`.
///
/// `phase` is the lifecycle phase tag (`"started"`, `"completed"`,
/// `"failed"`, `"cancelled"`). The summary is auto-derived: callers
/// don't need to handcraft strings.
pub(super) fn emit_lifecycle_decision(
    tx: &crate::decision::DecisionSender,
    active_run_id: &Arc<StdRwLock<Option<i64>>>,
    enabled: &Arc<AtomicBool>,
    phase: &str,
    extra: serde_json::Value,
) {
    if !enabled.load(Ordering::Relaxed) {
        return;
    }
    let summary = match phase {
        "started" => "Sequence started".to_string(),
        "completed" => "Sequence completed".to_string(),
        "failed" => "Sequence failed".to_string(),
        "cancelled" => "Sequence cancelled".to_string(),
        other => format!("Sequence lifecycle: {}", other),
    };
    let mut details = match extra {
        serde_json::Value::Object(m) => serde_json::Value::Object(m),
        // Why: wrap non-object payloads under a `data` key so the
        // persisted JSON column always parses to a map — keeps the
        // Dart deserialisation path uniform.
        other => serde_json::json!({ "data": other, "phase": phase }),
    };
    if let serde_json::Value::Object(ref mut m) = details {
        m.insert(
            "phase".to_string(),
            serde_json::Value::String(phase.to_string()),
        );
    }
    let event = crate::decision::DecisionEvent {
        timestamp: chrono::Utc::now(),
        category: crate::decision::DecisionCategory::SystemEvent,
        summary,
        details,
        node_id: None,
        sequence_run_id: *active_run_id.read(),
    };
    let _ = tx.send(event);
}

pub(super) fn executor_state_for_result(result: NodeStatus) -> ExecutorState {
    match result {
        NodeStatus::Success | NodeStatus::Skipped => ExecutorState::Completed,
        NodeStatus::Cancelled => ExecutorState::Cancelled,
        _ => ExecutorState::Failed,
    }
}
