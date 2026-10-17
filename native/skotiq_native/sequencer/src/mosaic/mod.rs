//! Mosaic Panel Wizard
//!
//! Calculates the grid of panel positions for mosaic imaging and runs
//! the per-panel iteration through the shared [`crate::wizard::Wizard`]
//! infrastructure.
//!
//! ## How a mosaic runs today
//!
//! The canonical path is Dart-side static expansion, not the Rust `Mosaic`
//! instruction node: `MosaicService.createMosaicSequence` expands an N×M
//! mosaic into N×M `TargetHeaderNode` children, each carrying its own
//! `MosaicPanelInfo`, and the executor walks those headers like any other
//! targets. The panel info flows into `ExecutionContext` at target-header
//! entry, and the per-frame FITS save path stamps `MOSAIC=1`, `PANELIDX`,
//! `PANELROW`, `PANELCOL` and the `NS-*` private keywords (see
//! `bridge/src/api/imaging.rs` `api_save_fits_file`).
//!
//! Resume comes from the node-level checkpoint: each panel's
//! `TargetHeaderNode` has a unique NodeId and the executor's
//! `SessionCheckpoint::node_statuses` map records its state, so a 3×3 mosaic
//! killed mid-panel-5 resumes at panel 5 with no mosaic-specific handling.
//!
//! ## What this module does
//!
//! `execute_mosaic` runs when a sequence contains a `NodeType::Mosaic` node —
//! the registry palette permits one, but Dart's UI does not emit one today.
//! It calculates panel positions, drives the [`crate::wizard::WizardExecutor`]
//! through one step per panel, and returns a metadata payload describing the
//! grid. The wizard step body looks up panel coordinates and records the panel
//! index; slew/center/expose belong to the surrounding tree.
//!
//! `run_mosaic_wizard` takes the running session's `CheckpointManager` — the
//! executor puts it on `ExecutionContext::checkpoint_manager` at start() and
//! `MosaicInstruction` passes it down — and wraps it in
//! `SessionWizardCheckpointSink`, so per-panel progress lands in the session
//! checkpoint's `wizard_states` slot on disk. When per-panel orchestration
//! moves into the Rust `Mosaic` node, resume is already persisted.
//!
//! ON-RIG VALIDATION IS OWED: the persistence path is covered by tests down to
//! disk, but no mosaic has been killed and resumed against real hardware.
//!
//! See `wizard/mod.rs` for the shared executor and trait, and `checkpoint.rs`
//! for the on-disk persistence layer.

mod panels;

pub use panels::{
    calculate_mosaic_area, calculate_mosaic_panels, estimate_mosaic_time, MosaicPanel,
};

use crate::checkpoint::{CheckpointManager, SessionWizardCheckpointSink};
use crate::instructions::{InstructionContext, InstructionResult};
use crate::wizard::{
    BorrowedProgressReporter, NullCheckpointSink, Wizard, WizardCheckpointSink, WizardExecutor,
    WizardProgressReporter, WizardRunStatus, WizardStepOutcome,
};
use crate::{MosaicConfig, NodeStatus};
use async_trait::async_trait;

/// One step per panel in the mosaic plan, identified by the global
/// panel index (row-major across the grid).
#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct MosaicStep {
    panel_index: u32,
}

/// Internal state for a mosaic run.
struct MosaicWizardRun<'a> {
    config: &'a MosaicConfig,
    panels: Vec<MosaicPanel>,
    /// Panel indices that completed in this run (for the final summary).
    /// Shared with the caller via `Arc<Mutex<...>>` so tests can observe
    /// which panels were actually visited (useful for resume tests).
    completed_panel_indices: std::sync::Arc<std::sync::Mutex<Vec<u32>>>,
}

#[async_trait]
impl<'a> Wizard for MosaicWizardRun<'a> {
    type StepKey = MosaicStep;
    type Outcome = InstructionResult;

