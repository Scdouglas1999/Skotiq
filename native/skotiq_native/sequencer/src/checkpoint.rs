//! Session checkpoint for crash recovery
//!
//! This module provides functionality to save and restore sequence execution state
//! for recovery after unexpected crashes or restarts.

use crate::scheduling::BudgetRegistrySnapshot;
use crate::triggers::TriggerState;
use crate::{
    ExecutorState, MeridianTriggerMethod, NodeId, NodeStatus, PierSide, SafetyFailMode,
    SequenceDefinition, SmartExposureCheckpoint,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

/// Current checkpoint schema version.
///
/// Version history:
/// * v1: original; node-level resume only.
/// * v2: adds `trigger_state` for trigger-state resume.
/// * v3: adds `wizard_states` for wizard-internal step-level resume (e.g.
///   flat-wizard binary-search trial number, mosaic panel index). Old
///   checkpoints without `wizard_states` deserialize with `default` and
///   resume from step 0 of each wizard, which matches pre-v3 behavior.
pub const CHECKPOINT_VERSION: u32 = 3;

/// Step-level resume record for a wizard. Stored inside
/// [`SessionCheckpoint::wizard_states`] keyed by
/// [`crate::wizard::Wizard::checkpoint_key`]. On resume the
/// `WizardExecutor` reads this and skips the first `completed_steps`
/// planned steps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WizardCheckpoint {
    /// Stable identifier of the wizard kind, e.g. `"flat_wizard"`.
    pub checkpoint_key: String,
    /// Number of plan steps already finished. The executor resumes at
    /// step index `completed_steps`.
    pub completed_steps: u32,
    /// When the checkpoint was written.
    pub timestamp: DateTime<Utc>,
}

/// Per-scheduler resume state.
///
/// Stored inside [`SessionCheckpoint::scheduler_states`] keyed by the
/// scheduler node's id (sequences may contain more than one TargetScheduler).
/// `current_target_id` is the last-picked target's child node id;
/// `exposures_in_current_target` lets the in-target recompute cadence resume
/// where it left off. Old checkpoints lacking this field deserialize to an
/// empty map and resume with a fresh decision — backwards-compatible.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchedulerCheckpoint {
    /// Scheduler node id (matches `NodeDefinition::id` of the
    /// `TargetScheduler` variant). Stored for cross-validation on resume.
    pub scheduler_node_id: String,
    /// Last picked target's child node id, or `None` if the last decision
    /// produced no runnable target.
    pub current_target_id: Option<String>,
    /// Exposures completed inside the current target subtree since the last
    /// decision; surfaces the `recompute_every_n_exposures` cadence on resume.
    pub exposures_in_current_target: u32,
    /// 1-based decision counter. Resumes from `decision_counter + 1` so the
    /// Run Dashboard's row indices stay monotonic across resume.
    pub decision_counter: u32,
    /// When the checkpoint was written.
    pub timestamp: DateTime<Utc>,
}

/// Serializable copy of trigger state needed to resume without repeating actions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TriggerStateSnapshot {
    pub baseline_hfr: Option<f64>,
    pub current_hfr: Option<f64>,
    pub autofocus_invalidated: bool,
    pub autofocus_invalidation_reason: Option<String>,
    pub current_hour_angle: Option<f64>,
    pub pier_side: Option<PierSide>,
    pub mount_tracking_limit_time: Option<i64>,
    pub has_flipped_this_target: bool,
    pub current_target_name: Option<String>,
    pub next_meridian_flip_time: Option<i64>,
    pub guiding_enabled: bool,
    pub guide_star_lost: bool,
    pub current_humidity: Option<f64>,
    pub current_altitude: Option<f64>,
    pub weather_safe: bool,
    pub baseline_temperature: Option<f64>,
    pub current_temperature: Option<f64>,
    pub baseline_focuser_position: Option<i32>,
    pub filter_changed: bool,
    pub current_filter: Option<String>,
    pub dawn_time: Option<i64>,
    pub observer_latitude: Option<f64>,
    pub observer_longitude: Option<f64>,
    pub completed_exposures: u32,
    pub last_autofocus_frame: u32,
    pub last_dither_frame: u32,
    pub last_plate_solve_ra: Option<f64>,
    pub last_plate_solve_dec: Option<f64>,
    pub last_plate_solve_pixel_scale: Option<f64>,
    pub target_ra: Option<f64>,
    pub target_dec: Option<f64>,
    pub mount_is_tracking: Option<bool>,
    pub mount_tracking_expected: bool,
    pub mount_tracking_lost: bool,
    pub mount_slewing: Option<bool>,
    pub mount_parked: Option<bool>,
    pub mount_status_query_failed: bool,
    pub tracking_limit_detected_at: Option<i64>,
    pub meridian_trigger_method: Option<MeridianTriggerMethod>,
    pub dome_shutter_status: Option<String>,
    pub dome_shutter_open_expected: bool,
    pub grid_dither_index: u32,
    pub safety_fail_mode: SafetyFailMode,
    pub triggers_enabled: bool,
    pub filter_focus_offsets: HashMap<String, i32>,
    /// Filter focus offset currently embodied in the focuser position so a
    /// resumed sequence applies the next filter change as a delta rather than
    /// re-stacking. `#[serde(default)]` keeps legacy checkpoints loadable.
    #[serde(default)]
    pub last_applied_filter_offset: i32,
}

impl TriggerStateSnapshot {
    pub fn from_state(
        state: &TriggerState,
        safety_fail_mode: SafetyFailMode,
        triggers_enabled: bool,
        filter_focus_offsets: HashMap<String, i32>,
    ) -> Self {
        Self {
            baseline_hfr: state.baseline_hfr,
            current_hfr: state.current_hfr,
            autofocus_invalidated: state.autofocus_invalidated,
            autofocus_invalidation_reason: state.autofocus_invalidation_reason.clone(),
            current_hour_angle: state.current_hour_angle,
            pier_side: state.pier_side,
            mount_tracking_limit_time: state.mount_tracking_limit_time,
            has_flipped_this_target: state.has_flipped_this_target,
            current_target_name: state.current_target_name.clone(),
            next_meridian_flip_time: state.next_meridian_flip_time,
            guiding_enabled: state.guiding_enabled,
            guide_star_lost: state.guide_star_lost,
            current_humidity: state.current_humidity,
            current_altitude: state.current_altitude,
            weather_safe: state.weather_safe,
            baseline_temperature: state.baseline_temperature,
            current_temperature: state.current_temperature,
            baseline_focuser_position: state.baseline_focuser_position,
            filter_changed: state.filter_changed,
            current_filter: state.current_filter.clone(),
            dawn_time: state.dawn_time,
            observer_latitude: state.observer_latitude,
            observer_longitude: state.observer_longitude,
            completed_exposures: state.completed_exposures,
            last_autofocus_frame: state.last_autofocus_frame,
            last_dither_frame: state.last_dither_frame,
            last_plate_solve_ra: state.last_plate_solve_ra,
            last_plate_solve_dec: state.last_plate_solve_dec,
            last_plate_solve_pixel_scale: state.last_plate_solve_pixel_scale,
            target_ra: state.target_ra,
            target_dec: state.target_dec,
            mount_is_tracking: state.mount_is_tracking,
            mount_tracking_expected: state.mount_tracking_expected,
            mount_tracking_lost: state.mount_tracking_lost,
            mount_slewing: state.mount_slewing,
            mount_parked: state.mount_parked,
            mount_status_query_failed: state.mount_status_query_failed,
            tracking_limit_detected_at: state.tracking_limit_detected_at,
            meridian_trigger_method: state.meridian_trigger_method,
            dome_shutter_status: state.dome_shutter_status.clone(),
            dome_shutter_open_expected: state.dome_shutter_open_expected,
            grid_dither_index: state.grid_dither_index,
            safety_fail_mode,
            triggers_enabled,
            filter_focus_offsets,
            last_applied_filter_offset: state.last_applied_filter_offset,
        }
    }

