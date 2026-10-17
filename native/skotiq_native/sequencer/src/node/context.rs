//! ExecutionContext — the per-run state that flows through every node.
//!
//! Derives `Clone` so the parallel executor can clone the context for each
//! spawned branch instead of field-copying ~22 members. `progress_callback`
//! is an `Arc<dyn Fn>` rather than a `Box`, so cloning bumps the refcount
//! rather than moving ownership.

#[cfg(test)]
use crate::device_ops::NullDeviceOps;
use crate::device_ops::SharedDeviceOps;
use crate::executor::ExecutorEvent;
use crate::instructions::InstructionContext;
use crate::node::progress::ProgressUpdate;
use crate::scheduling::{default_clock, BudgetRegistry, Clock};
use crate::{NodeId, SafetyFailMode};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, RwLock};

/// A detached handle onto the run's operator-pause state, obtained from
/// [`ExecutionContext::pause_gate`].
///
/// Instruction code receives an [`InstructionContext`], not an
/// `ExecutionContext`, so it cannot see `is_paused`. Anything that loops over
/// several units of work inside a single instruction (exposure bursts,
/// autofocus sweeps) takes one of these and calls
/// [`wait_while_paused`](Self::wait_while_paused) between units.
///
/// [`Default`] is the never-paused gate, which is what standalone callers
/// (bridge one-shots, wizards, tests) get.
#[derive(Clone, Default)]
pub struct PauseGate {
    handles: Option<(Arc<AtomicBool>, Arc<tokio::sync::Notify>)>,
}

impl PauseGate {
    pub fn is_paused(&self) -> bool {
        self.handles
            .as_ref()
            .is_some_and(|(paused, _)| paused.load(Ordering::Relaxed))
    }

    /// Block while the run is paused. Returns `false` when `cancellation_token`
    /// fires while waiting, so the caller unwinds instead of resuming into a
    /// cancelled run.
    pub async fn wait_while_paused(&self, cancellation_token: &AtomicBool) -> bool {
        let Some((paused, resume_notify)) = self.handles.as_ref() else {
            return true;
        };
        if !paused.load(Ordering::Relaxed) {
            return true;
        }
        tracing::info!("Paused: holding before the next unit of work in this instruction");
        loop {
            if cancellation_token.load(Ordering::Relaxed) {
                tracing::info!("Cancelled while paused inside an instruction");
                return false;
            }
            if !paused.load(Ordering::Relaxed) {
                tracing::info!("Resumed: continuing the instruction");
                return true;
            }
            tokio::select! {
                _ = resume_notify.notified() => {}
                _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
            }
        }
    }
}

/// snapshot of the latest cloud-motion analyzer reading.
///
/// Pushed from Dart via `ExecutorCommand::UpdateCloudMotion`; consumed by
/// the cloud-aware recovery actions (`SlewToGapAndContinue`) and the
/// run-dashboard "Cloud Motion" panel. Mirrored into `ExecutionContext`
/// (rather than only the trigger state) so consumers don't need to hold
/// the trigger-state lock to read it.
///
/// All quantities are `Option` because the analyzer may not yet have
/// enough radar history to produce them — absent values disable the
/// dependent recovery branch rather than firing on defaults.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct CloudMotionSnapshot {
    /// Current cloud cover percentage (0-100).
    pub current_cover_percent: Option<f64>,
    /// Predicted minutes until significant clouds reach the user.
    pub predicted_arrival_minutes: Option<f64>,
    /// Predicted minutes until a clear opening reaches the user.
    pub predicted_opening_minutes: Option<f64>,
    /// Predicted duration of the opening (seconds).
    pub predicted_opening_duration_secs: Option<f64>,
    /// (alt_deg, az_deg) of a clear-sky direction; consumed by
    /// `RecoveryAction::SlewToGapAndContinue`.
    pub predicted_clear_sky_direction: Option<(f64, f64)>,
    /// UTC unix timestamp of the last update. None if no data yet.
    pub last_update_unix_secs: Option<i64>,
}

/// Progress callback type. Wrapped in `Arc` so ExecutionContext is Clone.
/// Sync (not async) because instruction code invokes it from inside
/// synchronous callback closures.
pub type ProgressCallback = Arc<dyn Fn(ProgressUpdate) + Send + Sync>;

/// Polar-alignment live-image callback. Same Arc-wrapping rationale.
pub type PolarAlignImageCallback =
    Arc<dyn Fn(crate::polar_align::PolarAlignmentImageData) + Send + Sync>;

