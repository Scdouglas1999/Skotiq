//! Nightshade Sequencer Engine
//!
//! Implements a behavior tree-based sequencer for automated imaging.

pub mod all_sky_polar;
pub mod autofocus;
// live-stacking broadcast service.
pub mod broadcast;
pub mod checkpoint;
// Replay Debug: structured decision logging that powers the
// retrospective Replay view (every scheduler pick, trigger firing,
// recovery transition, frame verdict, plugin invocation, manual action,
// and system event).
pub mod decision;
pub mod depth_goal;
mod device_ops;
// Dual-rig / multi-camera synchronized imaging: dither-coordination barrier
// + secondary capture-loop driver.
pub mod dual_rig;
mod executor;
// Variables / expression interpolation engine. Powers user-authored
// templates in node names, notification text, RunScript args, and FITS save
// paths. See `expressions/mod.rs` for syntax + variable catalog.
pub mod expressions;
pub mod flat_wizard;
pub mod focus_prediction;
// Measuring a focuser's mechanical backlash instead of asking the operator
// for a figure the app has never been able to work out for itself.
pub mod focuser_calibration;
pub mod instructions;
pub mod meridian;
pub mod meridian_events;
pub mod meridian_flip_executor;
pub mod mosaic;
mod node;
mod polar_align;
// Image Grading: per-frame Pass/Reject grading + reject-folder routing.
pub mod quality;
// Recovery Mode — first-class executor state machine wired up so the
// UI can render a visible "Recovering" LED + banner + Try Now/Abort controls
// instead of users having to guess whether a stalled sequence is broken or
// retrying. Types live here so they are reachable from the executor, the
// bridge, and downstream wire formats.
pub mod recovery;
// TargetScheduler — native port of the planetarium scoring math
// so the executor has a runtime authority for scheduling decisions.
pub mod scheduling;
// Solar position: the one answer to "where is the Sun" that the daylight gate,
// the WaitTime twilight instruction and the DawnApproaching trigger all share.
pub mod solar;
pub mod temperature_compensation;
mod triggers;
pub mod wizard;

pub use all_sky_polar::*;
pub use checkpoint::*;
// Replay Debug — hoist the decision types so the bridge can use
// them without pathing through `nightshade_sequencer::decision::…`.
pub use decision::{
    emit_decision, DecisionCategory, DecisionEvent, DecisionReceiver, DecisionSender,
    DEFAULT_DECISION_CHANNEL_CAPACITY,
};
pub use depth_goal::{
    DepthGoalBinding, DepthGoalCompletion, DepthGoalOps, DepthGoalVerdict, SharedDepthGoalOps,
};
pub use device_ops::*;
pub use dual_rig::{
    DitherBarrier, InFlightDitherPolicy, SecondaryFrameMeta, SecondaryRig, SecondaryRigConfig,
    SecondaryRigState, SecondaryRigStatus, DEFAULT_DITHER_MAX_WAIT_SECS,
};
pub use executor::*;
// interpolation engine — surface the most common entry points so
// callers outside the sequencer (bridge, integration tests) can build
// templates without pathing through `expressions::resolver`.
pub use expressions::{
    catalog::catalog_json, interpolate, interpolate_optional, EvaluationFrame, InterpolationError,
    TemplatePart, VariableEntry, VariableGroup, VariableValue,
};
pub use focuser_calibration::{
    derive_backlash_calibration, resolution_limit_steps, ApproachDirection,
    BacklashAnalysisThresholds, CalibrationConfidence, CalibrationRefusal, DirectionalScan,
    FocuserBacklashCalibration, MeasurementContext,
};
pub use instructions::*;
pub use meridian_events::*;
pub use meridian_flip_executor::*;
pub use mosaic::*;
pub use node::*;
pub use polar_align::*;
// hoist the recovery types so the bridge can use them without
// pathing through `nightshade_sequencer::recovery::…`.
pub use recovery::{
    compute_max_attempts, AttemptOutcome, RecoveryCause, RecoveryContext, RecoveryHistoryEntry,
    RecoveryPhase, RecoveryRuntimeConfig, RecoverySignals,
};
pub use triggers::*;

// Re-export focus prediction types
pub use focus_prediction::{
    DriftStatus, FilterOffset, FocusModel, FocusPredictionEngine, FocusTrainingSample,
    PersistedFocusModel, PredictionResult, PredictiveAfConfig, PredictiveAfDecision,
};

// Re-export autofocus types (with alias to avoid conflict)
pub use autofocus::{
    AutofocusMethod as AfMethod, AutofocusResult, BacklashCompensation,
    FocusDataPoint as AfDataPoint, VCurveAutofocus,
};

// Re-export temperature compensation types
pub use temperature_compensation::{CompensationMode, TemperatureCompensationConfig};

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Unique identifier for a sequence node
pub type NodeId = String;

/// Defines how the safety system behaves when weather/safety devices fail or are unavailable.
/// This mirrors the Dart-side SafetyFailMode enum in app_settings.dart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum SafetyFailMode {
    /// Treat unavailable safety data as unsafe.
    #[default]
    FailClosed,
    /// Treat unavailable safety data as safe and continue operations.
    FailOpen,
    /// Preserve prior safety state and emit an operator-visible warning.
    WarnOnly,
}

/// Status of a node execution
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeStatus {
    /// Node has not started
    Pending,
    /// Node is currently running
    Running,
    /// Node completed successfully
    Success,
    /// Node failed
    Failure,
    /// Node was skipped
    Skipped,
    /// Node was cancelled
    Cancelled,
}

impl NodeStatus {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            NodeStatus::Success | NodeStatus::Failure | NodeStatus::Skipped | NodeStatus::Cancelled
        )
    }
}

/// A sequence definition that can be saved/loaded
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SequenceDefinition {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub root_node_id: Option<NodeId>,
    pub nodes: Vec<NodeDefinition>,
    #[serde(default)]
    pub metadata: HashMap<String, String>,
}

impl SequenceDefinition {
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            description: None,
            root_node_id: None,
            nodes: Vec::new(),
            metadata: HashMap::new(),
        }
    }
}

/// Definition of a node that can be serialized
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeDefinition {
    pub id: NodeId,
    #[serde(default)]
    pub name: String,
    pub node_type: NodeType,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub children: Vec<NodeId>,
}

fn default_enabled() -> bool {
    true
}

/// Types of nodes in the sequencer
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum NodeType {
    // Container/Logic nodes
    TargetHeader(TargetHeaderConfig),
    /// Legacy alias - deserializes to TargetHeader
    #[serde(alias = "TargetGroup")]
    TargetGroup(TargetHeaderConfig),
    Loop(LoopConfig),
    Parallel(ParallelConfig),
    Conditional(ConditionalConfig),
    Recovery(RecoveryConfig),

    // Instruction nodes
    SlewToTarget(SlewConfig),
    CenterTarget(CenterConfig),
    TakeExposure(ExposureConfig),
    Autofocus(AutofocusConfig),
    TemperatureCompensation(TemperatureCompensationConfig),
    Dither(DitherConfig),
    StartGuiding(StartGuidingConfig),
    StopGuiding,
    ChangeFilter(FilterConfig),
    CoolCamera(CoolConfig),
    WarmCamera(WarmConfig),
    MoveRotator(RotatorConfig),
    Park,
    Unpark,
    WaitForTime(WaitTimeConfig),
    Delay(DelayConfig),
    Notification(NotificationConfig),
    RunScript(ScriptConfig),
    PolarAlignment(PolarAlignConfig),
    MeridianFlip(MeridianFlipConfig),
    OpenDome(DomeConfig),
    CloseDome(DomeConfig),
    ParkDome(DomeConfig),
    Mosaic(MosaicConfig),
    FlatWizard(FlatWizardConfig),
    // Cover Calibrator / Flat Panel instructions
    OpenCover(CoverCalibratorConfig),
    CloseCover(CoverCalibratorConfig),
    CalibratorOn(CalibratorOnConfig),
    CalibratorOff(CoverCalibratorConfig),

    // TargetScheduler — dynamic target picker. Container
    // node whose children MUST be `TargetHeader` variants; at each scheduling
    // decision point the highest-scoring runnable child is executed.
    TargetScheduler(TargetSchedulerConfig),

    // SmartExposure — one row per filter, container-style
    // instruction. Internally delegates to ChangeFilter + TakeExposure via
    // the InstructionRegistry; per-filter completed counts and the current
    // plan index are persisted to `SessionCheckpoint::wizard_states` so a
    // sequence killed mid-rotation resumes on the right filter at the
    // right frame index.
    SmartExposure(SmartExposureConfig),

    // PluginNode — a plugin-contributed instruction whose
    // execution is dispatched into the Dart side via a request/response
    // protocol. The Rust executor knows only the identifiers
    // (`plugin_id`/`node_type_id`) and the opaque `config_json` blob; the
    // Dart `PluginNodeExecutor` is the one that resolves the registration
    // and runs `PluginSequenceNode.execute`.
    //
    // The runtime contract is:
    //   1. The executor emits `ExecutorEvent::PluginNodeRequested {…}`.
    //   2. Dart picks the event up via the typed sequencer-event stream,
    //      runs the plugin, and sends
    //      `ExecutorCommand::PluginNodeFinished {…}` back through the
    //      bridge.
    //   3. The Rust instruction node blocks on a oneshot keyed by node id
    //      and returns Success/Failure based on the reply.
    //
    // A timeout (default 10 minutes; overridable via `timeout_secs`) fails
    // the node loudly when no reply arrives.
    PluginNode {
        plugin_id: String,
        node_type_id: String,
        /// Opaque JSON payload that the plugin author authored on the Dart
        /// side. Rust never deserialises this — it only forwards the
        /// string verbatim. Defaults to empty string.
        #[serde(default)]
        config_json: String,
        /// Optional human-readable label surfaced in logs. The display
        /// name on `NodeDefinition` still wins for UI; this is only used
        /// when log lines need a friendlier label than the raw type id.
        #[serde(default)]
        display_name: Option<String>,
        /// Optional per-node timeout in seconds. None falls back to the
        /// executor default (600 s). `Some(0)` is treated the same as
        /// `None` (use default) rather than zero-second-fail-now, because
        /// a zero-second timeout would be a configuration bug.
        #[serde(default)]
        timeout_secs: Option<u32>,
    },

    // LiveStacking — EAA / outreach broadcast node.
    // When entered, this node arms a frame-level subscription that pipes
    // each newly-captured sub into the live-stacking engine (sigma-clipped
    // average / median rejection / pure average depending on
    // `stack_method`). The latest stacked JPEG + telemetry is published
    // to the broadcast service so a phone client on the LAN (or a public
    // outreach URL) can watch the image build up frame-by-frame.
    //
    // The node itself is asynchronous: it does NOT block the sequence.
    // The sequencer enters the node, registers the broadcast intent with
    // `BroadcastService`, and returns Success once the listener is
    // installed. The listener keeps stacking on every successful exposure
    // until the parent target/loop exits — at which point the node's
    // sibling exposures naturally stop producing frames and the stacker
    // is reset on the next start.
    LiveStacking(LiveStackingConfig),

    // Science: SciencePhotometryNode — cadence-enforced photometric
    // capture for variable-star / exoplanet timing. Inherits the standard
    // expose pipeline (camera + grading + FITS save) and layers in:
    //   * Per-frame instrumental + (optionally) differential magnitude
    //     extraction from `target_designation` + `reference_stars`.
    //   * A photometry-specific `PhotometryQualityGates` step that re-uses
    //     Image Grading's reject path for frames that fail SNR /
    //     FWHM / airmass / reference-visibility thresholds.
    //   * Cadence enforcement: if the gap between consecutive exposure
    //     starts exceeds `max_cadence_gap_secs`, the executor emits a
    //     `ProgressDetail::PhotometryCadenceBroken` warning (does NOT
    //     abort — partial cadence-broken data is still useful for offline
    //     re-analysis).
    //   * Photometric FITS keywords: `OBJCAT`, `REFSTARS`, `AIRMASS`,
    //     `MJD-OBS`, `INSTRMAG`, `DIFFMAG`, `FWHM`, `SNR`.
    //
    // See `node/instructions/science_photometry.rs` for the execution
    // flow. The Dart layer subscribes to `ProgressDetail::PhotometryFrame`
    // for live light-curve updates.
    SciencePhotometry(SciencePhotometryConfig),
}

impl NodeType {
    /// True for the variants whose executor actually descends into children.
    ///
    /// Every other variant is a leaf: its instruction runs, returns a status,
    /// and the node tree never looks at `children`. Anything parented under a
    /// leaf is therefore UNREACHABLE — it is stored, drawn in the builder's
    /// flat list, counted in the header chip, and then silently never
    /// executed. That is what made a run of Target → Unpark → SlewToTarget →
    /// TakeExposure (each nested inside the previous) execute one instruction
    /// and report `completed` with 0 frames and no errors.
    pub fn accepts_children(&self) -> bool {
        matches!(
            self,
            NodeType::TargetHeader(_)
                | NodeType::TargetGroup(_)
                | NodeType::Loop(_)
                | NodeType::Parallel(_)
                | NodeType::Conditional(_)
                | NodeType::Recovery(_)
                | NodeType::TargetScheduler(_)
        )
    }
}

// Science: SciencePhotometry configuration