    pub fn restore_into(&self, state: &mut TriggerState) {
        state.restored_from_checkpoint = true;
        state.baseline_hfr = self.baseline_hfr;
        state.current_hfr = self.current_hfr;
        state.autofocus_invalidated = self.autofocus_invalidated;
        state.autofocus_invalidation_reason = self.autofocus_invalidation_reason.clone();
        state.current_hour_angle = self.current_hour_angle;
        state.pier_side = self.pier_side;
        state.mount_tracking_limit_time = self.mount_tracking_limit_time;
        state.has_flipped_this_target = self.has_flipped_this_target;
        state.current_target_name = self.current_target_name.clone();
        state.next_meridian_flip_time = self.next_meridian_flip_time;
        state.guiding_enabled = self.guiding_enabled;
        state.guide_star_lost = self.guide_star_lost;
        state.current_humidity = self.current_humidity;
        state.current_altitude = self.current_altitude;
        state.weather_safe = self.weather_safe;
        state.baseline_temperature = self.baseline_temperature;
        state.current_temperature = self.current_temperature;
        state.baseline_focuser_position = self.baseline_focuser_position;
        state.filter_changed = self.filter_changed;
        state.current_filter = self.current_filter.clone();
        state.dawn_time = self.dawn_time;
        state.observer_latitude = self.observer_latitude;
        state.observer_longitude = self.observer_longitude;
        state.completed_exposures = self.completed_exposures;
        state.last_autofocus_frame = self.last_autofocus_frame;
        state.last_dither_frame = self.last_dither_frame;
        state.last_plate_solve_ra = self.last_plate_solve_ra;
        state.last_plate_solve_dec = self.last_plate_solve_dec;
        state.last_plate_solve_pixel_scale = self.last_plate_solve_pixel_scale;
        state.target_ra = self.target_ra;
        state.target_dec = self.target_dec;
        state.mount_is_tracking = self.mount_is_tracking;
        state.mount_tracking_expected = self.mount_tracking_expected;
        state.mount_tracking_lost = self.mount_tracking_lost;
        state.mount_slewing = self.mount_slewing;
        state.mount_parked = self.mount_parked;
        state.mount_status_query_failed = self.mount_status_query_failed;
        state.tracking_limit_detected_at = self.tracking_limit_detected_at;
        state.meridian_trigger_method = self.meridian_trigger_method;
        state.dome_shutter_status = self.dome_shutter_status.clone();
        state.dome_shutter_open_expected = self.dome_shutter_open_expected;
        state.grid_dither_index = self.grid_dither_index;
        state.last_applied_filter_offset = self.last_applied_filter_offset;
    }
}

/// Checkpoint containing all state needed to resume a sequence
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionCheckpoint {
    /// Version for forward compatibility
    pub version: u32,
    /// When the checkpoint was created
    pub timestamp: DateTime<Utc>,
    /// The sequence definition
    pub sequence: SequenceDefinition,
    /// Status of each node
    pub node_statuses: HashMap<NodeId, NodeStatus>,
    /// Last completed node ID
    pub last_completed_node: Option<NodeId>,
    /// Current node being executed (if any)
    pub current_node: Option<NodeId>,
    /// Executor state when checkpoint was taken
    pub executor_state: ExecutorState,
    /// Connected device IDs
    pub camera_id: Option<String>,
    pub mount_id: Option<String>,
    pub focuser_id: Option<String>,
    pub filterwheel_id: Option<String>,
    pub rotator_id: Option<String>,
    /// Save path for images
    pub save_path: Option<PathBuf>,
    /// Observer location
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Total completed exposures
    pub completed_exposures: u32,
    /// Total completed integration time
    pub completed_integration_secs: f64,
    /// Whether this checkpoint is from an active session
    pub is_active: bool,
    /// Trigger state and runtime trigger settings for crash-safe resume.
    #[serde(default)]
    pub trigger_state: Option<TriggerStateSnapshot>,
    /// Per-wizard step-level resume state. Keyed by
    /// [`crate::wizard::Wizard::checkpoint_key`]. Empty for sequences
    /// that don't contain wizard nodes (or for v1/v2 checkpoints loaded
    /// from disk — `#[serde(default)]` produces an empty map).
    #[serde(default)]
    pub wizard_states: HashMap<String, WizardCheckpoint>,
    /// per-`TargetScheduler` resume state keyed by the
    /// scheduler node's id. `#[serde(default)]` keeps v1/v2/v3 checkpoints
    /// loading: old data sees an empty map and resumes with a fresh
    /// decision, which is the documented backwards-compat behaviour.
    #[serde(default)]
    pub scheduler_states: HashMap<String, SchedulerCheckpoint>,
    /// per-target integration budget accounting snapshot.
    /// `#[serde(default)]` keeps older checkpoints loading: missing
    /// field deserializes to an empty snapshot, which the registry
    /// treats as "no targets tracked yet" — exactly equivalent to a
    /// fresh run, which is the documented backwards-compat behaviour.
    #[serde(default)]
    pub budget_states: BudgetRegistrySnapshot,
    /// per-`SmartExposure` resume state keyed by the
    /// SmartExposure node's id. Mirrors the `scheduler_states` pattern.
    /// `#[serde(default)]` keeps every older checkpoint loading: missing
    /// field deserializes to an empty map and the next run starts each
    /// SmartExposure from a fresh state (plan index 0, no per-filter
    /// completed counts) — the documented backwards-compat behaviour.
    ///
    /// Why a dedicated map instead of stuffing into `wizard_states`:
    /// SmartExposure is not a wizard (it has no plan tree, no step
    /// counter), and the checkpoint values differ in shape — a single
    /// `WizardCheckpoint::completed_steps` cannot represent the
    /// per-filter HashMap. Keeping them separate also lets the typed
    /// helpers below return the concrete struct without a string-based
    /// key namespace collision risk.
    #[serde(default)]
    pub smart_exposure_states: HashMap<String, SmartExposureCheckpoint>,
    /// per-`Loop` node `current_iteration` at checkpoint time, keyed by
    /// the loop node's id. `#[serde(default)]` keeps older checkpoints loading
    /// (missing field → empty map → loops resume from iteration 1, the prior
    /// behaviour). With it populated, a resumed Count loop continues from the
    /// iteration it reached instead of re-imaging every completed iteration.
    #[serde(default)]
    pub loop_iterations: HashMap<NodeId, u32>,
}

