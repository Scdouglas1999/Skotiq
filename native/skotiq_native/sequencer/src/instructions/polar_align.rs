//! `polar_align.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Polar alignment instruction

/// Execute polar alignment
pub async fn execute_polar_alignment(
    config: &PolarAlignConfig,
    ctx: &InstructionContext,
    status_callback: impl Fn(String, Option<f64>) + Send + Sync,
    image_callback: impl Fn(crate::polar_align::PolarAlignmentImageData) + Send + Sync,
) -> InstructionResult {
    crate::polar_align::perform_polar_alignment(config, ctx, status_callback, image_callback).await
}