/// Configuration for the [`NodeType::SciencePhotometry`] instruction.
///
/// Differential photometry workflow: the user picks a target (variable
/// star, exoplanet host, etc.) and one or more reference stars in the same
/// field, points the rig, and lets a long burst run at constant cadence.
/// Each frame yields one `photometry_measurements` row containing the
/// instrumental magnitude of the target + (when `apply_differential` is
/// true) the differential magnitude against the average reference star
/// flux.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SciencePhotometryConfig {
    /// Target object identifier in the catalogue used by the science
    /// pipeline (e.g. `"V0376 Per"`, `"KIC-9832227"`, `"TIC-25155310"`).
    /// Surfaced as the FITS `OBJCAT` keyword.
    pub target_designation: String,
    /// Reference stars (catalogue IDs) used for differential photometry.
    /// Empty when `apply_differential` is false. Surfaced as the FITS
    /// `REFSTARS` keyword (comma-separated).
    #[serde(default)]
    pub reference_stars: Vec<String>,
    /// Maximum gap (seconds) allowed between consecutive exposure starts.
    /// If exceeded — usually due to a mid-burst autofocus or dither — the
    /// node emits a `ProgressDetail::PhotometryCadenceBroken` warning.
    /// 0.0 disables cadence checking; values below `exposure_secs` are
    /// physically impossible and rejected by the validator.
    #[serde(default = "default_photometry_cadence_gap")]
    pub max_cadence_gap_secs: f64,
    /// Photometric filter (one of `V`, `B`, `R`, `I`, `g`, `r`, `i`, `z`,
    /// `Clear`, `CV`). Non-photometric filters are flagged by the
    /// validator.
    pub filter: String,
    /// Per-frame exposure duration in seconds. Constant cadence requires
    /// this to be uniform across the burst.
    pub exposure_secs: f64,
    /// Number of frames to capture in the burst.
    pub count: u32,
    /// When true, the science pipeline extracts the target's instrumental
    /// magnitude from each captured frame in real time and writes a row
    /// to `photometry_measurements`. When false the frames are captured
    /// "raw" and the science pipeline does the extraction offline.
    #[serde(default = "default_photometry_reduce_live")]
    pub reduce_live: bool,
    /// When true (and `reduce_live` is true), the runtime additionally
    /// computes the differential magnitude against `reference_stars` and
    /// stamps `DIFFMAG` into the FITS header. Requires non-empty
    /// `reference_stars`.
    #[serde(default = "default_photometry_apply_differential")]
    pub apply_differential: bool,
    /// Per-frame quality gates. Frames that fail are rejected via the
    /// Image Grading reject path; the photometry row is still
    /// written (with `is_outlier = true`) so the offline pipeline has
    /// the full chronological record.
    #[serde(default)]
    pub quality: PhotometryQualityGates,
    /// Optional gain override. None falls back to the camera's profile
    /// default; matches `ExposureConfig::gain`.
    #[serde(default)]
    pub gain: Option<i32>,
    /// Optional offset override.
    #[serde(default)]
    pub offset: Option<i32>,
    /// Binning. Photometry typically wants 1x1 to preserve PSF sampling;
    /// the validator warns when binning != 1x1 for photometric filters.
    #[serde(default)]
    pub binning: Binning,
}

fn default_photometry_cadence_gap() -> f64 {
    2.0
}

fn default_photometry_reduce_live() -> bool {
    true
}

fn default_photometry_apply_differential() -> bool {
    true
}

impl Default for SciencePhotometryConfig {
    fn default() -> Self {
        Self {
            target_designation: String::new(),
            reference_stars: Vec::new(),
            max_cadence_gap_secs: default_photometry_cadence_gap(),
            filter: "Clear".to_string(),
            exposure_secs: 60.0,
            count: 60,
            reduce_live: default_photometry_reduce_live(),
            apply_differential: default_photometry_apply_differential(),
            quality: PhotometryQualityGates::default(),
            gain: None,
            offset: None,
            binning: Binning::One,
        }
    }
}

impl SciencePhotometryConfig {
    /// True when the configured `filter` is one of the standard
    /// photometric bands. Used by validation and by the FITS header
    /// writer to gate the `INSTRMAG`/`DIFFMAG` keywords: photometric
    /// magnitudes are never stamped on frames captured through a
    /// non-photometric filter.
    pub fn is_photometric_filter(&self) -> bool {
        Self::is_photometric_filter_name(&self.filter)
    }

    /// Static check usable in validation without constructing a config.
    pub fn is_photometric_filter_name(name: &str) -> bool {
        // Accept the standard Johnson-Cousins (V, B, R, I), Sloan/SDSS
        // (g, r, i, z), Clear, and the CV (clear with V-band photometric
        // transformation) labels used by AAVSO observers.
        let n = name.trim();
        matches!(
            n,
            "V" | "B"
                | "R"
                | "I"
                | "U"
                | "g"
                | "r"
                | "i"
                | "z"
                | "g'"
                | "r'"
                | "i'"
                | "z'"
                | "Clear"
                | "CV"
                | "CR"
                | "CB"
        )
    }
}

/// Per-frame quality gates for photometric capture.
///
/// All thresholds are honoured by the runtime when
/// `SciencePhotometryConfig::reduce_live` is true. A frame failing any
/// gate is routed to the Image Grading reject folder and its
/// `photometry_measurements` row is marked `is_outlier = true` (so the
/// offline pipeline can still re-analyse the data if desired).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PhotometryQualityGates {
    /// Minimum target SNR to accept. AAVSO publishes per-band SNR
    /// thresholds (V: 50, B: 30, etc.); the default here matches the
    /// "research-grade transit" threshold from the AAVSO Observer
    /// Manual.
    #[serde(default = "default_photometry_min_snr")]
    pub min_snr: f64,
    /// Maximum acceptable FWHM in arcseconds. Frames blurrier than this
    /// are usually wind-affected or out-of-focus; rejecting them
    /// preserves the light curve's noise floor.
    #[serde(default = "default_photometry_max_fwhm_arcsec")]
    pub max_fwhm_arcsec: f64,
    /// When true, frames where ANY reference star failed to extract are
    /// rejected (differential magnitude is unreliable). When false,
    /// missing references are tolerated and the runtime falls back to
    /// per-frame instrumental magnitude.
    #[serde(default = "default_photometry_require_all_refs_visible")]
    pub require_all_refs_visible: bool,
    /// Maximum airmass. Frames captured too close to the horizon suffer
    /// large extinction errors; default 2.5 (~24° altitude) matches the
    /// AAVSO Bright Star Monitor cut-off.
    #[serde(default = "default_photometry_max_airmass")]
    pub max_airmass: f64,
}

fn default_photometry_min_snr() -> f64 {
    50.0
}

fn default_photometry_max_fwhm_arcsec() -> f64 {
    5.0
}

fn default_photometry_require_all_refs_visible() -> bool {
    true
}

fn default_photometry_max_airmass() -> f64 {
    2.5
}

impl Default for PhotometryQualityGates {
    fn default() -> Self {
        Self {
            min_snr: default_photometry_min_snr(),
            max_fwhm_arcsec: default_photometry_max_fwhm_arcsec(),
            require_all_refs_visible: default_photometry_require_all_refs_visible(),
            max_airmass: default_photometry_max_airmass(),
        }
    }
}

/// One outcome of evaluating [`PhotometryQualityGates`] against a frame.
///
/// `Pass` means every gate passed; `Reject` carries the failure reason so
/// the Image Grading reject path can stamp it into the
/// `FrameRejected` progress event.
#[derive(Debug, Clone, PartialEq)]
pub enum PhotometryFrameVerdict {
    Pass,
    Reject { reason: String },
}

impl PhotometryQualityGates {
    /// Apply the gates to a measured frame. `snr`, `fwhm_arcsec`,
    /// `airmass`, and `refs_visible` are all `Option` because the
    /// extractor may not have produced the corresponding measurement
    /// (e.g. no plate-solve => no airmass). A missing measurement is a
    /// Reject when the corresponding gate is active, never a silent pass.
    pub fn evaluate(
        &self,
        snr: Option<f64>,
        fwhm_arcsec: Option<f64>,
        airmass: Option<f64>,
        refs_total: usize,
        refs_visible: usize,
    ) -> PhotometryFrameVerdict {
        if self.min_snr > 0.0 {
            let measured = match snr {
                Some(v) => v,
                None => {
                    return PhotometryFrameVerdict::Reject {
                        reason: "SNR not measured (no stars detected?)".to_string(),
                    };
                }
            };
            if measured < self.min_snr {
                return PhotometryFrameVerdict::Reject {
                    reason: format!("SNR {:.1} below threshold {:.1}", measured, self.min_snr),
                };
            }
        }
        if self.max_fwhm_arcsec > 0.0 {
            let measured = match fwhm_arcsec {
                Some(v) => v,
                None => {
                    return PhotometryFrameVerdict::Reject {
                        reason: "FWHM not measured (no stars detected?)".to_string(),
                    };
                }
            };
            if measured > self.max_fwhm_arcsec {
                return PhotometryFrameVerdict::Reject {
                    reason: format!(
                        "FWHM {:.2}\" above threshold {:.2}\"",
                        measured, self.max_fwhm_arcsec
                    ),
                };
            }
        }
        if self.max_airmass > 0.0 {
            let measured = match airmass {
                Some(v) => v,
                None => {
                    return PhotometryFrameVerdict::Reject {
                        reason: "Airmass not computed (no altitude?)".to_string(),
                    };
                }
            };
            if measured > self.max_airmass {
                return PhotometryFrameVerdict::Reject {
                    reason: format!(
                        "Airmass {:.2} above threshold {:.2}",
                        measured, self.max_airmass
                    ),
                };
            }
        }
        if self.require_all_refs_visible && refs_total > 0 && refs_visible < refs_total {
            return PhotometryFrameVerdict::Reject {
                reason: format!(
                    "Only {}/{} reference stars visible",
                    refs_visible, refs_total
                ),
            };
        }
        PhotometryFrameVerdict::Pass
    }
}

// LiveStacking configuration

/// Stacking method used by the LiveStacking node.
///
/// The names are kebab-cased on the wire (so the same JSON loads on Dart
/// without bespoke conversion) and match the brief's enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum StackMethod {
    /// Pure mean of accepted frames. Cheapest, but does not reject outliers.
    #[default]
    Average,
    /// Median with sigma rejection. Best for hot-pixel / satellite-trail
    /// suppression at the cost of a slightly noisier-looking preview at
    /// low frame counts.
    MedianRej,
    /// Sigma-clipped mean. Compromise between Average and MedianRej —
    /// rejects outliers but converges faster than median for the same
    /// frame count.
    Sigma,
}

impl StackMethod {
    /// Lower-case stable string for the bridge layer and tracing logs.
    pub fn as_str(&self) -> &'static str {
        match self {
            StackMethod::Average => "average",
            StackMethod::MedianRej => "median_rej",
            StackMethod::Sigma => "sigma",
        }
    }
}

/// Operating mode for the LiveStacking node.
///
/// `BroadcastOnly` keeps the on-disk captured sub completely untouched —
/// the stack lives only in memory and is published to the broadcast
/// service. `RecordAndBroadcast` additionally writes the stacked JPEG
/// snapshot to the session's save directory on every frame so the user
/// keeps a record of the building image alongside the regular FITS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum LiveStackingMode {
    #[default]
    BroadcastOnly,
    RecordAndBroadcast,
}

impl LiveStackingMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            LiveStackingMode::BroadcastOnly => "broadcast_only",
            LiveStackingMode::RecordAndBroadcast => "record_and_broadcast",
        }
    }
}

/// Configuration for the [`NodeType::LiveStacking`] node.
///
/// All ports / paths are validated by the editor-side validation rules
/// (see Dart `LiveStackingPortClashRule` / `LiveStackingNoExposureRule`).
/// The Rust runtime does not re-validate — invalid configs are caught
/// before the sequence starts.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LiveStackingConfig {
    /// `BroadcastOnly` or `RecordAndBroadcast`.
    #[serde(default)]
    pub mode: LiveStackingMode,
    /// Stacking method (average / median+rej / sigma-clipped).
    #[serde(default)]
    pub stack_method: StackMethod,
    /// Hard cap on number of frames added to the stack. `0` = unlimited.
    /// Useful at long outreach events to keep memory bounded.
    #[serde(default)]
    pub max_frames_to_stack: u32,
    /// Whether the broadcast endpoint is enabled. When `false` the
    /// stacker still runs (for the local preview), but the HTTP endpoint
    /// returns 404 on `/api/broadcast/live-stack`. The user can flip
    /// this mid-sequence by editing the node when paused.
    #[serde(default = "default_broadcast_enabled")]
    pub broadcast_enabled: bool,
    /// TCP port the broadcast service binds. Defaults to 8081 to stay
    /// out of the headless API server (default 8080) and the web
    /// dashboard. The Dart `LiveStackingPortClashRule` errors if this
    /// matches the headless API port.
    #[serde(default = "default_broadcast_port")]
    pub broadcast_port: u16,
    /// HTTP path prefix the broadcast service serves under. Default
    /// `/broadcast`. Allows the user to host the broadcast under a
    /// vanity prefix at outreach events.
    #[serde(default = "default_broadcast_path")]
    pub broadcast_path: String,
    /// Optional shared secret. When `Some` and non-empty, every
    /// broadcast endpoint requires `?token=…` matching this value.
    /// `None` (or `Some("")`) = public access.
    #[serde(default)]
    pub auth_token: Option<String>,
    /// Optional watermark text rendered on the broadcast JPEG. Supports
    /// the variable interpolation engine — e.g. `"M42 — L
    /// ${integration.hms}"`. `None` disables the watermark entirely.
    #[serde(default)]
    pub watermark_text: Option<String>,
    /// Output thumbnail size (width × height) for the broadcast JPEG.
    /// Larger sizes give a more detailed preview at the cost of LAN
    /// bandwidth. Default 1280×720 (HD).
    #[serde(default = "default_thumbnail_width")]
    pub thumbnail_width: u32,
    #[serde(default = "default_thumbnail_height")]
    pub thumbnail_height: u32,
    // NOTE (OSC scope): the manual OSC / colour-stacking path lives entirely in
    // the bridge stacker (`stacking_api.rs`: sensor_mode / bayer_pattern /
    // demosaic_quality on `LiveStackingConfigApi`) and its Dart surfaces
    // (Stack-and-Share + the live-stacking panel). The unattended sequencer
    // broadcast path does NOT yet feed frames into a colour debayer — the
    // executor's `FrameAccepted` handler does not call
    // `LiveStackingBroadcastService.publishFrame`, and the broadcast renders
    // mono JPEGs. Carrying inert OSC fields on this config (with comments
    // describing a Dart consumer that reads them back) advertised wiring that
    // does not exist, so the fields were removed rather than left dead. When the
    // broadcast frame-feed is implemented, reintroduce them alongside the actual
    // consumer.
}

fn default_broadcast_enabled() -> bool {
    true
}

fn default_broadcast_port() -> u16 {
    8081
}

fn default_broadcast_path() -> String {
    "/broadcast".to_string()
}

fn default_thumbnail_width() -> u32 {
    1280
}

fn default_thumbnail_height() -> u32 {
    720
}

