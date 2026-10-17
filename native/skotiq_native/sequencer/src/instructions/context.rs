//! `context.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

/// Result of an instruction execution
#[derive(Debug)]
pub struct InstructionResult {
    pub status: NodeStatus,
    pub message: Option<String>,
    pub data: Option<serde_json::Value>,
    /// HFR values from exposures (for trigger monitoring)
    pub hfr_values: Vec<f64>,
}

impl InstructionResult {
    pub fn success() -> Self {
        Self {
            status: NodeStatus::Success,
            message: None,
            data: None,
            hfr_values: Vec::new(),
        }
    }

    pub fn success_with_message(message: impl Into<String>) -> Self {
        Self {
            status: NodeStatus::Success,
            message: Some(message.into()),
            data: None,
            hfr_values: Vec::new(),
        }
    }

    pub fn failure(message: impl Into<String>) -> Self {
        Self {
            status: NodeStatus::Failure,
            message: Some(message.into()),
            data: None,
            hfr_values: Vec::new(),
        }
    }

    /// Create a failure result with a recovery code that the UI can use to offer recovery options
    pub fn failure_with_recovery(
        message: impl Into<String>,
        recovery_code: impl Into<String>,
    ) -> Self {
        Self {
            status: NodeStatus::Failure,
            message: Some(message.into()),
            data: Some(serde_json::json!({"recovery_code": recovery_code.into()})),
            hfr_values: Vec::new(),
        }
    }

    pub fn cancelled(message: impl Into<String>) -> Self {
        Self {
            status: NodeStatus::Cancelled,
            message: Some(message.into()),
            data: None,
            hfr_values: Vec::new(),
        }
    }

    /// Get the status, logging any failure or cancellation message.
    /// This ensures error messages are not silently discarded.
    pub fn log_and_get_status(self, node_name: &str) -> NodeStatus {
        self.log_and_get_status_with_recovery(node_name, None, None)
    }

    /// Get the status, logging failures and promoting disconnected-device
    /// failures to the executor recovery loop when the live context exposes
    /// a recovery request channel.
    pub fn log_and_get_status_with_context(
        self,
        node_name: &str,
        ctx: &InstructionContext,
    ) -> NodeStatus {
        // Publish the reason BEFORE the recovery handler consumes `self`. It is
        // the only copy: the node tree hands the executor a bare `NodeStatus`, so
        // without this the run's terminal event, toast and persisted
        // `errorMessages` all fall back to the hardcoded "Sequence failed".
        //
        // Exactly ONCE per failed node, though, and on the FIRST attempt. The node
        // runtime re-executes an instruction whose failure was promoted to
        // device-disconnect recovery (see
        // `execute_instruction_with_disconnect_retry`), so publishing per
        // execution fills the session report with one identical error line and one
        // Critical toast per try and the error count can never match the number of
        // failed nodes. Reporting on the first attempt rather than the last means
        // no path (recovery driver absent, recovery cancelled, retries exhausted)
        // can swallow the reason.
        if matches!(self.status, NodeStatus::Failure)
            && !crate::node::runtime::is_disconnect_retry_attempt()
        {
            if let (Some(message), Some(event_tx)) =
                (self.message.as_deref(), ctx.event_tx.as_ref())
            {
                let _ = event_tx.send(crate::executor::ExecutorEvent::InstructionFailed {
                    node_name: node_name.to_string(),
                    message: message.to_string(),
                });
            }
        }
        self.log_and_get_status_with_recovery(
            node_name,
            ctx.recovery_request_tx.as_ref(),
            Some(&ctx.device_disconnect_recovery_pending),
        )
    }