    fn name(&self) -> &'static str {
        "Mosaic"
    }

    fn checkpoint_key(&self) -> &'static str {
        "mosaic"
    }

    fn plan_steps(&self, _resume_idx: usize) -> Vec<MosaicStep> {
        // Mosaic has a fixed plan (one step per pre-computed panel),
        // so `_resume_idx` is informational only — the executor will
        // skip the first `_resume_idx` panels from the same plan.
        self.panels
            .iter()
            .map(|p| MosaicStep {
                panel_index: p.panel_index,
            })
            .collect()
    }

    fn describe_step(&self, step: &MosaicStep, _idx: usize) -> String {
        // Why: usize -> u32 saturates in the pathological case which is
        // far beyond mosaic sizes; total panels is u32 already.
        let total = u32::try_from(self.panels.len()).unwrap_or(u32::MAX);
        format!("Panel {}/{}", step.panel_index + 1, total)
    }

    async fn execute_step(
        &mut self,
        _ctx: &InstructionContext,
        step: MosaicStep,
        _idx: usize,
        progress: &dyn WizardProgressReporter,
    ) -> WizardStepOutcome<MosaicStep> {
        // Look up the panel coordinates (slewing / centering / exposing
        // for each panel is performed by the surrounding node tree —
        // this wizard tracks per-panel progress + checkpoint slot).
        let panel = match self
            .panels
            .iter()
            .find(|p| p.panel_index == step.panel_index)
        {
            Some(p) => p,
            None => {
                return WizardStepOutcome::Failed(format!(
                    "Mosaic panel index {} not found in computed grid",
                    step.panel_index
                ));
            }
        };

        tracing::debug!(
            "Mosaic panel {} at RA={:.4}h, Dec={:.4}° (row={}, col={})",
            step.panel_index,
            panel.ra_hours,
            panel.dec_degrees,
            panel.row,
            panel.col,
        );

        // Mid-panel progress (between the executor's per-step "Panel X/N"
        // emission), scaled to overall 0..100%.
        // Why: usize <= u32::MAX in realistic mosaics; widening to f64
        // is exact for u32.
        let total = self.panels.len();
        let progress_frac = if total > 0 {
            (step.panel_index as f64 + 1.0) / (total as f64)
        } else {
            0.0
        };
        progress.report(
            progress_frac,
            format!("Mosaic panel {}/{}", step.panel_index + 1, total),
        );

        self.completed_panel_indices
            .lock()
            .expect("MosaicWizardRun mutex")
            .push(step.panel_index);
        WizardStepOutcome::Completed
    }

    fn finalize(self, status: WizardRunStatus) -> InstructionResult {
        let total_panels = self.panels.len();
        match status {
            WizardRunStatus::Completed => InstructionResult {
                status: NodeStatus::Success,
                message: Some(format!("Mosaic configured: {} panels", total_panels)),
                data: Some(serde_json::json!({
                    "total_panels": total_panels,
                    "panels_horizontal": self.config.panels_horizontal,
                    "panels_vertical": self.config.panels_vertical,
                    "overlap_percent": self.config.overlap_percent,
                    "total_area_arcmin2": calculate_mosaic_area(self.config),
                })),
                hfr_values: Vec::new(),
            },
            WizardRunStatus::Cancelled => InstructionResult::cancelled("Operation cancelled"),
            WizardRunStatus::Failed(msg) => InstructionResult::failure(msg),
        }
    }
}

/// Execute the mosaic instruction (validate grid, iterate panel
/// checkpoints, emit progress, return the summary payload).
///
/// The public entry is [`crate::instructions::execute_mosaic`]; this is the
/// implementation it delegates to.
/// `checkpoint_manager` is the running session's manager (the executor
/// passes `ExecutionContext::checkpoint_manager`). When present, per-panel
/// progress is written into the session checkpoint's `wizard_states` slot
/// through [`SessionWizardCheckpointSink`], so a run killed mid-mosaic
/// resumes at the first unfinished panel. When absent (no checkpoint
/// directory, or a wizard run outside a session) nothing is persisted and
/// every run starts at panel 0.
pub async fn run_mosaic_wizard(
    config: &MosaicConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    checkpoint_manager: Option<&CheckpointManager>,
) -> InstructionResult {
    let session_sink = checkpoint_manager.map(SessionWizardCheckpointSink::new);
    let null_sink = NullCheckpointSink;
    let sink: &dyn WizardCheckpointSink = match session_sink {
        Some(ref session) => session,
        None => &null_sink,
    };
    let visited = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    run_mosaic_wizard_inner(config, ctx, progress_callback, sink, visited).await
}