impl Default for LiveStackingConfig {
    fn default() -> Self {
        Self {
            mode: LiveStackingMode::default(),
            stack_method: StackMethod::default(),
            max_frames_to_stack: 0,
            broadcast_enabled: default_broadcast_enabled(),
            broadcast_port: default_broadcast_port(),
            broadcast_path: default_broadcast_path(),
            auth_token: None,
            watermark_text: None,
            thumbnail_width: default_thumbnail_width(),
            thumbnail_height: default_thumbnail_height(),
        }
    }
}

// SmartExposure configuration

/// Configuration for the SmartExposure container instruction.
///
/// SmartExposure is the "one row per filter" automation users expect from
/// modern sequencers: instead of authoring `FilterChange → Loop(N) →
/// TakeExposure` chains by hand for L/R/G/B, the user lists one
/// [`FilterPlan`] per filter and SmartExposure handles filter changes,
/// dither cadence, and rotation order itself.
///
/// Per-filter progress is checkpointed (see [`SmartExposureCheckpoint`]) so
/// a sequence killed mid-rotation resumes on the correct filter at the
/// correct exposure count.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmartExposureConfig {
    /// Ordered list of per-filter plans. Order is the rotation order when
    /// [`Self::rotate_filters`] is true. Editable mid-run when the sequence
    /// is paused (canEdit gating).
    pub plans: Vec<FilterPlan>,
    /// If true, take one batch from each plan in `plans` order before
    /// repeating (RGRGRG …). If false, exhaust each plan in turn before
    /// moving to the next (RRRRRGGG …). Default true (rotation).
    #[serde(default = "default_rotate_filters")]
    pub rotate_filters: bool,
    /// If true, run a dither between filter changes in addition to the
    /// per-plan `dither_every`. Default false because a filter change
    /// itself shifts the field slightly; an explicit dither is cheap
    /// insurance but not always wanted.
    #[serde(default)]
    pub dither_on_filter_change: bool,
    /// Global integration budget cap in seconds. When > 0 and the
    /// SmartExposure-local accumulated exposure time exceeds this value,
    /// SmartExposure returns `Success` even if some plans have unfilled
    /// counts. 0 = no cap (run every plan to completion).
    ///
    /// Useful for "shoot whatever fits in 4 hours" runs where the user
    /// cares about wall-clock more than per-filter completeness.
    #[serde(default)]
    pub integration_budget_secs: f64,
    /// Number of exposures to take per filter before rotating to the next
    /// filter (only meaningful when `rotate_filters` is true). Default 1 —
    /// matches the classical "one sub then rotate" behaviour. Increasing
    /// this batches multiple subs per filter visit, which reduces filter
    /// wheel wear at the cost of slightly less even temporal sampling.
    #[serde(default = "default_smart_exposure_batch_size")]
    pub batch_size: u32,
    /// "Loop until stopped" mode. When true, SmartExposure ignores the
    /// per-plan `count`s entirely and takes exactly one sub per filter,
    /// round-robin, repeating indefinitely until EITHER the
    /// `integration_budget_secs` cap is met OR the surrounding target's
    /// `end_when` window closes (or the sequence is stopped/skipped), so every
    /// filter stays evenly sampled across the whole available window.
    ///
    /// In this mode `batch_size` is forced to 1 and `rotate_filters` to true
    /// regardless of their stored values, because "1 sub per filter,
    /// round-robin" is the whole point. Default false.
    ///
    /// Entering this mode with NO integration budget AND no detectable
    /// target-window/stop bound is a misconfiguration — the executor returns
    /// Failure rather than spinning forever.
    #[serde(default)]
    pub loop_until_stopped: bool,
}

fn default_rotate_filters() -> bool {
    true
}

fn default_smart_exposure_batch_size() -> u32 {
    1
}

impl Default for SmartExposureConfig {
    fn default() -> Self {
        Self {
            plans: Vec::new(),
            rotate_filters: default_rotate_filters(),
            dither_on_filter_change: false,
            integration_budget_secs: 0.0,
            batch_size: default_smart_exposure_batch_size(),
            loop_until_stopped: false,
        }
    }
}

/// One per-filter row in a [`SmartExposureConfig`]. Conceptually equivalent
/// to a `FilterChange → Loop(count) → TakeExposure` chain, but stored as a
/// single data row so the UI can present a tabular editor.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterPlan {
    /// Filter wheel slot name (e.g. "L", "Ha"). Matched against the
    /// connected filter wheel's name list when `filter_index` is None.
    pub filter_name: String,
    /// 0-based filter wheel index. Preferred over `filter_name` for
    /// reliability — matches `FilterConfig::filter_index`. None falls back
    /// to name matching.
    #[serde(default)]
    pub filter_index: Option<i32>,
    /// Total number of exposures to take for this filter. Used together
    /// with the per-filter completed count in
    /// [`SmartExposureCheckpoint`] to decide when this plan is done.
    pub count: u32,
    /// Sub-exposure duration in seconds.
    pub duration_secs: f64,
    /// Optional gain override. None means "use camera/profile default".
    #[serde(default)]
    pub gain: Option<i32>,
    /// Optional offset override.
    #[serde(default)]
    pub offset: Option<i32>,
    /// Binning for this filter. Defaults to 1x1.
    #[serde(default)]
    pub binning: Binning,
    /// Per-plan dither cadence (every N frames). None disables dithering
    /// for this filter regardless of any global default. Some(0) is
    /// treated as "no dither" — matches `ExposureConfig::dither_every`.
    #[serde(default)]
    pub dither_every: Option<u32>,
    /// Optional DepthLock binding. When set, Smart Exposure asks the host's
    /// goal store for a verdict before each batch of this plan and treats an
    /// achieved goal as the plan being complete. `None` (the default, and
    /// every pre-feature sequence document) leaves the plan purely
    /// count-bounded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub depth_goal: Option<crate::depth_goal::DepthGoalBinding>,
}

impl Default for FilterPlan {
    fn default() -> Self {
        Self {
            filter_name: String::new(),
            filter_index: None,
            count: 10,
            duration_secs: 60.0,
            gain: None,
            offset: None,
            binning: Binning::default(),
            dither_every: None,
            depth_goal: None,
        }
    }
}

/// Per-filter progress record persisted in
/// [`crate::checkpoint::SessionCheckpoint::wizard_states`] under the key
/// [`smart_exposure_checkpoint_key`]. Old sequences without this entry
/// resume from a fresh state (all counts zero, plan index 0) — the
/// `#[serde(default)]` on `wizard_states` already guarantees this.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SmartExposureCheckpoint {
    /// completed_count keyed by filter name. We key by name (not index)
    /// because the user might re-order plans between runs; resuming on
    /// the "L" plan should still see "L" frames already taken even if it
    /// moved from index 0 to index 2.
    pub per_filter_completed: HashMap<String, u32>,
    /// Index of the plan currently being executed (so resume returns to
    /// the right row, not necessarily the first incomplete plan when
    /// `rotate_filters` is false).
    pub current_plan_index: usize,
    /// Accumulated integration seconds attributed to this SmartExposure
    /// node, used for the per-node `integration_budget_secs` cap. The
    /// global `completed_integration_secs` on ExecutionContext is shared
    /// across the whole sequence, so SmartExposure tracks its own slice
    /// here for the budget comparison.
    pub completed_integration_secs: f64,
    /// DepthLock goals this node has already retired, keyed by goal id with
    /// the revision the verdict was for. Recorded so a resumed run neither
    /// re-announces the completion nor re-queries a store that may have
    /// moved on; the store's own record is still the durable verdict.
    /// Absent in pre-feature checkpoints.
    #[serde(default)]
    pub depth_completed: HashMap<String, u64>,
}

/// Stable checkpoint key for SmartExposure resume state. Re-uses the
/// `wizard_states` slot on `SessionCheckpoint` so a single map covers
/// every kind of step-level resume state — but the key namespace is
/// distinct (`smart_exposure:<node_id>`) so two SmartExposure nodes in the
/// same sequence don't clobber each other's state.
pub fn smart_exposure_checkpoint_key(node_id: &NodeId) -> String {
    format!("smart_exposure:{}", node_id)
}

// TargetScheduler ----------------------------------------------

/// How the scheduler should drive multi-filter cycling within a
/// single dispatch on a target whose subtree contains a [`SmartExposureConfig`]
/// (typical for mosaic panels with LRGB / SHO plans).
///
/// Under `SingleFilter` the scheduler picks a target, executes its subtree, and
/// the SmartExposure node inside that subtree uses whatever `rotate_filters` /
/// `batch_size` it was authored with. In the mosaic + scheduler composition
/// that gives one panel one filter burst per dispatch — a 4-panel LRGB mosaic
/// of 50/50/50/50 frames needs 200 separate scheduler ticks instead of
/// interleaving filters within the panel visit, wasting meridian-flip headroom
/// and producing uneven coverage.
///
/// `RoundRobin { frames_per_burst }` overrides each `SmartExposure` node in
/// the picked subtree for the duration of that dispatch: the rotation flag is
/// forced on and the per-visit batch size is set to `frames_per_burst`. The
/// override is installed on `ExecutionContext` immediately before the picked
/// child executes and cleared on return, so it does NOT leak into sibling
/// dispatches and does NOT mutate the saved sequence definition on disk.
///
/// The default is `SingleFilter`, and the field is `#[serde(default)]` so
/// existing sequence JSON deserialises unchanged.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Default)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum FilterCycleMode {
    /// The historical behaviour — the scheduler does NOT override the picked
    /// subtree's SmartExposure config. Whatever the node was authored with
    /// (`rotate_filters` / `batch_size`) wins, and a single dispatch typically
    /// produces a burst of one filter.
    #[default]
    SingleFilter,
    /// Force each `SmartExposure` node in the picked subtree to rotate
    /// across all filters with `batch_size = frames_per_burst`. The dispatch
    /// continues until either: (a) every plan in that SmartExposure node is
    /// exhausted, (b) the SmartExposure node's own `integration_budget_secs`
    /// (if set) fires, or (c) the scheduler's recompute cadence yields the
    /// dispatch back so the surrounding loop can re-rank targets.
    RoundRobin {
        /// Frames per filter visit before rotating. Must be >= 1 — values of
        /// 0 are clamped to 1 by [`FilterCycleMode::frames_per_burst_clamped`]
        /// because rotating after zero frames is a no-op infinite loop.
        frames_per_burst: u32,
    },
}

impl FilterCycleMode {
    /// True when the mode is anything other than `SingleFilter`. The
    /// dispatch path skips its subtree-walk entirely when this returns false.
    pub fn is_active(&self) -> bool {
        !matches!(self, FilterCycleMode::SingleFilter)
    }

    /// Clamp `frames_per_burst` to the legal `>= 1` band. SingleFilter
    /// returns `None` (no override applies).
    pub fn frames_per_burst_clamped(&self) -> Option<u32> {
        match self {
            FilterCycleMode::SingleFilter => None,
            FilterCycleMode::RoundRobin { frames_per_burst } => Some((*frames_per_burst).max(1)),
        }
    }
}

/// Configuration for the [`NodeType::TargetScheduler`] container node.
///
/// Mirrors the Dart-side `TargetSchedulerNode` config. Default values match
/// the brief — `0.25 / 0.25 / 0.20 / 0.15 / 0.15` weights, 30-point minimum
/// score, no automatic recompute mid-target, and the "finish the current loop
/// iteration before switching" guard turned on so a partially-finished
/// exposure burst is not abandoned mid-frame.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TargetSchedulerConfig {
    /// Per-axis weights passed through to the scheduling::scoring layer.
    #[serde(default = "default_scheduler_altitude_weight")]
    pub altitude_weight: f64,
    #[serde(default = "default_scheduler_moon_distance_weight")]
    pub moon_distance_weight: f64,
    #[serde(default = "default_scheduler_transit_proximity_weight")]
    pub transit_proximity_weight: f64,
    #[serde(default = "default_scheduler_darkness_weight")]
    pub darkness_weight: f64,
    #[serde(default = "default_scheduler_airmass_weight")]
    pub airmass_weight: f64,
    /// Minimum total score (0..=100) below which the scheduler treats every
    /// target as unrunnable. When no child clears the floor the node returns
    /// `Skipped`.
    #[serde(default = "default_scheduler_min_score_to_run")]
    pub min_score_to_run: f64,
    /// Recompute the schedule every N exposures completed inside the
    /// currently-running target's subtree. `0` means "only re-decide when the
    /// current target finishes" (boundary-only mode).
    #[serde(default)]
    pub recompute_every_n_exposures: u32,
    /// Once a target's subtree starts, finish its current `Loop` iteration
    /// before switching even if a recompute would otherwise pick someone else.
    /// Prevents abandoning a partially-completed exposure burst.
    #[serde(default = "default_scheduler_finish_iteration_on_switch")]
    pub finish_iteration_on_switch: bool,

    /// Optional HARD moon-avoidance gate in degrees. When set, the scheduler
    /// marks any target within this angular separation of an up, at-least-10%
    /// illuminated moon as not-runnable (with a skip reason), regardless of its
    /// score — matching NINA/Ekos moon avoidance. `None` (default) keeps only
    /// the existing soft moon-distance score.
    #[serde(default)]
    pub min_moon_separation_deg: Option<f64>,

    // Sky-conditions-aware adaptive target swap.
    //
    // When `swap_on_conditions_below` is `Some(threshold)`, the scheduler
    // consults `crate::scheduling::adaptive_swap::pick_target_for_conditions`
    // at every decision point. If the live composite ConditionsScore is at
    // or below the threshold AND the currently-running target's
    // brightness_tier_hint no longer accepts the score, the scheduler swaps
    // to the highest-scoring brighter backup. `None` => adaptive swap is
    // disabled (the ordinary ranking runs unchanged).
    /// Conditions-score floor below which adaptive swap engages. `None`
    /// disables the feature for this scheduler instance.
    #[serde(default)]
    pub swap_on_conditions_below: Option<f64>,

    /// Minimum seconds between consecutive adaptive swaps. Stops the
    /// scheduler from thrashing between targets when conditions hover
    /// around the threshold. Default 180s (3 minutes).
    #[serde(default = "default_scheduler_swap_hysteresis_secs")]
    pub swap_hysteresis_secs: f64,

    /// Tier preferences (per-tier conditions-score floors). Defaults
    /// follow the brief (faint ≥ 70, medium ≥ 50, bright ≥ 30).
    #[serde(default)]
    pub brightness_tier_preferences: crate::scheduling::BrightnessTierPreferences,

    /// Score readings older than this are treated as "telemetry missing"
    /// and the scheduler falls back to the ordinary ranking. Default 300s.
    #[serde(default = "default_scheduler_max_score_age_secs")]
    pub max_conditions_score_age_secs: i64,

    /// multi-filter cycle mode for SmartExposure-bearing
    /// children. `SingleFilter` (the default) preserves the historical
    /// "one filter per dispatch" behaviour; `RoundRobin { frames_per_burst }`
    /// overrides each `SmartExposure` in the picked subtree to rotate
    /// across all filters with the given batch size, so a mosaic panel
    /// visit produces an LRGB cycle within one dispatch instead of one
    /// dispatch per (panel, filter) pair.
    #[serde(default)]
    pub filter_cycle_mode: FilterCycleMode,

    /// Optional per-azimuth horizon mask (local obstructions: trees,
    /// buildings, roof lines). When present, the scheduler marks any
    /// target whose current altitude sits below the horizon's
    /// min-altitude at the target's current azimuth as not-runnable
    /// (with a skip reason naming the azimuth) — the Rust mirror of the
    /// Dart `HorizonProfile.minAltitudeAt(az)` constraint. `None`
    /// (default) keeps the flat-floor-only behaviour. Matches
    /// NINA/SGP/Ekos horizon profiles. Wire format matches the Dart
    /// `HorizonProfile` samples (`{"samples":[{"az":..,"alt":..}]}`).
    #[serde(default)]
    pub horizon_profile: Option<crate::scheduling::HorizonProfile>,
}

