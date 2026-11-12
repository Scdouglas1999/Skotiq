//! The executor's public data types: parts of the settings it is driven by
//! ([`ObserverProfile`], [`ParkPolicy`], [`DefectMapApplyState`]) and the
//! command / state / progress / event vocabulary it speaks
//! ([`ExecutorCommand`], [`ExecutorState`], [`SequenceProgress`],
//! [`ExecutorEvent`]).

use super::*;

/// pre-loaded per-frame defect-map application state.
///
/// The bridge loads the `.ndm` file into memory once when the user toggles
/// "Apply defect map" on (or sets the auto-apply default + a matching map
/// exists). It then hands this struct to `SequenceExecutor::update_defect_map`
/// so each frame's correction is a `correct_u16_slice` call against the
/// pre-loaded `Arc<DefectMap>` — no per-frame disk I/O, no per-frame
/// allocation.
///
/// Held behind `Arc<RwLock<Option<DefectMapApplyState>>>` inside the
/// ExecutionContext. `None` means "do not apply". Mutating the inner
/// Option (toggle on / toggle off) does NOT require restarting the
/// sequence.
#[derive(Clone)]
pub struct DefectMapApplyState {
    /// Camera identifier this map applies to (`native:zwo:ASI2600MC`,
    /// `ascom:ZWO.ASICamera2`, etc.). The capture path verifies that the
    /// connected camera id matches before applying — a mismatch logs a
    /// warning and skips the frame's correction (rather than mis-applying
    /// a map built for a different sensor).
    pub camera_id: String,
    /// Shared pointer to the loaded defect map. Arc-wrapped so the
    /// ExecutionContext clone shares the bitmap allocation across all
    /// parallel branches and per-frame application is lock-free.
    pub map: Arc<skotiq_imaging::defect_map::DefectMap>,
    /// Replacement method — median (default), mean, or Gaussian-weighted.
    pub method: skotiq_imaging::defect_map::CorrectionMethod,
    /// Kernel diameter (3, 5, or 7).
    pub kernel: skotiq_imaging::defect_map::KernelSize,
    /// When true, the original uncorrected pixels are written to a
    /// sibling `Raw/` directory under the save folder before the
    /// in-place correction runs. Default false (the corrected frame
    /// replaces the raw one).
    pub save_original: bool,
}

impl std::fmt::Debug for DefectMapApplyState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DefectMapApplyState")
            .field("camera_id", &self.camera_id)
            .field("defective_pixels", &self.map.defective_count())
            .field("dimensions", &(self.map.width, self.map.height))
            .field("method", &self.method)
            .field("kernel_diameter", &self.kernel.diameter())
            .field("save_original", &self.save_original)
            .finish()
    }
}

/// Observer / equipment-identification payload pushed from Dart at
/// sequencer start. Drives the FITS `OBSERVER`, `SITEELEV`, `TELESCOP`,
/// `FOCALLEN`, `APTDIA`, `INSTRUME` keywords. All fields are `Option`
/// so a headless / no-profile run emits an absent keyword rather than a
/// sentinel.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ObserverProfile {
    pub observer_name: Option<String>,
    pub site_elevation_m: Option<f64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub telescope_name: Option<String>,
    pub telescope_focal_length_mm: Option<f64>,
    pub telescope_aperture_mm: Option<f64>,
}

/// Whether the standard Weather Unsafe and Dawn Approaching triggers may park
/// the mount and close the cover and dome.
///
/// Both default to parking, which is what the shipped settings say. The app
/// pushes the operator's own values at launch and whenever they change
/// ([`SequenceExecutor::set_park_policy`]). With parking off the trigger still
/// protects the data: unsafe weather holds the run in the weather recovery
/// ladder, and dawn ends the run. Neither moves or closes anything.
///
/// Only the standard triggers read this. A Recovery node in the sequence that
/// the operator configured with Park and Abort keeps its own choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ParkPolicy {
    pub park_on_unsafe_weather: bool,
    pub park_before_dawn: bool,
}

impl Default for ParkPolicy {
    fn default() -> Self {
        Self {
            park_on_unsafe_weather: true,
            park_before_dawn: true,
        }
    }
}