    pub(crate) fn log_and_get_status_with_recovery(
        self,
        node_name: &str,
        recovery_request_tx: Option<&mpsc::Sender<crate::recovery::RecoveryCause>>,
        device_disconnect_recovery_pending: Option<&Arc<AtomicBool>>,
    ) -> NodeStatus {
        match self.status {
            NodeStatus::Failure => {
                if let Some(msg) = &self.message {
                    tracing::error!("{} failed: {}", node_name, msg);
                    if is_device_disconnected_message(msg) {
                        // Mark the failure as a promoted device-disconnect BEFORE
                        // returning, so the node-runtime retry wrapper knows to
                        // wait for recovery + retry this instruction rather than
                        // letting the Failure end the sequence. Set the flag even
                        // when the recovery channel is absent so a future runtime
                        // can still observe the cause; the actual recovery only
                        // runs when the channel forwards the request.
                        if let Some(flag) = device_disconnect_recovery_pending {
                            flag.store(true, Ordering::Relaxed);
                        }
                        request_device_disconnected_recovery(node_name, msg, recovery_request_tx);
                    }
                } else {
                    tracing::error!("{} failed (no details)", node_name);
                }
            }
            NodeStatus::Cancelled => {
                if let Some(msg) = &self.message {
                    tracing::warn!("{} cancelled: {}", node_name, msg);
                }
            }
            _ => {}
        }
        self.status
    }
}