/// Per-device exclusion locks, keyed by device id.
///
/// `Parallel` derives every branch context with `ctx.clone()`, so two branches
/// can reach the same physical device at the same time. A camera cannot expose
/// twice at once: the live rig produced two overlapping bursts on
/// `sim_camera_1`, two `captured_images` rows and one file on disk. Instruction
/// code takes the handle for the device it is about to drive and holds the
/// guard for the whole operation. Keyed by id, so a genuinely dual-camera
/// parallel block still runs concurrently.
#[derive(Default)]
pub struct DeviceLockRegistry {
    locks: parking_lot::Mutex<std::collections::HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl DeviceLockRegistry {
    pub fn handle(&self, device_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut locks = self.locks.lock();
        if let Some(existing) = locks.get(device_id) {
            return existing.clone();
        }
        let created = Arc::new(tokio::sync::Mutex::new(()));
        locks.insert(device_id.to_string(), created.clone());
        created
    }
}

/// Context passed to nodes during execution.
///
/// Cloning is cheap: every field is either `Copy`, `Arc`, or already
/// `Clone`, and the parallel executor uses `ctx.clone()` to derive
/// per-branch contexts.
#[derive(Clone)]
pub struct ExecutionContext {
    /// ID of the scope this context belongs to — the ROOT node for the main run,
    /// or the branch/recovery node for contexts derived by `parallel` and
    /// `recovery`. It is NOT rewritten as execution descends the tree, so it does
    /// not answer "which node is running now"; instruction code takes its own id
    /// as an argument (see [`Self::to_instruction_context`]).
    pub node_id: NodeId,
    /// Current target information (propagated from TargetGroup)
    pub target_ra: Option<f64>,
    pub target_dec: Option<f64>,
    pub target_name: Option<String>,
    pub target_rotation: Option<f64>,
    /// Current filter
    pub current_filter: Option<String>,
    /// Current binning
    pub current_binning: crate::Binning,
    /// Cancellation flag
    pub is_cancelled: Arc<AtomicBool>,
    /// Pause flag - set by recovery nodes, cleared by executor on resume
    pub is_paused: Arc<AtomicBool>,
    /// Monotonic count of COMPLETED device-disconnect recovery cycles.
    ///
    /// `is_paused` alone cannot tell an instruction whether recovery happened:
    /// the driver raises it on engage and clears it on success, so a recovery
    /// that finishes before the failed instruction starts watching is
    /// indistinguishable from no driver at all — the faster the recovery, the
    /// more likely it kills the run. Instructions snapshot this counter before
    /// executing and compare afterwards, which is edge-durable where a
    /// transient level is not.
    pub recovery_generation: Arc<std::sync::atomic::AtomicU64>,
    /// Skip current target request - set by trigger monitor and consumed by target header.
    pub skip_to_next_target: Arc<AtomicBool>,
    /// TargetScheduler mid-target recompute support. Successful exposure
    /// bursts increment the completed-exposure counter; an active
    /// TargetScheduler can install a cadence/baseline so the exposure path
    /// asks containers to yield at the next safe child boundary.
    pub scheduler_completed_exposures: Arc<AtomicU64>,
    pub scheduler_recompute_cadence: Arc<AtomicU32>,
    pub scheduler_recompute_baseline: Arc<AtomicU64>,
    pub scheduler_recompute_requested: Arc<AtomicBool>,
    /// SkipToNode target. When `Some(node_id)`, the executor
    /// is in "skip until we reach this node" mode: container nodes mark
    /// children whose subtree does NOT contain the target as Skipped, and
    /// unwrap the request once the target's own subtree is entered. Cleared
    /// to None once consumed. Read-frequently / written-rarely (typically
    /// once per SkipToNode command), so a `parking_lot::RwLock` keeps the
    /// read path lock-free under no contention.
    pub skip_to_node: Arc<parking_lot::RwLock<Option<NodeId>>>,
    /// Resume notifier - signaled when execution should resume after pause
    pub resume_notify: Arc<tokio::sync::Notify>,
    /// Progress callback (Arc so ExecutionContext is Clone).
    pub progress_callback: Option<ProgressCallback>,
    /// Polar alignment image callback (Arc so ExecutionContext is Clone).
    pub polar_align_image_callback: Option<PolarAlignImageCallback>,
    /// Connected device IDs
    pub camera_id: Option<String>,
    pub mount_id: Option<String>,
    pub focuser_id: Option<String>,
    pub filterwheel_id: Option<String>,
    pub rotator_id: Option<String>,
    pub dome_id: Option<String>,
    pub cover_calibrator_id: Option<String>,
    /// Base save path for images
    pub save_path: Option<std::path::PathBuf>,
    /// Observer location
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Device operations handler
    pub device_ops: SharedDeviceOps,
    /// Per-device exclusion locks shared across every derived branch context.
    pub device_locks: Arc<DeviceLockRegistry>,
    /// Completed integration time in seconds (shared counter)
    pub completed_integration_secs: Arc<RwLock<f64>>,
    /// Trigger state (for updating during execution)
    pub trigger_state: Option<Arc<RwLock<crate::triggers::TriggerState>>>,
    /// Safety fail mode - determines behavior when safety devices fail or are unavailable
    pub safety_fail_mode: Arc<parking_lot::RwLock<SafetyFailMode>>,
    /// The maximum Sun altitude (degrees above the horizon) at which an on-sky
    /// LIGHT capture is permitted, mirroring the Dart scheduler's
    /// `maxSunAltitudeDegrees` so the native gate
    /// (`instructions::execute_slew` / `execute_exposure`) and the Dart twilight
    /// gate agree on the threshold. The native gate blocks a slew to a science
    /// target or a LIGHT exposure while the Sun is above this altitude, and
    /// deliberately does NOT block flats/darks/bias/park or a parked rig, so
    /// daytime calibration stays usable. Seeded from
    /// `RuntimeConfig::max_sun_altitude_degrees` at `start()`; defaults to
    /// [`crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES`].
    pub max_sun_altitude_degrees: f64,
    /// Filter focus offsets from equipment profile (filter_name -> offset_steps)
    pub filter_focus_offsets: std::collections::HashMap<String, i32>,
    /// Optional broadcast handle so instruction code can emit ExecutorEvents
    /// directly (used for surfacing FITS-save failures and other instruction-
    /// level errors that the UI must see, beyond the InstructionResult flow).
    /// `None` outside the live executor (e.g. unit tests / direct invocations).
    pub event_tx: Option<broadcast::Sender<ExecutorEvent>>,
    /// Optional recovery request channel installed by the live executor.
    /// Instruction nodes use this to promote device-disconnect failures into
    /// the same first-class recovery loop as trigger-driven recoveries.
    pub recovery_request_tx: Option<mpsc::Sender<crate::recovery::RecoveryCause>>,
    /// Set to `true` the moment an instruction failure is promoted to a
    /// `DeviceDisconnected` recovery (see
    /// `instructions::request_device_disconnected_recovery`). The node-runtime
    /// (`RuntimeNode::execute`) consumes this flag: instead of letting the
    /// node's `Failure` propagate up and end the night, it waits for the
    /// recovery driver to reconnect the device and then RETRIES the failed
    /// instruction. Shared `Arc<AtomicBool>` so the instruction-side write and
    /// the runtime-side read see the same allocation across the
    /// `ExecutionContext -> InstructionContext` boundary.
    pub device_disconnect_recovery_pending: Arc<AtomicBool>,
    /// in-memory SmartExposure per-node resume state,
    /// keyed by NodeId. Survives pause/resume within a single process run.
    /// Cross-process resume requires the executor to additionally plumb a
    /// `CheckpointManager` and serialize this map into
    /// `SessionCheckpoint::wizard_states` — wired through the wizard-checkpoint
    /// abstraction so a single map covers every kind of step-level resume
    /// state. `Arc<RwLock<...>>` so `ExecutionContext::clone` shares the
    /// allocation (matches the rest of this struct's shared-state pattern).
    pub smart_exposure_states:
        Arc<RwLock<std::collections::HashMap<NodeId, crate::SmartExposureCheckpoint>>>,
    /// The running session's checkpoint manager, when the executor was
    /// given a checkpoint directory. Wizards that own step-level resume
    /// state (mosaic panels today) wrap this in a
    /// [`crate::checkpoint::SessionWizardCheckpointSink`] so their
    /// progress lands in `SessionCheckpoint::wizard_states` alongside the
    /// session checkpoint. `None` (no checkpoint dir, or a wizard run
    /// outside a session) means nothing is persisted and the next run
    /// starts at step 0.
    ///
    /// The same `Arc` the executor holds, so the wizard sink and the
    /// streaming-checkpoint task share one manager (and one info cache).
    pub checkpoint_manager: Option<Arc<crate::checkpoint::CheckpointManager>>,
    /// DepthLock verdict source, installed by the host at start. `None`
    /// when the host has no goal store; a bound plan then warns once and
    /// stays count-bounded.
    pub depth_goal_ops: Option<crate::depth_goal::SharedDepthGoalOps>,
    /// shared per-target integration budget registry.
    /// `TargetHeader` runtime registers a state on entry; `expose` instruction
    /// credits successful bursts; the next `TargetHeader` child-boundary
    /// check terminates the target Success when the budget is met.
    /// Internally an `Arc<RwLock<...>>` so `ExecutionContext::clone` shares
    /// A single registry across parallel branches.
    pub budget_registry: BudgetRegistry,
    // -------------------------------------------------------------------
    // Image Grading: FITS-header metadata + grading state.
    //
    // The executor seeds the "session-static" fields (session_id, observer,
    // equipment identification, site elevation) at start time; the per-target
    // fields (target_id, mosaic_panel, last_plate_solve) flow in from
    // TargetHeader / CenterTarget; the per-burst fields (current_filter_index,
    // set_temp_c, bayer_pattern) are updated by the respective instructions.
    // `expose.rs` assembles a `FrameContext` from these fields plus live
    // device telemetry at FITS-save time.
    // -------------------------------------------------------------------
    /// Stable session identifier, generated by the executor at start time.
    /// Surfaced as the FITS keyword `SK-SESID` so frames captured in the
    /// same run can be linked back to one imaging_session database row.
    pub session_id: String,
    /// Stable identifier of the currently-active target (propagated from
    /// TargetHeader). Distinct from `target_name` because targets can be
    /// renamed mid-session — the id is the join key for the database row.
    pub target_id: Option<String>,
    /// Mosaic panel info for the active target. None unless the current
    /// TargetHeader carries a `mosaic_panel`. Carried here so `expose.rs`
    /// can populate the FITS header without re-walking the tree.
    pub mosaic_panel: Option<crate::MosaicPanelInfo>,
    /// Current filter index (1-based). Set by `execute_exposure` after a
    /// filter change, stamped into FITS as `FILTPOS`.
    pub current_filter_index: Option<i32>,
    /// Cooler target temperature in °C, set by CoolCamera. None when the
    /// cooler is off or has never been commanded.
    pub set_temp_c: Option<f64>,
    /// Bayer pattern string ("RGGB", "BGGR", etc.) reported by the camera.
    /// None for monochrome sensors.
    pub bayer_pattern: Option<String>,
    /// Observer name from app settings. FITS `OBSERVER`.
    pub observer_name: Option<String>,
    /// Observer site elevation in metres. FITS `SITEELEV`. Latitude /
    /// longitude already exist as `latitude` / `longitude` on this struct.
    pub site_elevation_m: Option<f64>,
    /// Camera identification (FITS `INSTRUME` = "<make> <model>").
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    /// Telescope identification (FITS `TELESCOP`, `FOCALLEN`, `APTDIA`).
    pub telescope_name: Option<String>,
    pub telescope_focal_length_mm: Option<f64>,
    pub telescope_aperture_mm: Option<f64>,
    /// Last plate-solve result for the active target — captured by the
    /// CenterTarget instruction and stamped into subsequent exposures'
    /// FITS headers as SOLVED-RA/DEC, PIXSCALE, CROTA1. Arc<RwLock> so
    /// the cloned ExecutionContext used by parallel branches sees the
    /// latest solve.
    pub last_plate_solve: Arc<RwLock<Option<crate::device_ops::PlateSolveResult>>>,
    /// Image Grading: rolling baseline HFR for the current target
    /// (median of the first N accepted frames). `None` until the baseline
    /// has been established; image grading checks then compare new frames
    /// against this baseline.
    pub hfr_baseline: Arc<RwLock<Option<f64>>>,
    /// Image Grading: HFR samples being averaged into the baseline.
    /// Discarded once the baseline becomes Some.
    pub hfr_baseline_samples: Arc<RwLock<Vec<f64>>>,
    /// Image Grading: running count of how many consecutive frames
    /// have been rejected. Reset to 0 every time an accepted frame lands.
    /// Used to detect "something is systematically wrong" — focus has
    /// drifted, clouds have rolled in, etc.
    pub consecutive_rejects: Arc<std::sync::atomic::AtomicU32>,
    /// Exposure triggers whose condition held on their last evaluation, keyed
    /// by node id and trigger position. A `Notify` trigger tells the operator
    /// when its key is added and stays quiet while it is present, so a soft
    /// hour is one notification rather than one per burst.
    pub exposure_trigger_episodes: Arc<parking_lot::Mutex<std::collections::HashSet<String>>>,
    /// Image Grading: cumulative accepted / rejected counters for
    /// the run. Surfaced to the dashboard quality panel via the progress
    /// callback.
    pub frames_accepted: Arc<std::sync::atomic::AtomicU32>,
    pub frames_rejected: Arc<std::sync::atomic::AtomicU32>,
    /// Global default image-quality thresholds, seeded from
    /// `RuntimeConfig.default_quality_check` at executor `start()`. Used as
    /// the fallback when a TakeExposure node does NOT carry its own
    /// `quality_check`. None => grading disabled globally.
    pub default_quality_check: Option<crate::quality::ImageQualityCheck>,
    /// Optional reject-folder override, seeded from
    /// `RuntimeConfig.reject_folder_path`. None => use `<save_path>/Reject/`.
    pub reject_folder_path: Option<String>,
    /// pluggable wall-clock used by scheduling code (target
    /// header altitude crossings, target scheduler, integration budget
    /// timeline). Defaults to [`crate::scheduling::WallClock`] in
    /// production; tests inject a `MockClock` via
    /// [`ExecutionContext::with_clock`] so time-of-day-dependent assertions
    /// are deterministic.
    pub clock: Arc<dyn Clock>,
    // sky-brightness adaptive exposures.
    // -------------------------------------------------------------------
    /// Live sky brightness in mag/arcsec² (bigger = darker). Pushed by
    /// the Dart layer via `ExecutorCommand::UpdateSkyBrightness` from the
    /// running `SkyBrightnessTracker`. `None` until the tracker has
    /// produced a valid sample. Shared via `Arc<RwLock<...>>` so
    /// `ExecutionContext::clone` keeps every parallel branch reading the
    /// same live value.
    pub current_sky_brightness_mag: Arc<RwLock<Option<f64>>>,
    /// global default adaptive-exposure config, seeded
    /// from `RuntimeConfig::default_adaptive_exposure` at start time and
    /// kept in sync by the `UpdateDefaultAdaptiveExposure` command. Per-
    /// node `ExposureConfig::adaptive_exposure` wins; this is the
    /// fallback when the node has none. `None` => no global default,
    /// no adaptation.
    ///
    /// Held behind `Arc<RwLock<...>>` so the executor's command handler — which
    /// holds a shared `&context` — can update it mid-run.
    pub default_adaptive_exposure: Arc<RwLock<Option<crate::scheduling::AdaptiveExposureConfig>>>,
    /// latest cloud-motion analyzer snapshot. Pushed by
    /// the Dart side via `ExecutorCommand::UpdateCloudMotion`; consumed by
    /// `RecoveryAction::SlewToGapAndContinue` (needs the clear-sky
    /// direction) and by the run-dashboard cloud-motion panel.
    /// `Arc<RwLock<...>>` so `ExecutionContext::clone` shares the
    /// allocation with every parallel branch.
    pub cloud_motion_snapshot: Arc<RwLock<CloudMotionSnapshot>>,
    /// pending plugin-node oneshots, keyed by node id.
    ///
    /// When `PluginNodeInstruction::execute` runs it inserts a oneshot
    /// sender keyed by `node_id` and awaits the receiver. The executor's
    /// command-handler observes `ExecutorCommand::PluginNodeFinished` and
    /// resolves the matching sender. `Arc<RwLock<...>>` so cloned
    /// ExecutionContexts share the same map (parallel branches don't
    /// fork the registration; one plugin invocation = one entry).
    pub plugin_node_pending: Arc<
        RwLock<std::collections::HashMap<NodeId, tokio::sync::oneshot::Sender<PluginNodeReply>>>,
    >,
    /// per-frame defect-map application state.
    ///
    /// When `Some`, `instructions::execute_exposure` applies the pre-loaded
    /// defect map to each captured frame before the FITS save; `None` disables
    /// defect correction. Pushed in via `ExecutorCommand::UpdateDefectMap`
    /// (toggle on/off from the calibration UI).
    pub defect_map_apply: Arc<RwLock<Option<crate::executor::DefectMapApplyState>>>,
    /// Science — latest sky transparency reading (0.0..=1.0 as a
    /// fraction of clear-sky reference; 1.0 = perfectly clear, 0.0 =
    /// totally opaque). Pushed from the Dart science pipeline via
    /// `ExecutorCommand::UpdateTransparency`. Consumed by the
    /// `TransparencyDropped` trigger evaluator and by the photometry
    /// node's per-frame quality gates. `Arc<RwLock<...>>` so cloned
    /// ExecutionContexts share the same allocation.
    pub current_transparency: Arc<RwLock<Option<f64>>>,
    /// Science — operator-configured backup plan that
    /// `RecoveryAction::SwitchTargetOrFilter` consults. Pushed by Dart
    /// at sequence start via `ExecutorCommand::UpdateTransparencyBackup`.
    /// `None` => no fallback configured (recovery falls back to
    /// `PauseAndWaitForClear` and emits an Error explaining the
    /// missing config — per no silent fallbacks).
    pub transparency_backup_plan: Arc<RwLock<Option<TransparencyBackupPlan>>>,
    /// Science — per-node photometry timing state keyed by
    /// NodeId. The photometry instruction stamps each frame's start
    /// time so the next iteration can detect cadence gaps without
    /// threading the value through the expose pipeline.
    pub science_photometry_states:
        Arc<RwLock<std::collections::HashMap<NodeId, PhotometryRuntimeState>>>,
    /// Replay Debug — optional decision broadcast sender. When
    /// `Some`, instruction code (scheduler, recovery driver, exposure
    /// grading, plugin nodes) emits a [`crate::decision::DecisionEvent`]
    /// via [`Self::emit_decision`]. The bridge subscribes to the channel
    /// and routes the events to the typed `SequencerEvent::DecisionLogged`
    /// event + the `sequence_decisions` persistence table.
    ///
    /// `None` outside the live executor (unit tests / one-shot
    /// instruction sites) — the helper is a no-op in that case so test
    /// code does not need to fabricate a sender.
    pub decision_tx: Option<crate::decision::DecisionSender>,
    /// Replay Debug — active `sequence_runs.id` stamped onto every
    /// emitted decision so the persistence layer can populate the FK
    /// without joining on wall-clock windows. `None` until the Dart side
    /// inserts the row and calls `set_active_sequence_run_id` on the
    /// executor (the executor then pushes that into the context).
    pub active_sequence_run_id: Arc<parking_lot::RwLock<Option<i64>>>,
    /// Frame-Failure Forensics rolling history.
    ///
    /// Bounded ring buffer of the last
    /// [`crate::quality::FORENSIC_HISTORY_LEN`] frame samples (accepted
    /// or rejected). Each entry carries the frame's metrics plus the
    /// environmental snapshot at capture time. The classifier consumes
    /// this slice to detect monotonic HFR trends, reject clusters,
    /// brightness drops, etc.
    ///
    /// Bounded growth: every push checks the length and pops the
    /// oldest entry — the buffer never exceeds `FORENSIC_HISTORY_LEN`
    /// regardless of run length.
    pub forensics_history:
        Arc<RwLock<std::collections::VecDeque<crate::quality::RecentFrameSample>>>,
    /// current wind speed reading (km/h) pushed by the Dart
    /// weather feed via `ExecutorCommand::UpdateWind`. `None` until the
    /// first sample arrives. Held behind `Arc<RwLock<...>>` so the
    /// executor's command handler can mutate it (the rest of the
    /// `ExecutionContext` clone pattern).
    pub current_wind_kph: Arc<RwLock<Option<f64>>>,
    /// last sensor temperature reading (°C) reported by the
    /// camera at capture completion. Snapshotted into the forensic
    /// event so a frame rejected during a cooler dropout can be
    /// classified against the temperature trend. `None` until the
    /// first sample arrives.
    pub current_sensor_temp_c: Arc<RwLock<Option<f64>>>,
    /// latest composite sky-conditions score pushed from Dart
    /// via `ExecutorCommand::UpdateConditionsScore`. Consumed by the
    /// `TargetScheduler` adaptive-swap logic and surfaced to the run
    /// dashboard's "Adaptive Conditions" panel. `None` until the Dart
    /// composer has produced its first sample.
    pub current_conditions_score: Arc<RwLock<Option<crate::scheduling::ConditionsScore>>>,
    /// adaptive-swap accounting (last swap timestamp, last
    /// decision, currently-running tier) shared across all
    /// `TargetScheduler` instances in the running sequence. Read by the
    /// run-dashboard panel via the bridge JSON snapshot getter.
    pub adaptive_swap_state: Arc<RwLock<AdaptiveSwapRuntimeState>>,
    /// per-dispatch override for SmartExposure cycling.
    ///
    /// Installed by [`crate::node::logic::target_scheduler`] immediately
    /// before it calls `execute()` on the picked target subtree (when the
    /// scheduler's `filter_cycle_mode` is anything other than
    /// `SingleFilter`) and cleared on return. While set, each
    /// `SmartExposure` node in the subtree reads it and uses the override
    /// instead of its own `rotate_filters` / `batch_size` for the duration
    /// of that dispatch. The scheduler restores the prior value on exit so
    /// the override does NOT leak into sibling subtrees (which is also
    /// safe even under future parallel scheduling because each branch
    /// would `clone` the context, getting its own slot).
    ///
    /// `parking_lot::RwLock` matches the lock-flavour used by other
    /// scheduler-runtime fields on this struct (`skip_to_node`,
    /// `adaptive_swap_state`).
    pub scheduler_filter_cycle_override: Arc<parking_lot::RwLock<Option<crate::FilterCycleMode>>>,
    /// Active target's effective `end_when` stop trigger, installed by
    /// `TargetHeader` for the duration of its child subtree and cleared on
    /// exit. The parent only *probes* `end_when` at child boundaries, so a
    /// child that loops internally (e.g. a SmartExposure node in
    /// `loop_until_stopped` mode) would never give the parent a boundary to
    /// probe. Exposing the trigger here lets such a node poll the target
    /// window itself between sub-exposure batches and terminate cleanly when
    /// the window closes — without the parent having to spawn a per-target
    /// background watcher.
    ///
    /// `None` outside a TargetHeader subtree, or when the active target has
    /// no end condition. Same lock flavour and install/restore discipline as
    /// [`Self::scheduler_filter_cycle_override`].
    pub active_target_end_trigger:
        Arc<parking_lot::RwLock<Option<crate::scheduling::TargetTrigger>>>,
    /// Dual-rig — optional dither-coordination barrier shared with a running
    /// secondary capture loop. `None` (the common single-rig case) makes every
    /// dither call site a plain pass-through. `Some` means a secondary camera
    /// is piggybacking: the primary announces a pending dither on this barrier,
    /// waits (bounded) for the secondary to clear its in-flight exposure,
    /// pulses the guider, then releases the barrier so the secondary resumes.
    /// See [`crate::dual_rig::DitherBarrier`].
    pub dither_barrier: Option<Arc<crate::dual_rig::DitherBarrier>>,
    /// The run's camera and filter-wheel retry policy. A single attempt until
    /// the executor installs the operator's handle at start.
    pub device_retry: crate::instructions::DeviceRetryHandle,
}

/// runtime adaptive-swap accounting. Hot-mutated by the
/// `TargetScheduler` when it makes an adaptive-swap decision; read by the
/// run-dashboard panel. Distinct from `ConditionsScore` (which is the
/// telemetry input) — this is the *output* of the decision engine,
/// preserved across decision ticks.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct AdaptiveSwapRuntimeState {
    /// Currently-running target id (`None` between targets). Mirrors
    /// the scheduler's `currently_running` so the dashboard does not
    /// need to reach back into the scheduler.
    pub current_target_id: Option<String>,
    /// Current target's brightness tier (wire string).
    pub current_tier: Option<String>,
    /// Last decision tag — one of `"defer"`, `"conditions_unknown"`,
    /// `"keep_running"`, `"hysteresis_cooldown"`, `"swap"`,
    /// `"no_candidate"`. Used by the UI to render a badge without
    /// parsing the reason string.
    pub last_decision_kind: Option<String>,
    /// Last decision's human-readable reason — surfaced verbatim in
    /// the dashboard breadcrumb.
    pub last_decision_reason: Option<String>,
    /// Unix epoch seconds at which the last actual swap fired. `None`
    /// when no swap has happened yet in this run.
    pub last_swap_unix_secs: Option<i64>,
    /// Previous target id (when a swap fired).
    pub last_swap_from_target_id: Option<String>,
    /// Target id picked by the last successful swap.
    pub last_swap_to_target_id: Option<String>,
    /// Latest conditions score sampled by the scheduler at decision time.
    pub last_observed_score: Option<f64>,
    /// Configured `swap_on_conditions_below` for the scheduler that
    /// just decided. Mirrored here so the dashboard can render the
    /// "threshold = X" line without re-walking the sequence tree.
    pub configured_threshold: Option<f64>,
    /// Configured hysteresis (seconds). Used together with
    /// `last_swap_unix_secs` to render the cooldown countdown.
    pub configured_hysteresis_secs: f64,
}