impl Default for TargetSchedulerConfig {
    fn default() -> Self {
        Self {
            altitude_weight: default_scheduler_altitude_weight(),
            moon_distance_weight: default_scheduler_moon_distance_weight(),
            transit_proximity_weight: default_scheduler_transit_proximity_weight(),
            darkness_weight: default_scheduler_darkness_weight(),
            airmass_weight: default_scheduler_airmass_weight(),
            min_score_to_run: default_scheduler_min_score_to_run(),
            // Sane self-driving default (matches the Dart node default): re-rank
            // every 5 exposures so the scheduler adapts over the night instead
            // of picking a target once and never reconsidering.
            recompute_every_n_exposures: 5,
            finish_iteration_on_switch: default_scheduler_finish_iteration_on_switch(),
            min_moon_separation_deg: None,
            swap_on_conditions_below: None,
            swap_hysteresis_secs: default_scheduler_swap_hysteresis_secs(),
            brightness_tier_preferences: crate::scheduling::BrightnessTierPreferences::default(),
            max_conditions_score_age_secs: default_scheduler_max_score_age_secs(),
            filter_cycle_mode: FilterCycleMode::default(),
            horizon_profile: None,
        }
    }
}

impl TargetSchedulerConfig {
    /// Construct a `ScoringWeights` view for the scheduling layer.
    pub fn weights(&self) -> crate::scheduling::ScoringWeights {
        crate::scheduling::ScoringWeights {
            altitude_weight: self.altitude_weight,
            moon_distance_weight: self.moon_distance_weight,
            transit_proximity_weight: self.transit_proximity_weight,
            darkness_weight: self.darkness_weight,
            airmass_weight: self.airmass_weight,
            min_moon_separation_deg: self.min_moon_separation_deg,
        }
    }

    /// True when the weights sum to ~1.0 (validator warning rule). Returns
    /// `true` for sums in `[0.95, 1.05]` to leave headroom for floating-point
    /// rounding from UI sliders.
    pub fn weights_normalised(&self) -> bool {
        let sum = self.weights().sum();
        (0.95..=1.05).contains(&sum)
    }
}

fn default_scheduler_altitude_weight() -> f64 {
    0.25
}
fn default_scheduler_moon_distance_weight() -> f64 {
    0.25
}
fn default_scheduler_transit_proximity_weight() -> f64 {
    0.20
}
fn default_scheduler_darkness_weight() -> f64 {
    0.15
}
fn default_scheduler_airmass_weight() -> f64 {
    0.15
}
fn default_scheduler_min_score_to_run() -> f64 {
    30.0
}
fn default_scheduler_finish_iteration_on_switch() -> bool {
    true
}
fn default_scheduler_swap_hysteresis_secs() -> f64 {
    180.0
}
fn default_scheduler_max_score_age_secs() -> i64 {
    300
}

// Configuration structs for each node type

/// Information about a mosaic panel for multi-panel imaging
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MosaicPanelInfo {
    pub mosaic_name: String,
    pub panel_index: i32,
    pub total_panels: i32,
    pub row: i32,
    pub column: i32,
}

impl MosaicPanelInfo {
    pub fn display_label(&self) -> String {
        format!("Panel {}/{}", self.panel_index + 1, self.total_panels)
    }
}

/// Target header configuration - the root node for each target in the sequence.
/// Contains coordinates, scheduling constraints, and optional mosaic panel info.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetHeaderConfig {
    pub target_name: String,
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub rotation: Option<f64>,
    pub priority: i32,
    /// **Deprecated as a runtime input** — kept for serialization back-compat.
    /// Pre-sequences populate this; the runtime now translates it
    /// (via [`crate::scheduling::legacy_to_triggers`]) into a
    /// `TargetTrigger::AltitudeAbove` term inside the effective `start_when`.
    /// New sequences should leave this `None` and set `start_when` directly.
    pub min_altitude: Option<f64>,
    /// **Deprecated as a runtime input** — kept for serialization back-compat.
    /// Translated into a `TargetTrigger::AltitudeAbove(N)` term inside
    /// `end_when` at load time.
    pub max_altitude: Option<f64>,
    /// **Deprecated** — Time constraint: don't start imaging before this
    /// Unix timestamp. Kept for back-compat; translated into a
    /// `TargetTrigger::TimeAfter` inside `start_when` when no explicit
    /// `start_when` is present.
    #[serde(default)]
    pub start_after: Option<i64>,
    /// **Deprecated** — Time constraint: stop imaging by this Unix
    /// timestamp. Translated into a `TargetTrigger::TimeAfter` inside
    /// `end_when` when no explicit `end_when` is present.
    #[serde(default)]
    pub end_before: Option<i64>,
    /// Mosaic panel info if this target is part of a mosaic
    #[serde(default)]
    pub mosaic_panel: Option<MosaicPanelInfo>,
    // per-target altitude crossings (SGP-style).
    //
    // `start_when` is a wait condition: TargetHeader doesn't begin executing
    // children until it becomes true. If already true at sequence start, no
    // wait. `end_when` is a stop condition: as soon as it becomes true,
    // remaining children are Skipped and the target returns Success.
    //
    // Both are optional and serialise with `#[serde(default)]` so
    // pre-Wave-4 sequences (which don't carry these fields) load identically.
    //
    // When BOTH the new fields and the legacy `min_altitude`/`start_after`
    // / `max_altitude`/`end_before` fields are present, the explicit
    // `start_when`/`end_when` wins. When only the legacy fields are
    // present, [`Self::effective_start_when`]/[`Self::effective_end_when`]
    // synthesise an equivalent trigger via
    // [`crate::scheduling::legacy_to_triggers`].
    /// wait condition: target only starts once this becomes true.
    #[serde(default)]
    pub start_when: Option<crate::scheduling::TargetTrigger>,
    /// stop condition: target ends as soon as this becomes true.
    #[serde(default)]
    pub end_when: Option<crate::scheduling::TargetTrigger>,
    /// how often (seconds) the runtime re-evaluates `start_when`
    /// and `end_when` while imaging. Default 30s. Setting this very low
    /// will burn CPU; setting it very high will delay reacting to the
    /// crossing.
    #[serde(default = "default_trigger_poll_interval_secs")]
    pub trigger_poll_interval_secs: u32,
    // Per-target integration budget.
    // `scheduling::integration_budget`. `#[serde(default)]` keeps backward
    // compatibility with previously-saved sequences that lack the field.
    //
    // The Smart Exposure and Target Scheduler
    // nodes both read this struct via `TargetHeaderConfig::integration_budget()`
    // and consult the per-run `BudgetState` cache that `target_header.rs`
    // installs on the ExecutionContext.
    #[serde(default)]
    pub integration_budget: Option<IntegrationBudget>,

    // adaptive sky-conditions target swap.
    //
    // Brightness tier hint consulted by the TargetScheduler's adaptive-swap
    // logic when live conditions drop. `None` => the scheduler infers from
    // object type / magnitude (currently treated as `Medium`); `Some(tier)`
    // pins the target to the user's choice. `#[serde(default)]` keeps the
    // field absent from existing JSON checkpoints (back-compat).
    #[serde(default)]
    pub brightness_tier_hint: Option<crate::scheduling::BrightnessTier>,
}

fn default_trigger_poll_interval_secs() -> u32 {
    30
}

impl Default for TargetHeaderConfig {
    fn default() -> Self {
        Self {
            target_name: String::new(),
            ra_hours: 0.0,
            dec_degrees: 0.0,
            rotation: None,
            priority: 0,
            min_altitude: None,
            max_altitude: None,
            start_after: None,
            end_before: None,
            mosaic_panel: None,
            start_when: None,
            end_when: None,
            trigger_poll_interval_secs: default_trigger_poll_interval_secs(),
            integration_budget: None,
            brightness_tier_hint: None,
        }
    }
}

/// Per-target integration budget.
///
/// Users can specify either:
/// * an absolute total wall-clock integration cap (`total_secs > 0`), OR
/// * a per-filter breakdown (`per_filter`) — each entry is either an
///   [`FilterBudgetEntry::Absolute`] cap in seconds, or a [`FilterBudgetEntry::Ratio`]
///   that is normalised against the other ratios in the same target to
///   carve up `total_secs`.
///
/// Both can be combined: "8h LRGB at 4:1:1:1" sets `total_secs = 28_800`
/// and four ratio entries. The runtime computes the per-filter absolute
/// cap from the ratio at first use.
///
/// When the budget is hit the [`crate::node::logic::target_header`] runtime
/// marks the target Success (not Failure) and execution proceeds to the next
/// sibling. See also [`LoopCondition::IntegrationTime`] — when both are set
/// on the same subtree the BUDGET wins (it's the more specific constraint).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IntegrationBudget {
    /// Total wall-clock integration cap across all filters (seconds).
    /// `0.0` means "no overall cap"; only `per_filter` entries apply.
    #[serde(default)]
    pub total_secs: f64,
    /// Per-filter budgets. Filter name -> entry. Empty map means
    /// "only `total_secs` applies" (no per-filter caps).
    #[serde(default)]
    pub per_filter: HashMap<String, FilterBudgetEntry>,
    /// When the budget is hit, the TargetHeader returns Success and the
    /// executor advances to the next sibling. Default true. When false,
    /// the budget is purely informational (UI surfaces progress but
    /// does not gate execution).
    #[serde(default = "default_stop_on_budget_met")]
    pub stop_on_budget_met: bool,
}

fn default_stop_on_budget_met() -> bool {
    true
}

impl Default for IntegrationBudget {
    fn default() -> Self {
        Self {
            total_secs: 0.0,
            per_filter: HashMap::new(),
            stop_on_budget_met: default_stop_on_budget_met(),
        }
    }
}

/// One entry in [`IntegrationBudget::per_filter`].
///
/// `#[serde(tag = "kind", content = "value")]` keeps the JSON shape
/// `{"kind":"Absolute","value":3600.0}` / `{"kind":"Ratio","value":4.0}` so
/// the Dart side can round-trip without a custom deserializer.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", content = "value")]
pub enum FilterBudgetEntry {
    /// Absolute time in this filter (seconds).
    Absolute(f64),
    /// Ratio relative to other filters in the same target. Normalised at
    /// runtime: each ratio gets `(ratio / sum_of_ratios) * total_secs`.
    Ratio(f64),
    /// Count-based completion: "N accepted frames of `sub_secs` each" — the
    /// NINA Target Scheduler model ("60 x Ha 300s until N accepted"). The
    /// budget registry credits ACCEPTED-frame exposure time only (rejected
    /// subs are subtracted upstream in the expose instruction), so the
    /// equivalent integration cap is `desired_accepted * sub_secs`: once the
    /// accumulated accepted-seconds for the filter reach that product, the
    /// filter has its N accepted subs. Resolving Count to a time cap lets the
    /// existing time-based [`crate::scheduling::BudgetState::is_met`] machinery
    /// enforce count completion without a parallel counter, and the
    /// per-filter accepted-seconds persist across pause/resume and (via the
    /// session-handoff carry-over seeding) across nights.
    Count {
        /// Number of ACCEPTED subs required for this filter.
        desired_accepted: u32,
        /// Per-sub exposure length (seconds). Must equal the exposure
        /// node's `duration_secs` for this filter so the seconds→count
        /// mapping is exact.
        sub_secs: f64,
    },
}

impl IntegrationBudget {
    /// Resolve the absolute per-filter cap (seconds) for a single filter
    /// given the budget's totals and ratio entries. Returns `None` when
    /// the filter has no entry AND no overall total applies to it. This
    /// is the single source of truth — both the runtime and the
    /// dry-run preview UI must read from here.
    pub fn resolved_filter_cap(&self, filter: &str) -> Option<f64> {
        match self.per_filter.get(filter) {
            Some(FilterBudgetEntry::Absolute(secs)) if *secs > 0.0 => Some(*secs),
            // Count → equivalent accepted-integration time cap. Requires a
            // positive frame count AND a positive per-sub length; either at
            // zero means "no cap" (fail closed — the validator surfaces a
            // misconfigured Count entry).
            Some(FilterBudgetEntry::Count {
                desired_accepted,
                sub_secs,
            }) if *desired_accepted > 0 && *sub_secs > 0.0 => {
                Some(f64::from(*desired_accepted) * *sub_secs)
            }
            Some(FilterBudgetEntry::Ratio(r)) if *r > 0.0 => {
                let total = self.total_secs;
                if total <= 0.0 {
                    // Ratio entries without a total can't be turned into
                    // absolute caps. The validator rules surface this as
                    // an error; here we fail closed.
                    None
                } else {
                    let sum: f64 = self
                        .per_filter
                        .values()
                        .filter_map(|e| match e {
                            FilterBudgetEntry::Ratio(r) if *r > 0.0 => Some(*r),
                            _ => None,
                        })
                        .sum();
                    if sum <= 0.0 {
                        None
                    } else {
                        Some((*r / sum) * total)
                    }
                }
            }
            // `Absolute(0.0)`, `Ratio(0.0)`, `Count` with a zero count or
            // zero sub length, missing entry: no cap.
            _ => None,
        }
    }