/// Run control sent to the running executor task. These are ordered with
/// one another through the channel; settings do not travel this way (see
/// [`RunConfigStore`]).
#[derive(Debug, Clone)]
pub enum ExecutorCommand {
    Pause,
    Resume,
    Stop,
    Skip,
    SkipToNode(NodeId),
    /// The operator pressed "Try Now" on the recovery banner: cancel the
    /// wait and attempt the recovery at once. Nothing happens outside a
    /// recovery.
    RecoveryTryNow,
    /// The operator pressed "Abort" on the recovery banner: leave the
    /// recovery loop and fail the run. Nothing happens outside a recovery.
    RecoveryAbort,
    /// The app finished running a plugin node and returns its verdict.
    /// `node_id` must be the one from the matching
    /// `ExecutorEvent::PluginNodeRequested`; a reply nobody is waiting for
    /// is logged and dropped.
    PluginNodeFinished {
        node_id: NodeId,
        success: bool,
        /// Shown in logs and on the node's final progress event.
        message: Option<String>,
        /// Plugin-authored JSON for the node's final progress event; invalid
        /// JSON is dropped with a warning.
        structured_detail_json: Option<String>,
    },
}

/// State of the sequence executor
///
/// `Recovering` was added as a first-class state so user-visible UI
/// (Run Dashboard LED, banner, audible alert, push notification) can react
/// to an in-flight recovery loop instead of seeing a vanilla `Running` while
/// the sequence is actually waiting for a guide-star reacquisition. The
/// recovery state machine itself lives in `crate::recovery` and is driven
/// by the trigger-monitor when a recoverable failure fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExecutorState {
    Idle,
    Running,
    Paused,
    Stopping,
    Cancelled,
    Completed,
    Failed,
    /// the executor is currently driving a recovery loop after a
    /// recoverable failure (guide-star lost, slew failed, plate-solve
    /// failed, weather unsafe, etc.). Retries fire on a configured cadence;
    /// the user can force `RecoveryTryNow` or `RecoveryAbort` via
    /// commands.
    Recovering,
}

/// Progress information for the sequence
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SequenceProgress {
    pub state: ExecutorState,
    pub current_node_id: Option<NodeId>,
    pub current_node_name: Option<String>,
    pub current_node_status: Option<NodeStatus>,
    pub total_exposures: u32,
    pub completed_exposures: u32,
    pub total_integration_secs: f64,
    pub completed_integration_secs: f64,
    pub elapsed_secs: f64,
    pub estimated_remaining_secs: Option<f64>,
    pub current_target: Option<String>,
    pub current_filter: Option<String>,
    pub message: Option<String>,
    pub node_statuses: HashMap<NodeId, NodeStatus>,
    /// per-target / per-filter completed integration in
    /// seconds. Outer key is the TargetHeader node id; inner key is the
    /// filter name (`""` for no-filter cameras). Updated when the
    /// exposure instruction emits an IntegrationBudget progress event so
    /// the dashboard can render budget bars without re-reading the registry.
    #[serde(default)]
    pub integration_by_target_filter: HashMap<NodeId, HashMap<String, f64>>,
    /// set of TargetHeader node ids whose integration
    /// budget has fired. Surfaced so the dashboard can flip the target
    /// tile to "complete" even while the executor is finishing the
    /// final burst.
    #[serde(default)]
    pub targets_with_budget_met: std::collections::HashSet<NodeId>,
}

impl Default for SequenceProgress {
    fn default() -> Self {
        Self {
            state: ExecutorState::Idle,
            current_node_id: None,
            current_node_name: None,
            current_node_status: None,
            total_exposures: 0,
            completed_exposures: 0,
            total_integration_secs: 0.0,
            completed_integration_secs: 0.0,
            elapsed_secs: 0.0,
            estimated_remaining_secs: None,
            current_target: None,
            current_filter: None,
            message: None,
            node_statuses: HashMap::new(),
            integration_by_target_filter: HashMap::new(),
            targets_with_budget_met: std::collections::HashSet::new(),
        }
    }
}