/// Science — operator-configured fallback plan consulted by
/// `RecoveryAction::SwitchTargetOrFilter`. Either field may be `None`:
///
/// * `backup_filter = Some, backup_target_id = None` => stay on this
///   target, switch to a haze-tolerant filter (e.g. RGB → Lum/Clear).
/// * `backup_target_id = Some, backup_filter = None` => skip to a
///   brighter backup target subtree without touching the filter wheel.
/// * Both `Some` => skip to the backup target AND apply the filter
///   swap once the new target's subtree starts.
/// * Both `None` => no fallback (recovery falls back to
///   `PauseAndWaitForClear`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct TransparencyBackupPlan {
    /// Filter to switch to when transparency drops (e.g. `"Lum"`).
    pub backup_filter: Option<String>,
    /// Sequence node id to skip to when transparency drops.
    pub backup_target_id: Option<String>,
    /// Optional human-readable description surfaced in the UI / logs.
    #[serde(default)]
    pub description: Option<String>,
}

/// Science — per-photometry-node timing record persisted in
/// `ExecutionContext::science_photometry_states`.
#[derive(Debug, Clone, Default)]
pub struct PhotometryRuntimeState {
    /// Unix epoch seconds at which the previous frame started exposing.
    /// `None` before the first frame of the burst.
    pub last_frame_start_unix_secs: Option<f64>,
    /// Total frames captured by this node so far this session
    /// (regardless of accept/reject verdict).
    pub frames_captured: u32,
    /// Cumulative cadence-broken warnings emitted by this node.
    pub cadence_breaks: u32,
}

