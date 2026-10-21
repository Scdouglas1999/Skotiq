//! `Dither`: the standard Dither Interval recovery.

use super::*;

/// Dither once and move the cadence anchor when it ran, or when the rig has
/// no guider to dither with (otherwise the interval stays due and re-fires on
/// every frame).
pub(in super::super) async fn run(
    trigger_name: &str,
    trigger_config: &crate::DitherConfig,
    rig: &Rig,
    run: &RunControl,
) -> ActionFlow {
    let config = effective_config(trigger_config, &rig.runtime_config.read());
    tracing::info!(
        "[DITHER] Trigger '{}' fired - executing dither (pixels={}, settle_pixels={})",
        trigger_name,
        config.pixels,
        config.settle_pixels,
    );
    let dither_ctx = rig.instruction_context(rig.target().await, run);
    let result = crate::instructions::execute_dither(&config, &dither_ctx, None).await;
    match classify_dither_result(result.status, result.message.as_deref()) {
        DitherTriggerOutcome::Performed => {
            rig.trigger_state.write().await.mark_dither_performed();
        }
        DitherTriggerOutcome::SkippedNoGuider => {
            rig.trigger_state.write().await.mark_dither_performed();
            tracing::debug!(
                "[DITHER] Trigger '{}' skipped - no guider configured",
                trigger_name
            );
        }
        DitherTriggerOutcome::Failed => {
            tracing::warn!(
                "[DITHER] Trigger-initiated dither failed: {:?}",
                result.message
            );
        }
    }
    ActionFlow::Finished
}

/// The operator's last UpdateDitherConfig wins once it has been pushed
/// (non-zero pixels); the pattern and grid size, which that command does not
/// carry, always come from the trigger.
fn effective_config(
    trigger_config: &crate::DitherConfig,
    runtime: &RuntimeConfig,
) -> crate::DitherConfig {
    if runtime.dither.pixels > 0.0 {
        crate::DitherConfig {
            pixels: runtime.dither.pixels,
            settle_pixels: runtime.dither.settle_pixels,
            settle_time: runtime.dither.settle_time,
            settle_timeout: runtime.dither.settle_timeout,
            ra_only: runtime.dither.ra_only,
            pattern: trigger_config.pattern,
            grid_size: trigger_config.grid_size,
        }
    } else {
        trigger_config.clone()
    }
}
