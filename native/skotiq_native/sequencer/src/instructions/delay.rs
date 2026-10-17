//! `delay.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Delay instruction

/// Execute delay
pub async fn execute_delay(
    config: &DelayConfig,
    ctx: &crate::node::context::ExecutionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    tracing::info!("Delaying for {:.1} seconds", config.seconds);

    // Emit initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, format!("{:.0}s delay", config.seconds));
    }

    // Why: config.seconds is f64 user-config delay (UI-bounded). f64 -> u64
    // saturates per Rust 1.45 spec; negatives clamp to 0 yielding no-wait.
    let total_steps = (config.seconds * 10.0) as u64;
    for step in 0..total_steps {
        if !ctx.wait_while_paused().await {
            return InstructionResult::cancelled("Delay cancelled");
        }
        if ctx.is_cancelled.load(Ordering::Relaxed) {
            return InstructionResult::cancelled("Delay cancelled");
        }

        // Emit progress every second (10 steps)
        if step % 10 == 0 {
            // Why: u64 step -> f64 lossless under any plausible delay length
            // (years of seconds fit in 53-bit mantissa).
            let elapsed_secs = step as f64 / 10.0;
            let remaining_secs = config.seconds - elapsed_secs;
            let progress = (elapsed_secs / config.seconds) * 100.0;
            if let Some(cb) = progress_callback {
                cb(progress, format!("{:.0}s remaining", remaining_secs));
            }
        }

        sleep(Duration::from_millis(100)).await;
    }

    if let Some(cb) = progress_callback {
        cb(100.0, "Delay complete".to_string());
    }

    InstructionResult::success_with_message(format!("Delayed {:.1} seconds", config.seconds))
}