/// Context for instruction execution
/// Contains the current imaging session state and cancellation flag
pub struct InstructionContext {
    /// ID of the sequence node this instruction is running for, threaded through
    /// from `ExecutionContext::node_id`.
    ///
    /// `emit_grade_progress` must name the producing node on the frame events it
    /// emits: the app turns each FrameAccepted / FrameRejected into a
    /// `captured_images` row and resolves the frame's target and exposure length
    /// by walking the sequence tree from this id. An empty id makes it drop the
    /// frame outright — no gallery row, no integration total, no per-target
    /// completion. Empty is therefore correct ONLY for node-less callers
    /// (wizards, one-shot bridge captures, trigger-driven recenters).
    pub node_id: String,
    /// Target RA in hours
    pub target_ra: Option<f64>,
    /// Target Dec in degrees
    pub target_dec: Option<f64>,
    /// Target mechanical rotation angle in degrees (rotator position the frame
    /// must be imaged at). `None` when the active target specifies no rotation,
    /// in which case centering must NOT move the rotator. Sourced from the
    /// TargetHeader's `target_rotation` via `ExecutionContext`.
    pub target_rotation: Option<f64>,
    /// Target name
    pub target_name: Option<String>,
    /// Current filter
    pub current_filter: Option<String>,
    /// Current binning
    pub current_binning: Binning,
    /// Cancellation token
    pub cancellation_token: Arc<AtomicBool>,
    /// Connected camera device ID
    pub camera_id: Option<String>,
    /// Connected mount device ID
    pub mount_id: Option<String>,
    /// Connected focuser device ID
    pub focuser_id: Option<String>,
    /// Connected filter wheel device ID
    pub filterwheel_id: Option<String>,
    /// Connected rotator device ID
    pub rotator_id: Option<String>,
    /// Connected dome device ID
    pub dome_id: Option<String>,
    /// Connected cover calibrator (flat panel) device ID
    pub cover_calibrator_id: Option<String>,
    /// Base path for saving images
    pub save_path: Option<PathBuf>,
    /// Observer's latitude (degrees)
    pub latitude: Option<f64>,
    /// Observer's longitude (degrees)
    pub longitude: Option<f64>,
    /// Device operations handler
    pub device_ops: SharedDeviceOps,
    /// Trigger state (for updating during execution)
    pub trigger_state: Option<Arc<tokio::sync::RwLock<crate::triggers::TriggerState>>>,
    /// Filter focus offsets from the equipment profile (filter_name -> offset_steps).
    /// When a filter change occurs, the focuser is moved by the offset relative to
    /// the current position. A positive offset means move outward.
    pub filter_focus_offsets: std::collections::HashMap<String, i32>,
    /// Optional broadcast handle so instruction code can emit ExecutorEvents
    /// directly to subscribers (UI, logging, etc.). Used to surface
    /// instruction-level failures that must be visible beyond the
    /// InstructionResult return value — e.g. FITS-save failures (see
    /// `execute_exposure`). `None` outside the live executor; instructions
    /// must use `if let Some(tx) = ...` and ignore send errors (no subscribers
    /// is a benign case for headless runs).
    pub event_tx: Option<tokio::sync::broadcast::Sender<crate::executor::ExecutorEvent>>,
    /// Recovery request channel for first-class recoverable instruction failures.
    pub recovery_request_tx: Option<mpsc::Sender<crate::recovery::RecoveryCause>>,
    /// Shared flag set when a device-disconnect failure is promoted to a
    /// `DeviceDisconnected` recovery. The node-runtime reads this to wait for
    /// recovery + retry the failed instruction instead of aborting the
    /// sequence. Shares its allocation with `ExecutionContext`. Defaults to a
    /// fresh `false` Arc in standalone instruction contexts (tests / one-shot
    /// bridge calls) where there is no runtime retry wrapper.
    pub device_disconnect_recovery_pending: Arc<AtomicBool>,
    // Image Grading: FITS-header metadata propagated from
    // ExecutionContext so `execute_exposure` can assemble a FrameContext
    // for save_fits.
    pub session_id: String,
    pub target_id: Option<String>,
    pub mosaic_panel: Option<crate::MosaicPanelInfo>,
    pub current_filter_index: Option<i32>,
    pub set_temp_c: Option<f64>,
    pub bayer_pattern: Option<String>,
    pub observer_name: Option<String>,
    pub site_elevation_m: Option<f64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub telescope_name: Option<String>,
    pub telescope_focal_length_mm: Option<f64>,
    pub telescope_aperture_mm: Option<f64>,
    /// Shared handle to last plate-solve result (set by CenterTarget).
    pub last_plate_solve: Arc<tokio::sync::RwLock<Option<crate::device_ops::PlateSolveResult>>>,
    // Image Grading: per-run grading state, shared via Arc with
    // ExecutionContext so progress events carry consistent totals across
    // the entire sequence.
    pub hfr_baseline: Arc<tokio::sync::RwLock<Option<f64>>>,
    pub hfr_baseline_samples: Arc<tokio::sync::RwLock<Vec<f64>>>,
    pub consecutive_rejects: Arc<std::sync::atomic::AtomicU32>,
    pub frames_accepted: Arc<std::sync::atomic::AtomicU32>,
    pub frames_rejected: Arc<std::sync::atomic::AtomicU32>,
    /// Global default image-quality thresholds. Used as the fallback when
    /// `ExposureConfig.quality_check` is None.
    pub default_quality_check: Option<crate::quality::ImageQualityCheck>,
    /// Optional reject-folder override (relative to save_path or absolute).
    /// None => use `<save_path>/Reject/`.
    pub reject_folder_path: Option<String>,
    /// per-frame defect-map application state. Cloned
    /// from `ExecutionContext::defect_map_apply` at instruction-context
    /// construction time. Pre-loading is bridge-side, so a `Some(...)`
    /// value carries the parsed `DefectMap` ready for per-frame
    /// `correct_u16_slice` application.
    pub defect_map_apply: Arc<tokio::sync::RwLock<Option<crate::executor::DefectMapApplyState>>>,
    // Frame-Failure Forensics.
    //
    // `emit_grade_progress` snapshots live env values, looks at the
    // rolling history, classifies the rejection, then pushes the new
    // sample into the history. All five Arcs are shared with
    // ExecutionContext so other instructions can keep mutating them.
    /// Rolling buffer of the last `FORENSIC_HISTORY_LEN` frame samples.
    pub forensics_history:
        Arc<tokio::sync::RwLock<std::collections::VecDeque<crate::quality::RecentFrameSample>>>,
    /// Sky brightness reading (mag/arcsec²) shared with the adaptive
    /// exposure adapter.
    pub current_sky_brightness_mag: Arc<tokio::sync::RwLock<Option<f64>>>,
    /// Cloud motion snapshot pushed by the Dart weather pipeline.
    pub cloud_motion_snapshot: Arc<tokio::sync::RwLock<crate::node::context::CloudMotionSnapshot>>,
    /// Current wind speed (km/h).
    pub current_wind_kph: Arc<tokio::sync::RwLock<Option<f64>>>,
    /// Current sensor temperature (°C).
    pub current_sensor_temp_c: Arc<tokio::sync::RwLock<Option<f64>>>,
    /// Replay Debug — broadcast handle for [`crate::decision::DecisionEvent`]s
    /// (FrameAccepted / FrameRejected emit from `emit_grade_progress`,
    /// AdaptiveSwap emit from the adaptive-exposure path, BudgetMet from
    /// the budget tracker, PluginNodeInvoked from the plugin instruction).
    /// `None` outside the live executor (test contexts / one-shot bridge
    /// calls); emission is a no-op then.
    pub decision_tx: Option<crate::decision::DecisionSender>,
    /// Replay Debug — active sequence_runs.id, populated for every
    /// emitted DecisionEvent so persistence can write the FK without
    /// re-joining on wall-clock windows.
    pub active_sequence_run_id: Arc<parking_lot::RwLock<Option<i64>>>,
    /// Dual-rig — shared dither-coordination barrier (see
    /// [`crate::dual_rig::DitherBarrier`]). `None` for single-rig sequences.
    /// When `Some`, the dither call sites (`execute_dither` + the inline burst
    /// dither in `execute_exposure`) announce + release on this barrier so a
    /// piggybacking secondary camera is never mid-exposure during the mount
    /// pulse.
    pub dither_barrier: Option<Arc<crate::dual_rig::DitherBarrier>>,
    /// How many times a failed camera exposure or filter-wheel move is retried
    /// (see [`super::device_retry`]). The run's live handle on the node path;
    /// a single attempt for contexts with no run behind them.
    pub device_retry: super::DeviceRetryHandle,
}

