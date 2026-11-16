//! The polar alignment instruction.

use super::*;

// Polar alignment instruction

pub async fn execute_polar_alignment(
    config: &PolarAlignConfig,
    ctx: &InstructionContext,
    status_callback: impl Fn(String, Option<f64>) + Send + Sync,
    image_callback: impl Fn(crate::polar_align::PolarAlignmentImageData) + Send + Sync,
) -> InstructionResult {
    crate::polar_align::perform_polar_alignment(config, ctx, status_callback, image_callback).await
}