/// Run the mosaic wizard with a caller-supplied checkpoint sink and a
/// shared "visited panels" accumulator. Used by tests to exercise
/// per-panel resume behavior. Returns the `InstructionResult` and the
/// list of panel indices that this particular run executed (i.e.,
/// after subtracting any steps skipped due to resume).
#[doc(hidden)]
pub async fn run_mosaic_wizard_with_sink(
    config: &MosaicConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    sink: &dyn WizardCheckpointSink,
) -> (InstructionResult, Vec<u32>) {
    let visited = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let result =
        run_mosaic_wizard_inner(config, ctx, progress_callback, sink, visited.clone()).await;
    let visited_panels = visited.lock().expect("visited mutex").clone();
    (result, visited_panels)
}

async fn run_mosaic_wizard_inner(
    config: &MosaicConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    sink: &dyn WizardCheckpointSink,
    visited: std::sync::Arc<std::sync::Mutex<Vec<u32>>>,
) -> InstructionResult {
    let reporter = BorrowedProgressReporter {
        callback: progress_callback,
    };

    // "Starting mosaic" at 0%, then "Calculating panel positions" at 30%.
    reporter.report(0.0, "Starting mosaic".to_string());

    tracing::info!(
        "Starting mosaic: {}x{} panels, {:.1}% overlap",
        config.panels_horizontal,
        config.panels_vertical,
        config.overlap_percent
    );

    reporter.report(0.30, "Calculating panel positions".to_string());

    let panels = calculate_mosaic_panels(config);
    let total_panels = panels.len();
    tracing::info!("Mosaic contains {} panels", total_panels);

    let executor = WizardExecutor::new(&reporter, sink);
    let wizard = MosaicWizardRun {
        config,
        panels,
        completed_panel_indices: visited,
    };
    let (result, _status) = executor.run(wizard, ctx).await;

    // Final progress: "Mosaic configured: N panels" at 100%.
    if result.status == NodeStatus::Success {
        reporter.report(1.0, format!("Mosaic configured: {} panels", total_panels));
    }

    result
}

#[cfg(test)]
mod resume_tests {
    use super::*;
    use crate::checkpoint::WizardCheckpoint;
    use crate::device_ops::NullDeviceOps;
    use crate::wizard::MemoryCheckpointSink;
    use std::collections::HashMap;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    fn dummy_ctx() -> InstructionContext {
        InstructionContext {
            node_id: String::new(),
            target_ra: None,
            target_dec: None,
            target_rotation: None,
            target_name: None,
            current_filter: None,
            current_binning: crate::Binning::One,
            cancellation_token: Arc::new(AtomicBool::new(false)),
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
            device_ops: Arc::new(NullDeviceOps),
            trigger_state: None,
            filter_focus_offsets: HashMap::new(),
            event_tx: None,
            recovery_request_tx: None,
            device_disconnect_recovery_pending: Arc::new(std::sync::atomic::AtomicBool::new(false)),
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
            last_plate_solve: Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline: Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline_samples: Arc::new(tokio::sync::RwLock::new(Vec::new())),
            consecutive_rejects: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_accepted: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_rejected: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            default_quality_check: None,
            reject_folder_path: None,
            defect_map_apply: Arc::new(tokio::sync::RwLock::new(None)),
            // Forensics test scaffolding.
            forensics_history: Arc::new(
                tokio::sync::RwLock::new(std::collections::VecDeque::new()),
            ),
            current_sky_brightness_mag: Arc::new(tokio::sync::RwLock::new(None)),
            cloud_motion_snapshot: Arc::new(tokio::sync::RwLock::new(
                crate::node::context::CloudMotionSnapshot::default(),
            )),
            current_wind_kph: Arc::new(tokio::sync::RwLock::new(None)),
            current_sensor_temp_c: Arc::new(tokio::sync::RwLock::new(None)),
            // Replay Debug — test ctx doesn't emit decisions.
            decision_tx: None,
            active_sequence_run_id: Arc::new(parking_lot::RwLock::new(None)),
            dither_barrier: None,
            device_retry: crate::instructions::DeviceRetryHandle::single_attempt(),
        }
    }

    fn three_by_three_config() -> MosaicConfig {
        MosaicConfig {
            center_ra: 12.0,
            center_dec: 30.0,
            panel_width_arcmin: 60.0,
            panel_height_arcmin: 60.0,
            overlap_percent: 10.0,
            rotation: 0.0,
            panels_horizontal: 3,
            panels_vertical: 3,
            panel_overhead_secs: 60.0,
        }
    }