impl SessionCheckpoint {
    /// Create a new checkpoint with the current version
    pub fn new(sequence: SequenceDefinition) -> Self {
        Self {
            version: CHECKPOINT_VERSION,
            timestamp: Utc::now(),
            sequence,
            node_statuses: HashMap::new(),
            last_completed_node: None,
            current_node: None,
            executor_state: ExecutorState::Idle,
            camera_id: None,
            mount_id: None,
            focuser_id: None,
            filterwheel_id: None,
            rotator_id: None,
            save_path: None,
            latitude: None,
            longitude: None,
            completed_exposures: 0,
            completed_integration_secs: 0.0,
            is_active: false,
            trigger_state: None,
            wizard_states: HashMap::new(),
            // empty by default; populated only when a
            // TargetScheduler node writes a decision through
            // `set_scheduler_state`.
            scheduler_states: HashMap::new(),
            // empty by default; populated only when a
            // TargetHeader's budget registry has produced state.
            budget_states: BudgetRegistrySnapshot::default(),
            // empty by default; populated only when a
            // SmartExposure node writes state through
            // `set_smart_exposure_state`.
            smart_exposure_states: HashMap::new(),
            // empty by default; populated from the live tree at
            // save_checkpoint time (loop nodes with current_iteration > 0).
            loop_iterations: HashMap::new(),
        }
    }

    /// Insert or replace a wizard checkpoint slot.
    pub fn set_wizard_state(&mut self, state: WizardCheckpoint) {
        self.wizard_states
            .insert(state.checkpoint_key.clone(), state);
        self.timestamp = Utc::now();
    }

    /// Look up a wizard checkpoint slot.
    pub fn wizard_state(&self, checkpoint_key: &str) -> Option<&WizardCheckpoint> {
        self.wizard_states.get(checkpoint_key)
    }

    /// Clear a wizard checkpoint slot (call when a wizard completes
    /// successfully so a future run starts fresh).
    pub fn clear_wizard_state(&mut self, checkpoint_key: &str) {
        self.wizard_states.remove(checkpoint_key);
        self.timestamp = Utc::now();
    }

    /// insert or replace a scheduler checkpoint slot.
    /// Keyed by `state.scheduler_node_id` so a sequence may contain multiple
    /// TargetScheduler nodes without collisions.
    pub fn set_scheduler_state(&mut self, state: SchedulerCheckpoint) {
        self.scheduler_states
            .insert(state.scheduler_node_id.clone(), state);
        self.timestamp = Utc::now();
    }

    /// look up a scheduler checkpoint slot by node id.
    pub fn scheduler_state(&self, scheduler_node_id: &str) -> Option<&SchedulerCheckpoint> {
        self.scheduler_states.get(scheduler_node_id)
    }

    /// clear a scheduler checkpoint slot (call when the
    /// scheduler exhausts its child list so the next run starts fresh).
    pub fn clear_scheduler_state(&mut self, scheduler_node_id: &str) {
        self.scheduler_states.remove(scheduler_node_id);
        self.timestamp = Utc::now();
    }

    /// insert or replace a SmartExposure checkpoint slot.
    /// Keyed by the SmartExposure node id so a sequence with multiple
    /// SmartExposure nodes resumes each one to its own per-filter counts.
    pub fn set_smart_exposure_state(&mut self, node_id: &str, state: SmartExposureCheckpoint) {
        self.smart_exposure_states
            .insert(node_id.to_string(), state);
        self.timestamp = Utc::now();
    }

    /// look up a SmartExposure checkpoint slot by node id.
    pub fn smart_exposure_state(&self, node_id: &str) -> Option<&SmartExposureCheckpoint> {
        self.smart_exposure_states.get(node_id)
    }

    /// clear a SmartExposure checkpoint slot (call when
    /// the node finishes all plans so the next run starts fresh).
    pub fn clear_smart_exposure_state(&mut self, node_id: &str) {
        self.smart_exposure_states.remove(node_id);
        self.timestamp = Utc::now();
    }

    /// Update the checkpoint with current progress
    pub fn update_progress(
        &mut self,
        node_statuses: HashMap<NodeId, NodeStatus>,
        current_node: Option<NodeId>,
        last_completed: Option<NodeId>,
        completed_exposures: u32,
        completed_integration_secs: f64,
    ) {
        self.timestamp = Utc::now();
        self.node_statuses = node_statuses;
        self.current_node = current_node;
        self.last_completed_node = last_completed;
        self.completed_exposures = completed_exposures;
        self.completed_integration_secs = completed_integration_secs;
    }

    /// Set device IDs
    pub fn set_devices(
        &mut self,
        camera: Option<String>,
        mount: Option<String>,
        focuser: Option<String>,
        filterwheel: Option<String>,
        rotator: Option<String>,
    ) {
        self.camera_id = camera;
        self.mount_id = mount;
        self.focuser_id = focuser;
        self.filterwheel_id = filterwheel;
        self.rotator_id = rotator;
    }

    /// Set observer location
    pub fn set_location(&mut self, lat: Option<f64>, lon: Option<f64>) {
        self.latitude = lat;
        self.longitude = lon;
    }

    /// Set save path
    pub fn set_save_path(&mut self, path: Option<PathBuf>) {
        self.save_path = path;
    }

    /// Mark checkpoint as active session
    pub fn set_active(&mut self, active: bool) {
        self.is_active = active;
        self.timestamp = Utc::now();
    }

    /// Store trigger state in the checkpoint.
    pub fn set_trigger_state(&mut self, trigger_state: TriggerStateSnapshot) {
        self.trigger_state = Some(trigger_state);
        self.timestamp = Utc::now();
    }

    /// Get the nodes that need to be skipped on resume (already completed)
    pub fn get_completed_nodes(&self) -> Vec<NodeId> {
        self.node_statuses
            .iter()
            .filter(|(_, status)| matches!(status, NodeStatus::Success))
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Check if this checkpoint can be resumed
    pub fn can_resume(&self) -> bool {
        // Resumability requires three things: (1) the session was alive at
        // checkpoint time (idle/completed sessions don't make sense to
        // "resume"), (2) the executor was in an interruptible state, and
        // (3) the sequence has a root — without it `build_node_tree` fails.
        self.is_active
            && matches!(
                self.executor_state,
                ExecutorState::Running | ExecutorState::Paused
            )
            && self.sequence.root_node_id.is_some()
    }

    /// Get time since checkpoint was created
    pub fn age_seconds(&self) -> i64 {
        Utc::now()
            .signed_duration_since(self.timestamp)
            .num_seconds()
    }
}

/// Manager for checkpoint persistence
pub struct CheckpointManager {
    checkpoint_dir: PathBuf,
    info_cache: Mutex<Option<CachedCheckpointInfo>>,
}

#[derive(Debug, Clone)]
struct CachedCheckpointInfo {
    primary_mtime: Option<SystemTime>,
    backup_mtime: Option<SystemTime>,
    info: Option<CheckpointInfo>,
}

impl CheckpointManager {
    const CHECKPOINT_FILENAME: &'static str = "skotiq_session.checkpoint";
    const CHECKPOINT_BACKUP: &'static str = "skotiq_session.checkpoint.bak";

    /// Get the checkpoint directory path
    pub fn checkpoint_dir(&self) -> &Path {
        &self.checkpoint_dir
    }

    /// Create a new checkpoint manager with the given directory
    pub fn new<P: AsRef<Path>>(checkpoint_dir: P) -> Self {
        Self {
            checkpoint_dir: checkpoint_dir.as_ref().to_path_buf(),
            info_cache: Mutex::new(None),
        }
    }

    /// Get the checkpoint file path
    fn checkpoint_path(&self) -> PathBuf {
        self.checkpoint_dir.join(Self::CHECKPOINT_FILENAME)
    }

