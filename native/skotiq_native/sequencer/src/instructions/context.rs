//! The context an instruction runs against and the result it returns.

use super::*;

/// Why an instruction fell short, where that changes what the run does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Setback {
    /// A device the instruction needs is not connected. The run reconnects
    /// it and runs the instruction again.
    Disconnected,
    /// The mount is parked and did not unpark for the slew.
    MountParked,
    /// The slew finished, but outside the tolerance around the target.
    OffTarget,
    /// The slew finished, but the mount's position could not be read back.
    PositionUnverified,
    /// Centering ran out of attempts without solving or converging.
    CenterNotConverged,
    /// The Flat Wizard never reached the target level.
    FlatsNotConverged,
    /// The autofocus sweep did not find focus and put the focuser back.
    /// `focuser_before` is where the focuser was when the sweep started.
    FocusNotFound { focuser_before: Option<i32> },
    /// The autofocus sweep stopped the guider and could not start it again.
    GuidingNotRestored,
    /// The guider found no guide star.
    NoGuideStar,
    /// The meridian flip failed.
    FlipFailed,
    /// The Sun is above the run's limit for light frames.
    SunUp,
    /// The target has no coordinates.
    TargetUnset,
}

/// Result of an instruction execution
#[derive(Debug)]
pub struct InstructionResult {
    pub status: NodeStatus,
    pub message: Option<String>,
    pub data: Option<serde_json::Value>,
    /// HFR values from exposures (for trigger monitoring)
    pub hfr_values: Vec<f64>,
    /// Set by the instruction when it knows why it fell short; see
    /// [`Self::setback`].
    pub setback: Option<Setback>,
}

impl InstructionResult {
    pub fn success() -> Self {
        Self {
            status: NodeStatus::Success,
            message: None,
            data: None,
            hfr_values: Vec::new(),
            setback: None,
        }
    }

    pub fn success_with_message(message: impl Into<String>) -> Self {
        Self {
            message: Some(message.into()),
            ..Self::success()
        }
    }

    pub fn failure(message: impl Into<String>) -> Self {
        Self {
            status: NodeStatus::Failure,
            message: Some(message.into()),
            ..Self::success()
        }
    }

    pub fn failure_because(message: impl Into<String>, setback: Setback) -> Self {
        Self {
            setback: Some(setback),
            ..Self::failure(message)
        }
    }

    pub fn cancelled(message: impl Into<String>) -> Self {
        Self {
            status: NodeStatus::Cancelled,
            message: Some(message.into()),
            ..Self::success()
        }
    }

    /// Why this result fell short. A failure whose text is a driver's "not
    /// connected" is a disconnect whatever the instruction was doing: the
    /// device layer reports that in words, and a device that dropped is
    /// recovered before anything else is judged.
    pub fn setback(&self) -> Option<Setback> {
        if self.status != NodeStatus::Failure {
            return None;
        }
        if self
            .message
            .as_deref()
            .is_some_and(is_device_disconnected_message)
        {
            return Some(Setback::Disconnected);
        }
        self.setback
    }