    #[tokio::test]
    async fn fresh_3x3_run_visits_all_nine_panels_in_order() {
        let config = three_by_three_config();
        let ctx = dummy_ctx();
        let sink = MemoryCheckpointSink::default();
        let (result, visited) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;

        assert_eq!(result.status, NodeStatus::Success);
        assert_eq!(visited, (0..9_u32).collect::<Vec<_>>());
        // Result payload shape.
        let data = result.data.expect("result.data");
        assert_eq!(data["total_panels"], serde_json::json!(9));
        // Sink is cleared on success.
        assert!(
            sink.load("mosaic").is_none(),
            "checkpoint should be cleared after successful completion"
        );
    }

    #[tokio::test]
    async fn resume_after_panel_4_starts_at_panel_5() {
        // Pre-populate the checkpoint slot as if a previous run completed
        // the first 4 panels (indices 0..3 inclusive, i.e. completed_steps=4).
        // The user's brief language is "panel 4/9" = panels 0..3 complete,
        // so the second run starts at panel index 4 ("panel 5/9").
        let sink = MemoryCheckpointSink::default();
        sink.save(&WizardCheckpoint {
            checkpoint_key: "mosaic".to_string(),
            completed_steps: 4,
            timestamp: chrono::Utc::now(),
        });

        let config = three_by_three_config();
        let ctx = dummy_ctx();
        let (result, visited) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;

        assert_eq!(result.status, NodeStatus::Success);
        // Only panels 4..8 were visited (5 panels: indices 4, 5, 6, 7, 8).
        assert_eq!(visited, vec![4, 5, 6, 7, 8]);
        // Checkpoint cleared after successful resume.
        assert!(sink.load("mosaic").is_none());
    }

    #[tokio::test]
    async fn resume_at_last_panel_visits_only_that_panel() {
        let sink = MemoryCheckpointSink::default();
        sink.save(&WizardCheckpoint {
            checkpoint_key: "mosaic".to_string(),
            completed_steps: 8, // 8/9 done, resume at panel index 8
            timestamp: chrono::Utc::now(),
        });

        let config = three_by_three_config();
        let ctx = dummy_ctx();
        let (result, visited) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;

        assert_eq!(result.status, NodeStatus::Success);
        assert_eq!(visited, vec![8]);
    }

    #[tokio::test]
    async fn legacy_checkpoint_without_mosaic_slot_resumes_from_zero() {
        // A checkpoint without a wizard_states entry for mosaic resumes
        // from panel 0.
        let sink = MemoryCheckpointSink::default();
        // Insert a slot under a DIFFERENT key so the mosaic lookup misses.
        sink.save(&WizardCheckpoint {
            checkpoint_key: "some_other_wizard".to_string(),
            completed_steps: 4,
            timestamp: chrono::Utc::now(),
        });

        let config = three_by_three_config();
        let ctx = dummy_ctx();
        let (_result, visited) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;

        // Full visit, panels 0..8.
        assert_eq!(visited, (0..9_u32).collect::<Vec<_>>());
    }