/// payload threaded from the executor's command handler
/// back to the `PluginNodeInstruction` that emitted the request. Kept
/// outside the public bridge / FRB surface because the oneshot is purely
/// an in-process synchronisation primitive.
#[derive(Debug, Clone)]
pub struct PluginNodeReply {
    pub success: bool,
    pub message: Option<String>,
    /// Optional plugin-authored structured detail (already parsed from
    /// the wire JSON). `None` => no structured payload (the synthetic
    /// "completed" progress tick uses an empty object).
    pub structured_detail: Option<serde_json::Value>,
}

impl ExecutionContext {
    /// Build a context for `node_id` against `device_ops`.
    ///
    /// The device handle is a constructor argument rather than a default
    /// because every instruction (slew, expose, autofocus, safety poll) routes
    /// through it: a context that fell back to [`NullDeviceOps`] would answer
    /// `safety_is_safe` = true and fabricate HFR readings against real
    /// hardware. `SequenceExecutor` refuses to start without a handle for the
    /// same reason.
    pub fn new(node_id: NodeId, device_ops: SharedDeviceOps) -> Self {
        Self {
            node_id,
            target_ra: None,
            target_dec: None,
            target_name: None,
            target_rotation: None,
            current_filter: None,
            current_binning: crate::Binning::One,
            is_cancelled: Arc::new(AtomicBool::new(false)),
            is_paused: Arc::new(AtomicBool::new(false)),
            recovery_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            skip_to_next_target: Arc::new(AtomicBool::new(false)),
            scheduler_completed_exposures: Arc::new(AtomicU64::new(0)),
            scheduler_recompute_cadence: Arc::new(AtomicU32::new(0)),
            scheduler_recompute_baseline: Arc::new(AtomicU64::new(0)),
            scheduler_recompute_requested: Arc::new(AtomicBool::new(false)),
            skip_to_node: Arc::new(parking_lot::RwLock::new(None)),
            resume_notify: Arc::new(tokio::sync::Notify::new()),
            progress_callback: None,
            polar_align_image_callback: None,
            camera_id: None,
            mount_id: None,
            focuser_id: None,
            filterwheel_id: None,
            rotator_id: None,
            dome_id: None,
            cover_calibrator_id: None,
            save_path: None,
            latitude: None,
            longitude: None,
            device_ops,
            device_locks: Arc::new(DeviceLockRegistry::default()),
            completed_integration_secs: Arc::new(RwLock::new(0.0)),
            trigger_state: None,
            safety_fail_mode: Arc::new(parking_lot::RwLock::new(SafetyFailMode::default())),
            // W1 native daylight gate — default threshold mirrors the Dart
            // scheduler's `maxSunAltitudeDegrees`; the executor overrides this
            // from `RuntimeConfig::max_sun_altitude_degrees` at start.
            max_sun_altitude_degrees: crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
            filter_focus_offsets: std::collections::HashMap::new(),
            event_tx: None,
            recovery_request_tx: None,
            device_disconnect_recovery_pending: Arc::new(AtomicBool::new(false)),
            smart_exposure_states: Arc::new(RwLock::new(std::collections::HashMap::new())),
            // No checkpoint manager outside a session: wizard step state
            // is not persisted and every run starts at step 0. The
            // executor installs its own Arc at start().
            checkpoint_manager: None,
            depth_goal_ops: None,
            budget_registry: BudgetRegistry::new(),
            // Image Grading: a non-empty session id is preferred to
            // "" so log lines always render a stable identifier; default
            // constructions get a new uuid so test runs are individually
            // identifiable.
            session_id: uuid::Uuid::new_v4().to_string(),
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
            last_plate_solve: Arc::new(RwLock::new(None)),
            hfr_baseline: Arc::new(RwLock::new(None)),
            hfr_baseline_samples: Arc::new(RwLock::new(Vec::new())),
            consecutive_rejects: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            exposure_trigger_episodes: Arc::default(),
            frames_accepted: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_rejected: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            default_quality_check: None,
            reject_folder_path: None,
            // production path uses the real wall clock; tests
            // override via `with_clock` to pin time.
            clock: default_clock(),
            // sky brightness starts unknown; the Dart
            // layer pushes the first reading once the tracker has
            // converged.
            current_sky_brightness_mag: Arc::new(RwLock::new(None)),
            default_adaptive_exposure: Arc::new(RwLock::new(None)),
            // empty snapshot; Dart pushes the first
            // sample once `cloudMotionAnalyzerProvider` produces data.
            cloud_motion_snapshot: Arc::new(RwLock::new(CloudMotionSnapshot::default())),
            // empty pending-plugin map; entries are added
            // and removed by `PluginNodeInstruction` + the executor's
            // command handler.
            plugin_node_pending: Arc::new(RwLock::new(std::collections::HashMap::new())),
            // defect map disabled by default. The
            // bridge pushes a `Some(...)` value once the user toggles
            // "Apply during capture" on for the connected camera.
            defect_map_apply: Arc::new(RwLock::new(None)),
            // Science — transparency reading starts unknown; the
            // Dart science pipeline pushes the first sample via
            // `ExecutorCommand::UpdateTransparency`. The backup plan
            // starts unset; the photometry timing map starts empty.
            current_transparency: Arc::new(RwLock::new(None)),
            transparency_backup_plan: Arc::new(RwLock::new(None)),
            science_photometry_states: Arc::new(RwLock::new(std::collections::HashMap::new())),
            // Replay Debug — `None` until the executor installs a
            // sender via `with_decision_sender(...)`. Test contexts left
            // at `None` produce no-op decision emissions.
            decision_tx: None,
            active_sequence_run_id: Arc::new(parking_lot::RwLock::new(None)),
            // Forensics — empty ring buffer; entries are appended
            // by the expose path after every accepted/rejected frame.
            forensics_history: Arc::new(RwLock::new(std::collections::VecDeque::with_capacity(
                crate::quality::FORENSIC_HISTORY_LEN,
            ))),
            current_wind_kph: Arc::new(RwLock::new(None)),
            current_sensor_temp_c: Arc::new(RwLock::new(None)),
            // adaptive sky-conditions swap. Both slots start empty;
            // Dart pushes the first ConditionsScore once the AdaptiveSwapService
            // has composed it, and the TargetScheduler populates the runtime
            // state on its first decision.
            current_conditions_score: Arc::new(RwLock::new(None)),
            adaptive_swap_state: Arc::new(RwLock::new(AdaptiveSwapRuntimeState::default())),
            // no scheduler override active until a
            // TargetScheduler installs one for the duration of its
            // dispatch.
            scheduler_filter_cycle_override: Arc::new(parking_lot::RwLock::new(None)),
            active_target_end_trigger: Arc::new(parking_lot::RwLock::new(None)),
            // Dual-rig — no secondary camera by default; single-rig sequences
            // leave this None and every dither is a plain pass-through.
            dither_barrier: None,
            device_retry: crate::instructions::DeviceRetryHandle::single_attempt(),
        }
    }