/// Event emitted by the executor
///
/// `ProgressUpdated` carries a fully-populated
/// `SequenceProgress` (~320 bytes once the budget HashMaps grew),
/// which is far larger than every other variant on this enum. Without
/// boxing, every `ExecutorEvent` value (including the small life-cycle
/// variants) reserves the worst-case 320 bytes on the stack and inside
/// the tokio broadcast channel — clippy rejects this under
/// `clippy::large_enum_variant`. We box the heavy payload so the enum
/// stays cache-friendly; the box dereferences automatically at every
/// match site, so callers don't change.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ExecutorEvent {
    StateChanged(ExecutorState),
    /// boxed to keep the enum size down (see enum doc-comment).
    /// Serde transparently serializes `Box<SequenceProgress>` as
    /// `SequenceProgress`, so the FRB wire format and JSON checkpoint
    /// payloads are byte-identical to the pre-box version.
    ProgressUpdated(Box<SequenceProgress>),
    NodeStarted {
        id: NodeId,
        name: String,
    },
    NodeCompleted {
        id: NodeId,
        status: NodeStatus,
    },
    NodeProgress {
        node_id: NodeId,
        instruction: String,
        progress_percent: f64,
        /// Legacy stringified detail (matches pre-Pack-H wire format so
        /// any subscriber that still consumes `detail` as a string keeps
        /// working). Derived from `structured_detail` via
        /// `ProgressDetail::detail_text()`.
        detail: String,
        /// structured detail payload, boxed to keep the
        /// `ExecutorEvent` variant size small. `None` for legacy
        /// progress emissions that don't carry a structured payload
        /// (instruction nodes pre-dating the progress refactor).
        /// The bridge layer reads this to dispatch to the typed
        /// `SequencerEvent` variants (`FrameAccepted`, `FrameRejected`,
        /// `SchedulerDecision`, `IntegrationBudget`) without parsing
        /// `detail`.
        structured_detail: Option<Box<crate::node::ProgressDetail>>,
    },
    ExposureStarted {
        frame: u32,
        total: u32,
        filter: Option<String>,
        duration_secs: f64,
    },
    ExposureCompleted {
        frame: u32,
        total: u32,
        duration_secs: f64,
    },
    /// A Smart Exposure plan finished early because its bound DepthLock goal
    /// reported an achieved verdict for the bound revision. Carries the
    /// evidence the verdict rested on so the run history can explain the
    /// transition without consulting the goal store.
    DepthGoalCompleted {
        node_id: NodeId,
        filter_name: String,
        completion: crate::depth_goal::DepthGoalCompletion,
    },
    TargetStarted {
        name: String,
        ra: f64,
        dec: f64,
    },
    TargetCompleted {
        name: String,
    },
    TriggerFired {
        trigger_id: String,
        trigger_name: String,
        action: String,
    },
    /// The run dithered the mount and the guider settled. Sent once per
    /// dither, whoever asked for it: a Dither node, a Smart Exposure plan's
    /// cadence, a burst's `dither_every`, or the Dither Interval trigger. The
    /// run's dither count is counted from this event alone. A dither that was
    /// skipped (no guider, imaging unguided, the grid's center cell) or that
    /// failed sends nothing.
    DitherPerformed {
        /// The node the dither ran for, or `None` for a trigger's dither.
        node_id: Option<NodeId>,
    },
    /// The frame watch measured a saved light frame or confirmed an
    /// obstruction; see [`crate::frame_watch::FrameWatchEvent`].
    FrameWatch(Box<crate::frame_watch::FrameWatchEvent>),
    /// A fault that fails its step or is ending the run. The run's own end
    /// is `SequenceFailed`; a problem the run survives is `StepProblem` and a
    /// pause for the operator is `RunHeld`.
    Error {
        message: String,
    },
    /// A non-fatal advisory: something the operator should know about a run
    /// that is otherwise proceeding normally.
    ///
    /// Distinct from [`ExecutorEvent::Error`] because severity is what the
    /// whole downstream chain routes on. There was no `Warning` variant, so
    /// advisories rode `Error` — and every consumer that only knows "an error
    /// happened" acted on them. A solverless machine running three dark frames
    /// produced, from ONE preflight advisory: a red `Critical - Sequencer`
    /// toast, a `Sequence Error` toast, a `Sequence failed / Sequence aborted
    /// at 20:14.` toast (plus the phone push behind it), and a red **Errors**
    /// section in the Session Report of a run that finished `Completed` with
    /// 3/3 frames accepted and 0 rejected.
    ///
    /// The bridge publishes this as a `SequencerEvent::Error` of kind
    /// `Advisory`; Dart lists it with the run's warnings, which the Session
    /// Report already renders under "Warnings".
    Warning {
        message: String,
    },
    /// One step had a problem and the run carries on: a check that could not
    /// be made, a recovery step that did not take, a trigger action that was
    /// skipped. The operator is told as a warning; nothing about the run's
    /// outcome follows from it, and it is never the reason a later failure
    /// reports.
    StepProblem {
        message: String,
    },
    /// The run is paused for the operator, and this is why. The pause itself
    /// is announced by the state turning `Paused`.
    RunHeld {
        message: String,
    },
    /// A meridian flip finished — successfully, degraded (it needed retries),
    /// aborted, or failed outright. This is what carries the flip verdict, a
    /// failed post-flip recenter included, into the run vitals.
    MeridianFlipOutcome {
        /// `"success"`, `"failed"`, or `"aborted"`.
        outcome: String,
        /// Target the flip was performed for, for operator-facing copy.
        target_name: String,
        /// Pier side reported after the flip (`East` / `West` / `Unknown`).
        new_pier_side: String,
        /// Wall-clock seconds for the whole flip, retries included.
        duration_secs: f64,
        /// Attempts made. `1` is a clean flip; higher means the retry ladder
        /// ran and the flip is DEGRADED even if it ultimately succeeded.
        attempts: u32,
        /// One `"<step>: <error>"` per failed attempt, oldest first.
        failed_steps: Vec<String>,
        /// Terminal error. `None` on a clean success.
        error: Option<String>,
        /// Configured failure action that was executed
        /// (`"PauseAndAlert"` / `"AbortAndPark"`). `None` unless
        /// `outcome == "failed"`.
        action_taken: Option<String>,
    },
    /// runtime configuration changed mid-sequence (dither pixels,
    /// observer location, or filter focus offsets). Subscribers should
    /// reload any cached values derived from these fields.
    RuntimeConfigUpdated {
        what: String,
    },
    /// Recovery Mode — the executor just entered the `Recovering`
    /// state. Carries the full [`RecoveryContext`] so subscribers (Run
    /// Dashboard banner, audible alert player, push-notification service)
    /// render the cause, attempt counter, and countdown without reaching
    /// back into the executor on every redraw. Boxed to keep the enum
    /// variant size small per the same reasoning as `ProgressUpdated`.
    RecoveryStarted {
        context: Box<crate::recovery::RecoveryContext>,
    },
    /// Recovery Mode — periodic update of the live recovery
    /// context (attempt counter incremented, phase changed, last_error
    /// updated). Subscribers refresh the dashboard banner from this; the
    /// `RecoveryStarted` / `RecoveryCompleted` / `RecoveryGaveUp` events
    /// bookend the loop while this carries deltas inside the loop.
    RecoveryProgress {
        context: Box<crate::recovery::RecoveryContext>,
    },
    /// Recovery Mode — recovery succeeded. The executor will
    /// transition back to `Running`; subscribers clear the dashboard
    /// banner and log the history entry.
    RecoveryCompleted {
        context: Box<crate::recovery::RecoveryContext>,
    },
    /// Recovery Mode — recovery exhausted attempts / time / was
    /// aborted by the user. The executor will transition to `Failed` (or
    /// run the configured ParkAndAbort policy). Subscribers log the
    /// history entry and emit a critical-severity event.
    RecoveryGaveUp {
        context: Box<crate::recovery::RecoveryContext>,
        /// True when the loop exited because the user pressed Abort.
        /// Distinct from exhaustion so the UI can render different copy
        /// ("Aborted by operator" vs "Exhausted retries").
        aborted_by_user: bool,
    },
    /// One measured point of an autofocus sweep. `detail` is the sweep's own
    /// `autofocus_progress` JSON (V-curve so far, star crops), which the
    /// bridge publishes as the focuser's `AutofocusProgress` property so the
    /// V-curve draws live for a run's autofocus as it does for one started by
    /// hand. Kept out of `NodeProgress`: its star crops would otherwise ride
    /// every progress message and the run's status line.
    AutofocusProgress {
        focuser_id: String,
        detail: String,
    },
    /// An autofocus sweep ended. `result_json` is the sequencer's
    /// `AutofocusResult` when it succeeded, so the focus panel shows the
    /// best position and fit without a manual run's return value.
    AutofocusFinished {
        focuser_id: String,
        status: NodeStatus,
        message: Option<String>,
        result_json: Option<String>,
    },
    SequenceCompleted,
    SequenceFailed {
        error: String,
    },
    /// An instruction returned `Failure` and this is the reason it gave.
    ///
    /// The executor consumes it to fill [`SequenceFailed::error`] and the bridge
    /// surfaces it as a mid-run error, so the operator reads the real cause
    /// rather than a bare "Sequence failed".
    InstructionFailed {
        node_name: String,
        message: String,
    },
    /// the executor has reached a `NodeType::PluginNode`
    /// and is waiting for the Dart side to run the plugin and reply with
    /// `ExecutorCommand::PluginNodeFinished`. Subscribers (specifically
    /// the Dart sequence executor) route this to `PluginNodeExecutor.run`
    /// and send back the result; non-plugin subscribers ignore this
    /// variant.
    ///
    /// `node_id` is the executor-side identifier the reply MUST echo back.
    /// `plugin_id` + `node_type_id` identify the plugin node in the
    /// `PluginNodeRegistry`. `config_json` is the opaque JSON payload the
    /// Rust side never inspects.
    PluginNodeRequested {
        node_id: NodeId,
        plugin_id: String,
        node_type_id: String,
        config_json: String,
        /// Optional human-readable label authored on the node definition.
        /// Falls back to `node_type_id` in the UI when absent.
        display_name: Option<String>,
        /// Effective timeout (seconds) the Rust side will wait. The Dart
        /// side MUST respect this — if the plugin runs longer the Rust
        /// node fails before the Dart-side timer can react.
        timeout_secs: u32,
    },
}