impl InstructionContext {
    pub fn check_cancelled(&self) -> Option<InstructionResult> {
        if self.cancellation_token.load(Ordering::Relaxed) {
            Some(InstructionResult::cancelled("Operation cancelled"))
        } else {
            None
        }
    }

    /// The [`ExecutionContext`] a save-path template resolves against, rebuilt
    /// from this context.
    ///
    /// `interpolate` reads the run's identity (target, observer, optics,
    /// session) off an `ExecutionContext`, which the node path already has.
    /// Callers that own only an `InstructionContext` — the Flat Wizard — need
    /// the same variables to resolve to the same values, so the fields the
    /// resolver reads are copied across; everything else keeps the
    /// [`ExecutionContext::new`] default because no template variable can see it.
    ///
    /// [`ExecutionContext`]: crate::node::context::ExecutionContext
    pub(crate) fn to_template_context(&self) -> crate::node::context::ExecutionContext {
        let mut ctx = crate::node::context::ExecutionContext::new(
            self.node_id.clone(),
            self.device_ops.clone(),
        );
        ctx.target_name = self.target_name.clone();
        ctx.target_id = self.target_id.clone();
        ctx.target_ra = self.target_ra;
        ctx.target_dec = self.target_dec;
        ctx.target_rotation = self.target_rotation;
        ctx.current_filter = self.current_filter.clone();
        ctx.current_filter_index = self.current_filter_index;
        ctx.current_binning = self.current_binning;
        ctx.save_path = self.save_path.clone();
        ctx.latitude = self.latitude;
        ctx.longitude = self.longitude;
        ctx.session_id = self.session_id.clone();
        ctx.set_temp_c = self.set_temp_c;
        ctx.observer_name = self.observer_name.clone();
        ctx.site_elevation_m = self.site_elevation_m;
        ctx.camera_make = self.camera_make.clone();
        ctx.camera_model = self.camera_model.clone();
        ctx.telescope_name = self.telescope_name.clone();
        ctx.telescope_focal_length_mm = self.telescope_focal_length_mm;
        ctx.telescope_aperture_mm = self.telescope_aperture_mm;
        ctx
    }

