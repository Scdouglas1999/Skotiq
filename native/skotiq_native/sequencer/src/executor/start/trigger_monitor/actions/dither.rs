//! `Dither`: the standard Dither Interval recovery.

use super::*;

/// Dither once; [`crate::instructions::execute_dither`] restarts the cadence.
pub(in super::super) async fn run(
    trigger_name: &str,
    trigger_config: &crate::DitherConfig,
    rig: &Rig,
    run: &RunControl,
) -> ActionFlow {
    let config = rig.runtime_config.read().dither_for(trigger_config);
    tracing::info!(
        "[DITHER] Trigger '{}' fired - executing dither (pixels={}, settle_pixels={})",
        trigger_name,
        config.pixels,
        config.settle_pixels,
    );
    let dither_ctx = rig.instruction_context(rig.target().await, run);
    let result = crate::instructions::execute_dither(&config, &dither_ctx, None).await;
    match result.status {
        NodeStatus::Success => {}
        NodeStatus::Skipped => tracing::info!(
            "[DITHER] Trigger '{}': {}",
            trigger_name,
            result.message.as_deref().unwrap_or("dither skipped")
        ),
        _ => tracing::warn!(
            "[DITHER] Trigger-initiated dither failed: {:?}",
            result.message
        ),
    }
    ActionFlow::Finished
}