    /// The node's status for this result under the run's policy, telling the
    /// operator what happened. Quality problems never stop the run (owner
    /// decision 2026-10-06): an off-target slew and a centering that did not
    /// converge carry on unless the operator chose to stop on quality
    /// problems; flats that did not converge and a missed focus always carry
    /// on. Each reports Skipped, which its container steps past; Failure
    /// would end the target and, through it, the night.
    pub async fn settle(self, node_name: &str, ctx: &InstructionContext) -> NodeStatus {
        match self.setback() {
            Some(Setback::OffTarget) if !ctx.stops_on_quality_problems().await => {
                let problem = format!(
                    "{} Skotiq slewed twice and goes on from here.",
                    self.message
                        .as_deref()
                        .unwrap_or("The slew landed off target.")
                );
                ctx.notify_quality_problem_continuing("Slew", &problem);
                NodeStatus::Skipped
            }
            Some(Setback::CenterNotConverged) if !ctx.stops_on_quality_problems().await => {
                let target = ctx.target_name.as_deref().unwrap_or("the target");
                let problem = format!(
                    "{} on {target}. The mount stays where the last correction put it.",
                    self.message
                        .as_deref()
                        .unwrap_or("Centering did not converge")
                );
                ctx.notify_quality_problem_continuing("Center", &problem);
                NodeStatus::Skipped
            }
            Some(Setback::FlatsNotConverged) => {
                let reason = self.message.as_deref().unwrap_or("flats did not converge");
                let message = format!("Flats skipped, the run continues: {reason}");
                tracing::warn!("{}", message);
                if let Some(event_tx) = &ctx.run.event_tx {
                    let _ = event_tx.send(crate::executor::ExecutorEvent::Warning { message });
                }
                NodeStatus::Skipped
            }
            Some(Setback::FocusNotFound { focuser_before }) => {
                notify_autofocus_failed_continuing(ctx, node_name, &self, focuser_before).await;
                NodeStatus::Skipped
            }
            _ => self.log_and_get_status_with_context(node_name, ctx),
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
    fn log_and_get_status_with_context(
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
                (self.message.as_deref(), ctx.run.event_tx.as_ref())
            {
                let _ = event_tx.send(crate::executor::ExecutorEvent::InstructionFailed {
                    node_name: node_name.to_string(),
                    message: message.to_string(),
                });
            }
        }
        self.log_and_get_status_with_recovery(
            node_name,
            ctx.run.recovery_request_tx.as_ref(),
            Some(&ctx.run.device_disconnect_recovery_pending),
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
                    if self.setback() == Some(Setback::Disconnected) {
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

/// The devices a run drives by role, where its frames go, the observing site,
/// and the focus offset of each filter (steps, positive is outward).
#[derive(Debug, Clone, Default)]
pub struct RunRig {
    pub camera_id: Option<String>,
    pub mount_id: Option<String>,
    pub focuser_id: Option<String>,
    pub filterwheel_id: Option<String>,
    pub rotator_id: Option<String>,
    pub dome_id: Option<String>,
    pub cover_calibrator_id: Option<String>,
    pub save_path: Option<PathBuf>,
    /// Degrees.
    pub latitude: Option<f64>,
    /// Degrees.
    pub longitude: Option<f64>,
    pub filter_focus_offsets: std::collections::HashMap<String, i32>,
}

impl RunRig {
    pub fn connected_device_ids(&self) -> Vec<String> {
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

/// The dome a run drives: the one assigned to it, else the one the device
/// layer has connected. Nothing in the app assigns a dome to the run, so on a
/// real rig it is always the connected one.
pub(crate) async fn run_dome_id(
    assigned: Option<&str>,
    device_ops: &SharedDeviceOps,
) -> Option<String> {
    match assigned {
        Some(id) => Some(id.to_string()),
        None => device_ops.active_dome_id().await,
    }
}

/// What a run writes into the header of every frame it saves: `SK-SESID`,
/// `OBSERVER`, `SITEELEV`, `INSTRUME` ("<make> <model>"), `TELESCOP`,
/// `FOCALLEN` and `APTDIA`. Empty outside a run.
#[derive(Debug, Clone, Default)]
pub struct FrameIdentity {
    /// One id per run start, linking its frames to one imaging session.
    pub session_id: String,
    pub observer_name: Option<String>,
    pub site_elevation_m: Option<f64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub telescope_name: Option<String>,
    pub telescope_focal_length_mm: Option<f64>,
    pub telescope_aperture_mm: Option<f64>,
}

/// How a run grades its frames and what grading has learned so far. Every
/// exposure of the run shares one set, so baselines and totals are the run's.
#[derive(Clone)]
pub struct GradingState {
    /// The thresholds a Take Exposures node without its own `quality_check`
    /// grades against. `None` grades nothing.
    pub default_quality_check: Option<crate::quality::ImageQualityCheck>,
    /// Where rejected frames go, relative to the save folder or absolute.
    /// `None` is a `Reject/` folder beside the frames.
    pub reject_folder_path: Option<String>,
    /// Median HFR of the first accepted frames; `None` until established.
    pub hfr_baseline: Arc<tokio::sync::RwLock<Option<f64>>>,
    /// HFR samples collected toward the baseline.
    pub hfr_baseline_samples: Arc<tokio::sync::RwLock<Vec<f64>>>,
    /// Star-count (and HFR) baselines, one per target and filter.
    pub star_count_baselines: crate::quality::StarCountBaselines,
    /// Rejected frames in a row; reset by every accepted frame.
    pub consecutive_rejects: Arc<std::sync::atomic::AtomicU32>,
    pub frames_accepted: Arc<std::sync::atomic::AtomicU32>,
    pub frames_rejected: Arc<std::sync::atomic::AtomicU32>,
    /// The last [`crate::quality::FORENSIC_HISTORY_LEN`] frames with the
    /// conditions they were taken in, for classifying a rejection.
    pub forensics_history:
        Arc<tokio::sync::RwLock<std::collections::VecDeque<crate::quality::RecentFrameSample>>>,
}

impl Default for GradingState {
    fn default() -> Self {
        Self {
            default_quality_check: None,
            reject_folder_path: None,
            hfr_baseline: Arc::default(),
            hfr_baseline_samples: Arc::default(),
            star_count_baselines: Default::default(),
            consecutive_rejects: Arc::default(),
            frames_accepted: Arc::default(),
            frames_rejected: Arc::default(),
            forensics_history: Arc::new(tokio::sync::RwLock::new(
                std::collections::VecDeque::with_capacity(crate::quality::FORENSIC_HISTORY_LEN),
            )),
        }
    }
}

/// Readings of the night taken while a run images, recorded with each frame
/// so a rejection can be classified against them.
#[derive(Clone, Default)]
pub struct LiveConditions {
    /// mag/arcsec² (bigger is darker), pushed by the app's sky-brightness
    /// tracker; also what adaptive exposure adapts to.
    pub sky_brightness_mag: Arc<tokio::sync::RwLock<Option<f64>>>,
    pub cloud_motion: Arc<tokio::sync::RwLock<crate::node::context::CloudMotionSnapshot>>,
    /// km/h.
    pub wind_kph: Arc<tokio::sync::RwLock<Option<f64>>>,
    pub sensor_temp_c: Arc<tokio::sync::RwLock<Option<f64>>>,
}

/// What every instruction of one run shares: the rig and its device layer,
/// the run's trigger state and channels, the identity its frames carry, and
/// its grading state. Cloning shares the run's state, it does not copy it.
#[derive(Clone)]
pub struct RunShared {
    pub device_ops: SharedDeviceOps,
    pub rig: RunRig,
    pub trigger_state: Option<Arc<tokio::sync::RwLock<crate::triggers::TriggerState>>>,
    /// The run's event feed (UI, logging). Sends ignore "no subscriber".
    pub event_tx: Option<tokio::sync::broadcast::Sender<crate::executor::ExecutorEvent>>,
    /// Where an instruction asks the run to recover from a failure.
    pub recovery_request_tx: Option<mpsc::Sender<crate::recovery::RecoveryCause>>,
    /// Set when a failure was promoted to a device-disconnect recovery; the
    /// node runtime then waits for the recovery and runs the instruction
    /// again instead of failing the run.
    pub device_disconnect_recovery_pending: Arc<AtomicBool>,
    /// The run's decision log. `None` records nothing.
    pub decision_tx: Option<crate::decision::DecisionSender>,
    /// `sequence_runs.id` of the run, stamped on every decision.
    pub active_sequence_run_id: Arc<parking_lot::RwLock<Option<i64>>>,
    pub identity: FrameIdentity,
    pub grading: GradingState,
    pub conditions: LiveConditions,
    /// The last plate solve of the current target, stamped into the headers
    /// of the frames after it.
    pub last_plate_solve: Arc<tokio::sync::RwLock<Option<crate::device_ops::PlateSolveResult>>>,
    /// The defect map each saved frame is corrected with; `None` corrects
    /// nothing. Read per frame, so a toggle mid-burst takes effect.
    pub defect_map_apply: Arc<tokio::sync::RwLock<Option<crate::executor::DefectMapApplyState>>>,
    /// Present while a secondary camera piggybacks: every dither waits for
    /// it to finish its exposure (see [`crate::dual_rig::DitherBarrier`]).
    pub dither_barrier: Option<Arc<crate::dual_rig::DitherBarrier>>,
    /// How often a failed camera exposure or filter-wheel move is retried.
    pub device_retry: super::DeviceRetryHandle,
    /// What a frame from a camera that delivers its own file is saved as.
    pub camera_file_saving: crate::CameraFileSaving,
    /// The run's operator settings. The site, the filter offsets, the frame
    /// identity, the grading defaults and the camera-file choice above are
    /// taken from it as each step starts ([`Self::take_settings`]); `None`
    /// for work outside a run, whose values are set where its context is
    /// built.
    pub settings: Option<crate::executor::RunConfigStore>,
}

impl RunShared {
    /// Take the operator's settings as they stand now, in one read. Done as
    /// each step of a run starts (a node of the plan, a trigger's action, a
    /// recovery's recenter), so a change made during the run reaches its next
    /// step and a step in progress keeps the values it started with.
    pub fn take_settings(&mut self) {
        let Some(store) = &self.settings else {
            return;
        };
        let config = store.read();
        self.rig.latitude = config.latitude;
        self.rig.longitude = config.longitude;
        self.rig.filter_focus_offsets = config.filter_focus_offsets.clone();
        let profile = &config.observer_profile;
        self.identity.observer_name = profile.observer_name.clone();
        self.identity.site_elevation_m = profile.site_elevation_m;
        self.identity.camera_make = profile.camera_make.clone();
        self.identity.camera_model = profile.camera_model.clone();
        self.identity.telescope_name = profile.telescope_name.clone();
        self.identity.telescope_focal_length_mm = profile.telescope_focal_length_mm;
        self.identity.telescope_aperture_mm = profile.telescope_aperture_mm;
        self.grading.default_quality_check = config.default_quality_check.clone();
        self.grading.reject_folder_path = config.reject_folder_path.clone();
        self.camera_file_saving = config.camera_file_saving;
    }

    /// This run's shared state for a step starting now; see
    /// [`Self::take_settings`].
    pub fn for_step(&self) -> Self {
        let mut shared = self.clone();
        shared.take_settings();
        shared
    }

    /// The shared state of work that runs outside a sequence run (an
    /// Imaging-tab capture, polar alignment, a test): no trigger state, no
    /// channels, one attempt per device call, nothing graded yet.
    pub fn new(device_ops: SharedDeviceOps) -> Self {
        Self {
            device_ops,
            rig: RunRig::default(),
            trigger_state: None,
            event_tx: None,
            recovery_request_tx: None,
            device_disconnect_recovery_pending: Arc::default(),
            decision_tx: None,
            active_sequence_run_id: Arc::default(),
            identity: FrameIdentity::default(),
            grading: GradingState::default(),
            conditions: LiveConditions::default(),
            last_plate_solve: Arc::default(),
            defect_map_apply: Arc::default(),
            dither_barrier: None,
            device_retry: super::DeviceRetryHandle::single_attempt(),
            camera_file_saving: crate::CameraFileSaving::default(),
            settings: None,
        }
    }

    /// Record a decision in the run's log, stamped with the run's id.
    pub fn emit_decision(&self, mut event: crate::decision::DecisionEvent) {
        let Some(tx) = self.decision_tx.as_ref() else {
            return;
        };
        if event.sequence_run_id.is_none() {
            event.sequence_run_id = *self.active_sequence_run_id.read();
        }
        let _ = tx.send(event);
    }
}

/// One instruction's view of the run: the run's shared state plus what this
/// call is about (its node, target, filter and cancellation).
pub struct InstructionContext {
    pub run: RunShared,
    /// The sequence node this instruction runs for. The app files each frame
    /// event under this node (target, exposure length) and drops a frame
    /// with an empty id, so empty is right only for work that is not a
    /// sequence node (wizards, Imaging-tab captures, trigger actions).
    pub node_id: String,
    /// Hours.
    pub target_ra: Option<f64>,
    /// Degrees.
    pub target_dec: Option<f64>,
    /// The rotator angle (degrees) the target is imaged at. `None` means
    /// centering must not move the rotator.
    pub target_rotation: Option<f64>,
    pub target_name: Option<String>,
    /// The target's stable id, the join key of its database row.
    pub target_id: Option<String>,
    pub mosaic_panel: Option<crate::MosaicPanelInfo>,
    /// The light filters the current target's exposures use, first use
    /// first; empty outside a target. A capture that finds the wheel on the
    /// dark slot moves to the first of these.
    pub target_light_filters: Vec<super::PlannedLightFilter>,
    pub current_filter: Option<String>,
    /// 1-based wheel slot (`FILTPOS`).
    pub current_filter_index: Option<i32>,
    pub current_binning: Binning,
    /// Cooler set point, °C.
    pub set_temp_c: Option<f64>,
    /// "RGGB", "BGGR", ...; `None` for a monochrome sensor.
    pub bayer_pattern: Option<String>,
    pub cancellation_token: Arc<AtomicBool>,
}

impl InstructionContext {
    /// An instruction against `run` with no node, target or filter.
    pub fn new(run: RunShared, cancellation_token: Arc<AtomicBool>) -> Self {
        Self {
            run,
            node_id: String::new(),
            target_ra: None,
            target_dec: None,
            target_rotation: None,
            target_name: None,
            target_id: None,
            mosaic_panel: None,
            target_light_filters: Vec::new(),
            current_filter: None,
            current_filter_index: None,
            current_binning: Binning::One,
            set_temp_c: None,
            bayer_pattern: None,
            cancellation_token,
        }
    }

    pub fn check_cancelled(&self) -> Option<InstructionResult> {
        if self.cancellation_token.load(Ordering::Relaxed) {
            Some(InstructionResult::cancelled("Operation cancelled"))
        } else {
            None
        }
    }

    /// The [`ExecutionContext`] a save-path template resolves against, for
    /// callers that hold only an `InstructionContext` (the Flat Wizard):
    /// this run, and the call's target and filter.
    ///
    /// [`ExecutionContext`]: crate::node::context::ExecutionContext
    pub(crate) fn to_template_context(&self) -> crate::node::context::ExecutionContext {
        let mut ctx = crate::node::context::ExecutionContext::new(
            self.node_id.clone(),
            self.run.device_ops.clone(),
        );
        ctx.run = self.run.clone();
        ctx.target_name = self.target_name.clone();
        ctx.target_id = self.target_id.clone();
        ctx.target_ra = self.target_ra;
        ctx.target_dec = self.target_dec;
        ctx.target_rotation = self.target_rotation;
        ctx.current_filter = self.current_filter.clone();
        ctx.current_filter_index = self.current_filter_index;
        ctx.current_binning = self.current_binning;
        ctx.set_temp_c = self.set_temp_c;
        ctx
    }

    /// Get camera ID or error
    pub fn camera_id(&self) -> Result<&str, InstructionResult> {
        self.run.rig.camera_id.as_deref().ok_or_else(|| {
            InstructionResult::failure_because("No camera connected", Setback::Disconnected)
        })
    }

    /// Get mount ID or error
    pub fn mount_id(&self) -> Result<&str, InstructionResult> {
        self.run.rig.mount_id.as_deref().ok_or_else(|| {
            InstructionResult::failure_because("No mount connected", Setback::Disconnected)
        })
    }

    /// Get focuser ID or error
    pub fn focuser_id(&self) -> Result<&str, InstructionResult> {
        self.run.rig.focuser_id.as_deref().ok_or_else(|| {
            InstructionResult::failure_because("No focuser connected", Setback::Disconnected)
        })
    }

    /// Get filter wheel ID or error
    pub fn filterwheel_id(&self) -> Result<&str, InstructionResult> {
        self.run.rig.filterwheel_id.as_deref().ok_or_else(|| {
            InstructionResult::failure_because("No filter wheel connected", Setback::Disconnected)
        })
    }

    /// Get rotator ID or error  
    pub fn rotator_id(&self) -> Result<&str, InstructionResult> {
        self.run.rig.rotator_id.as_deref().ok_or_else(|| {
            InstructionResult::failure_because("No rotator connected", Setback::Disconnected)
        })
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
        run_dome_id(self.run.rig.dome_id.as_deref(), &self.run.device_ops)
            .await
            .ok_or_else(|| {
                InstructionResult::failure_because("No dome connected", Setback::Disconnected)
            })
    }

    /// Get cover calibrator ID or error. Falls back to
    /// [`DeviceOps::active_cover_calibrator_id`] for the same reason as
    /// [`Self::dome_id`].
    pub async fn cover_calibrator_id(&self) -> Result<String, InstructionResult> {
        if let Some(id) = self.run.rig.cover_calibrator_id.as_deref() {
            return Ok(id.to_string());
        }
        match self.run.device_ops.active_cover_calibrator_id().await {
            Some(id) => {
                tracing::debug!(
                    "No cover calibrator in the sequence context; using connected panel '{id}'"
                );
                Ok(id)
            }
            None => Err(InstructionResult::failure_because(
                "No cover calibrator (flat panel) connected",
                Setback::Disconnected,
            )),
        }
    }

    /// See [`crate::triggers::stops_on_quality_problems`].
    pub async fn stops_on_quality_problems(&self) -> bool {
        crate::triggers::stops_on_quality_problems(self.run.trigger_state.as_ref()).await
    }

    /// Whether the run is imaging unguided because the guide-star recovery ran
    /// out. See [`crate::triggers::GuidingState::is_unguided`].
    pub async fn imaging_unguided(&self) -> bool {
        match &self.run.trigger_state {
            Some(state) => state.read().await.guiding.is_unguided(),
            None => false,
        }
    }

    /// The bar a planned restart of guiding settles at in this run (see
    /// [`crate::GuiderSettle::restart_bar`]), or `fallback` outside a run.
    pub async fn restart_settle_or(&self, fallback: crate::GuiderSettle) -> crate::GuiderSettle {
        match &self.run.trigger_state {
            Some(state) => state.read().await.restart_settle(),
            None => fallback,
        }
    }

    /// Why the run itself holds the guider stopped right now, if it does: a
    /// tracking-limit or pre-meridian hold, a mount move in progress, or a
    /// move whose stopped guiding has not been started again yet.
    pub async fn run_holds_guider_stopped(&self) -> Option<&'static str> {
        let state = self.run.trigger_state.as_ref()?.read().await;
        if let Some(hold) = state.run.hold() {
            return Some(match hold {
                crate::triggers::RunHold::TrackingLimit => {
                    "the run is holding at the mount's tracking limit until the flip"
                }
                crate::triggers::RunHold::PreMeridian => {
                    "the run is holding at the meridian until the flip"
                }
                crate::triggers::RunHold::RecoveryTracking => "a recovery has stopped tracking",
            });
        }
        if state.guiding.in_motion() {
            return Some("the mount is moving");
        }
        if state.guiding.resume_pending() {
            return Some(
                "guiding was stopped for a mount move and starts again before the next frame",
            );
        }
        None
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
        self.run.emit_decision(continuation.decision);
        if let Some(event_tx) = &self.run.event_tx {
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
        let Some(trigger_state) = &ctx.run.trigger_state else {
            return Ok(Self { token: None });
        };
        let mut announced = false;
        loop {
            if let Some(result) = ctx.check_cancelled() {
                return Err(result);
            }
            let (token, hold) = {
                let mut state = trigger_state.write().await;
                match state.imaging_train.try_claim(holder, expected_secs) {
                    Some(token) => (Some(token), None),
                    None => (None, state.imaging_train.hold()),
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
        let (Some(token), Some(trigger_state)) = (self.token, &ctx.run.trigger_state) else {
            return;
        };
        trigger_state.write().await.imaging_train.release(token);
    }
}

#[cfg(test)]
mod settings_tests {
    use super::*;

    /// An exposure already running keeps the grading, reject folder, frame
    /// identity and camera-file choice it started with; the next one takes
    /// what the operator saved meanwhile.
    #[tokio::test]
    async fn a_step_in_progress_keeps_the_settings_it_started_with() {
        let executor = crate::executor::SequenceExecutor::new();
        let mut shared = RunShared::new(Arc::new(crate::device_ops::NullDeviceOps));
        shared.settings = Some(executor.run_config_store());
        let exposing = InstructionContext::new(shared.for_step(), Arc::new(AtomicBool::new(false)));

        executor
            .handle()
            .update_run_config(|config| {
                config.reject_folder_path = Some("/rejects".to_string());
                config.observer_profile.observer_name = Some("Grace".to_string());
                config.camera_file_saving = crate::CameraFileSaving::Both;
            })
            .await
            .expect("the settings apply");

        assert_eq!(exposing.run.grading.reject_folder_path, None);
        assert_eq!(exposing.run.identity.observer_name, None);
        assert_eq!(
            exposing.run.camera_file_saving,
            crate::CameraFileSaving::Converted
        );

        let next = shared.for_step();
        assert_eq!(next.grading.reject_folder_path.as_deref(), Some("/rejects"));
        assert_eq!(next.identity.observer_name.as_deref(), Some("Grace"));
        assert_eq!(next.camera_file_saving, crate::CameraFileSaving::Both);
    }

    /// Work outside a run keeps the values its context was built with.
    #[test]
    fn without_run_settings_a_step_keeps_its_own_values() {
        let mut shared = RunShared::new(Arc::new(crate::device_ops::NullDeviceOps));
        shared.rig.latitude = Some(12.0);
        assert_eq!(shared.for_step().rig.latitude, Some(12.0));
    }
}
