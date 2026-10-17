//! Mosaic instruction node.
//!
//! ## When this code runs
//!
//! This node executes only when a sequence contains a
//! [`NodeType::Mosaic`] variant. In the current architecture
//! Skotiq's Dart UI does NOT emit `Mosaic` nodes — the
//! `MosaicService.createMosaicSequence` path expands a mosaic into
//! N×M `TargetHeader` siblings instead, so the per-panel slew /
//! center / expose / dither work happens at the node tree level. See
//! [`crate::mosaic`] module docs for the full architectural
//! discussion.
//!
//! This node is the forward-looking entry point for when the
//! orchestration eventually moves into Rust (so the Dart side emits a
//! single mosaic node with `MosaicConfig` and the wizard owns
//! per-panel work). Its per-panel resume is already real: the node
//! hands [`crate::mosaic::run_mosaic_wizard`] the session's
//! `CheckpointManager` off `ExecutionContext`, which persists each
//! completed panel through `SessionWizardCheckpointSink` — see
//! `resume_round_trips_through_session_sink_on_disk` in
//! [`crate::mosaic`] and `node_persists_panel_progress_through_the_session_sink`
//! below. ON-RIG VALIDATION IS OWED.
//!
//! ## Progress reporting
//!
//! Every progress update emitted by the wizard carries a structured
//! [`ProgressDetail::Mosaic`] payload (`panel_index`, `total_panels`).
//! The Dart Run Dashboard consumes the typed payload directly so it
//! can render "Panel 5/9" without parsing message strings.

use crate::instructions::execute_mosaic;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct MosaicInstruction;

#[async_trait]
impl InstructionNode for MosaicInstruction {
    fn type_name(&self) -> &'static str {
        "Mosaic"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::Mosaic(config) = node_type else {
            tracing::error!("MosaicInstruction received non-Mosaic variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        // Per-panel resume: hand the wizard the session's checkpoint
        // manager so completed panels are recorded on disk. `None` (no
        // checkpoint directory configured) runs without persistence.
        let checkpoint_manager = context.checkpoint_manager.clone();
        let progress_cb = context.progress_callback.as_ref();
        let total_panels = config
            .panels_horizontal
            .saturating_mul(config.panels_vertical);
        let panels_horizontal = config.panels_horizontal;

        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                let panel_index = extract_panel_index(&detail).unwrap_or(0);
                // derive panel_row / panel_col from the panel
                // index using the configured horizontal grid width.
                // The mosaic plan emits panels in row-major order
                // (`calculate_mosaic_panels` enforces this), so
                // `row = idx / cols`, `col = idx % cols`. `panel_index`
                // here is 1-based when parsed out of the progress
                // string ("panel 5/9"); we convert to 0-based for the
                // row/col arithmetic, then keep `panel_index` as 1-based
                // in the payload (matches the existing wire shape).
                let (panel_row, panel_col) = if panels_horizontal > 0 && panel_index > 0 {
                    let zero_based = panel_index - 1;
                    (
                        Some(zero_based / panels_horizontal),
                        Some(zero_based % panels_horizontal),
                    )
                } else {
                    (None, None)
                };
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Mosaic",
                    progress,
                    ProgressDetail::Mosaic {
                        panel_index,
                        total_panels,
                        panel_row,
                        panel_col,
                    },
                ));
            }
        };

        execute_mosaic(
            config,
            &ctx,
            Some(&progress_fn),
            checkpoint_manager.as_deref(),
        )
        .await
        .log_and_get_status_with_context("Mosaic", &ctx)
    }
}

fn extract_panel_index(detail: &str) -> Option<u32> {
    let lower = detail.to_lowercase();
    let idx = lower.find("panel ")?;
    let rest = &detail[idx + "panel ".len()..];
    let mut buf = String::new();
    for c in rest.chars() {
        if c.is_ascii_digit() {
            buf.push(c);
        } else {
            break;
        }
    }
    if buf.is_empty() {
        None
    } else {
        buf.parse::<u32>().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::checkpoint::{CheckpointManager, SessionCheckpoint, WizardCheckpoint};
    use crate::{ExecutorState, MosaicConfig, SequenceDefinition};
    use std::sync::{Arc, Mutex};

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

    /// The PRODUCTION wiring, end to end from the node down to disk.
    /// `MosaicInstruction` reads the session's `CheckpointManager` off
    /// `ExecutionContext` and hands it to the wizard, which persists per-panel
    /// progress through `SessionWizardCheckpointSink`. A checkpoint left by a
    /// killed run must make the node resume at the first unfinished panel, and
    /// the slot must be cleared once the mosaic finishes — a
    /// `NullCheckpointSink` here reports every panel from 1 and leaves the stale
    /// slot on disk.
    #[tokio::test]
    async fn node_persists_panel_progress_through_the_session_sink() {
        let dir = std::env::temp_dir().join(format!(
            "skotiq_mosaic_node_resume_{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).expect("test dir");

        // A previous run died after four of nine panels.
        let manager = Arc::new(CheckpointManager::new(&dir));
        let mut seeded =
            SessionCheckpoint::new(SequenceDefinition::new("Mosaic Sequence".to_string()));
        seeded.is_active = true;
        seeded.executor_state = ExecutorState::Running;
        seeded.set_wizard_state(WizardCheckpoint {
            checkpoint_key: "mosaic".to_string(),
            completed_steps: 4,
            timestamp: chrono::Utc::now(),
        });
        manager.save(&seeded).expect("seed save");

        let panels = Arc::new(Mutex::new(Vec::new()));
        let recorded = panels.clone();
        let mut context = ExecutionContext::new_for_test("mosaic-1".to_string());
        // What the executor installs at start().
        context.checkpoint_manager = Some(manager.clone());
        context.progress_callback = Some(Arc::new(move |update: ProgressUpdate| {
            if let Some(ProgressDetail::Mosaic { panel_index, .. }) = update.detail {
                recorded.lock().expect("panel mutex").push(panel_index);
            }
        }));

        let status = MosaicInstruction
            .execute(
                "mosaic-1",
                &NodeType::Mosaic(three_by_three_config()),
                &mut context,
            )
            .await;

        assert_eq!(status, NodeStatus::Success);
        let reported = panels.lock().expect("panel mutex").clone();
        assert!(
            reported.contains(&5) && !reported.contains(&1),
            "the node must resume at panel 5, not restart at panel 1: {reported:?}"
        );
        let after = manager
            .load()
            .expect("load after run")
            .expect("session checkpoint still present");
        assert!(
            after.wizard_state("mosaic").is_none(),
            "the completed mosaic must clear its slot so the next run starts fresh"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