    /// Replay Debug — install the decision broadcast sender from
    /// the executor. Builder-style so `start()` can chain it alongside
    /// the existing `with_clock` / `with_device_ops` calls.
    pub fn with_decision_sender(
        mut self,
        tx: crate::decision::DecisionSender,
        active_run_id: Arc<parking_lot::RwLock<Option<i64>>>,
    ) -> Self {
        self.decision_tx = Some(tx);
        self.active_sequence_run_id = active_run_id;
        self
    }

    /// Replay Debug — emit a structured decision into the
    /// broadcast channel. Stamps the active `sequence_runs.id` (if any)
    /// so the persistence layer can populate the FK without re-joining.
    ///
    /// Drop-on-the-floor when no sender is installed (unit tests, one-
    /// shot instruction sites) — emit sites should not need to care
    /// whether they're inside a live executor or not.
    pub fn emit_decision(&self, mut event: crate::decision::DecisionEvent) {
        let Some(tx) = self.decision_tx.as_ref() else {
            return;
        };
        if event.sequence_run_id.is_none() {
            event.sequence_run_id = *self.active_sequence_run_id.read();
        }
        let _ = tx.send(event);
    }

    /// install a pluggable clock. Production callers don't need
    /// this (the default `WallClock` is already wired); test code uses it
    /// to inject a `MockClock`.
    pub fn with_clock(mut self, clock: Arc<dyn Clock>) -> Self {
        self.clock = clock;
        self
    }

    pub fn with_safety_fail_mode(mut self, mode: SafetyFailMode) -> Self {
        self.safety_fail_mode = Arc::new(parking_lot::RwLock::new(mode));
        self
    }

    /// W1 native daylight gate — install the maximum permitted Sun altitude
    /// (degrees) for on-sky LIGHT captures. Builder-style so the executor can
    /// seed it from `RuntimeConfig::max_sun_altitude_degrees` alongside the
    /// other `with_*` calls. A non-finite value falls back to the default so a
    /// misconfiguration can never silently disable the gate.
    pub fn with_max_sun_altitude(mut self, degrees: f64) -> Self {
        self.max_sun_altitude_degrees = if degrees.is_finite() {
            degrees
        } else {
            crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES
        };
        self
    }

