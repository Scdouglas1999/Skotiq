//! Session checkpoint for crash recovery
//!
//! This module provides functionality to save and restore sequence execution state
//! for recovery after unexpected crashes or restarts.

use crate::scheduling::BudgetRegistrySnapshot;
use crate::triggers::{PersistedTriggerState, TriggerState};
use crate::{
    ExecutorState, NodeId, NodeStatus, SafetyFailMode, SequenceDefinition, SmartExposureCheckpoint,
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

/// What a checkpoint keeps of the trigger state: the persisted fields of its
/// parts, plus the three run settings the executor holds beside it. One flat
/// JSON object, every field tolerant of being absent from an older file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TriggerStateSnapshot {
    #[serde(flatten)]
    pub state: PersistedTriggerState,
    #[serde(default)]
    pub safety_fail_mode: SafetyFailMode,
    #[serde(default = "default_triggers_enabled")]
    pub triggers_enabled: bool,
    #[serde(default)]
    pub filter_focus_offsets: HashMap<String, i32>,
}

fn default_triggers_enabled() -> bool {
    true
}

impl TriggerStateSnapshot {
    pub fn from_state(
        state: &TriggerState,
        safety_fail_mode: SafetyFailMode,
        triggers_enabled: bool,
        filter_focus_offsets: HashMap<String, i32>,
    ) -> Self {
        Self {
            state: state.persisted(),
            safety_fail_mode,
            triggers_enabled,
            filter_focus_offsets,
        }
    }

    pub fn restore_into(&self, state: &mut TriggerState) {
        state.restore(&self.state);
    }
}

/// Checkpoint containing all state needed to resume a sequence
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionCheckpoint {
    /// Version for forward compatibility
    pub version: u32,
    /// When the checkpoint was created
    pub timestamp: DateTime<Utc>,
    pub sequence: SequenceDefinition,
    pub node_statuses: HashMap<NodeId, NodeStatus>,
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
    pub completed_exposures: u32,
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
    /// per-target integration budget accounting snapshot.
    /// `#[serde(default)]` keeps older checkpoints loading: missing
    /// field deserializes to an empty snapshot, which the registry
    /// treats as "no targets tracked yet" — exactly equivalent to a
    /// fresh run, which is the documented backwards-compat behaviour.
    #[serde(default)]
    pub budget_states: BudgetRegistrySnapshot,
    /// per-`SmartExposure` resume state keyed by the
    /// SmartExposure node's id. Keyed like `wizard_states`.
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
    /// Frames a Take Exposures burst had taken when the run stopped part-way
    /// through it, keyed by the node's id; a resumed run takes the rest.
    #[serde(default)]
    pub exposure_frames_taken: HashMap<NodeId, u32>,
    /// Frames each Take Exposures step has taken over the whole plan, every
    /// loop pass and every run this one continues, keyed by the node's id.
    /// Empty in checkpoints written before it existed.
    #[serde(default)]
    pub exposure_frames_done: HashMap<NodeId, u32>,
    /// How the run ended, when it ended on its own terms: stopped by the
    /// operator, failed, or ended early by a trigger (dawn, weather). `None`
    /// while it runs, so a checkpoint still `None` after the app restarts
    /// belongs to a run the app died under: the only kind that was
    /// interrupted. Older checkpoints load as `None`.
    #[serde(default)]
    pub ended: Option<RunEnd>,
}

/// How a run that kept its checkpoint ended (see [`SessionCheckpoint::ended`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunEnd {
    /// The operator stopped it.
    Stopped,
    Failed,
    /// A trigger ended it early and put the rig away (dawn, unsafe weather).
    EndedEarly,
}