    /// Get camera ID or error
    pub fn camera_id(&self) -> Result<&str, InstructionResult> {
        self.camera_id
            .as_deref()
            .ok_or_else(|| InstructionResult::failure("No camera connected"))
    }

    /// Get mount ID or error
    pub fn mount_id(&self) -> Result<&str, InstructionResult> {
        self.mount_id
            .as_deref()
            .ok_or_else(|| InstructionResult::failure("No mount connected"))
    }

    /// Get focuser ID or error
    pub fn focuser_id(&self) -> Result<&str, InstructionResult> {
        self.focuser_id
            .as_deref()
            .ok_or_else(|| InstructionResult::failure("No focuser connected"))
    }

    /// Get filter wheel ID or error
    pub fn filterwheel_id(&self) -> Result<&str, InstructionResult> {
        self.filterwheel_id
            .as_deref()
            .ok_or_else(|| InstructionResult::failure("No filter wheel connected"))
    }

    /// Get rotator ID or error  
    pub fn rotator_id(&self) -> Result<&str, InstructionResult> {
        self.rotator_id
            .as_deref()
            .ok_or_else(|| InstructionResult::failure("No rotator connected"))
    }

    /// Get dome ID or error.
    ///
    /// Unlike the other role accessors this one falls back to
    /// [`DeviceOps::active_dome_id`] when the context carries no assignment:
    /// nothing in the Dart→FFI runtime-config path ever calls
    /// `SequenceExecutor::set_dome`, so `self.dome_id` is `None` on every real
    /// run and the seven dome/cover node types were unconditionally dead. The
    /// device layer knows what is connected; ask it before declaring failure.
    pub async fn dome_id(&self) -> Result<String, InstructionResult> {
        if let Some(id) = self.dome_id.as_deref() {
            return Ok(id.to_string());
        }
        match self.device_ops.active_dome_id().await {
            Some(id) => {
                tracing::debug!("No dome in the sequence context; using connected dome '{id}'");
                Ok(id)
            }
            None => Err(InstructionResult::failure("No dome connected")),
        }
    }

    /// Get cover calibrator ID or error. Falls back to
    /// [`DeviceOps::active_cover_calibrator_id`] for the same reason as
    /// [`Self::dome_id`].
    pub async fn cover_calibrator_id(&self) -> Result<String, InstructionResult> {
        if let Some(id) = self.cover_calibrator_id.as_deref() {
            return Ok(id.to_string());
        }
        match self.device_ops.active_cover_calibrator_id().await {
            Some(id) => {
                tracing::debug!(
                    "No cover calibrator in the sequence context; using connected panel '{id}'"
                );
                Ok(id)
            }
            None => Err(InstructionResult::failure(
                "No cover calibrator (flat panel) connected",
            )),
        }
    }

    /// Replay Debug — emit a structured decision into the
    /// broadcast channel. No-op when `decision_tx` is `None` (one-shot
    /// instruction sites, unit tests). Stamps the active sequence_run_id
    /// before forwarding so the persistence layer has the FK.
    pub fn emit_decision(&self, mut event: crate::decision::DecisionEvent) {
        let Some(tx) = self.decision_tx.as_ref() else {
            return;
        };
        if event.sequence_run_id.is_none() {
            event.sequence_run_id = *self.active_sequence_run_id.read();
        }
        let _ = tx.send(event);
    }

    /// Whether the operator asked for quality problems to stop the run. Off by
    /// default, and off with no run state at all (a one-shot instruction).
    /// See [`crate::triggers::TriggerState::stop_on_quality_problems`].
    pub async fn stops_on_quality_problems(&self) -> bool {
        match &self.trigger_state {
            Some(state) => state.read().await.stop_on_quality_problems,
            None => false,
        }
    }

    /// Whether the run is imaging unguided because the guide-star recovery ran
    /// out. See [`crate::triggers::TriggerState::imaging_unguided`].
    pub async fn imaging_unguided(&self) -> bool {
        match &self.trigger_state {
            Some(state) => state.read().await.imaging_unguided,
            None => false,
        }
    }