    /// Get the backup checkpoint file path
    fn backup_path(&self) -> PathBuf {
        self.checkpoint_dir.join(Self::CHECKPOINT_BACKUP)
    }

    /// Save a checkpoint to disk
    pub fn save(&self, checkpoint: &SessionCheckpoint) -> Result<(), String> {
        std::fs::create_dir_all(&self.checkpoint_dir)
            .map_err(|e| format!("Failed to create checkpoint directory: {}", e))?;

        let path = self.checkpoint_path();
        let backup = self.backup_path();

        // Backup-before-overwrite so a crash mid-write does not lose the
        // previous good checkpoint; the load() path falls back to .bak
        // when the primary fails to parse.
        if path.exists() {
            let _ = std::fs::copy(&path, &backup);
        }

        // Atomic write via temp-file + rename: a partial write would
        // leave a malformed JSON that crashes the next load(); rename is
        // atomic on POSIX and good-enough on Windows for our needs.
        let json = serde_json::to_string_pretty(checkpoint)
            .map_err(|e| format!("Failed to serialize checkpoint: {}", e))?;

        let temp_path = path.with_extension("tmp");
        std::fs::write(&temp_path, &json)
            .map_err(|e| format!("Failed to write checkpoint: {}", e))?;

        std::fs::rename(&temp_path, &path)
            .map_err(|e| format!("Failed to finalize checkpoint: {}", e))?;

        self.invalidate_info_cache();
        tracing::debug!("Checkpoint saved: {}", path.display());
        Ok(())
    }

    /// Load a checkpoint from disk
    pub fn load(&self) -> Result<Option<SessionCheckpoint>, String> {
        let path = self.checkpoint_path();
        let backup = self.backup_path();
        let mut primary_error: Option<String> = None;

        if !path.exists() && !backup.exists() {
            return Ok(None);
        }

        if path.exists() {
            match Self::read_checkpoint_file(&path) {
                Ok(checkpoint) => return Ok(Some(checkpoint)),
                Err(primary_err) => {
                    tracing::warn!(
                        "Primary checkpoint load failed ({}), attempting backup",
                        primary_err
                    );
                    primary_error = Some(primary_err);
                }
            }
        }

        if backup.exists() {
            let checkpoint = Self::read_checkpoint_file(&backup)?;
            tracing::warn!(
                "Recovered checkpoint from backup file: {}",
                backup.display()
            );

            // Attempt to self-heal by restoring backup to primary path.
            if let Err(e) = std::fs::copy(&backup, &path) {
                tracing::warn!("Failed to restore primary checkpoint from backup: {}", e);
            }

            return Ok(Some(checkpoint));
        }

        if let Some(primary_err) = primary_error {
            return Err(primary_err);
        }

        Ok(None)
    }

    fn read_checkpoint_file(path: &Path) -> Result<SessionCheckpoint, String> {
        let json = std::fs::read_to_string(path)
            .map_err(|e| format!("Failed to read checkpoint {}: {}", path.display(), e))?;

        let checkpoint: SessionCheckpoint = serde_json::from_str(&json)
            .map_err(|e| format!("Failed to parse checkpoint {}: {}", path.display(), e))?;

        if checkpoint.version > CHECKPOINT_VERSION {
            return Err(format!(
                "Checkpoint {} has unsupported version {} (max supported: {})",
                path.display(),
                checkpoint.version,
                CHECKPOINT_VERSION
            ));
        }

        if checkpoint.version < CHECKPOINT_VERSION && checkpoint.trigger_state.is_none() {
            tracing::info!(
                "Checkpoint {} is version {} (pre-trigger-state); resume will use default trigger state",
                path.display(),
                checkpoint.version
            );
        }

        Ok(checkpoint)
    }

    fn checkpoint_signature(&self) -> Result<(Option<SystemTime>, Option<SystemTime>), String> {
        let path = self.checkpoint_path();
        let backup = self.backup_path();

        let primary_mtime = if path.exists() {
            Some(
                std::fs::metadata(&path)
                    .map_err(|e| format!("Failed to stat checkpoint {}: {}", path.display(), e))?
                    .modified()
                    .map_err(|e| {
                        format!("Failed to read checkpoint mtime {}: {}", path.display(), e)
                    })?,
            )
        } else {
            None
        };

        let backup_mtime = if backup.exists() {
            Some(
                std::fs::metadata(&backup)
                    .map_err(|e| {
                        format!(
                            "Failed to stat backup checkpoint {}: {}",
                            backup.display(),
                            e
                        )
                    })?
                    .modified()
                    .map_err(|e| {
                        format!(
                            "Failed to read backup checkpoint mtime {}: {}",
                            backup.display(),
                            e
                        )
                    })?,
            )
        } else {
            None
        };

        Ok((primary_mtime, backup_mtime))
    }

    fn build_checkpoint_info(&self) -> Result<Option<CheckpointInfo>, String> {
        match self.load()? {
            Some(checkpoint) => Ok(Some(CheckpointInfo {
                sequence_name: checkpoint.sequence.name.clone(),
                timestamp: checkpoint.timestamp,
                completed_exposures: checkpoint.completed_exposures,
                completed_integration_secs: checkpoint.completed_integration_secs,
                can_resume: checkpoint.can_resume(),
                age_seconds: checkpoint.age_seconds(),
            })),
            None => Ok(None),
        }
    }

    fn cached_checkpoint_info(&self) -> Result<Option<CheckpointInfo>, String> {
        let (primary_mtime, backup_mtime) = self.checkpoint_signature()?;
        // Why: `std::sync::Mutex::lock()` only returns Err when poisoned by
        // a prior panic in the holder. `e.into_inner()` retrieves the still-valid guard;
        // the checkpoint cache is a write-through cache of `build_checkpoint_info` and any
        // stale state will be invalidated by the mtime check on the next line. This is the
        // canonical "unpoisonable cache" idiom — equivalent to switching to parking_lot.
        let mut cache = self.info_cache.lock().unwrap_or_else(|e| e.into_inner());

        if let Some(cached) = &*cache {
            if cached.primary_mtime == primary_mtime && cached.backup_mtime == backup_mtime {
                return Ok(cached.info.clone());
            }
        }

        let info = self.build_checkpoint_info()?;
        *cache = Some(CachedCheckpointInfo {
            primary_mtime,
            backup_mtime,
            info: info.clone(),
        });
        Ok(info)
    }