    /// Mosaic-Resume — end-to-end resume through the production
    /// checkpoint sink. A `MemoryCheckpointSink` is convenient in unit
    /// tests, but the production path is `SessionWizardCheckpointSink`
    /// which writes through a [`crate::checkpoint::CheckpointManager`]
    /// to disk. This test exercises that path verbatim:
    ///
    /// 1. Seed a `SessionCheckpoint` with `wizard_states["mosaic"] =
    ///    completed_steps: 4` on disk.
    /// 2. Open a fresh `CheckpointManager` pointing at the same dir
    ///    (simulating an app restart).
    /// 3. Wrap it in `SessionWizardCheckpointSink` and run the mosaic
    ///    wizard.
    /// 4. Assert only panels 4..8 were visited (i.e. resume worked
    ///    end-to-end through real disk I/O).
    /// 5. Assert the wizard cleared its checkpoint slot after success
    ///    (so a future run starts fresh).
    #[tokio::test]
    async fn resume_round_trips_through_session_sink_on_disk() {
        use crate::checkpoint::{
            CheckpointManager, SessionCheckpoint, SessionWizardCheckpointSink,
        };
        use crate::{ExecutorState, SequenceDefinition};

        let dir =
            std::env::temp_dir().join(format!("skotiq_mosaic_resume_e2e_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("test dir");

        // Step 1: seed a SessionCheckpoint with completed_steps=4 for
        // the mosaic wizard. Mimics the previous run dying after panel
        // 4 of 9.
        {
            let manager = CheckpointManager::new(&dir);
            let mut checkpoint =
                SessionCheckpoint::new(SequenceDefinition::new("Mosaic Sequence".to_string()));
            checkpoint.is_active = true;
            checkpoint.executor_state = ExecutorState::Running;
            checkpoint.set_wizard_state(WizardCheckpoint {
                checkpoint_key: "mosaic".to_string(),
                completed_steps: 4,
                timestamp: chrono::Utc::now(),
            });
            manager.save(&checkpoint).expect("seed save");
        }

        // Step 2: simulate restart by constructing a fresh manager that
        // reads the same on-disk checkpoint.
        let manager = CheckpointManager::new(&dir);
        let loaded = manager
            .load()
            .expect("load after restart")
            .expect("checkpoint file exists");
        let slot = loaded
            .wizard_state("mosaic")
            .expect("mosaic slot survived restart");
        assert_eq!(
            slot.completed_steps, 4,
            "on-disk slot must round-trip exactly"
        );

        // Step 3: run the wizard with the production sink.
        let sink = SessionWizardCheckpointSink::new(&manager);
        let config = three_by_three_config();
        let ctx = dummy_ctx();
        let (result, visited) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;
        assert_eq!(result.status, NodeStatus::Success);
        assert_eq!(
            visited,
            vec![4, 5, 6, 7, 8],
            "resume must skip the first 4 panels"
        );

        // Step 4: after success the sink clears the slot. Reload from
        // disk and confirm.
        let after = manager
            .load()
            .expect("load after wizard")
            .expect("session checkpoint still present (other fields preserved)");
        assert!(
            after.wizard_state("mosaic").is_none(),
            "wizard slot must be cleared after successful run"
        );
        // The surrounding SessionCheckpoint fields (is_active,
        // executor_state) are preserved.
        assert!(after.is_active);
        assert_eq!(after.executor_state, ExecutorState::Running);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Seed an on-disk session checkpoint whose mosaic wizard slot says
    /// `completed_steps` panels are already done, as a killed run leaves it.
    fn seed_session_checkpoint(dir: &std::path::Path, completed_steps: u32) {
        use crate::checkpoint::{CheckpointManager, SessionCheckpoint};
        use crate::{ExecutorState, SequenceDefinition};

        std::fs::create_dir_all(dir).expect("test dir");
        let manager = CheckpointManager::new(dir);
        let mut checkpoint =
            SessionCheckpoint::new(SequenceDefinition::new("Mosaic Sequence".to_string()));
        checkpoint.is_active = true;
        checkpoint.executor_state = ExecutorState::Running;
        checkpoint.set_wizard_state(WizardCheckpoint {
            checkpoint_key: "mosaic".to_string(),
            completed_steps,
            timestamp: chrono::Utc::now(),
        });
        manager.save(&checkpoint).expect("seed save");
    }

    /// Collects the 1-based panel numbers the wizard actually reported, in
    /// order, from the "Mosaic panel N/M" progress messages.
    fn panel_recorder(
        seen: &std::sync::Mutex<Vec<u32>>,
    ) -> impl Fn(f64, String) + Send + Sync + '_ {
        move |_fraction, message| {
            let Some(rest) = message.strip_prefix("Mosaic panel ") else {
                return;
            };
            let Some((number, _total)) = rest.split_once('/') else {
                return;
            };
            if let Ok(number) = number.parse::<u32>() {
                seen.lock().expect("panel recorder mutex").push(number);
            }
        }
    }

    /// The PRODUCTION entry point, not a test-only one, must resume through the
    /// session sink: `run_mosaic_wizard` is handed the executor's
    /// `CheckpointManager` and with one present wraps it in
    /// `SessionWizardCheckpointSink`, so a seeded on-disk slot skips the
    /// completed panels and the slot is cleared once the run finishes.
    #[tokio::test]
    async fn production_entry_resumes_through_the_session_sink() {
        use crate::checkpoint::CheckpointManager;

        let dir = std::env::temp_dir().join(format!(
            "skotiq_mosaic_production_entry_{}",
            uuid::Uuid::new_v4()
        ));
        seed_session_checkpoint(&dir, 4);

        // A fresh manager, as an app restart would build.
        let manager = CheckpointManager::new(&dir);
        let seen = std::sync::Mutex::new(Vec::new());
        let recorder = panel_recorder(&seen);

        let result = run_mosaic_wizard(
            &three_by_three_config(),
            &dummy_ctx(),
            Some(&recorder),
            Some(&manager),
        )
        .await;

        assert_eq!(result.status, NodeStatus::Success);
        assert_eq!(
            seen.lock().expect("panel recorder mutex").clone(),
            vec![5, 6, 7, 8, 9],
            "the production entry must skip the four panels the checkpoint records"
        );
        let after = manager
            .load()
            .expect("load after wizard")
            .expect("session checkpoint still present");
        assert!(
            after.wizard_state("mosaic").is_none(),
            "the session sink clears the slot after a successful run"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The other half of the same wiring: no checkpoint manager (no
    /// checkpoint directory configured) means no persistence at all — every
    /// panel runs and nothing on disk is touched.
    #[tokio::test]
    async fn production_entry_without_a_manager_persists_nothing() {
        use crate::checkpoint::CheckpointManager;

        let dir =
            std::env::temp_dir().join(format!("skotiq_mosaic_no_manager_{}", uuid::Uuid::new_v4()));
        seed_session_checkpoint(&dir, 4);

        let seen = std::sync::Mutex::new(Vec::new());
        let recorder = panel_recorder(&seen);
        let result = run_mosaic_wizard(
            &three_by_three_config(),
            &dummy_ctx(),
            Some(&recorder),
            None,
        )
        .await;

        assert_eq!(result.status, NodeStatus::Success);
        assert_eq!(
            seen.lock().expect("panel recorder mutex").clone(),
            (1..=9_u32).collect::<Vec<_>>(),
            "without a manager the wizard cannot resume and runs every panel"
        );
        let after = CheckpointManager::new(&dir)
            .load()
            .expect("load after wizard")
            .expect("session checkpoint still present");
        assert_eq!(
            after
                .wizard_state("mosaic")
                .expect("slot untouched")
                .completed_steps,
            4,
            "a run with no manager must not write through to the on-disk slot"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn checkpoint_persisted_after_each_panel() {
        // Run a 3x3 mosaic from scratch and verify the sink holds the
        // running completed_steps count after every panel.
        struct ProbeSink {
            inner: std::sync::Mutex<Vec<WizardCheckpoint>>,
        }
        impl crate::wizard::WizardCheckpointSink for ProbeSink {
            fn save(&self, cp: &WizardCheckpoint) {
                self.inner.lock().unwrap().push(cp.clone());
            }
            fn load(&self, _: &str) -> Option<WizardCheckpoint> {
                None
            }
            fn clear(&self, _: &str) {
                self.inner.lock().unwrap().clear();
            }
        }
        let sink = ProbeSink {
            inner: std::sync::Mutex::new(Vec::new()),
        };

        let config = three_by_three_config();
        let ctx = dummy_ctx();
        let (result, _visited) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;
        assert_eq!(result.status, NodeStatus::Success);

        // Sink's `clear` is called on success; we want the saves that
        // happened before that. ProbeSink::clear empties the buffer, so
        // by this point the buffer is empty — instead, observe via the
        // intermediate state. Re-run with a non-clearing sink to capture
        // every save event.
        struct CaptureSink {
            saves: std::sync::Mutex<Vec<u32>>,
        }
        impl crate::wizard::WizardCheckpointSink for CaptureSink {
            fn save(&self, cp: &WizardCheckpoint) {
                self.saves.lock().unwrap().push(cp.completed_steps);
            }
            fn load(&self, _: &str) -> Option<WizardCheckpoint> {
                None
            }
            fn clear(&self, _: &str) {}
        }
        let sink = CaptureSink {
            saves: std::sync::Mutex::new(Vec::new()),
        };
        let (_result, _) = run_mosaic_wizard_with_sink(&config, &ctx, None, &sink).await;
        let saves = sink.saves.lock().unwrap().clone();
        // Saves happen after each step: 1, 2, ..., 9.
        assert_eq!(saves, vec![1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}