    /// Resolved absolute caps for every filter mentioned in `per_filter`,
    /// keyed by filter name. Filters with `None` cap are omitted.
    pub fn resolved_caps(&self) -> HashMap<String, f64> {
        self.per_filter
            .keys()
            .filter_map(|f| self.resolved_filter_cap(f).map(|cap| (f.clone(), cap)))
            .collect()
    }

    /// True iff the budget is meaningful (at least one cap that can ever
    /// fire). Used by [`TargetHeaderConfig::integration_budget`] to
    /// suppress no-op budget UI/runtime work.
    pub fn is_active(&self) -> bool {
        self.total_secs > 0.0
            || self.per_filter.values().any(|e| match e {
                FilterBudgetEntry::Absolute(s) => *s > 0.0,
                FilterBudgetEntry::Ratio(r) => *r > 0.0,
                FilterBudgetEntry::Count {
                    desired_accepted,
                    sub_secs,
                } => *desired_accepted > 0 && *sub_secs > 0.0,
            })
    }
}

impl TargetHeaderConfig {
    /// Check if this target has time constraints
    pub fn has_time_constraints(&self) -> bool {
        self.start_after.is_some() || self.end_before.is_some()
    }

    /// Check if this target has altitude constraints
    pub fn has_altitude_constraints(&self) -> bool {
        self.min_altitude.is_some() || self.max_altitude.is_some()
    }

    /// Get display name including mosaic panel info if applicable
    pub fn display_name(&self) -> String {
        if let Some(ref panel) = self.mosaic_panel {
            format!("{} ({})", self.target_name, panel.display_label())
        } else {
            self.target_name.clone()
        }
    }

    /// explicit accessor so Smart Exposure
    /// and Target Scheduler can read the budget without
    /// coupling to the field layout. Returns `None` when no budget is
    /// configured or when the budget is structurally inactive
    /// (every cap is zero).
    pub fn integration_budget(&self) -> Option<&IntegrationBudget> {
        self.integration_budget.as_ref().filter(|b| b.is_active())
    }

    /// effective start-when trigger for this target.
    ///
    /// Returns:
    /// * `Some(start_when)` if the user explicitly set one — the explicit
    ///   field wins over any legacy fields.
    /// * Otherwise, synthesises a trigger from the legacy
    ///   `start_after` / `min_altitude` fields via
    ///   [`crate::scheduling::legacy_to_triggers`].
    /// * `None` when both the explicit and legacy slots are empty —
    ///   "no start gate".
    pub fn effective_start_when(&self) -> Option<crate::scheduling::TargetTrigger> {
        if self.start_when.is_some() {
            return self.start_when.clone();
        }
        crate::scheduling::legacy_to_triggers(
            self.start_after,
            self.end_before,
            self.min_altitude,
            self.max_altitude,
        )
        .0
    }

    /// effective end-when trigger. Same precedence as
    /// [`Self::effective_start_when`].
    pub fn effective_end_when(&self) -> Option<crate::scheduling::TargetTrigger> {
        if self.end_when.is_some() {
            return self.end_when.clone();
        }
        crate::scheduling::legacy_to_triggers(
            self.start_after,
            self.end_before,
            self.min_altitude,
            self.max_altitude,
        )
        .1
    }

    /// poll interval (seconds) honouring zero / pathological
    /// inputs by clamping to at least 1s.
    pub fn effective_poll_interval_secs(&self) -> u32 {
        self.trigger_poll_interval_secs.max(1)
    }
}

/// Legacy type alias for backward compatibility
pub type TargetGroupConfig = TargetHeaderConfig;

// Priority 2: Advanced Features Configuration

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MosaicConfig {
    pub center_ra: f64,
    pub center_dec: f64,
    pub panel_width_arcmin: f64,
    pub panel_height_arcmin: f64,
    pub overlap_percent: f64,
    pub rotation: f64,
    pub panels_horizontal: u32,
    pub panels_vertical: u32,
    #[serde(default = "default_mosaic_panel_overhead_secs")]
    pub panel_overhead_secs: f64,
}

impl Default for MosaicConfig {
    fn default() -> Self {
        Self {
            center_ra: 0.0,
            center_dec: 0.0,
            panel_width_arcmin: 60.0,
            panel_height_arcmin: 40.0,
            overlap_percent: 10.0,
            rotation: 0.0,
            panels_horizontal: 3,
            panels_vertical: 3,
            panel_overhead_secs: default_mosaic_panel_overhead_secs(),
        }
    }
}

