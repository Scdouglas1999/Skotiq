//! `mosaic.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Mosaic instruction

/// Execute mosaic panel iteration. Delegates to [`crate::mosaic::run_mosaic_wizard`]
/// which drives a [`crate::wizard::Wizard`] for per-panel checkpoint
/// support.
pub async fn execute_mosaic(
    config: &crate::MosaicConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    checkpoint_manager: Option<&crate::checkpoint::CheckpointManager>,
) -> InstructionResult {
    crate::mosaic::run_mosaic_wizard(config, ctx, progress_callback, checkpoint_manager).await
}
