//! The executor's public data types: the runtime configuration it is driven
//! by ([`RuntimeConfig`], [`ObserverProfile`], [`DefectMapApplyState`]) and
//! the command / state / progress / event vocabulary it speaks
//! ([`ExecutorCommand`], [`ExecutorState`], [`SequenceProgress`],
//! [`ExecutorEvent`]). Moved verbatim out of `executor/mod.rs`.

use super::*;

/// pre-loaded per-frame defect-map application state.
///
/// The bridge loads the `.ndm` file into memory once when the user toggles
/// "Apply defect map" on (or sets the auto-apply default + a matching map
/// exists). It then pushes this struct in via `ExecutorCommand::UpdateDefectMap`
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
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ObserverProfile {
    pub observer_name: Option<String>,
    pub site_elevation_m: Option<f64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub telescope_name: Option<String>,
    pub telescope_focal_length_mm: Option<f64>,
    pub telescope_aperture_mm: Option<f64>,
}

/// Runtime-mutable configuration shared between the executor task,
/// instruction nodes, and the trigger-action handlers. Stored in
/// `Arc<RwLock<RuntimeConfig>>` so an `UpdateDitherConfig` / `UpdateLocation`
/// / `UpdateFilterOffsets` command takes effect on the next
/// dither/capture/autofocus invocation without a sequence reload.
#[derive(Debug, Clone, Default)]
pub struct RuntimeConfig {
    /// Default dither configuration used by trigger-driven dithers
    /// (`RecoveryAction::Dither` and standalone Dither nodes that resolve
    /// against the runtime config). Per-exposure overrides (e.g.
    /// `ExposureConfig::dither_pixels`) take precedence — this only sets the
    /// fallback.
    pub dither: crate::DitherConfig,
    /// Autofocus configuration used by trigger-driven autofocus
    /// (`RecoveryAction::Autofocus` fired by the HFR / temperature / focus-
    /// drift / interval triggers). Seeded at `start()` from the sequence's
    /// first Autofocus node so trigger-fired refocus uses the operator's real
    /// tuning (step size, exposure, backlash, method, filter) instead of
    /// library defaults. `None` means the sequence has no Autofocus node to
    /// copy tuning from; the trigger path then falls back to defaults AND logs
    /// a warning rather than falling back silently.
    pub autofocus: Option<crate::AutofocusConfig>,
    /// Observer location (degrees). `None` means location is not configured.
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Filter -> focus offset (steps). Used by autofocus on filter change so
    /// the focuser is moved by the configured offset.
    pub filter_focus_offsets: HashMap<String, i32>,
    /// Runtime safety-poll fail mode. Trigger monitor reads this every poll
    /// so operator changes take effect without a sequence restart.
    pub safety_fail_mode: SafetyFailMode,
    /// Runtime cadence for safety/humidity device polling. The trigger loop
    /// still ticks every second; only expensive safety/weather driver calls
    /// are throttled by this interval.
    pub safety_check_interval_secs: u64,
    /// Maximum Sun altitude (degrees above the horizon) at which an on-sky LIGHT
    /// capture is permitted; mirrors the Dart scheduler's `maxSunAltitudeDegrees`.
    /// The native gate in `instructions::execute_slew` / `execute_exposure`
    /// refuses a slew to a science target or a LIGHT exposure above it, so a raw
    /// sequence started through `api_sequencer_start` (a mosaic included) cannot
    /// expose lights in daylight. Flats, darks, bias and park are unaffected.
    /// Seeded into both the `ExecutionContext` and the shared `TriggerState` at
    /// `start()`.
    ///
    /// `None` means nothing has been pushed: the Dart side sends its
    /// `SchedulerConfig.maxSunAltitudeDegrees` through
    /// [`SequenceExecutor::update_max_sun_altitude`]
    /// ([`ExecutorCommand::UpdateMaxSunAltitude`]), and `None` — like any
    /// non-finite value — resolves at `start()` to
    /// [`crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES`] (-12°), so the
    /// native gate is never weaker than the Dart gate it backstops.
    pub max_sun_altitude_degrees: Option<f64>,
    /// How long (seconds) a pushed `Some(true)` (UNSAFE) Dart weather verdict may
    /// go un-refreshed before it counts as stale. A stale verdict is missing
    /// data: fail closed keeps holding and warns, fail open and warn only set
    /// it aside and warn (see [`stale_unsafe_verdict_holds`]). `0` falls back
    /// to [`DEFAULT_WEATHER_VERDICT_STALENESS_SECS`]; any other value is
    /// clamped to a sane floor so a misconfiguration cannot make every tick
    /// warn.
    pub weather_verdict_staleness_secs: u64,
    /// How long the sky must read safe, without a break, before a weather hold
    /// lets the run image again. `None` means nothing has been pushed and
    /// [`DEFAULT_WEATHER_RESUME_AFTER_SAFE_SECS`] applies.
    pub weather_resume_after_safe_secs: Option<u64>,
    /// user override for the standard `AutofocusInterval`
    /// trigger's `every_n_frames`. The Rust default is 25 frames, which is
    /// wildly wrong for both very-short (5 s) and very-long (5 min) subs —
    /// the user must be able to tune this from the equipment profile or
    /// sequence-level settings. `None` means "use the seeded default";
    /// `Some(n)` overrides the trigger's `every_n_frames` field on the next
    /// trigger reload.
    pub autofocus_interval_frames: Option<u32>,
    /// Image Grading: global default image-grading thresholds.
    /// Applied to every TakeExposure node that does NOT carry its own
    /// `quality_check`. `None` => grading disabled globally. The Dart UI
    /// surfaces this via the new image-grading settings page.
    pub default_quality_check: Option<crate::quality::ImageQualityCheck>,
    /// Image Grading: where rejected frames go.
    ///
    /// `None` => a `Reject/` folder beside the frames, by default
    /// `<save_path>/<target>/Reject/` (created on first reject).
    /// `Some(path)` => use the explicit path (resolves relative to the
    /// frames' folder; absolute paths are honored verbatim). When the
    /// resolved reject folder equals the save_path, validation flags it
    /// as a warning (mixing accepted + rejected defeats the purpose).
    pub reject_folder_path: Option<String>,
    /// observer / equipment identification pushed at start by Dart.
    /// Used to populate FITS `OBSERVER`, `SITEELEV`, `TELESCOP`, `FOCALLEN`,
    /// `APTDIA`, `INSTRUME` keywords. Default is all-None (empty profile)
    /// so frames captured without a configured profile honestly emit no
    /// observer / telescope keywords.
    pub observer_profile: ObserverProfile,
    /// Recovery Mode — user-tunable defaults consumed on every
    /// recovery entry. Updated mid-flight via `UpdateRecoveryConfig` so
    /// the user can tweak the cadence/duration during a long session
    /// (e.g. shortening the interval after the first cloud cell drifts
    /// off the rig). Defaults follow SGP: 10 min interval, 90 min total.
    pub recovery: crate::recovery::RecoveryRuntimeConfig,
    /// global default sky-brightness adaptive exposure
    /// config. Applied to every TakeExposure node that does NOT carry
    /// its own `adaptive_exposure` block. `None` => no global default;
    /// exposures use their nominal duration unless the node explicitly
    /// opts in.
    pub default_adaptive_exposure: Option<crate::scheduling::AdaptiveExposureConfig>,
    /// per-frame defect map application state. `None`
    /// means defect correction is disabled for the current camera /
    /// session. Mirrored into `ExecutionContext::defect_map_apply` at
    /// start time and on every `ExecutorCommand::UpdateDefectMap`.
    pub defect_map_apply: Option<DefectMapApplyState>,
    /// per-target carry-over integration to seed into the
    /// `BudgetRegistry` at the start of the next run, mapped from
    /// `target_id` → `filter` → `seconds_already_captured`.
    ///
    /// Drives the "Resume / Restart / Continue New" handoff dialog:
    ///   * `Resume`     → populate with the prior session's per-filter
    ///     totals; the budget tracker treats those
    ///     frames as already-captured against the
    ///     configured budget.
    ///   * `Restart`    → populate with an explicit empty map for the
    ///     target so any pre-existing checkpoint state
    ///     is overwritten with zeros.
    ///   * `ContinueNew` → no entry for the target; default behaviour
    ///     (no carry-over, no zeroing) applies.
    ///
    /// Consumed exactly once at the top of the spawned executor task
    /// during `start()`; the map is cloned and applied, then cleared
    /// from the runtime config so a subsequent restart without an
    /// explicit re-seed runs without stale carry-over.
    pub pending_integration_carry_over: HashMap<String, HashMap<String, f64>>,
    /// The operator's "Park on unsafe weather" and "Park before dawn"
    /// settings. They decide whether the standard Weather Unsafe and Dawn
    /// Approaching triggers park; see [`ParkPolicy`].
    pub park_policy: ParkPolicy,
    /// The operator's "Camera retries" and "Filter wheel retries" settings,
    /// as a live handle: every run's instruction contexts share it, so a
    /// change reaches the next attempt of a running sequence.
    pub device_retry: crate::instructions::DeviceRetryHandle,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

/// Commands that can be sent to the executor
#[derive(Debug, Clone)]
pub enum ExecutorCommand {
    Pause,
    Resume,
    Stop,
    Skip,
    SkipToNode(NodeId),
    /// Recovery Mode — operator pressed "Try Now" on the dashboard
    /// banner. Cancels the wait timer and forces an immediate retry of the
    /// recovery attempt. No-op if the executor is not currently in
    /// `Recovering`.
    RecoveryTryNow,
    /// Recovery Mode — operator pressed "Abort" on the dashboard
    /// banner. Exits the recovery loop and transitions the executor to
    /// `Failed`. No-op if the executor is not currently in `Recovering`.
    RecoveryAbort,
    /// Recovery Mode — push the user-tunable recovery defaults
    /// (retry interval, max duration, stop-tracking flag, …) into the
    /// executor's runtime config so the next recovery entry honours them.
    UpdateRecoveryConfig {
        config: crate::recovery::RecoveryRuntimeConfig,
    },
    /// Update safety-poll fail behaviour while a sequence is running.
    UpdateSafetyFailMode {
        mode: SafetyFailMode,
    },
    /// Update safety/humidity poll cadence while a sequence is running.
    UpdateSafetyCheckInterval {
        seconds: u64,
    },
    /// Update dither configuration at runtime (e.g., when user changes settings mid-sequence)
    UpdateDitherConfig {
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    },
    /// Update observer location at runtime
    UpdateLocation {
        latitude: Option<f64>,
        longitude: Option<f64>,
    },
    /// Push the native daylight gate's maximum Sun altitude (the Dart
    /// `SchedulerConfig.maxSunAltitudeDegrees`)
    /// into the running executor so the native gate threshold equals the Dart
    /// one. Writes `RuntimeConfig::max_sun_altitude_degrees` AND patches the
    /// live trigger state so the gate (read through the trigger-state handle)
    /// picks it up on the next slew / exposure without a sequence reload.
    UpdateMaxSunAltitude {
        degrees: Option<f64>,
    },
    /// Update filter focus offsets at runtime (e.g., when equipment profile changes)
    UpdateFilterOffsets {
        offsets: std::collections::HashMap<String, i32>,
    },
    /// update the autofocus-interval cadence at runtime.
    /// Patches the standard `AutofocusInterval` trigger's `every_n_frames`
    /// so the next periodic-AF tick honours the new value; mid-flight tuning
    /// from the equipment-profile UI works without a sequence reload.
    UpdateAutofocusInterval {
        every_n_frames: u32,
    },
    /// update the global default image-grading thresholds.
    /// `None` disables grading globally (per-node `quality_check` on
    /// TakeExposure still wins). Mirrors the Dart-side
    /// `enableImageGrading` toggle on app settings.
    UpdateDefaultQualityCheck {
        check: Option<crate::quality::ImageQualityCheck>,
    },
    /// update the reject-folder override. `None` => default
    /// `<save_path>/<target>/Reject/`. Mirrors the Dart `imageGradingRejectFolderPath`
    /// setting.
    UpdateRejectFolderPath {
        path: Option<String>,
    },
    /// push observer / equipment identification (observer name,
    /// camera make/model, telescope name/focal length/aperture, site
    /// elevation) to the executor so the next FITS save stamps real
    /// keywords (OBSERVER, TELESCOP, FOCALLEN, APTDIA, INSTRUME, SITEELEV).
    UpdateObserverProfile {
        profile: ObserverProfile,
    },
    /// push the latest sky-brightness reading from the
    /// Dart `SkyBrightnessTracker` to the executor. The next adaptive-
    /// exposure decision reads this value. Pass `mag = None` when the
    /// tracker has lost lock so the adapter falls back to nominal
    /// (and emits a structured `Unavailable` reason).
    UpdateSkyBrightness {
        mag: Option<f64>,
    },
    /// push the user's global default sky-brightness
    /// adaptive exposure config. Per-node `ExposureConfig.adaptive_exposure`
    /// still wins; this is the runtime fallback the next TakeExposure
    /// node consults when it has none.
    UpdateDefaultAdaptiveExposure {
        config: Option<crate::scheduling::AdaptiveExposureConfig>,
    },
    /// Dart side has finished running a plugin node and is
    /// returning the verdict to the Rust executor. The executor finds the
    /// pending oneshot keyed by `node_id` and resolves it; the
    /// `PluginNodeInstruction` blocking on that oneshot returns Success or
    /// Failure based on the verdict.
    ///
    /// `node_id` MUST match the `node_id` from the corresponding
    /// `ExecutorEvent::PluginNodeRequested`. Stray finishes (no pending
    /// oneshot) are logged at warn and dropped — they're a bug on the
    /// Dart side but we don't want to crash the executor over a
    /// duplicate reply.
    PluginNodeFinished {
        node_id: NodeId,
        success: bool,
        /// Optional human-readable message surfaced in logs and on the
        /// final progress event. Empty / `None` is the success case.
        message: Option<String>,
        /// Optional plugin-authored JSON payload emitted as the node's
        /// final progress event (parsed as `serde_json::Value`; invalid
        /// JSON is replaced with `null` and a warn line is logged).
        structured_detail_json: Option<String>,
    },
    /// push the active per-frame defect map (or clear it).
    ///
    /// Sent by `api_sequencer_update_defect_map` when the user toggles
    /// "Apply during capture" on or off. When `state` is `Some`, every
    /// subsequent frame whose camera id matches gets the defect map
    /// applied between camera readout and FITS save. When `None`, defect
    /// correction is disabled — the bridge call sends this on toggle-off
    /// AND on camera disconnect to make sure a stale map cannot be
    /// applied to a frame from a different sensor.
    ///
    /// Pre-loading happens bridge-side (the `.ndm` file is parsed into
    /// memory) so per-frame application is just a slice operation.
    UpdateDefectMap {
        state: Option<DefectMapApplyState>,
    },
    /// push the latest cloud-motion analyzer reading into
    /// the executor's trigger state. The Dart side
    /// (`cloudMotionAnalyzerProvider` -> WeatherSafetyNotifier) sends this
    /// every ~60s while a sequence is running so the cloud-aware triggers
    /// (`CloudArrivingIn`, `CloudOpeningIn`, `CloudCoverThreshold`) have
    /// current data. All fields are `Option` because the analyzer may not
    /// yet have enough radar history to produce every quantity; `None`
    /// fields disable the corresponding evaluator branch rather than firing on a
    /// default.
    UpdateCloudMotion {
        /// Current cloud cover percentage (0-100). Open-Meteo merged with
        /// the analyzer.
        current_cover_percent: Option<f64>,
        /// Predicted minutes until significant clouds arrive. `None` when
        /// no approach is predicted.
        predicted_arrival_minutes: Option<f64>,
        /// Predicted minutes until a clear opening reaches the user.
        /// `None` when no opening is predicted.
        predicted_opening_minutes: Option<f64>,
        /// Predicted duration (seconds) of the opening referenced by
        /// `predicted_opening_minutes`.
        predicted_opening_duration_secs: Option<f64>,
        /// (altitude_deg, azimuth_deg) of a clear-sky direction reported by
        /// the analyzer. Consumed by `RecoveryAction::SlewToGapAndContinue`.
        predicted_clear_sky_alt: Option<f64>,
        predicted_clear_sky_az: Option<f64>,
    },
    /// Science — push the latest sky transparency reading from
    /// the Dart science pipeline. Mirrored onto
    /// `TriggerState::current_transparency` (for the
    /// `TransparencyDropped` trigger evaluator) and
    /// `ExecutionContext::current_transparency` (for the photometry
    /// node's per-frame quality gates).
    ///
    /// Pass `transparency = None` when the science pipeline has lost
    /// lock so the trigger evaluator falls back to "no data" (does NOT
    /// fire on absent telemetry — "no silent fallbacks").
    UpdateTransparency {
        /// Live transparency reading expressed as a fraction of clear-sky
        /// reference (0.0..=1.0; 1.0 = clear). Values outside [0.0, 1.5]
        /// are clamped + WARN-logged by `TriggerState::update_transparency`.
        transparency: Option<f64>,
    },
    /// Science — push the operator-configured backup plan that
    /// `RecoveryAction::SwitchTargetOrFilter` consults. Pass `plan =
    /// None` to clear the plan (e.g. the operator removed it mid-session).
    UpdateTransparencyBackup {
        plan: Option<crate::node::context::TransparencyBackupPlan>,
    },
    /// push the composite sky-conditions score that the
    /// `TargetScheduler`'s adaptive-swap logic consults. The Dart-side
    /// `AdaptiveSwapService` composes the score from transparency / seeing
    /// / cloud cover / wind every ~30 seconds and sends this command. The
    /// score is mirrored onto `ExecutionContext::current_conditions_score`
    /// so the scheduler reads from a non-blocking slot. Pass `score =
    /// None` when the Dart composer has insufficient data.
    UpdateConditionsScore {
        score: Option<crate::scheduling::ConditionsScore>,
    },
    /// Push the Dart-side `weatherSafetyProvider` overall verdict into the
    /// executor's trigger state. The hardware `safety_is_safe` poll only knows
    /// what a connected safety/weather device reports, so a rig without one needs
    /// this second unsafe source: the Dart side computes UNSAFE from the user's
    /// configured thresholds plus API/cloud data. `unsafe_override = Some(true)`
    /// => Dart computed UNSAFE; `Some(false)` => Dart computed SAFE; `None` =>
    /// Dart abstains (provider disabled / no data) and this layer is inert.
    /// Folded as an OR-of-unsafe into `weather_safe` evaluation, so it can only
    /// make the rig safer than the hardware verdict, never less safe.
    UpdateWeatherVerdict {
        unsafe_override: Option<bool>,
        /// The UNSAFE verdict rests only on a forecast or cloud model.
        advisory: bool,
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
    /// The bridge maps this to `EventSeverity::Warning` on the existing
    /// `SequencerEvent::Error` payload, so no wire format changes; Dart routes
    /// on the severity into the run's `warningMessages`, which the Session
    /// Report already renders under "Warnings".
    Warning {
        message: String,
    },
    /// A meridian flip finished — successfully, degraded (it needed retries),
    /// aborted, or failed outright.
    ///
    /// `MeridianFlipEvent` is log-only unless a caller wires
    /// `with_event_channel`, and the trigger path does not, so this variant is
    /// what carries the flip verdict — a failed post-flip recenter included —
    /// into the run vitals.
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