fn default_mosaic_panel_overhead_secs() -> f64 {
    60.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlatWizardConfig {
    /// Target ADU value for flats
    pub target_adu: u16,
    /// Minimum exposure time to try (seconds)
    pub min_exposure: f64,
    /// Maximum exposure time to try (seconds)
    pub max_exposure: f64,
    /// ADU tolerance percentage (default: 5%)
    pub tolerance_percent: f64,
    /// Where flats are taken from (panel, dawn sky, dusk sky)
    pub panel_location: PanelLocation,
    /// Filter to use (optional)
    pub filter: Option<String>,
    /// Filter position (0-based index). When specified, used instead of filter name.
    #[serde(default)]
    pub filter_index: Option<i32>,
    /// Initial brightness for flat panel (0-255, ignored for sky flats)
    #[serde(default = "default_brightness")]
    pub brightness: i32,
    /// Whether to auto-adjust brightness if target ADU can't be reached
    #[serde(default)]
    pub auto_adjust_brightness: bool,
    /// Minimum brightness to try when auto-adjusting
    #[serde(default = "default_min_brightness")]
    pub min_brightness: i32,
    /// Maximum brightness to try when auto-adjusting
    #[serde(default = "default_max_brightness")]
    pub max_brightness: i32,
    /// Number of flat frames the wizard captures and saves after finding optimal exposure
    #[serde(default = "default_flat_count")]
    pub flat_count: u32,
}

fn default_brightness() -> i32 {
    128
}
fn default_min_brightness() -> i32 {
    10
}
fn default_max_brightness() -> i32 {
    255
}
fn default_flat_count() -> u32 {
    30
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PanelLocation {
    DawnSky,
    DuskSky,
    FlatPanel,
}

impl Default for FlatWizardConfig {
    fn default() -> Self {
        Self {
            target_adu: 32000,
            min_exposure: 0.001,
            max_exposure: 10.0,
            tolerance_percent: 5.0,
            panel_location: PanelLocation::DuskSky,
            filter: None,
            filter_index: None,
            brightness: 128,
            auto_adjust_brightness: false,
            min_brightness: 10,
            max_brightness: 255,
            flat_count: default_flat_count(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExposureTrigger {
    pub condition: TriggerCondition,
    pub action: TriggerAction,
    pub debounce_secs: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TriggerCondition {
    GuidingRmsAbove(f64),
    HfrAbove(f64),
    DriftAbove { ra_px: f64, dec_px: f64 },
}

/// What an exposure trigger does when its condition holds after a burst.
///
/// HFR, guiding RMS and drift are the software's judgment of the frames, and
/// that judgment can be wrong, so the action the node editor gives a new
/// trigger is `Notify` (owner decision 2026-10-06: only a risk to the hardware
/// stops a run by itself). `PauseAndRecalibrate` and `Abort` stay for the
/// operator who picks them.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TriggerAction {
    /// Hold the run until the operator resumes it.
    PauseAndRecalibrate,
    Autofocus,
    /// End the run.
    Abort,
    /// Tell the operator once per episode (the first burst the condition
    /// holds after one where it did not) and keep imaging.
    Notify,
}

// Existing Configurations

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoopConfig {
    pub iterations: Option<u32>,
    pub condition: LoopCondition,
    pub condition_value: Option<f64>,
    /// Optional per-azimuth local-horizon mask (trees, roofline, buildings).
    ///
    /// When present and the condition is [`LoopCondition::AltitudeAbove`] /
    /// [`LoopCondition::AltitudeBelow`], the flat `condition_value` altitude
    /// floor is replaced by the horizon's altitude at the target's *current*
    /// azimuth (whichever is higher). This makes
    /// "loop until the target rises above the local horizon at its current
    /// azimuth" work behind a tree/roofline instead of a single flat floor.
    ///
    /// Crosses the FFI boundary inside the node-definition JSON string (the
    /// node config is serialized to JSON in the bridge and deserialized back
    /// here), so this field needs no FRB regen. `#[serde(default)]` keeps
    /// legacy sequence files — which omit it — deserializing to `None`, which
    /// preserves the prior flat-floor-only behaviour.
    #[serde(default)]
    pub horizon_profile: Option<crate::scheduling::HorizonProfile>,
}

impl Default for LoopConfig {
    fn default() -> Self {
        Self {
            iterations: Some(1),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ParallelConfig {
    pub required_successes: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConditionalConfig {
    pub condition: ConditionalCheck,
    /// Target a specific safety monitor when the condition is
    /// [`ConditionalCheck::SafetyMonitorSafe`]. `None` falls back to the
    /// profile-default / aggregated safety monitor (current behaviour for
    /// single-monitor setups). When set, the value is passed through to
    /// [`crate::device_ops::DeviceOps::safety_is_safe`] as
    /// `Some(safety_id)` so multi-safety-monitor configurations can wire a
    /// conditional branch to one specific device. Ignored for any other
    /// `ConditionalCheck` variant.
    #[serde(default)]
    pub safety_monitor_id: Option<String>,
}

impl Default for ConditionalConfig {
    fn default() -> Self {
        Self {
            condition: ConditionalCheck::Always,
            safety_monitor_id: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryConfig {
    pub trigger: Option<TriggerType>,
    pub recovery_action: RecoveryAction,
    pub max_retries: u32,
}

impl Default for RecoveryConfig {
    fn default() -> Self {
        Self {
            trigger: None,
            recovery_action: RecoveryAction::default(),
            max_retries: 3,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlewConfig {
    pub use_target_coords: bool,
    pub custom_ra: Option<f64>,
    pub custom_dec: Option<f64>,
}

impl Default for SlewConfig {
    fn default() -> Self {
        Self {
            use_target_coords: true,
            custom_ra: None,
            custom_dec: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CenterConfig {
    pub use_target_coords: bool,
    pub custom_ra: Option<f64>,
    pub custom_dec: Option<f64>,
    pub accuracy_arcsec: f64,
    pub max_attempts: u32,
    pub exposure_duration: f64,
    pub filter: Option<String>,
}

impl Default for CenterConfig {
    fn default() -> Self {
        Self {
            use_target_coords: true,
            custom_ra: None,
            custom_dec: None,
            accuracy_arcsec: 5.0,
            max_attempts: 5,
            exposure_duration: 5.0,
            filter: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExposureConfig {
    pub duration_secs: f64,
    pub count: u32,
    pub filter: Option<String>,
    /// Filter position (0-based index). When specified, this is used instead of filter name
    /// for more reliable filter changes that don't depend on name matching.
    #[serde(default)]
    pub filter_index: Option<i32>,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub binning: Binning,
    pub dither_every: Option<u32>,
    #[serde(default = "default_dither_pixels")]
    pub dither_pixels: f64,
    #[serde(default = "default_dither_settle_pixels")]
    pub dither_settle_pixels: f64,
    #[serde(default = "default_dither_settle_time")]
    pub dither_settle_time: f64,
    #[serde(default = "default_dither_settle_timeout")]
    pub dither_settle_timeout: f64,
    #[serde(default)]
    pub dither_ra_only: bool,
    pub save_to: Option<String>,
    #[serde(default)]
    pub triggers: Vec<ExposureTrigger>,
    /// Image Grading: per-node image-quality thresholds. When
    /// `None`, the executor falls back to the global grading settings
    /// installed in the runtime config (`RuntimeConfig::default_quality_check`).
    /// `#[serde(default)]` keeps old sequence JSON loadable.
    #[serde(default)]
    pub quality_check: Option<crate::quality::ImageQualityCheck>,
    /// sky-brightness adaptive exposure config. When
    /// `Some(...)`, the executor consults the live sky-brightness
    /// reading at capture time and may extend (or shrink) the burst's
    /// per-frame duration to keep SNR roughly constant across changing
    /// sky conditions. `None` falls back to the runtime default
    /// (`RuntimeConfig::default_adaptive_exposure`) and finally to using
    /// `duration_secs` as-is. `#[serde(default)]` keeps old JSON
    /// loadable without an adaptive section.
    #[serde(default)]
    pub adaptive_exposure: Option<crate::scheduling::AdaptiveExposureConfig>,
    /// FITS `IMAGETYP`-style frame type for every frame this node captures:
    /// "Light" | "Dark" | "Flat" | "Bias" | "DarkFlat" | "Snapshot".
    /// Drives the saved FITS header, and gates star-based quality grading
    /// and in-burst dithering (both light-frame-only). `#[serde(default)]`
    /// keeps old sequence JSON (which omitted the key and was implicitly
    /// all-lights) loadable.
    #[serde(default = "default_frame_type")]
    pub frame_type: String,
}

fn default_frame_type() -> String {
    "Light".to_string()
}

impl Default for ExposureConfig {
    fn default() -> Self {
        Self {
            duration_secs: 60.0,
            count: 10,
            filter: None,
            filter_index: None,
            gain: None,
            offset: None,
            binning: Binning::One,
            dither_every: Some(1),
            dither_pixels: default_dither_pixels(),
            dither_settle_pixels: default_dither_settle_pixels(),
            dither_settle_time: default_dither_settle_time(),
            dither_settle_timeout: default_dither_settle_timeout(),
            dither_ra_only: false,
            save_to: None,
            triggers: Vec::new(),
            quality_check: None,
            adaptive_exposure: None,
            frame_type: default_frame_type(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum Binning {
    #[default]
    One,
    Two,
    Three,
    Four,
}

impl Binning {
    pub fn as_str(&self) -> &'static str {
        match self {
            Binning::One => "1x1",
            Binning::Two => "2x2",
            Binning::Three => "3x3",
            Binning::Four => "4x4",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutofocusFilterConfig {
    /// Exposure override when this imaging filter is active.
    #[serde(default)]
    pub af_exposure_time: Option<f64>,
    /// Autofocus filter override when this imaging filter is active.
    #[serde(default)]
    pub af_filter_name: Option<String>,
    #[serde(default)]
    pub binning: Binning,
    #[serde(default)]
    pub gain: Option<i32>,
    #[serde(default)]
    pub offset: Option<i32>,
}

impl Default for AutofocusFilterConfig {
    fn default() -> Self {
        Self {
            af_exposure_time: None,
            af_filter_name: None,
            binning: Binning::One,
            gain: None,
            offset: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutofocusConfig {
    #[serde(default)]
    pub method: AutofocusMethod,
    #[serde(default = "default_af_step_size")]
    pub step_size: i32,
    #[serde(default = "default_af_steps_out")]
    pub steps_out: u32,
    #[serde(default = "default_af_exposure_duration")]
    pub exposure_duration: f64,
    #[serde(default)]
    pub filter: Option<String>,
    /// Runtime overrides keyed by the imaging filter active when AF begins.
    #[serde(default)]
    pub filter_settings: std::collections::HashMap<String, AutofocusFilterConfig>,
    /// Optional camera gain override. None preserves the camera's current value.
    #[serde(default)]
    pub gain: Option<i32>,
    /// Optional camera offset override. None preserves the camera's current value.
    #[serde(default)]
    pub offset: Option<i32>,
    #[serde(default)]
    pub binning: Binning,
    /// Backlash compensation in focuser steps, as the OPERATOR entered it.
    /// Zero means they have not entered one.
    #[serde(default = "default_af_backlash_compensation")]
    pub backlash_compensation: i32,
    /// Backlash this app measured on the focuser this run is about to drive,
    /// from a stored per-focuser calibration. `None` when that focuser has
    /// never been calibrated.
    ///
    /// This never overrides [`AutofocusConfig::backlash_compensation`]: a
    /// figure the operator typed outranks one we measured. It only sizes the
    /// final run-up when they have left theirs at the shipped 0, which is the
    /// case this exists for.
    #[serde(default)]
    pub measured_backlash_in: Option<i32>,
    /// Whether the autofocus engine may use temperature prediction.
    #[serde(default = "default_af_use_temperature_prediction")]
    pub use_temperature_prediction: bool,
    /// Reject autofocus points when star count changes beyond this fraction.
    #[serde(default = "default_af_max_star_count_change")]
    pub max_star_count_change: Option<f64>,
    /// Sigma threshold for autofocus outlier rejection. Use 0 to disable.
    #[serde(default = "default_af_outlier_rejection_sigma")]
    pub outlier_rejection_sigma: f64,
    /// Maximum duration in seconds before the autofocus run is aborted.
    /// Default 600s (10 minutes).
    #[serde(default = "default_af_max_duration")]
    pub max_duration_secs: f64,
    /// Minimum number of stars per V-curve frame for the result to count as
    /// a valid sample. Frames with fewer stars are rejected;
    /// if more than half the frames are rejected the autofocus run fails.
    /// Default 10 — matches the previous hardcoded `MIN_STAR_COUNT` constant.
    #[serde(default = "default_af_min_star_count")]
    pub min_star_count: u32,
    /// Full-sweep attempts before reporting failure.
    #[serde(default = "default_af_number_of_attempts")]
    pub number_of_attempts: u32,
    /// Frames measured and median-combined at each focus position.
    #[serde(default = "default_af_exposures_per_point")]
    pub exposures_per_point: u32,
    /// Minimum acceptable curve-fit R².
    #[serde(default = "default_af_r_squared_threshold")]
    pub r_squared_threshold: f64,
    /// Central image fraction retained for star measurement (0, 1].
    #[serde(default = "default_af_outer_crop_ratio")]
    pub outer_crop_ratio: f64,
    /// Central image fraction excluded from star measurement [0, outer).
    #[serde(default)]
    pub inner_crop_ratio: f64,
    /// Brightest stars used for HFR; zero means all eligible stars. On by
    /// default (10): see [`default_af_use_brightest_n_stars`].
    #[serde(default = "default_af_use_brightest_n_stars")]
    pub use_brightest_n_stars: u32,
    /// Extra mechanical settle after the driver first reports idle.
    #[serde(default = "default_af_focuser_settle_time_ms")]
    pub focuser_settle_time_ms: u64,
    /// Outward-direction backlash compensation in focuser steps.
    #[serde(default)]
    pub backlash_out_compensation: i32,
    /// Pause an active guider for the complete filter-switch + focus run.
    #[serde(default)]
    pub disable_guiding_during_af: bool,
    /// How far above the reference HFR the frames may sit, as a multiple, and
    /// still be called usable after autofocus has failed.
    ///
    /// A failed autofocus never parks the mount or ends the run (owner decision
    /// 2026-10-06: "Failed AF should never park the rig, just notify the
    /// user"). The focuser goes back to where it started, the operator is
    /// notified, and imaging carries on at that focus. This ratio only decides
    /// what the notice says: at 1.6, a run whose reference HFR is 2.5 is told
    /// its frames at 3.8 (1.52x) are slightly soft, and at 10 (4x) that they
    /// are past the limit and focus needs checking. It is a ratio rather than
    /// an absolute HFR because the same number means different things at
    /// different focal lengths and pixel scales.
    ///
    /// Autofocus also borrows it as the landing tolerance (see
    /// `instructions::autofocus`), falling back to the shipped ratio when it is
    /// at or below 1.
    ///
    /// A profile saved before the decision may still carry a `failure_action`
    /// key next to this one (`AbortAndPark` or `PauseAndAlert`). Unknown keys
    /// are ignored when the config is read, so that stored value has nothing
    /// left to select.
    #[serde(default = "default_af_failure_hfr_tolerance_ratio")]
    pub failure_hfr_tolerance_ratio: f64,
}

fn default_af_failure_hfr_tolerance_ratio() -> f64 {
    1.6
}

fn default_af_max_duration() -> f64 {
    600.0
}

fn default_af_step_size() -> i32 {
    100
}

fn default_af_steps_out() -> u32 {
    7
}

fn default_af_exposure_duration() -> f64 {
    3.0
}

/// Backlash is a property of the operator's focuser, not something this
/// app can know. Shipping a guess moves their drawtube by that guess on the
/// first autofocus; zero means the compensation stays off until it is
/// measured and entered.
fn default_af_backlash_compensation() -> i32 {
    0
}

fn default_af_use_temperature_prediction() -> bool {
    true
}

fn default_af_max_star_count_change() -> Option<f64> {
    Some(0.5)
}

fn default_af_outlier_rejection_sigma() -> f64 {
    3.0
}

fn default_af_min_star_count() -> u32 {
    10
}

fn default_af_number_of_attempts() -> u32 {
    // Two sweeps, not one. A single failed sweep is weak evidence — the
    // common causes (a passing cloud, a gust, a sparse field) are transient
    // and a second sweep usually succeeds before the operator is told that
    // autofocus failed.
    2
}

fn default_af_exposures_per_point() -> u32 {
    1
}

fn default_af_r_squared_threshold() -> f64 {
    0.7
}

/// Star selection on, measuring the brightest 10 stars (owner, 2026-10-06:
/// "Autofocus star selection should be on"). Counting every detection lets
/// faint, noisy sources dominate the mean: the in-focus rig frame of
/// 2026-09-14 (2.12 px by an independent PSF fit) reads 13.8 px over every
/// star and 3.2 px over its brightest 10, which is what the rig ran with. A
/// stored value, zero included, still wins.
pub(crate) fn default_af_use_brightest_n_stars() -> u32 {
    10
}

fn default_af_outer_crop_ratio() -> f64 {
    1.0
}

fn default_af_focuser_settle_time_ms() -> u64 {
    500
}

impl Default for AutofocusConfig {
    fn default() -> Self {
        Self {
            method: AutofocusMethod::VCurve,
            step_size: default_af_step_size(),
            steps_out: default_af_steps_out(),
            exposure_duration: default_af_exposure_duration(),
            filter: None,
            filter_settings: std::collections::HashMap::new(),
            gain: None,
            offset: None,
            binning: Binning::One,
            backlash_compensation: default_af_backlash_compensation(),
            measured_backlash_in: None,
            use_temperature_prediction: default_af_use_temperature_prediction(),
            max_star_count_change: default_af_max_star_count_change(),
            outlier_rejection_sigma: default_af_outlier_rejection_sigma(),
            max_duration_secs: default_af_max_duration(),
            min_star_count: default_af_min_star_count(),
            number_of_attempts: default_af_number_of_attempts(),
            exposures_per_point: default_af_exposures_per_point(),
            r_squared_threshold: default_af_r_squared_threshold(),
            outer_crop_ratio: default_af_outer_crop_ratio(),
            inner_crop_ratio: 0.0,
            use_brightest_n_stars: default_af_use_brightest_n_stars(),
            focuser_settle_time_ms: default_af_focuser_settle_time_ms(),
            backlash_out_compensation: 0,
            disable_guiding_during_af: false,
            failure_hfr_tolerance_ratio: default_af_failure_hfr_tolerance_ratio(),
        }
    }
}

impl From<&AutofocusConfig> for crate::autofocus::AutofocusConfig {
    fn from(config: &AutofocusConfig) -> Self {
        Self {
            method: config.method.into(),
            step_size: config.step_size,
            steps_out: config.steps_out,
            exposure_duration: config.exposure_duration,
            backlash_compensation: config.backlash_compensation,
            backlash_out_compensation: config.backlash_out_compensation,
            use_temperature_prediction: config.use_temperature_prediction,
            max_star_count_change: config.max_star_count_change,
            outlier_rejection_sigma: config.outlier_rejection_sigma,
            max_duration_secs: config.max_duration_secs,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum AutofocusMethod {
    #[default]
    VCurve,
    Quadratic,
    Hyperbolic,
}

/// The wire enum and the curve-fitting engine's enum are deliberately
/// separate types — one is a serde contract with Dart, the other is internal
/// to [`crate::autofocus`] — so the crossing is spelled out once, here.
impl From<AutofocusMethod> for crate::autofocus::AutofocusMethod {
    fn from(method: AutofocusMethod) -> Self {
        match method {
            AutofocusMethod::VCurve => Self::VCurve,
            AutofocusMethod::Quadratic => Self::Quadratic,
            AutofocusMethod::Hyperbolic => Self::Hyperbolic,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum DitherPattern {
    /// Random offsets (classic dither)
    #[default]
    Random,
    /// Walk through an NxN grid, cycling back to start after all positions visited
    Grid,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DitherConfig {
    pub pixels: f64,
    pub settle_pixels: f64,
    pub settle_time: f64,
    pub settle_timeout: f64,
    pub ra_only: bool,
    /// Dither pattern: Random (classic) or Grid (systematic NxN walk)
    #[serde(default)]
    pub pattern: DitherPattern,
    /// Grid size N for Grid pattern (NxN grid). Ignored for Random pattern.
    /// Default is 3 (3x3 = 9 positions).
    #[serde(default = "default_grid_size")]
    pub grid_size: u32,
}

fn default_grid_size() -> u32 {
    3
}

impl Default for DitherConfig {
    fn default() -> Self {
        Self {
            pixels: default_dither_pixels(),
            settle_pixels: default_dither_settle_pixels(),
            settle_time: default_dither_settle_time(),
            settle_timeout: default_dither_settle_timeout(),
            ra_only: false,
            pattern: DitherPattern::default(),
            grid_size: default_grid_size(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartGuidingConfig {
    /// Settle threshold in pixels
    pub settle_pixels: f64,
    /// Time to remain settled (seconds)
    pub settle_time: f64,
    /// Maximum time to wait for settling (seconds)
    pub settle_timeout: f64,
    /// Whether to auto-select a guide star if none selected
    pub auto_select_star: bool,
    /// Maximum allowable deviation of
    /// `|ra_angle - dec_angle|` from 90° before we fail the StartGuiding
    /// instruction. A wildly off-perpendicular calibration is a strong
    /// signal that the mount pulse responses were wrong (mirror flip,
    /// wrong direction wiring, etc.) and that the night's guiding will
    /// drift instead of correct.
    #[serde(default = "default_max_cal_axis_error_deg")]
    pub max_calibration_axis_error_deg: f64,
    /// Ceiling on guiding RMS sampled over the post-settle window.
    /// Defaults to 3.0 pixels — well above any reasonable rig but low
    /// enough to catch outright broken calibrations that nevertheless
    /// passed settle (e.g. settle_pixels was set permissively high).
    #[serde(default = "default_max_post_settle_rms_pixels")]
    pub max_post_settle_rms_pixels: f64,
    /// Allow the user to skip post-start validation if needed (legacy
    /// drivers that don't report calibration angles, for example).
    /// Default `true`: validation always runs.
    #[serde(default = "default_validate_calibration")]
    pub validate_calibration: bool,
}

fn default_max_cal_axis_error_deg() -> f64 {
    20.0
}

fn default_max_post_settle_rms_pixels() -> f64 {
    3.0
}

fn default_validate_calibration() -> bool {
    true
}

impl Default for StartGuidingConfig {
    fn default() -> Self {
        Self {
            settle_pixels: 1.5,
            settle_time: 10.0,
            settle_timeout: 60.0,
            auto_select_star: true,
            max_calibration_axis_error_deg: default_max_cal_axis_error_deg(),
            max_post_settle_rms_pixels: default_max_post_settle_rms_pixels(),
            validate_calibration: default_validate_calibration(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FilterConfig {
    pub filter_name: String,
    pub filter_index: Option<i32>,
    /// Timeout in seconds for filter wheel change operation.
    /// If None, uses default of 120 seconds.
    /// Some filter wheels (especially those with many positions or motorized covers)
    /// may require longer timeouts.
    #[serde(default)]
    pub timeout_secs: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoolConfig {
    pub target_temp: f64,
    pub duration_mins: Option<f64>,
}

impl Default for CoolConfig {
    fn default() -> Self {
        Self {
            target_temp: -10.0,
            duration_mins: Some(10.0),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WarmConfig {
    pub rate_per_min: f64,
    #[serde(default)]
    pub target_temp: Option<f64>,
}

impl Default for WarmConfig {
    fn default() -> Self {
        Self {
            rate_per_min: 2.0,
            target_temp: None,
        }
    }
}

const fn default_dither_pixels() -> f64 {
    5.0
}

const fn default_dither_settle_pixels() -> f64 {
    1.5
}

const fn default_dither_settle_time() -> f64 {
    30.0
}

const fn default_dither_settle_timeout() -> f64 {
    120.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RotatorConfig {
    pub target_angle: f64,
    pub relative: bool,
}

impl Default for RotatorConfig {
    fn default() -> Self {
        Self {
            target_angle: 0.0,
            relative: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WaitTimeConfig {
    pub wait_until: Option<i64>, // Unix timestamp
    pub wait_for_twilight: Option<TwilightType>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum TwilightType {
    Civil,
    Nautical,
    Astronomical,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DelayConfig {
    pub seconds: f64,
}

impl Default for DelayConfig {
    fn default() -> Self {
        Self { seconds: 5.0 }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NotificationConfig {
    pub title: String,
    pub message: String,
    pub level: NotificationLevel,
    /// per-node override list of NotificationTransportKind
    /// names (Dart-side enum, serialised as string). When set, the Dart
    /// NotificationRouter dispatches via these transports instead of the
    /// matrix's `custom` rule. `None` (or empty) = inherit matrix routing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub explicit_transports: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum NotificationLevel {
    #[default]
    Info,
    Warning,
    Error,
    Success,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ScriptConfig {
    pub script_path: String,
    pub arguments: Vec<String>,
    pub timeout_secs: Option<u32>,
}

/// Method to determine when meridian flip should trigger
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq)]
pub enum MeridianTriggerMethod {
    #[default]
    MinutesPastMeridian,
    MinutesBeforeLimit,
    HourAngleThreshold,
    /// Flip when mount stops tracking due to hitting its custom tracking limits.
    /// Uses a heuristic (connected, not slewing/parked, pre-flip pier side, HA > 0)
    /// to distinguish limit hits from actual errors.
    OnTrackingLimitHit,
}

/// Action when flip fails after all retries
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq)]
pub enum FlipFailureAction {
    #[default]
    PauseAndAlert,
    AbortAndPark,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeridianFlipConfig {
    // Trigger conditions
    pub trigger_method: MeridianTriggerMethod,
    pub minutes_past_meridian: f64,
    pub minutes_before_limit: f64,
    pub hour_angle_threshold: f64,
    /// Minutes to wait after tracking limit is detected before flipping (0 = immediate).
    /// Only used with OnTrackingLimitHit trigger method.
    #[serde(default)]
    pub tracking_limit_wait_minutes: f64,

    // Flip sequence options
    pub pause_guiding: bool,
    pub auto_center: bool,
    pub refocus_after: bool,
    pub settle_time: f64,
    pub resume_guiding: bool,

    // Error handling
    pub max_retries: u32,
    pub retry_delays_secs: Vec<f64>,
    pub failure_action: FlipFailureAction,

    /// Minimum altitude (degrees) the target must be at, after the flip, for
    /// the executor to proceed. Below ~10° atmospheric refraction makes
    /// plate-solve unreliable and most amateur mounts approach their lower
    /// limit.
    #[serde(default = "default_min_post_flip_altitude_deg")]
    pub min_post_flip_altitude_deg: f64,

    /// Tolerance (degrees) for the RA/Dec coordinate-fallback pier-side
    /// verification used when the mount does not report pier side natively.
    /// Defaults to 1 arcminute.
    #[serde(default = "default_flip_coordinate_tolerance_deg")]
    pub flip_coordinate_tolerance_deg: f64,

    /// How many times to retry mount park / abort-slew / set-tracking calls
    /// inside `execute_failure_action` before giving up.
    #[serde(default = "default_safety_action_retry_count")]
    pub safety_action_retry_count: u32,

    /// Delay (seconds) between safety-action retries.
    #[serde(default = "default_safety_action_retry_delay_secs")]
    pub safety_action_retry_delay_secs: f64,

    // Post-flip guider re-lock settle. These mirror StartGuidingConfig and come
    // from the user's guiding settle settings, so the re-lock is held to the same
    // standard the normal Start Guiding path applies; `#[serde(default)]` keeps
    // previously-saved sequences loading.
    /// Guider settle threshold (pixels) for the post-flip re-lock. Sourced from
    /// the user's guiding settle settings.
    #[serde(default = "default_guider_settle_pixels")]
    pub guider_settle_pixels: f64,

    /// Guider settle stabilisation time (seconds) for the post-flip re-lock —
    /// how long guiding must stay under the threshold.
    #[serde(default = "default_guider_settle_time")]
    pub guider_settle_time: f64,

    /// Guider settle timeout (seconds) for the post-flip re-lock.
    #[serde(default = "default_guider_settle_timeout")]
    pub guider_settle_timeout: f64,

    /// Ceiling on post-settle guiding RMS (pixels) sampled after the re-lock
    /// before declaring guiding good. Mirrors StartGuidingConfig's gate so a
    /// poor post-flip re-lock fails (→ failure_action) instead of resuming
    /// imaging on bad guiding.
    #[serde(default = "default_meridian_max_post_settle_rms_pixels")]
    pub max_post_settle_rms_pixels: f64,
}

// Exposed as `pub(crate)` so executor tests can reference the canonical
// defaults without re-hardcoding them.
pub(crate) fn default_min_post_flip_altitude_deg() -> f64 {
    10.0
}

pub(crate) fn default_flip_coordinate_tolerance_deg() -> f64 {
    1.0 / 60.0
}

pub(crate) fn default_safety_action_retry_count() -> u32 {
    3
}

pub(crate) fn default_safety_action_retry_delay_secs() -> f64 {
    5.0
}

// Post-flip guider re-lock settle defaults. Numeric values match the executor
// constants and StartGuidingConfig's defaults, so a user who does not override
// their guiding settle gets the same behaviour on both paths.
pub(crate) fn default_guider_settle_pixels() -> f64 {
    1.5
}

pub(crate) fn default_guider_settle_time() -> f64 {
    10.0
}

pub(crate) fn default_guider_settle_timeout() -> f64 {
    60.0
}

pub(crate) fn default_meridian_max_post_settle_rms_pixels() -> f64 {
    3.0
}

impl Default for MeridianFlipConfig {
    fn default() -> Self {
        Self {
            trigger_method: MeridianTriggerMethod::MinutesPastMeridian,
            minutes_past_meridian: 5.0,
            minutes_before_limit: 10.0,
            hour_angle_threshold: 0.5,
            tracking_limit_wait_minutes: 0.0,
            pause_guiding: true,
            auto_center: true,
            refocus_after: false,
            settle_time: 10.0,
            resume_guiding: true,
            max_retries: 3,
            retry_delays_secs: vec![30.0, 60.0, 120.0],
            failure_action: FlipFailureAction::PauseAndAlert,
            // These defaults equal StartGuidingConfig's defaults.
            min_post_flip_altitude_deg: default_min_post_flip_altitude_deg(),
            flip_coordinate_tolerance_deg: default_flip_coordinate_tolerance_deg(),
            safety_action_retry_count: default_safety_action_retry_count(),
            safety_action_retry_delay_secs: default_safety_action_retry_delay_secs(),
            guider_settle_pixels: default_guider_settle_pixels(),
            guider_settle_time: default_guider_settle_time(),
            guider_settle_timeout: default_guider_settle_timeout(),
            max_post_settle_rms_pixels: default_meridian_max_post_settle_rms_pixels(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DomeConfig {
    pub shutter_only: bool, // If true, only open/close shutter, don't park/unpark dome
}

/// Cover calibrator configuration (for dust cover / flat panel devices)
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CoverCalibratorConfig {
    /// Timeout in seconds for cover movement (default: 60)
    #[serde(default = "default_cover_timeout")]
    pub timeout_secs: u32,
}

fn default_cover_timeout() -> u32 {
    60
}

/// Calibrator on configuration (for flat panel brightness control)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CalibratorOnConfig {
    /// Brightness level (0-max, typically 0-255)
    pub brightness: i32,
    /// Timeout in seconds for calibrator to reach ready state (default: 30)
    #[serde(default = "default_calibrator_timeout")]
    pub timeout_secs: u32,
}

fn default_calibrator_timeout() -> u32 {
    30
}

impl Default for CalibratorOnConfig {
    fn default() -> Self {
        Self {
            brightness: 128,
            timeout_secs: 30,
        }
    }
}

/// Loop conditions
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum LoopCondition {
    /// Loop N times (use iterations field)
    Count,
    /// Loop until time (condition_value = Unix timestamp)
    UntilTime,
    /// Loop until altitude below threshold (condition_value = altitude degrees)
    AltitudeBelow,
    /// Loop until altitude above threshold (condition_value = altitude degrees)
    AltitudeAbove,
    /// Loop until integration time reached (condition_value = seconds)
    IntegrationTime,
    /// Loop forever (until stopped)
    Forever,
    /// Loop while sky is dark
    WhileDark,
}

/// Conditions for conditional nodes.
///
/// Wire format:
///
/// The Dart sequence executor emits the conditional payload as
/// `{"type": "<Variant>", "value": <data>}` (see
/// `sequence_executor.dart::ConditionalNode` case in the build-payload
/// switch). With the default externally-tagged serde representation the
/// non-unit variants (HfrBelow, GuidingRmsBelow, AltitudeAbove,
/// MoonSeparationAbove, TimeAfter) failed to deserialize at the FFI
/// boundary — Dart sent `{"type":"HfrBelow","value":1.5}` and serde
/// expects `{"HfrBelow":1.5}`, silently breaking every non-`Always`
/// conditional at runtime.
///
/// So `#[serde(tag = "type", content = "value")]` makes the Rust struct match
/// the Dart wire format. Unit variants serialise as
/// `{"type":"Always"}` (the content tag is omitted for unit variants);
/// tuple variants serialise as `{"type":"HfrBelow","value":1.5}`. The
/// `#[serde(default)]` on `ConditionalConfig.safety_monitor_id` is
/// unaffected — it lives on the containing struct.
///
/// All Rust-side construction goes through the typed enum (grep:
/// `ConditionalCheck::`); no JSON literal in the Rust tree depends on the
/// externally-tagged shape outside the unit tests below.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "value")]
pub enum ConditionalCheck {
    /// Always execute
    Always,
    /// Check if altitude is above threshold
    AltitudeAbove(f64),
    /// Check if time is after
    TimeAfter(i64),
    /// Check if guiding RMS is below threshold
    GuidingRmsBelow(f64),
    /// Check if HFR is below threshold
    HfrBelow(f64),
    /// Check if weather is safe
    WeatherSafe,
    /// Check if moon separation is above degrees
    MoonSeparationAbove(f64),
    /// Check if safety monitor is safe
    SafetyMonitorSafe,
}

/// Trigger types that run in parallel
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TriggerType {
    /// Trigger when HFR degrades beyond acceptable limits.
    ///
    /// Two modes of operation:
    /// - **Relative mode** (`threshold_percent`): Triggers when HFR increases by
    ///   more than this percentage above the baseline HFR (set after autofocus).
    /// - **Absolute mode** (`absolute_threshold`): Triggers when HFR exceeds a
    ///   fixed value in arcseconds/pixels, regardless of baseline.
    ///
    /// `consecutive_frames` prevents false positives from momentary seeing spikes
    /// by requiring multiple consecutive frames above the threshold before firing.
    HfrDegraded {
        /// Percentage above baseline HFR that triggers (e.g., 20.0 = 20% above baseline).
        /// Used in relative mode. Set to 0.0 or leave at default to disable relative check.
        threshold_percent: f64,
        /// Absolute HFR threshold in arcseconds/pixels. When current HFR exceeds this
        /// value, the trigger fires regardless of baseline. Set to 0.0 to disable.
        #[serde(default)]
        absolute_threshold: f64,
        /// Number of consecutive frames that must exceed the threshold before triggering.
        /// Prevents false positives from momentary seeing spikes. Default is 1 (trigger immediately).
        #[serde(default = "default_consecutive_frames")]
        consecutive_frames: u32,
    },
    /// Trigger when meridian flip is needed
    MeridianFlip { config: MeridianFlipConfig },
    /// Trigger when guiding fails
    GuidingFailed {
        rms_threshold: f64,
        duration_secs: f64,
        /// how many seconds of guiding-RMS history to retain.
        /// `update_guiding_rms` trims the rolling window to this duration so
        /// older (stale) samples cannot mask a recent spike. Default 300s
        /// (5 minutes) — preserves the previous hardcoded behaviour.
        #[serde(default = "default_guiding_rms_retention_secs")]
        rms_retention_secs: u64,
    },
    /// Trigger when altitude too low
    AltitudeLimit { min_altitude: f64 },
    /// Trigger when weather unsafe
    WeatherUnsafe,
    /// Trigger when temperature changes
    TemperatureShift { degrees: f64 },
    /// Trigger on filter change
    FilterChange,
    /// Trigger when dawn is approaching (astronomical twilight)
    DawnApproaching { minutes_before: f64 },
    /// Trigger autofocus every N exposures
    AutofocusInterval { every_n_frames: u32 },
    /// Trigger dither every N exposures
    DitherInterval { every_n_frames: u32 },
    /// Mount tracking was lost during exposure
    MountTrackingLost,
    /// Dome shutter is not open when expected
    DomeShutterNotOpen,
    /// Guide star lost - guider reports no star or lost lock
    GuideStarLost,
    /// Focus drift detection - monotonically increasing HFR moving average over N frames
    /// Unlike HfrDegraded which catches sudden spikes, this detects gradual drift
    FocusDrift {
        /// Number of HFR samples to track in the moving window
        window_size: usize,
        /// Minimum number of consecutive increases before triggering (must be >= 2)
        min_increasing_count: usize,
        /// Minimum total HFR increase (last - first in the increasing run) to fire
        min_total_increase: f64,
    },
    /// Humidity threshold - fire when humidity exceeds max_percent
    HumidityThreshold {
        /// Maximum humidity percentage before triggering (e.g., 85.0)
        max_percent: f64,
    },
    /// Plate-solve drift trigger. Fires when the most recent
    /// plate-solve reports an accumulated drift from the target exceeding
    /// `max_pixels`. The drift is computed by `TriggerState::calculate_drift_pixels`
    /// using the last plate-solve coordinates, the target coordinates, and the
    /// solver-reported pixel scale; both the RA and Dec axes are summed in
    /// quadrature so a small drift in either axis cannot mask a large drift
    /// in the other. Default standard recovery is `Recenter`.
    DriftLimit {
        /// Maximum drift in pixels before the trigger fires.
        max_pixels: f64,
    },
    /// cloud-motion-aware trigger.
    ///
    /// Fires when the live cloud-motion analyzer predicts that significant
    /// cloud cover will arrive at the user's location within `minutes_before`
    /// minutes AND the predicted coverage exceeds `coverage_threshold` percent.
    /// The novelty over the legacy `WeatherUnsafe` boolean is that this fires
    /// *before* clouds arrive, giving the recovery layer enough lead time to
    /// pause-and-track or slew to a clear gap rather than abort mid-exposure.
    ///
    /// The trigger is fed by Dart's `CloudMotionAnalyzer` (see
    /// `packages/nightshade_core/lib/src/services/weather/cloud_motion_analyzer.dart`)
    /// pushed via `ExecutorCommand::UpdateCloudMotion`. When the analyzer is
    /// unavailable (e.g. no radar fetch yet) the trigger stays quiescent —
    /// `state.predicted_cloud_arrival_minutes` is `None` and the evaluator
    /// returns false.
    CloudArrivingIn {
        /// Fire when arrival time is at or below this many minutes.
        minutes_before: f64,
        /// Only fire when predicted coverage exceeds this percentage (0-100).
        coverage_threshold: f64,
    },
    /// positive cloud-motion trigger.
    ///
    /// Fires when the analyzer predicts a clear opening (gap in the cloud
    /// field) within `minutes_before` minutes whose duration is at least
    /// `minimum_duration_secs`. Used in combination with
    /// `RecoveryAction::PauseAndWaitForClear` so a paused sequence resumes
    /// once the clear window is imminent.
    ///
    /// Edge-triggered: fires once when the predicted opening crosses the
    /// threshold; the cooldown prevents a noisy analyzer from re-firing the
    /// same opening over and over.
    CloudOpeningIn {
        /// Fire when the opening is within this many minutes.
        minutes_before: f64,
        /// Reject openings shorter than this (a 30-second hole in the clouds
        /// is not useful for imaging — the sequence would slew, settle, and
        /// expose into the next cloud cell).
        minimum_duration_secs: f64,
    },
    /// current cloud cover threshold.
    ///
    /// Fires when the live cloud cover (from `CloudMotionAnalyzer` or the
    /// Open-Meteo cloud-cover provider) exceeds `max_percent` for at least
    /// `duration_secs` consecutive seconds. The duration acts as a debounce
    /// so a single noisy reading does not force a recovery.
    CloudCoverThreshold {
        /// Maximum allowed cloud coverage percentage (0-100).
        max_percent: f64,
        /// Required duration (seconds) above the threshold before firing.
        /// Zero is allowed and means "fire immediately on the first sample".
        duration_secs: f64,
    },
    /// Science — transparency-adaptive trigger.
    ///
    /// Fires when the live sky transparency reading (pushed in via
    /// `ExecutorCommand::UpdateTransparency` from the Dart science
    /// pipeline) drops below `below_threshold` (fraction of clear-sky
    /// reference; 1.0 = perfectly clear, 0.0 = totally opaque) for at
    /// least `duration_secs` consecutive seconds. The duration acts as
    /// a debounce so a brief gust of haze does not force a target swap.
    ///
    /// Paired with [`RecoveryAction::SwitchTargetOrFilter`] for the
    /// "swap from RGB faint target to Lum bright backup" workflow
    /// described in the brief.
    TransparencyDropped {
        /// Trip threshold as a fraction of clear-sky reference (0.0..=1.0).
        /// A common operator default is 0.7 — "drop more than 30% from
        /// best".
        below_threshold: f64,
        /// Required duration (seconds) at or below the threshold before
        /// firing. Zero is allowed for tests; production sequences should
        /// use at least 30s to debounce single-frame haze samples.
        duration_secs: f64,
    },
}

fn default_consecutive_frames() -> u32 {
    1
}

/// Default rolling-window length (seconds) for guiding-RMS history retained
/// in `TriggerState::guiding_rms_history`.
pub fn default_guiding_rms_retention_secs() -> u64 {
    300
}

/// Default focus-drift window size (samples) for the standard `FocusDrift`
/// trigger. Named here so config loaders and the standard-trigger builder
/// share the same default.
pub fn default_focus_drift_window_size() -> usize {
    10
}

/// Default minimum-consecutive-increasing-frame count for the standard
/// `FocusDrift` trigger.
pub fn default_focus_drift_min_increasing_count() -> usize {
    5
}

/// Default minimum total HFR increase across the increasing run for the
/// standard `FocusDrift` trigger.
pub fn default_focus_drift_min_total_increase() -> f64 {
    0.5
}

/// Default cadence (frames between autofocus runs) used by
/// the standard `AutofocusInterval` trigger seeded by
/// `TriggerManager::create_standard_triggers`. 25 frames matches a typical
/// "autofocus every ~30 minutes" cadence for 60-90 s sub-exposures. Exposed
/// as a function so config loaders and the builder share the same default
/// — and so the value can be overridden in a downstream profile JSON via
/// the standard `#[serde(default = "...")]` pattern.
pub fn default_autofocus_interval_frames() -> u32 {
    25
}

/// Recovery action to take when a trigger fires or error occurs.
///
/// - `Dither(DitherConfig)` gives the standard `DitherInterval` trigger a real
///   action to run; without it the trigger silently drops into the catch-all
///   match arm.
/// - `CustomBranch` is retained for serialised on-disk compatibility with
///   stored sequences but is rejected as a configuration error at runtime
///   (the executor emits an error event and pauses the sequence) until a
///   child-node recovery branch is wired. Treating it as a no-op is a silent
///   drop — refusing it loudly is the policy.
/// - `Recenter` gives the `DriftLimit` trigger a non-destructive recovery
///   path: re-slew to the target and plate-solve instead of pausing the whole
///   sequence.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub enum RecoveryAction {
    /// Continue execution (ignore error)
    #[default]
    Continue,
    /// Pause the sequence
    Pause,
    /// Run autofocus
    Autofocus,
    /// Skip to next target
    NextTarget,
    /// Retry the failed node
    Retry { max_attempts: u32 },
    /// Park and abort
    ParkAndAbort,
    /// Reserved variant — see the enum-level rustdoc. Stored sequences may
    /// still contain this value, so it must round-trip; the executor refuses
    /// it at runtime instead of silently treating it as a no-op.
    CustomBranch,
    /// Execute meridian flip with given config
    MeridianFlip(MeridianFlipConfig),
    /// Run a dither using the supplied config. Used by the standard
    /// `DitherInterval` trigger so periodic dithering is honoured even when
    /// no explicit Dither instruction node is in the sequence.
    Dither(DitherConfig),
    /// Re-slew to the target and plate-solve. Used by the `DriftLimit` trigger
    /// when accumulated drift exceeds the configured pixel
    /// budget — a recenter is the lowest-risk recovery (no flip, no abort).
    Recenter,
    /// pause the sequence and wait for a cloud-opening
    /// trigger (or operator) to resume. Distinct from generic `Pause` because
    /// the cloud-aware recovery layer keeps polling the analyzer in the
    /// background; when `CloudOpeningIn` fires the executor auto-resumes.
    /// Mounted with `RecoveryCause::WeatherUnsafe` so the Recovery
    /// Mode banner / audible alert fires as well.
    PauseAndWaitForClear,
    /// re-slew to a target in a clear sky direction.
    ///
    /// Uses `ExecutionContext::predicted_clear_sky_direction` (populated by
    /// the most recent `UpdateCloudMotion` command) to choose a (alt, az)
    /// destination. Falls back to `PauseAndWaitForClear` when no clear
    /// direction is reported, rather than silently ignoring the request.
    SlewToGapAndContinue,
    /// Transparency-adaptive sequence swap, paired with
    /// [`TriggerType::TransparencyDropped`]. The runtime reads
    /// `ExecutionContext::transparency_backup_plan` (populated by the Dart layer
    /// at sequence start) and:
    ///   1. If a `backup_filter` is set, issues a single ChangeFilter to
    ///      that filter (the user typically picks Lum/Clear here because
    ///      those bands tolerate haze better than narrowband).
    ///   2. If a `backup_target_id` is set, requests a `skip_to_node` to
    ///      that node id so the executor jumps to a brighter backup
    ///      target's subtree.
    ///   3. If BOTH are set, the filter swap is applied to the new
    ///      target after the skip.
    ///   4. If NEITHER is set (no operator-configured fallback), the
    ///      action falls back to `PauseAndWaitForClear` rather than
    ///      silently no-oping.
    SwitchTargetOrFilter,
}

#[cfg(test)]
mod live_stacking_config_tests {
    use super::LiveStackingConfig;

    /// A legacy persisted blob must still deserialize via serde defaults. This
    /// includes blobs from the brief window when an OSC-capable editor wrote
    /// `sensor_mode` / `bayer_pattern` / `demosaic_quality` keys: now that the
    /// unattended broadcast path does not consume them, those keys are unknown
    /// and must be tolerated (serde ignores unknown fields by default) rather
    /// than failing the load of an existing sequence.
    #[test]
    fn legacy_json_with_unknown_osc_keys_still_deserializes() {
        let json = r#"{
            "mode": "record_and_broadcast",
            "stack_method": "average",
            "max_frames_to_stack": 0,
            "broadcast_enabled": true,
            "broadcast_port": 8081,
            "broadcast_path": "/broadcast",
            "auth_token": null,
            "watermark_text": null,
            "thumbnail_width": 1280,
            "thumbnail_height": 720,
            "sensor_mode": "osc",
            "bayer_pattern": "RGGB",
            "demosaic_quality": "vng"
        }"#;

        let config: LiveStackingConfig = serde_json::from_str(json)
            .expect("legacy config with now-removed OSC keys must still deserialize");
        // The broadcast-relevant fields still load.
        assert_eq!(config.broadcast_port, 8081);
        assert_eq!(config.broadcast_path, "/broadcast");
    }

    /// An empty persisted blob must load entirely via serde defaults.
    #[test]
    fn empty_json_object_deserializes_to_defaults() {
        let config: LiveStackingConfig =
            serde_json::from_str("{}").expect("empty object must deserialize via serde defaults");
        assert_eq!(config, LiveStackingConfig::default());
    }
}

#[cfg(test)]
mod recovery_action_serde_tests {
    use super::{NodeType, RecoveryAction};

    /// `RecoveryAction::Retry` is a STRUCT variant `Retry { max_attempts }`, so
    /// serde's externally-tagged default requires the object form
    /// `{"Retry": {"max_attempts": N}}`. The Dart serialiser
    /// (`serialization_operations.dart` `_recoveryActionToRust`) emits this
    /// shape. This test pins the exact node-level JSON the bridge feeds to
    /// `serde_json::from_str::<NodeType>` (bridge/src/api/sequencer.rs:212) for
    /// a Recovery node whose action is Retry, so a regression that reverts to a
    /// bare `"Retry"` string fails here instead of silently aborting the whole
    /// sequence load with InvalidInput.
    #[test]
    fn recovery_node_with_retry_struct_variant_deserializes() {
        // Mirrors the Dart `_nodeToConfig` Recovery case: internally `type`-
        // tagged NodeType plus flattened RecoveryConfig fields.
        let json = r#"{
            "type": "Recovery",
            "trigger": null,
            "recovery_action": { "Retry": { "max_attempts": 5 } },
            "max_retries": 5
        }"#;

        let node: NodeType = serde_json::from_str(json)
            .expect("Recovery node with struct-variant Retry must deserialize");

        match node {
            NodeType::Recovery(cfg) => match cfg.recovery_action {
                RecoveryAction::Retry { max_attempts } => {
                    assert_eq!(max_attempts, 5, "max_attempts must round-trip");
                }
                other => panic!("expected RecoveryAction::Retry, got {other:?}"),
            },
            other => panic!("expected NodeType::Recovery, got {other:?}"),
        }
    }

    /// Guards the historical bug: a bare `"Retry"` string is rejected by serde
    /// for a struct variant. If this ever starts succeeding, serde's
    /// representation of `RecoveryAction` changed and the Dart serialiser must
    /// be revisited.
    #[test]
    fn bare_retry_string_is_rejected() {
        let json = r#"{
            "type": "Recovery",
            "trigger": null,
            "recovery_action": "Retry",
            "max_retries": 3
        }"#;

        let result: Result<NodeType, _> = serde_json::from_str(json);
        assert!(
            result.is_err(),
            "bare-string \"Retry\" must NOT deserialize into the struct variant"
        );
    }

    /// Unit variants use the bare-string form; this pins the common path.
    #[test]
    fn unit_variant_recovery_action_still_deserializes() {
        let json = r#"{
            "type": "Recovery",
            "trigger": null,
            "recovery_action": "Continue",
            "max_retries": 3
        }"#;

        let node: NodeType = serde_json::from_str(json)
            .expect("Recovery node with unit-variant action must deserialize");
        match node {
            NodeType::Recovery(cfg) => {
                assert!(matches!(cfg.recovery_action, RecoveryAction::Continue));
            }
            other => panic!("expected NodeType::Recovery, got {other:?}"),
        }
    }

    /// Sequence JSON authored before `frame_type` existed (every frame was
    /// implicitly a light) must keep loading — and must default to "Light".
    /// A serializer that DOES send the field must round-trip it verbatim.
    #[test]
    fn exposure_frame_type_defaults_to_light_and_round_trips() {
        let legacy = r#"{
            "type": "TakeExposure",
            "duration_secs": 60.0,
            "count": 5,
            "filter": null,
            "gain": null,
            "offset": null,
            "binning": "One",
            "dither_every": null,
            "save_to": null
        }"#;
        let node: NodeType = serde_json::from_str(legacy)
            .expect("legacy TakeExposure without frame_type must deserialize");
        match node {
            NodeType::TakeExposure(cfg) => assert_eq!(cfg.frame_type, "Light"),
            other => panic!("expected NodeType::TakeExposure, got {other:?}"),
        }

        let dark = r#"{
            "type": "TakeExposure",
            "duration_secs": 30.0,
            "count": 20,
            "filter": null,
            "gain": null,
            "offset": null,
            "binning": "One",
            "dither_every": 3,
            "save_to": null,
            "frame_type": "Dark"
        }"#;
        let node: NodeType = serde_json::from_str(dark)
            .expect("TakeExposure with explicit frame_type must deserialize");
        match node {
            NodeType::TakeExposure(cfg) => assert_eq!(cfg.frame_type, "Dark"),
            other => panic!("expected NodeType::TakeExposure, got {other:?}"),
        }
    }
}