    pub fn with_device_ops(mut self, ops: SharedDeviceOps) -> Self {
        self.device_ops = ops;
        self
    }

    /// A context wired to [`NullDeviceOps`], for tests that exercise logic no
    /// device call reaches.
    #[cfg(test)]
    pub(crate) fn new_for_test(node_id: NodeId) -> Self {
        Self::new(node_id, Arc::new(NullDeviceOps))
    }

    pub fn with_target(mut self, name: String, ra: f64, dec: f64, rotation: Option<f64>) -> Self {
        self.target_name = Some(name);
        self.target_ra = Some(ra);
        self.target_dec = Some(dec);
        self.target_rotation = rotation;
        self
    }

    pub async fn is_cancelled(&self) -> bool {
        self.is_cancelled.load(Ordering::Relaxed)
    }

    /// Check if currently paused
    pub fn is_paused(&self) -> bool {
        self.is_paused.load(Ordering::Relaxed)
    }

    /// Request pause and wait for resume
    /// Returns false if cancelled while waiting
    pub async fn pause_and_wait_for_resume(&self) -> bool {
        self.is_paused.store(true, Ordering::Relaxed);
        tracing::info!("Execution paused, waiting for resume...");

        loop {
            tokio::select! {
                _ = self.resume_notify.notified() => {
                    if !self.is_paused.load(Ordering::Relaxed) {
                        tracing::info!("Execution resumed");
                        return true;
                    }
                }
                // Belt-and-suspenders: notify_waiters() and is_paused are not
                // atomically coupled, so a stale notify could fire just before
                // is_paused flips. The 100 ms tick lets us re-check both
                // is_cancelled and is_paused even if no wake-up arrives.
                _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                    if self.is_cancelled.load(Ordering::Relaxed) {
                        tracing::info!("Cancelled while paused");
                        return false;
                    }
                    if !self.is_paused.load(Ordering::Relaxed) {
                        tracing::info!("Execution resumed");
                        return true;
                    }
                }
            }
        }
    }

    /// If execution is currently paused — by an operator Pause or a recovery
    /// freeze — block until it resumes or is cancelled, WITHOUT itself
    /// initiating a pause (unlike [`pause_and_wait_for_resume`], which is for
    /// a node/trigger that wants to *request* a pause).
    ///
    /// Returns `false` if cancelled while waiting (the caller should unwind),
    /// `true` otherwise (not paused, or resumed). Called at container/burst
    /// boundaries so an operator Pause and recovery freeze actually halt the
    /// node tree between instructions instead of being silently ignored.
    pub async fn wait_while_paused(&self) -> bool {
        if !self.is_paused.load(Ordering::Relaxed) {
            return true;
        }
        tracing::info!("Execution paused at boundary, waiting for resume...");
        loop {
            if self.is_cancelled.load(Ordering::Relaxed) {
                tracing::info!("Cancelled while paused at boundary");
                return false;
            }
            if !self.is_paused.load(Ordering::Relaxed) {
                tracing::info!("Execution resumed at boundary");
                return true;
            }
            tokio::select! {
                _ = self.resume_notify.notified() => {}
                _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
            }
        }
    }

    /// Resume execution (called by executor)
    pub fn resume(&self) {
        self.is_paused.store(false, Ordering::Relaxed);
        self.resume_notify.notify_waiters();
    }

    /// Detachable handle onto this run's pause state.
    ///
    /// [`wait_while_paused`](Self::wait_while_paused) only reaches code that
    /// holds an `ExecutionContext`, which is the node tree — every check
    /// therefore lands *between* instructions. Instructions that loop over
    /// units of work internally (an exposure burst is N frames inside ONE
    /// node) never saw the flag at all, so an operator Pause showed a PAUSED
    /// badge while the camera kept opening the shutter for the rest of the
    /// burst. This handle is what those loops take so they can honour the
    /// same flag without the whole context.
    pub fn pause_gate(&self) -> PauseGate {
        PauseGate {
            handles: Some((self.is_paused.clone(), self.resume_notify.clone())),
        }
    }

    /// Request that execution skips the current target and advances to the next one.
    pub fn request_skip_to_next_target(&self) {
        self.skip_to_next_target.store(true, Ordering::Relaxed);
    }

    /// Check whether a skip-to-next-target request is pending.
    pub fn is_skip_to_next_target_requested(&self) -> bool {
        self.skip_to_next_target.load(Ordering::Relaxed)
    }

    /// Clear a pending skip-to-next-target request.
    pub fn clear_skip_to_next_target_request(&self) {
        self.skip_to_next_target.store(false, Ordering::Relaxed);
    }

    /// Arm TargetScheduler exposure-cadence recompute for the active target.
    pub fn configure_scheduler_recompute(&self, cadence: u32) {
        self.scheduler_recompute_cadence
            .store(cadence, Ordering::Relaxed);
        self.scheduler_recompute_baseline
            .store(self.scheduler_completed_exposures(), Ordering::Relaxed);
        self.scheduler_recompute_requested
            .store(false, Ordering::Relaxed);
    }

    /// Disable scheduler-driven child-boundary preemption.
    pub fn clear_scheduler_recompute(&self) {
        self.scheduler_recompute_cadence.store(0, Ordering::Relaxed);
        self.scheduler_recompute_requested
            .store(false, Ordering::Relaxed);
    }

    /// Count successful exposures and request a scheduler re-plan once the
    /// active cadence has elapsed. The request uses the existing
    /// skip-to-next-target signal so loops and sequential containers yield
    /// at their normal safe boundaries; the separate recompute flag lets
    /// TargetScheduler distinguish this from a user/manual skip.
    pub fn record_scheduler_completed_exposures(&self, count: u64) {
        if count == 0 {
            return;
        }
        let completed = self
            .scheduler_completed_exposures
            .fetch_add(count, Ordering::Relaxed)
            .saturating_add(count);
        let cadence = self.scheduler_recompute_cadence.load(Ordering::Relaxed);
        if cadence == 0 {
            return;
        }
        let baseline = self.scheduler_recompute_baseline.load(Ordering::Relaxed);
        if completed.saturating_sub(baseline) >= u64::from(cadence) {
            self.scheduler_recompute_requested
                .store(true, Ordering::Relaxed);
            self.request_skip_to_next_target();
        }
    }

    pub fn scheduler_completed_exposures(&self) -> u64 {
        self.scheduler_completed_exposures.load(Ordering::Relaxed)
    }

    pub fn take_scheduler_recompute_request(&self) -> bool {
        self.scheduler_recompute_requested
            .swap(false, Ordering::Relaxed)
    }

    /// install a multi-filter cycle override for the duration
    /// of the next subtree execution. Returns the prior value so the
    /// caller can restore it on exit. Callers MUST pair `install_` with
    /// `set_` of the restored value on every exit path (Success, Failure,
    /// Skipped, Cancelled, early-return) — the helper is paired with
    /// [`SchedulerCycleGuard`] elsewhere to make the restoration
    /// drop-safe.
    pub fn install_scheduler_filter_cycle_override(
        &self,
        mode: Option<crate::FilterCycleMode>,
    ) -> Option<crate::FilterCycleMode> {
        let mut slot = self.scheduler_filter_cycle_override.write();
        let prior = *slot;
        *slot = mode;
        prior
    }

    /// read the active multi-filter cycle override (if any).
    /// Returns `None` when no scheduler has installed one OR the installed
    /// mode is `SingleFilter` (the dispatch path uses `is_active()` to
    /// gate, so SingleFilter is treated identically to "no override" at
    /// the consumer site).
    pub fn scheduler_filter_cycle_override(&self) -> Option<crate::FilterCycleMode> {
        *self.scheduler_filter_cycle_override.read()
    }

    /// Install the active target's `end_when` stop trigger for the duration
    /// of a TargetHeader child subtree. Returns the prior value so the
    /// caller can restore it on exit. Callers MUST restore on every exit
    /// path so the trigger does not leak into sibling subtrees (the same
    /// install/restore discipline as
    /// [`Self::install_scheduler_filter_cycle_override`]).
    pub fn install_active_target_end_trigger(
        &self,
        trigger: Option<crate::scheduling::TargetTrigger>,
    ) -> Option<crate::scheduling::TargetTrigger> {
        let mut slot = self.active_target_end_trigger.write();
        let prior = slot.take();
        *slot = trigger;
        prior
    }

    /// Read the active target's `end_when` stop trigger, if a surrounding
    /// TargetHeader installed one. Used by internally-looping instruction
    /// nodes (SmartExposure `loop_until_stopped`) to detect the target
    /// window closing between sub-exposure batches.
    pub fn active_target_end_trigger(&self) -> Option<crate::scheduling::TargetTrigger> {
        self.active_target_end_trigger.read().clone()
    }

    /// Evaluate the active target's `end_when` trigger against the current
    /// observer/target snapshot. Returns:
    ///   * `Some(true)`  — a trigger is installed and is satisfied right now
    ///     (the target window has closed; the loop should stop);
    ///   * `Some(false)` — a trigger is installed but not yet satisfied;
    ///   * `None`        — no trigger is installed, OR an altitude-bearing
    ///     trigger cannot be evaluated because observer/target coordinates
    ///     are missing. `None` is deliberately distinct from `Some(false)`
    ///     so callers can tell "no bound" apart from "bounded, not yet met"
    ///     and refuse to enter an unbounded infinite loop.
    pub fn active_target_end_trigger_satisfied(&self) -> Option<bool> {
        let trigger = self.active_target_end_trigger.read().clone()?;
        let (ra, dec) = match (self.target_ra, self.target_dec) {
            (Some(ra), Some(dec)) => (ra, dec),
            _ => {
                // Time-based triggers don't need coordinates; altitude/HA
                // ones do. Only bail when the trigger actually references
                // altitude (or hour angle) and we lack the coordinates to
                // evaluate it.
                if trigger.references_altitude() {
                    return None;
                }
                (0.0, 0.0)
            }
        };
        if trigger.references_altitude() && (self.latitude.is_none() || self.longitude.is_none()) {
            return None;
        }
        let ctx = crate::scheduling::TriggerObserverContext {
            latitude_deg: self.latitude.unwrap_or(0.0),
            longitude_deg: self.longitude.unwrap_or(0.0),
            target_ra_hours: ra,
            target_dec_degrees: dec,
            now: self.clock.now_utc(),
        };
        Some(trigger.is_satisfied(&ctx))
    }

    /// Read the current SkipToNode target, if any.
    /// Returns the target node id when the executor is in "skip until we
    /// reach this node" mode; None otherwise.
    pub fn skip_to_node_target(&self) -> Option<NodeId> {
        self.skip_to_node.read().clone()
    }

    /// Clear the SkipToNode request, signalling that execution has reached (or
    /// recursed into) the target subtree and normal execution should resume.
    pub fn clear_skip_to_node_request(&self) {
        *self.skip_to_node.write() = None;
    }

    /// Set the SkipToNode request from outside the tree walk (called by the
    /// executor command handler).
    pub fn set_skip_to_node_request(&self, node_id: NodeId) {
        *self.skip_to_node.write() = Some(node_id);
    }

    pub fn send_progress(&self, update: ProgressUpdate) {
        // Integration time is not tracked here: the canonical update happens on
        // the awaiting path in `TakeExposure` (the
        // `completed_integration_secs.write().await` block in the exposure
        // instruction). `send_progress` is sync because it is invoked from the
        // synchronous progress callbacks supplied to instruction code.
        if let Some(callback) = &self.progress_callback {
            callback(update);
        }
    }

    /// Get the current completed integration time in seconds
    pub async fn get_completed_integration_secs(&self) -> f64 {
        *self.completed_integration_secs.read().await
    }

    /// Calculate current altitude of target based on RA/Dec and observer location
    pub fn calculate_altitude(&self) -> Option<f64> {
        let ra_hours = self.target_ra?;
        let dec_degrees = self.target_dec?;
        let lat = self.latitude?;
        let lon = self.longitude?;

        let now = chrono::Utc::now();
        let jd = crate::meridian::julian_day(&now);
        let lst = crate::meridian::local_sidereal_time(jd, lon);

        let ha = lst - ra_hours;
        let ha_rad = (ha * 15.0).to_radians(); // RA is stored in hours; 1 h = 15°
        let dec_rad = dec_degrees.to_radians();
        let lat_rad = lat.to_radians();

        // Standard astronomy formula: sin(alt) = sin(lat)·sin(dec) + cos(lat)·cos(dec)·cos(HA)
        let sin_alt = lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos();
        Some(sin_alt.asin().to_degrees())
    }

    /// Calculate separation between target and moon in degrees
    pub fn calculate_moon_separation(&self) -> Option<f64> {
        let target_ra = self.target_ra?;
        let target_dec = self.target_dec?;

        // Low-precision lunar ephemeris adequate for moon-avoidance: the
        // ConditionalCheck::MoonSeparationAbove threshold is typically tens of
        // degrees, so the ~0.1° error this approximation incurs is irrelevant
        // and avoids pulling in a full ephemeris dependency.
        let now = chrono::Utc::now();
        let jd = crate::meridian::julian_day(&now);
        let days = jd - 2451545.0;

        // Mean longitude, mean anomaly, ascending-node longitude (Meeus low-precision).
        let moon_longitude = (218.32 + 13.176396 * days) % 360.0;
        let moon_anomaly = (134.9 + 13.064993 * days) % 360.0;
        let moon_node = (93.3 + 13.229350 * days) % 360.0;

        // Two largest periodic terms only (evection + variation analogues).
        let ecl_lon = moon_longitude + 6.29 * moon_anomaly.to_radians().sin()
            - 1.27 * (2.0 * moon_node.to_radians() - moon_anomaly.to_radians()).sin();
        let ecl_lat = 5.13 * moon_node.to_radians().sin();

        let obliquity = 23.439f64;
        let ecl_lon_rad = ecl_lon.to_radians();
        let ecl_lat_rad = ecl_lat.to_radians();
        let obl_rad = obliquity.to_radians();

        let moon_ra = ((ecl_lon_rad.sin() * obl_rad.cos() - ecl_lat_rad.tan() * obl_rad.sin())
            .atan2(ecl_lon_rad.cos()))
        .to_degrees()
            / 15.0; // Convert to hours
        let moon_dec = (ecl_lat_rad.sin() * obl_rad.cos()
            + ecl_lat_rad.cos() * obl_rad.sin() * ecl_lon_rad.sin())
        .asin()
        .to_degrees();

        // Spherical law of cosines: cos(sep) = sin(d1)sin(d2) + cos(d1)cos(d2)cos(Δra).
        // Adequate for moon avoidance — haversine's small-angle precision is
        // unnecessary at the tens-of-degrees thresholds users configure.
        let target_ra_rad = (target_ra * 15.0).to_radians();
        let target_dec_rad = target_dec.to_radians();
        let moon_ra_rad = (moon_ra * 15.0).to_radians();
        let moon_dec_rad = moon_dec.to_radians();

        let cos_sep = target_dec_rad.sin() * moon_dec_rad.sin()
            + target_dec_rad.cos() * moon_dec_rad.cos() * (target_ra_rad - moon_ra_rad).cos();

        Some(cos_sep.acos().to_degrees())
    }

    /// Check if it's currently dark (astronomical twilight has ended)
    pub fn is_dark(&self) -> Option<bool> {
        let lat = self.latitude?;
        let lon = self.longitude?;

        let sun_alt = current_sun_altitude_degrees(lat, lon);

        // Astronomical twilight ends when the sun is more than 18° below the
        // horizon — the IAU-adopted definition; deep-sky imaging targets this
        // boundary because any brighter sky elevates the background floor.
        Some(sun_alt < -18.0)
    }

    /// Set the next meridian flip time in the trigger state (if available)
    /// If trigger state is not accessible, the timestamp is skipped.
    pub async fn set_next_meridian_flip_time(&self, timestamp: Option<i64>) {
        if let Some(trigger_state_lock) = &self.trigger_state {
            let mut trigger_state = trigger_state_lock.write().await;
            trigger_state.next_meridian_flip_time = timestamp;
        } else if let Some(ts) = timestamp {
            tracing::debug!(
                "Meridian flip timestamp {} calculated but trigger state is unavailable",
                ts
            );
        }
    }

    /// Build an InstructionContext from this ExecutionContext.
    ///
    /// `node_id` is the node being executed, which the caller must supply — an
    /// `ExecutionContext` is run-scoped and its own `node_id` is the ROOT (only
    /// parallel branches and recovery rewrite it), so it cannot answer "which
    /// node is running". Instruction nodes get the real id as an argument to
    /// `InstructionNode::execute`; pass that through. Frame registration in the
    /// app depends on it (see [`InstructionContext::node_id`]), so a wrong id
    /// silently mis-attributes captured frames rather than failing loudly.
    pub async fn to_instruction_context(&self, node_id: &str) -> InstructionContext {
        InstructionContext {
            node_id: node_id.to_string(),
            target_ra: self.target_ra,
            target_dec: self.target_dec,
            target_rotation: self.target_rotation,
            target_name: self.target_name.clone(),
            current_filter: self.current_filter.clone(),
            current_binning: self.current_binning,
            cancellation_token: self.is_cancelled.clone(),
            camera_id: self.camera_id.clone(),
            mount_id: self.mount_id.clone(),
            focuser_id: self.focuser_id.clone(),
            filterwheel_id: self.filterwheel_id.clone(),
            rotator_id: self.rotator_id.clone(),
            dome_id: self.dome_id.clone(),
            cover_calibrator_id: self.cover_calibrator_id.clone(),
            save_path: self.save_path.clone(),
            latitude: self.latitude,
            longitude: self.longitude,
            device_ops: self.device_ops.clone(),
            trigger_state: self.trigger_state.clone(),
            filter_focus_offsets: self.filter_focus_offsets.clone(),
            event_tx: self.event_tx.clone(),
            recovery_request_tx: self.recovery_request_tx.clone(),
            device_disconnect_recovery_pending: self.device_disconnect_recovery_pending.clone(),
            // Image Grading: thread the FITS-header metadata
            // through so execute_exposure can assemble a FrameContext at
            // save time. These fields are all cheap clones (Strings/Options/
            // Arc handles) so the per-instruction context build remains O(1).
            session_id: self.session_id.clone(),
            target_id: self.target_id.clone(),
            mosaic_panel: self.mosaic_panel.clone(),
            current_filter_index: self.current_filter_index,
            set_temp_c: self.set_temp_c,
            bayer_pattern: self.bayer_pattern.clone(),
            observer_name: self.observer_name.clone(),
            site_elevation_m: self.site_elevation_m,
            camera_make: self.camera_make.clone(),
            camera_model: self.camera_model.clone(),
            telescope_name: self.telescope_name.clone(),
            telescope_focal_length_mm: self.telescope_focal_length_mm,
            telescope_aperture_mm: self.telescope_aperture_mm,
            last_plate_solve: self.last_plate_solve.clone(),
            hfr_baseline: self.hfr_baseline.clone(),
            hfr_baseline_samples: self.hfr_baseline_samples.clone(),
            consecutive_rejects: self.consecutive_rejects.clone(),
            frames_accepted: self.frames_accepted.clone(),
            frames_rejected: self.frames_rejected.clone(),
            // seeded from RuntimeConfig at executor.start() via the
            // ExecutionContext fields. Per-node `quality_check` on
            // ExposureConfig still wins; this is the global fallback.
            default_quality_check: self.default_quality_check.clone(),
            reject_folder_path: self.reject_folder_path.clone(),
            // share the Arc handle so the capture
            // path's runtime read sees the latest defect-map toggle
            // even if the user flips it mid-burst.
            defect_map_apply: self.defect_map_apply.clone(),
            // Forensics history + live env Arcs propagated by
            // reference clone so `emit_grade_progress` can read the
            // shared state without re-borrowing `ExecutionContext`.
            forensics_history: self.forensics_history.clone(),
            current_sky_brightness_mag: self.current_sky_brightness_mag.clone(),
            cloud_motion_snapshot: self.cloud_motion_snapshot.clone(),
            current_wind_kph: self.current_wind_kph.clone(),
            current_sensor_temp_c: self.current_sensor_temp_c.clone(),
            // Replay Debug — propagate the decision sender / run-id
            // so instruction code can emit decisions even though the
            // sender was added to `InstructionContext` after this
            // function was first written.
            decision_tx: self.decision_tx.clone(),
            active_sequence_run_id: self.active_sequence_run_id.clone(),
            // Dual-rig — share the barrier Arc so the dither call sites in
            // `instructions::{execute_dither, execute_exposure}` can coordinate
            // with the secondary capture loop.
            dither_barrier: self.dither_barrier.clone(),
            device_retry: self.device_retry.clone(),
        }
    }
}