    /// Tell the operator about a quality problem the run carries on through:
    /// the decision row the app's "Problem noticed — the run continues"
    /// notification is raised from, and a Warning in the run's feed. A Warning,
    /// not an Error: every sequencer Error is reported as a failed sequence.
    pub fn notify_quality_problem_continuing(&self, source: &str, problem: &str) {
        let continuation = crate::executor::quality_problem_continuation(
            source,
            problem,
            serde_json::json!({ "node_id": self.node_id }),
        );
        tracing::warn!("{}", continuation.operator_message);
        self.emit_decision(continuation.decision);
        if let Some(event_tx) = &self.event_tx {
            let _ = event_tx.send(crate::executor::ExecutorEvent::Warning {
                message: continuation.operator_message,
            });
        }
    }
}

/// Holds the imaging-train claim (main camera + filter wheel) for one
/// instruction-side operation.
///
/// Every operation that drives the camera or the filter wheel — a burst's
/// filter change, each frame, a ChangeFilter node, an autofocus's own filter
/// move — takes this before touching either device, so the sequence's node tree
/// and the trigger monitor's recovery actions cannot interleave on them. The
/// trigger side takes the same claim through `TriggerCameraClaim`.
///
/// Release is explicit rather than `Drop`-based because releasing needs the
/// async lock; every call site is written so the operation has one exit that
/// reaches [`Self::release`]. A guard that is dropped without releasing is not
/// a wedged run — the claim lapses on its own expiry — but it does cost the
/// waiter that long, so the single-exit shape is the contract.
///
/// A context with no `trigger_state` (bridge one-shots, wizards, tests) has no
/// run to arbitrate with, so the guard is unheld and every method is a no-op.
#[must_use = "an imaging-train claim must be released, or waiters wait out its expiry"]
pub(crate) struct ImagingTrainClaimGuard {
    token: Option<u64>,
}

impl ImagingTrainClaimGuard {
    /// Take the imaging train, waiting for whoever holds it.
    ///
    /// The wait is bounded by the current holder's claim expiry, which is
    /// derived from the operation actually in flight rather than from a fixed
    /// number — see `IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`. Returns the
    /// instruction's cancellation result if the run is cancelled while waiting,
    /// so an operator Stop is never made to sit behind a 180 s frame.
    pub(crate) async fn acquire(
        ctx: &InstructionContext,
        holder: &'static str,
        expected_secs: f64,
    ) -> Result<Self, InstructionResult> {
        let Some(trigger_state) = &ctx.trigger_state else {
            return Ok(Self { token: None });
        };
        let mut announced = false;
        loop {
            if let Some(result) = ctx.check_cancelled() {
                return Err(result);
            }
            let (token, hold) = {
                let mut state = trigger_state.write().await;
                match state.try_claim_imaging_train(holder, expected_secs) {
                    Some(token) => (Some(token), None),
                    None => (None, state.imaging_train_hold()),
                }
            };
            if let Some(token) = token {
                if announced {
                    tracing::info!("Imaging train free; {} proceeding", holder);
                }
                return Ok(Self { token: Some(token) });
            }
            if let Some(hold) = hold {
                if !announced {
                    announced = true;
                    tracing::info!(
                        "Holding {} for ~{:.0}s: {} is using the camera and filter wheel \
                         (at most {:.0}s)",
                        holder,
                        hold.expected_remaining_secs,
                        hold.holder,
                        hold.max_remaining_secs
                    );
                }
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }

    /// Hand the imaging train back. Consumes the guard so it cannot be released
    /// twice; the release is identity-checked on the token as well, so a stale
    /// release can never free a claim that has since been taken by someone
    /// else — which would destroy exactly the frame the claim protects.
    pub(crate) async fn release(self, ctx: &InstructionContext) {
        let (Some(token), Some(trigger_state)) = (self.token, &ctx.trigger_state) else {
            return;
        };
        trigger_state.write().await.release_imaging_train(token);
    }
}