    fn invalidate_info_cache(&self) {
        // Why: unpoisonable-cache idiom; see `cached_checkpoint_info`.
        *self.info_cache.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// Check if a recoverable checkpoint exists
    pub fn has_recoverable_checkpoint(&self) -> bool {
        self.cached_checkpoint_info()
            .map(|info| info.is_some_and(|checkpoint| checkpoint.can_resume))
            // Why: boolean probe used to gate UI-side "resume" affordance.
            // `Err` from `cached_checkpoint_info` (e.g. corrupted JSON on disk) maps to
            // `false` here, which is the correct fail-CLOSED behavior — a non-readable
            // checkpoint MUST NOT be presented as resumable. The actual recovery path
            // (`load_checkpoint`) propagates errors via `?`.
            .unwrap_or(false)
    }

    /// Delete the checkpoint (call when sequence completes normally)
    pub fn clear(&self) -> Result<(), String> {
        let path = self.checkpoint_path();
        let backup = self.backup_path();

        if path.exists() {
            std::fs::remove_file(&path)
                .map_err(|e| format!("Failed to remove checkpoint: {}", e))?;
        }

        if backup.exists() {
            let _ = std::fs::remove_file(&backup);
        }

        self.invalidate_info_cache();
        tracing::debug!("Checkpoint cleared");
        Ok(())
    }

    /// Mark checkpoint as inactive (sequence completed or was stopped gracefully)
    pub fn mark_completed(&self) -> Result<(), String> {
        // A `None` load means there is no checkpoint to mark, and a corrupt
        // file is a load error: returning Ok(()) for either made a no-op
        // indistinguishable from a real mark (L52), so both are reported to
        // the caller instead.
        let mut checkpoint = match self.load() {
            Ok(Some(checkpoint)) => checkpoint,
            Ok(None) => {
                self.invalidate_info_cache();
                return Err("mark_completed: no checkpoint on disk to mark".to_string());
            }
            Err(e) => {
                self.invalidate_info_cache();
                return Err(e);
            }
        };
        checkpoint.is_active = false;
        checkpoint.executor_state = ExecutorState::Completed;
        self.save(&checkpoint)?;
        self.invalidate_info_cache();
        Ok(())
    }

    /// Get checkpoint info without loading full checkpoint
    pub fn get_checkpoint_info(&self) -> Result<Option<CheckpointInfo>, String> {
        self.cached_checkpoint_info()
    }

    /// Save a single wizard checkpoint slot into the session checkpoint
    /// on disk, leaving every other field untouched. Used by the
    /// [`crate::wizard::WizardCheckpointSink`] adapter. If no session
    /// checkpoint exists this is a no-op — a wizard running outside an
    /// active session has nothing to persist its state into, and that's
    /// fine.
    pub fn save_wizard_state(&self, state: &WizardCheckpoint) {
        let mut checkpoint = match self.load() {
            Ok(Some(cp)) => cp,
            // No session checkpoint to attach to — wizard is running
            // standalone (no surrounding sequence). The next run will
            // start fresh, which is the documented behavior.
            Ok(None) => return,
            Err(e) => {
                tracing::warn!(
                    "save_wizard_state: failed to load existing checkpoint: {}",
                    e
                );
                return;
            }
        };
        checkpoint.set_wizard_state(state.clone());
        if let Err(e) = self.save(&checkpoint) {
            tracing::warn!("save_wizard_state: failed to write checkpoint: {}", e);
        }
    }

    /// Load a single wizard checkpoint slot. Returns None when no
    /// session checkpoint exists or when no slot matches `key`.
    pub fn load_wizard_state(&self, key: &str) -> Option<WizardCheckpoint> {
        self.load()
            .ok()
            .flatten()
            .and_then(|cp| cp.wizard_states.get(key).cloned())
    }

    /// Clear a single wizard checkpoint slot.
    pub fn clear_wizard_state(&self, key: &str) {
        let mut checkpoint = match self.load() {
            Ok(Some(cp)) => cp,
            _ => return,
        };
        checkpoint.clear_wizard_state(key);
        if let Err(e) = self.save(&checkpoint) {
            tracing::warn!("clear_wizard_state: failed to write checkpoint: {}", e);
        }
    }

    /// save a single SmartExposure checkpoint slot into
    /// the session checkpoint on disk, leaving every other field
    /// untouched. Mirrors `save_wizard_state` / `save_scheduler_state` so
    /// crashed runs resume mid-rotation on the right filter at the right
    /// frame index.
    ///
    /// If no session checkpoint exists this is a no-op — a SmartExposure
    /// running outside an active session (rare; tests / standalone tools)
    /// has nothing to persist its state into, and the next run will
    /// start from a fresh state, which is documented behaviour.
    pub fn save_smart_exposure_state(&self, node_id: &str, state: &SmartExposureCheckpoint) {
        let mut checkpoint = match self.load() {
            Ok(Some(cp)) => cp,
            Ok(None) => return,
            Err(e) => {
                tracing::warn!(
                    "save_smart_exposure_state: failed to load existing checkpoint: {}",
                    e
                );
                return;
            }
        };
        checkpoint.set_smart_exposure_state(node_id, state.clone());
        if let Err(e) = self.save(&checkpoint) {
            tracing::warn!(
                "save_smart_exposure_state: failed to write checkpoint: {}",
                e
            );
        }
    }

    /// load a single SmartExposure checkpoint slot.
    /// Returns None when no session checkpoint exists or when no slot
    /// matches `node_id`.
    pub fn load_smart_exposure_state(&self, node_id: &str) -> Option<SmartExposureCheckpoint> {
        self.load()
            .ok()
            .flatten()
            .and_then(|cp| cp.smart_exposure_states.get(node_id).cloned())
    }

    /// clear a single SmartExposure checkpoint slot.
    /// Called when the SmartExposure node completes all plans so the next
    /// run starts fresh.
    pub fn clear_smart_exposure_state(&self, node_id: &str) {
        let mut checkpoint = match self.load() {
            Ok(Some(cp)) => cp,
            _ => return,
        };
        checkpoint.clear_smart_exposure_state(node_id);
        if let Err(e) = self.save(&checkpoint) {
            tracing::warn!(
                "clear_smart_exposure_state: failed to write checkpoint: {}",
                e
            );
        }
    }
}

/// Adapts a `CheckpointManager` to the wizard module's `WizardCheckpointSink`.
/// Wizards running inside an active session use this to persist
/// step-level resume state alongside the session-level checkpoint.
pub struct SessionWizardCheckpointSink<'a> {
    pub manager: &'a CheckpointManager,
}

impl<'a> SessionWizardCheckpointSink<'a> {
    pub fn new(manager: &'a CheckpointManager) -> Self {
        Self { manager }
    }
}

impl<'a> crate::wizard::WizardCheckpointSink for SessionWizardCheckpointSink<'a> {
    fn save(&self, checkpoint: &WizardCheckpoint) {
        self.manager.save_wizard_state(checkpoint);
    }
    fn load(&self, checkpoint_key: &str) -> Option<WizardCheckpoint> {
        self.manager.load_wizard_state(checkpoint_key)
    }
    fn clear(&self, checkpoint_key: &str) {
        self.manager.clear_wizard_state(checkpoint_key);
    }
}

/// Summary info about a checkpoint
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckpointInfo {
    pub sequence_name: String,
    pub timestamp: DateTime<Utc>,
    pub completed_exposures: u32,
    pub completed_integration_secs: f64,
    pub can_resume: bool,
    pub age_seconds: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn test_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "skotiq_checkpoint_test_{}_{}",
            name,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_checkpoint_serialization() {
        let seq = SequenceDefinition::new("Test Sequence".to_string());
        let checkpoint = SessionCheckpoint::new(seq);

        let json = serde_json::to_string(&checkpoint).unwrap();
        let loaded: SessionCheckpoint = serde_json::from_str(&json).unwrap();

        assert_eq!(loaded.sequence.name, "Test Sequence");
    }

    #[test]
    fn test_load_corrupt_primary_without_backup_returns_error() {
        let dir = test_dir("corrupt_primary_no_backup");
        let manager = CheckpointManager::new(&dir);
        let primary = manager.checkpoint_path();
        fs::write(&primary, "{not valid json").unwrap();

        let result = manager.load();
        assert!(
            result.is_err(),
            "Expected error for corrupt primary checkpoint"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_load_falls_back_to_backup_when_primary_corrupt() {
        let dir = test_dir("primary_corrupt_backup_ok");
        let manager = CheckpointManager::new(&dir);

        let seq = SequenceDefinition::new("Backup Sequence".to_string());
        let checkpoint = SessionCheckpoint::new(seq);
        manager.save(&checkpoint).unwrap();

        let primary = manager.checkpoint_path();
        let backup = manager.backup_path();
        fs::copy(&primary, &backup).unwrap();
        fs::write(&primary, "{not valid json").unwrap();

        let loaded = manager
            .load()
            .unwrap()
            .expect("Expected checkpoint from backup");
        assert_eq!(loaded.sequence.name, "Backup Sequence");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_checkpoint_info_cache_invalidates_when_file_disappears() {
        let dir = test_dir("info_cache_invalidation");
        let manager = CheckpointManager::new(&dir);
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("Resume".to_string()));
        checkpoint.sequence.root_node_id = Some("root".to_string());
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        manager.save(&checkpoint).unwrap();

        let first = manager.get_checkpoint_info().unwrap();
        assert!(first.as_ref().is_some_and(|info| info.can_resume));

        fs::remove_file(manager.checkpoint_path()).unwrap();

        let second = manager.get_checkpoint_info().unwrap();
        assert!(second.is_none());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_mark_completed_clears_resume_banner_but_keeps_file() {
        // On normal sequence completion the executor calls mark_completed(), which
        // clears is_active — otherwise has_recoverable_checkpoint() keeps returning
        // true and the UI shows a stale "resume?" banner after a successful night.
        let dir = test_dir("mark_completed_clears_banner");
        let manager = CheckpointManager::new(&dir);
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("Night".to_string()));
        checkpoint.sequence.root_node_id = Some("root".to_string());
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        manager.save(&checkpoint).unwrap();

        // Sanity: a running checkpoint IS offered for resume.
        assert!(
            manager.has_recoverable_checkpoint(),
            "running checkpoint should be resumable before completion"
        );

        // Normal completion path.
        manager.mark_completed().unwrap();

        // Banner gone …
        assert!(
            !manager.has_recoverable_checkpoint(),
            "completed checkpoint must NOT be offered for resume"
        );
        // … but the file is preserved (with is_active=false / Completed) so the
        // post-session report can still read totals.
        let loaded = manager
            .load()
            .unwrap()
            .expect("mark_completed must preserve the checkpoint file, not delete it");
        assert!(!loaded.is_active);
        assert_eq!(loaded.executor_state, ExecutorState::Completed);
        assert!(!loaded.can_resume());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_mark_completed_without_checkpoint_is_an_error() {
        // A no-op used to return Ok(()), indistinguishable from a real mark.
        // The caller's "failed to mark completed" log must fire instead.
        let dir = test_dir("mark_completed_no_checkpoint");
        let manager = CheckpointManager::new(&dir);

        assert!(
            manager.mark_completed().is_err(),
            "mark_completed with no checkpoint on disk must not report success"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_mark_completed_propagates_a_corrupt_checkpoint() {
        // A corrupt checkpoint used to be swallowed the same way: the load
        // error was discarded inside the `if let Ok` and Ok(()) was returned.
        let dir = test_dir("mark_completed_corrupt");
        let manager = CheckpointManager::new(&dir);
        fs::write(manager.checkpoint_path(), "{not valid json").unwrap();

        assert!(
            manager.mark_completed().is_err(),
            "mark_completed must surface a load error, not report success"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_trigger_state_snapshot_round_trip_preserves_every_field() {
        let mut original = TriggerState::new();
        original.baseline_hfr = Some(2.5);
        original.current_hfr = Some(2.7);
        original.autofocus_invalidated = true;
        original.autofocus_invalidation_reason = Some("filter changed".into());
        original.current_hour_angle = Some(0.75);
        original.pier_side = Some(PierSide::West);
        original.mount_tracking_limit_time = Some(1_700_000_000);
        original.has_flipped_this_target = true;
        original.current_target_name = Some("M31".into());
        original.guiding_enabled = true;
        original.guide_star_lost = false;
        original.current_humidity = Some(63.0);
        original.current_altitude = Some(58.4);
        original.weather_safe = true;
        original.baseline_temperature = Some(-3.5);
        original.current_temperature = Some(-2.0);
        original.baseline_focuser_position = Some(28000);
        original.filter_changed = true;
        original.current_filter = Some("Ha".into());
        original.dawn_time = Some(1_700_010_000);
        original.observer_latitude = Some(45.5);
        original.observer_longitude = Some(-122.6);
        original.completed_exposures = 42;
        original.last_autofocus_frame = 30;
        original.last_dither_frame = 41;
        original.tracking_limit_detected_at = Some(1_700_005_000);
        original.grid_dither_index = 7;
        original.last_applied_filter_offset = 42;

        let mut offsets = HashMap::new();
        offsets.insert("Ha".to_string(), 42);
        offsets.insert("OIII".to_string(), -17);

        let snapshot = TriggerStateSnapshot::from_state(
            &original,
            SafetyFailMode::WarnOnly,
            true,
            offsets.clone(),
        );

        let json = serde_json::to_string(&snapshot).expect("snapshot must serialize");
        let restored_snapshot: TriggerStateSnapshot =
            serde_json::from_str(&json).expect("snapshot must deserialize");
        assert_eq!(
            snapshot, restored_snapshot,
            "TriggerStateSnapshot serde round-trip must preserve every field"
        );
        assert_eq!(restored_snapshot.safety_fail_mode, SafetyFailMode::WarnOnly);
        assert!(restored_snapshot.triggers_enabled);
        assert_eq!(restored_snapshot.filter_focus_offsets, offsets);

        let mut restored = TriggerState::new();
        restored_snapshot.restore_into(&mut restored);
        assert_eq!(restored.baseline_hfr, original.baseline_hfr);
        assert_eq!(restored.current_hfr, original.current_hfr);
        assert_eq!(
            restored.autofocus_invalidated,
            original.autofocus_invalidated
        );
        assert_eq!(
            restored.autofocus_invalidation_reason,
            original.autofocus_invalidation_reason
        );
        assert_eq!(restored.current_hour_angle, original.current_hour_angle);
        assert_eq!(restored.pier_side, original.pier_side);
        assert_eq!(
            restored.mount_tracking_limit_time,
            original.mount_tracking_limit_time
        );
        assert_eq!(
            restored.has_flipped_this_target,
            original.has_flipped_this_target
        );
        assert_eq!(restored.current_target_name, original.current_target_name);
        assert_eq!(restored.guiding_enabled, original.guiding_enabled);
        assert_eq!(restored.guide_star_lost, original.guide_star_lost);
        assert_eq!(restored.current_humidity, original.current_humidity);
        assert_eq!(restored.current_altitude, original.current_altitude);
        assert_eq!(restored.weather_safe, original.weather_safe);
        assert_eq!(restored.baseline_temperature, original.baseline_temperature);
        assert_eq!(restored.current_temperature, original.current_temperature);
        assert_eq!(
            restored.baseline_focuser_position,
            original.baseline_focuser_position
        );
        assert_eq!(restored.filter_changed, original.filter_changed);
        assert_eq!(restored.current_filter, original.current_filter);
        assert_eq!(
            restored.last_applied_filter_offset,
            original.last_applied_filter_offset
        );
        assert_eq!(restored.dawn_time, original.dawn_time);
        assert_eq!(restored.observer_latitude, original.observer_latitude);
        assert_eq!(restored.observer_longitude, original.observer_longitude);
        assert_eq!(restored.completed_exposures, original.completed_exposures);
        assert_eq!(restored.last_autofocus_frame, original.last_autofocus_frame);
        assert_eq!(restored.last_dither_frame, original.last_dither_frame);
        assert_eq!(
            restored.tracking_limit_detected_at,
            original.tracking_limit_detected_at
        );
        assert_eq!(restored.grid_dither_index, original.grid_dither_index);
    }

    #[test]
    fn test_checkpoint_persists_has_flipped_this_target_across_save_load() {
        let dir = test_dir("trigger_state_persist");
        let manager = CheckpointManager::new(&dir);

        let mut state = TriggerState::new();
        state.has_flipped_this_target = true;
        state.current_target_name = Some("NGC7000".into());
        state.completed_exposures = 17;
        state.last_autofocus_frame = 10;
        state.last_dither_frame = 16;
        state.grid_dither_index = 4;
        state.baseline_hfr = Some(2.1);

        let snapshot = TriggerStateSnapshot::from_state(
            &state,
            SafetyFailMode::FailClosed,
            true,
            HashMap::new(),
        );

        let mut checkpoint =
            SessionCheckpoint::new(SequenceDefinition::new("Persist test".to_string()));
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        checkpoint.set_trigger_state(snapshot);

        manager.save(&checkpoint).expect("save");

        let loaded = manager
            .load()
            .expect("load")
            .expect("checkpoint must exist");
        let restored_snapshot = loaded
            .trigger_state
            .as_ref()
            .expect("trigger_state must round-trip via JSON");
        assert!(restored_snapshot.has_flipped_this_target);
        assert_eq!(
            restored_snapshot.current_target_name.as_deref(),
            Some("NGC7000")
        );
        assert_eq!(restored_snapshot.completed_exposures, 17);
        assert_eq!(restored_snapshot.last_autofocus_frame, 10);
        assert_eq!(restored_snapshot.last_dither_frame, 16);
        assert_eq!(restored_snapshot.grid_dither_index, 4);
        assert_eq!(restored_snapshot.baseline_hfr, Some(2.1));
        assert_eq!(loaded.version, CHECKPOINT_VERSION);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn wizard_state_round_trips_through_session_checkpoint_serde() {
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("ws".to_string()));
        checkpoint.set_wizard_state(WizardCheckpoint {
            checkpoint_key: "flat_wizard".to_string(),
            completed_steps: 5,
            timestamp: Utc::now(),
        });
        checkpoint.set_wizard_state(WizardCheckpoint {
            checkpoint_key: "mosaic".to_string(),
            completed_steps: 4,
            timestamp: Utc::now(),
        });

        let json = serde_json::to_string(&checkpoint).expect("serialize");
        let loaded: SessionCheckpoint = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(loaded.wizard_states.len(), 2);
        assert_eq!(
            loaded.wizard_state("flat_wizard").unwrap().completed_steps,
            5
        );
        assert_eq!(loaded.wizard_state("mosaic").unwrap().completed_steps, 4);
    }

    #[test]
    fn wizard_state_persists_through_manager_save_load() {
        let dir = test_dir("wizard_state_persist");
        let manager = CheckpointManager::new(&dir);

        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("WS Test".to_string()));
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        checkpoint.set_wizard_state(WizardCheckpoint {
            checkpoint_key: "flat_wizard".to_string(),
            completed_steps: 7,
            timestamp: Utc::now(),
        });

        manager.save(&checkpoint).expect("save");

        let loaded = manager.load().expect("load").expect("checkpoint exists");
        let slot = loaded
            .wizard_state("flat_wizard")
            .expect("wizard_state slot");
        assert_eq!(slot.completed_steps, 7);
        assert_eq!(loaded.version, CHECKPOINT_VERSION);

        // Sink adapter should also see the slot.
        let sink = SessionWizardCheckpointSink::new(&manager);
        let via_sink = crate::wizard::WizardCheckpointSink::load(&sink, "flat_wizard")
            .expect("sink load slot");
        assert_eq!(via_sink.completed_steps, 7);

        // Clear via sink and confirm it's gone.
        crate::wizard::WizardCheckpointSink::clear(&sink, "flat_wizard");
        let after_clear = manager
            .load()
            .expect("load after clear")
            .expect("checkpoint still present");
        assert!(after_clear.wizard_state("flat_wizard").is_none());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn scheduler_state_round_trips_through_session_checkpoint_serde() {
        // scheduler_states map must round-trip + be keyed by
        // scheduler node id (a sequence may contain multiple schedulers).
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("sch".to_string()));
        checkpoint.set_scheduler_state(SchedulerCheckpoint {
            scheduler_node_id: "sched_a".to_string(),
            current_target_id: Some("m42".to_string()),
            exposures_in_current_target: 3,
            decision_counter: 1,
            timestamp: Utc::now(),
        });
        checkpoint.set_scheduler_state(SchedulerCheckpoint {
            scheduler_node_id: "sched_b".to_string(),
            current_target_id: None,
            exposures_in_current_target: 0,
            decision_counter: 7,
            timestamp: Utc::now(),
        });
        let json = serde_json::to_string(&checkpoint).expect("serialize");
        let loaded: SessionCheckpoint = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(loaded.scheduler_states.len(), 2);
        assert_eq!(
            loaded
                .scheduler_state("sched_a")
                .unwrap()
                .current_target_id
                .as_deref(),
            Some("m42")
        );
        assert_eq!(
            loaded.scheduler_state("sched_b").unwrap().decision_counter,
            7
        );
    }

    #[test]
    fn legacy_v3_checkpoint_without_scheduler_states_loads_with_empty_map() {
        // backwards-compat — checkpoints written before the
        // scheduler_states field existed must still load (serde(default)).
        let dir = test_dir("legacy_v3_no_scheduler");
        let manager = CheckpointManager::new(&dir);

        let pre_scheduler_json = serde_json::json!({
            "version": 3,
            "timestamp": Utc::now(),
            "sequence": SequenceDefinition::new("v3pre".to_string()),
            "node_statuses": {},
            "last_completed_node": null,
            "current_node": null,
            "executor_state": "Running",
            "camera_id": null,
            "mount_id": null,
            "focuser_id": null,
            "filterwheel_id": null,
            "rotator_id": null,
            "save_path": null,
            "latitude": null,
            "longitude": null,
            "completed_exposures": 0,
            "completed_integration_secs": 0.0,
            "is_active": true,
            "trigger_state": null,
            "wizard_states": {},
        });
        let primary = manager.checkpoint_path();
        fs::create_dir_all(&dir).unwrap();
        fs::write(&primary, pre_scheduler_json.to_string()).unwrap();

        let loaded = manager
            .load()
            .expect("legacy v3 must load")
            .expect("checkpoint exists");
        assert!(loaded.scheduler_states.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_v2_checkpoint_without_wizard_states_loads_with_empty_map() {
        let dir = test_dir("legacy_v2_no_wizard_states");
        let manager = CheckpointManager::new(&dir);

        let v2_json = serde_json::json!({
            "version": 2,
            "timestamp": Utc::now(),
            "sequence": SequenceDefinition::new("v2".to_string()),
            "node_statuses": {},
            "last_completed_node": null,
            "current_node": null,
            "executor_state": "Running",
            "camera_id": null,
            "mount_id": null,
            "focuser_id": null,
            "filterwheel_id": null,
            "rotator_id": null,
            "save_path": null,
            "latitude": null,
            "longitude": null,
            "completed_exposures": 3,
            "completed_integration_secs": 120.0,
            "is_active": true,
            "trigger_state": null
        });
        let primary = manager.checkpoint_path();
        fs::create_dir_all(&dir).unwrap();
        fs::write(&primary, v2_json.to_string()).unwrap();

        let loaded = manager
            .load()
            .expect("v2 checkpoint must load")
            .expect("checkpoint exists");
        assert_eq!(loaded.version, 2);
        assert!(
            loaded.wizard_states.is_empty(),
            "missing wizard_states field defaults to empty map (resume from step 0)"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_legacy_v1_checkpoint_loads_with_no_trigger_state() {
        let dir = test_dir("legacy_v1_no_trigger_state");
        let manager = CheckpointManager::new(&dir);

        let v1_json = serde_json::json!({
            "version": 1,
            "timestamp": Utc::now(),
            "sequence": SequenceDefinition::new("v1".to_string()),
            "node_statuses": {},
            "last_completed_node": null,
            "current_node": null,
            "executor_state": "Running",
            "camera_id": null,
            "mount_id": null,
            "focuser_id": null,
            "filterwheel_id": null,
            "rotator_id": null,
            "save_path": null,
            "latitude": null,
            "longitude": null,
            "completed_exposures": 5,
            "completed_integration_secs": 600.0,
            "is_active": true
        });
        let primary = manager.checkpoint_path();
        fs::create_dir_all(&dir).unwrap();
        fs::write(&primary, v1_json.to_string()).unwrap();

        let loaded = manager
            .load()
            .expect("v1 checkpoint must load")
            .expect("checkpoint should be present");
        assert_eq!(loaded.version, 1);
        assert!(loaded.trigger_state.is_none());

        let _ = fs::remove_dir_all(&dir);
    }

    // SmartExposure cross-process resume.

    #[test]
    fn smart_exposure_state_round_trips_through_session_checkpoint_serde() {
        // Two SmartExposure nodes must round-trip independently — the map is
        // keyed by node id so the same checkpoint file can carry per-node
        // state without collisions.
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("se".to_string()));
        let mut state_a = SmartExposureCheckpoint::default();
        state_a.per_filter_completed.insert("L".to_string(), 3);
        state_a.per_filter_completed.insert("R".to_string(), 1);
        state_a.current_plan_index = 2;
        state_a.completed_integration_secs = 240.0;

        let mut state_b = SmartExposureCheckpoint::default();
        state_b.per_filter_completed.insert("Ha".to_string(), 6);
        state_b.current_plan_index = 0;
        state_b.completed_integration_secs = 1800.0;

        checkpoint.set_smart_exposure_state("node_a", state_a);
        checkpoint.set_smart_exposure_state("node_b", state_b);

        let json = serde_json::to_string(&checkpoint).expect("serialize");
        let loaded: SessionCheckpoint = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(loaded.smart_exposure_states.len(), 2);

        let restored_a = loaded
            .smart_exposure_state("node_a")
            .expect("node_a slot exists");
        assert_eq!(restored_a.per_filter_completed.get("L"), Some(&3));
        assert_eq!(restored_a.per_filter_completed.get("R"), Some(&1));
        assert_eq!(restored_a.current_plan_index, 2);
        assert!((restored_a.completed_integration_secs - 240.0).abs() < f64::EPSILON);

        let restored_b = loaded
            .smart_exposure_state("node_b")
            .expect("node_b slot exists");
        assert_eq!(restored_b.per_filter_completed.get("Ha"), Some(&6));
        assert_eq!(restored_b.current_plan_index, 0);
        assert!((restored_b.completed_integration_secs - 1800.0).abs() < f64::EPSILON);
    }

    #[test]
    fn smart_exposure_save_load_clear_through_checkpoint_manager() {
        // the manager helpers must preserve other fields
        // when writing a smart-exposure slot, and must round-trip the
        // value end-to-end through the on-disk checkpoint file.
        let dir = test_dir("smart_exposure_save_load_clear");
        let manager = CheckpointManager::new(&dir);

        // Seed a full session checkpoint so other fields exist to be
        // preserved.
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("SE".to_string()));
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        checkpoint.completed_exposures = 12;
        manager.save(&checkpoint).expect("seed save");

        let mut state = SmartExposureCheckpoint::default();
        state.per_filter_completed.insert("L".to_string(), 3);
        state.per_filter_completed.insert("R".to_string(), 4);
        state.current_plan_index = 1;
        state.completed_integration_secs = 540.0;

        manager.save_smart_exposure_state("se_node", &state);

        // Load through the dedicated helper.
        let loaded_state = manager
            .load_smart_exposure_state("se_node")
            .expect("smart-exposure slot present");
        assert_eq!(loaded_state.per_filter_completed.get("L"), Some(&3));
        assert_eq!(loaded_state.per_filter_completed.get("R"), Some(&4));
        assert_eq!(loaded_state.current_plan_index, 1);
        assert!((loaded_state.completed_integration_secs - 540.0).abs() < f64::EPSILON);

        // Make sure the other session fields survived the partial write.
        let full = manager
            .load()
            .expect("load full checkpoint")
            .expect("checkpoint exists");
        assert_eq!(full.completed_exposures, 12);
        assert!(full.is_active);
        assert_eq!(full.executor_state, ExecutorState::Running);

        // Clearing removes only the smart-exposure slot, not the others.
        manager.clear_smart_exposure_state("se_node");
        assert!(manager.load_smart_exposure_state("se_node").is_none());
        let after_clear = manager
            .load()
            .expect("load after clear")
            .expect("checkpoint still present");
        assert!(after_clear.smart_exposure_states.is_empty());
        assert_eq!(after_clear.completed_exposures, 12);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_v3_checkpoint_without_smart_exposure_states_loads_with_empty_map() {
        // A checkpoint written before added `smart_exposure_states`
        // must still deserialize (serde(default)) and the map is empty.
        let dir = test_dir("legacy_no_smart_exposure");
        let manager = CheckpointManager::new(&dir);

        let pre_se_json = serde_json::json!({
            "version": 3,
            "timestamp": Utc::now(),
            "sequence": SequenceDefinition::new("legacy".to_string()),
            "node_statuses": {},
            "last_completed_node": null,
            "current_node": null,
            "executor_state": "Running",
            "camera_id": null,
            "mount_id": null,
            "focuser_id": null,
            "filterwheel_id": null,
            "rotator_id": null,
            "save_path": null,
            "latitude": null,
            "longitude": null,
            "completed_exposures": 0,
            "completed_integration_secs": 0.0,
            "is_active": true,
            "wizard_states": {},
            "scheduler_states": {}
        });
        let primary = manager.checkpoint_path();
        fs::create_dir_all(&dir).unwrap();
        fs::write(&primary, pre_se_json.to_string()).unwrap();

        let loaded = manager
            .load()
            .expect("legacy load must succeed")
            .expect("checkpoint should be present");
        assert!(
            loaded.smart_exposure_states.is_empty(),
            "missing smart_exposure_states field defaults to empty map"
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