impl RunEnd {
    /// The wire name, as serialized.
    pub fn as_str(self) -> &'static str {
        match self {
            RunEnd::Stopped => "stopped",
            RunEnd::Failed => "failed",
            RunEnd::EndedEarly => "ended_early",
        }
    }
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
            ended: None,
            trigger_state: None,
            wizard_states: HashMap::new(),
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
            exposure_frames_taken: HashMap::new(),
            exposure_frames_done: HashMap::new(),
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

    pub fn set_save_path(&mut self, path: Option<PathBuf>) {
        self.save_path = path;
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
                ended: checkpoint.ended,
                frames_done_by_step: checkpoint.exposure_frames_done,
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
                return Ok(cached.info.clone().map(with_current_age));
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

    /// Record how a run that keeps its checkpoint ended, with the progress it
    /// reached. The streaming writer saves every 30 s and stops with the run,
    /// so without this final write the checkpoint keeps the counts of its last
    /// save (a run stopped within its first 30 s reads "0 frames"). The
    /// checkpoint stays resumable.
    pub fn record_run_end(
        &self,
        end: RunEnd,
        completed_exposures: u32,
        completed_integration_secs: f64,
    ) -> Result<(), String> {
        let mut checkpoint = match self.load() {
            Ok(Some(checkpoint)) => checkpoint,
            Ok(None) => {
                self.invalidate_info_cache();
                return Err("record_run_end: no checkpoint on disk to update".to_string());
            }
            Err(e) => {
                self.invalidate_info_cache();
                return Err(e);
            }
        };
        checkpoint.ended = Some(end);
        checkpoint.completed_exposures = completed_exposures;
        checkpoint.completed_integration_secs = completed_integration_secs;
        checkpoint.timestamp = Utc::now();
        self.save(&checkpoint)?;
        self.invalidate_info_cache();
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
}

/// [info] with its age measured now. The cache keeps the summary for as long
/// as the file is unchanged, but the age grows with every read.
fn with_current_age(mut info: CheckpointInfo) -> CheckpointInfo {
    info.age_seconds = Utc::now()
        .signed_duration_since(info.timestamp)
        .num_seconds();
    info
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
    /// How the run ended; `None` when the app died under it (interrupted).
    #[serde(default)]
    pub ended: Option<RunEnd>,
    /// Frames each Take Exposures step of the plan has taken, by node id.
    #[serde(default)]
    pub frames_done_by_step: HashMap<NodeId, u32>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PierSide;
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
    fn test_checkpoint_info_age_advances_while_cached() {
        let dir = test_dir("info_cache_age");
        let manager = CheckpointManager::new(&dir);
        let mut checkpoint = SessionCheckpoint::new(SequenceDefinition::new("Age".to_string()));
        checkpoint.sequence.root_node_id = Some("root".to_string());
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        checkpoint.timestamp = Utc::now() - chrono::Duration::hours(2);
        manager.save(&checkpoint).unwrap();

        let first = manager.get_checkpoint_info().unwrap().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let second = manager.get_checkpoint_info().unwrap().unwrap();

        assert!(first.age_seconds >= 7200);
        assert!(
            second.age_seconds > first.age_seconds,
            "age stayed at {} s across reads of an unchanged checkpoint",
            first.age_seconds
        );

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
        original.latches.baseline_hfr = Some(2.5);
        original.latches.current_hfr = Some(2.7);
        original.latches.autofocus_invalidated = true;
        original.latches.autofocus_invalidation_reason = Some("filter changed".into());
        original.target.current_hour_angle = Some(0.75);
        original.telemetry.pier_side = Some(PierSide::West);
        original.telemetry.mount_tracking_limit_time = Some(1_700_000_000);
        original.meridian.mark_performed(None);
        original.target.current_target_name = Some("M31".into());
        original.guiding.restore(true, false);
        original.telemetry.current_humidity = Some(63.0);
        original.target.current_altitude = Some(58.4);
        original.telemetry.weather_safe = true;
        original.latches.baseline_temperature = Some(-3.5);
        original.latches.current_temperature = Some(-2.0);
        original.latches.baseline_focuser_position = Some(28000);
        original.latches.filter_changed = true;
        original.latches.current_filter = Some("Ha".into());
        original.telemetry.dawn_time = Some(1_700_010_000);
        original.settings.observer_latitude = Some(45.5);
        original.settings.observer_longitude = Some(-122.6);
        original.latches.completed_exposures = 42;
        original.latches.last_autofocus_frame = 30;
        original.latches.last_dither_frame = 41;
        original.tracking.set_limit_detected_at(Some(1_700_005_000));
        original.latches.grid_dither_index = 7;
        original.latches.last_applied_filter_offset = 42;

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
        assert_eq!(restored.latches.baseline_hfr, original.latches.baseline_hfr);
        assert_eq!(restored.latches.current_hfr, original.latches.current_hfr);
        assert_eq!(
            restored.latches.autofocus_invalidated,
            original.latches.autofocus_invalidated
        );
        assert_eq!(
            restored.latches.autofocus_invalidation_reason,
            original.latches.autofocus_invalidation_reason
        );
        assert_eq!(
            restored.target.current_hour_angle,
            original.target.current_hour_angle
        );
        assert_eq!(restored.telemetry.pier_side, original.telemetry.pier_side);
        assert_eq!(
            restored.telemetry.mount_tracking_limit_time,
            original.telemetry.mount_tracking_limit_time
        );
        assert_eq!(
            restored.meridian.has_flipped(),
            original.meridian.has_flipped()
        );
        assert_eq!(
            restored.target.current_target_name,
            original.target.current_target_name
        );
        assert_eq!(restored.guiding.is_enabled(), original.guiding.is_enabled());
        assert_eq!(restored.guiding.star_lost(), original.guiding.star_lost());
        assert_eq!(
            restored.telemetry.current_humidity,
            original.telemetry.current_humidity
        );
        assert_eq!(
            restored.target.current_altitude,
            original.target.current_altitude
        );
        assert_eq!(
            restored.telemetry.weather_safe,
            original.telemetry.weather_safe
        );
        assert_eq!(
            restored.latches.baseline_temperature,
            original.latches.baseline_temperature
        );
        assert_eq!(
            restored.latches.current_temperature,
            original.latches.current_temperature
        );
        assert_eq!(
            restored.latches.baseline_focuser_position,
            original.latches.baseline_focuser_position
        );
        assert_eq!(
            restored.latches.filter_changed,
            original.latches.filter_changed
        );
        assert_eq!(
            restored.latches.current_filter,
            original.latches.current_filter
        );
        assert_eq!(
            restored.latches.last_applied_filter_offset,
            original.latches.last_applied_filter_offset
        );
        assert_eq!(restored.telemetry.dawn_time, original.telemetry.dawn_time);
        assert_eq!(
            restored.settings.observer_latitude,
            original.settings.observer_latitude
        );
        assert_eq!(
            restored.settings.observer_longitude,
            original.settings.observer_longitude
        );
        assert_eq!(
            restored.latches.completed_exposures,
            original.latches.completed_exposures
        );
        assert_eq!(
            restored.latches.last_autofocus_frame,
            original.latches.last_autofocus_frame
        );
        assert_eq!(
            restored.latches.last_dither_frame,
            original.latches.last_dither_frame
        );
        assert_eq!(
            restored.tracking.limit_detected_at(),
            original.tracking.limit_detected_at()
        );
        assert_eq!(
            restored.latches.grid_dither_index,
            original.latches.grid_dither_index
        );
    }

    #[test]
    fn a_trigger_state_snapshot_tolerates_missing_and_unknown_fields() {
        let snapshot: TriggerStateSnapshot = serde_json::from_str(
            r#"{
                "completed_exposures": 3,
                "has_flipped_this_target": true,
                "next_meridian_flip_time": 1700000000,
                "a_field_from_a_newer_version": {"anything": [1, 2]}
            }"#,
        )
        .expect("a sparse snapshot with unknown fields must load");
        assert_eq!(snapshot.state.latches.completed_exposures, 3);
        assert!(snapshot.state.meridian.has_flipped_this_target);
        assert_eq!(snapshot.state.target.current_target_name, None);
        assert!(!snapshot.state.telemetry.weather_safe);
        assert_eq!(snapshot.safety_fail_mode, SafetyFailMode::FailClosed);
        assert!(snapshot.triggers_enabled, "triggers default to on");
        assert!(snapshot.filter_focus_offsets.is_empty());
    }

    #[test]
    fn test_checkpoint_persists_has_flipped_this_target_across_save_load() {
        let dir = test_dir("trigger_state_persist");
        let manager = CheckpointManager::new(&dir);

        let mut state = TriggerState::new();
        state.meridian.mark_performed(None);
        state.target.current_target_name = Some("NGC7000".into());
        state.latches.completed_exposures = 17;
        state.latches.last_autofocus_frame = 10;
        state.latches.last_dither_frame = 16;
        state.latches.grid_dither_index = 4;
        state.latches.baseline_hfr = Some(2.1);

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
        assert!(restored_snapshot.state.meridian.has_flipped_this_target);
        assert_eq!(
            restored_snapshot
                .state
                .target
                .current_target_name
                .as_deref(),
            Some("NGC7000")
        );
        assert_eq!(restored_snapshot.state.latches.completed_exposures, 17);
        assert_eq!(restored_snapshot.state.latches.last_autofocus_frame, 10);
        assert_eq!(restored_snapshot.state.latches.last_dither_frame, 16);
        assert_eq!(restored_snapshot.state.latches.grid_dither_index, 4);
        assert_eq!(restored_snapshot.state.latches.baseline_hfr, Some(2.1));
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