/// Compute the Sun's current altitude (degrees above the horizon) for an
/// observer at `latitude` / `longitude` (degrees). Positive = Sun above the
/// horizon.
///
/// `is_dark` answers the binary astronomical-twilight question, whereas the
/// native daylight START gate (`instructions::execute_slew` /
/// `instructions::execute_exposure`) needs the continuous altitude so it can
/// compare against a configurable `max_sun_altitude_degrees` that mirrors the
/// Dart scheduler's `maxSunAltitudeDegrees`. A free `pub(crate)` fn rather
/// than a method so the instruction layer can call it without an
/// `ExecutionContext`.
pub(crate) fn current_sun_altitude_degrees(latitude: f64, longitude: f64) -> f64 {
    crate::solar::sun_altitude_degrees(latitude, longitude, &chrono::Utc::now())
}

/// Normalize an observer location, mapping the Null Island sentinel to "unset".
///
/// An operator who never entered a site is UNKNOWN, not at (0°, 0°) in the Gulf
/// of Guinea — but that is exactly how absence reaches the sequencer: the
/// persisted settings carry `Some(lat: 0, lon: 0)` and the bridge seeds it
/// verbatim. The daylight gate then computed a real Sun altitude for Greenwich
/// and refused every light frame of an Australian night, blaming the Sun for a
/// missing setting. Every consumer of the site (gate, altitude limits, dawn,
/// meridian hour angle) is better served by knowing it does not know.
///
/// A partial pair is also unset: half a location cannot place a telescope.
pub(crate) fn normalized_observer_location(
    latitude: Option<f64>,
    longitude: Option<f64>,
) -> (Option<f64>, Option<f64>) {
    match (latitude, longitude) {
        (Some(lat), Some(lon)) if lat == 0.0 && lon == 0.0 => {
            tracing::info!(
                "Observer location (0, 0) treated as unset: no observing site is configured"
            );
            (None, None)
        }
        (Some(lat), Some(lon)) => (Some(lat), Some(lon)),
        _ => (None, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The instruction context must carry the producing node id: with an empty
    /// `node_id`, `emit_grade_progress` emits FrameAccepted / FrameRejected
    /// events the app drops instead of writing a `captured_images` row — no
    /// gallery entry, no integration total, no per-target completion, the frames
    /// existing only as files on disk.
    #[tokio::test]
    async fn instruction_context_carries_producing_node_id() {
        // The run-scoped context is rooted at "root"; the instruction context
        // must report the node the caller names, not the root — mixing those up
        // is what mis-attributed every captured frame to the root node.
        let ctx = ExecutionContext::new_for_test("root".to_string());
        let ictx = ctx.to_instruction_context("exposure-node-7").await;
        assert_eq!(ictx.node_id, "exposure-node-7");
    }

    #[test]
    fn execution_context_is_clone() {
        let ctx = ExecutionContext::new_for_test("root".to_string());
        let cloned = ctx.clone();
        assert_eq!(cloned.node_id, ctx.node_id);
        // Arc fields must point at the same allocation (shared state preserved).
        assert!(Arc::ptr_eq(&cloned.is_cancelled, &ctx.is_cancelled));
        assert!(Arc::ptr_eq(&cloned.is_paused, &ctx.is_paused));
        assert!(Arc::ptr_eq(
            &cloned.completed_integration_secs,
            &ctx.completed_integration_secs
        ));
    }

    #[test]
    fn clone_preserves_progress_callback_identity() {
        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        let counter = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter_clone = counter.clone();
        ctx.progress_callback = Some(Arc::new(move |_| {
            counter_clone.fetch_add(1, Ordering::Relaxed);
        }));
        let cloned = ctx.clone();
        // Both contexts share the same callback Arc; firing through either
        // bumps the same counter.
        cloned.send_progress(ProgressUpdate::lifecycle(
            "n".to_string(),
            crate::NodeStatus::Running,
            "first",
        ));
        ctx.send_progress(ProgressUpdate::lifecycle(
            "n".to_string(),
            crate::NodeStatus::Running,
            "second",
        ));
        assert_eq!(counter.load(Ordering::Relaxed), 2);
    }
}
