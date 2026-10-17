//! `notification.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Notification instruction

/// Execute notification
pub async fn execute_notification(
    config: &NotificationConfig,
    ctx: &InstructionContext,
) -> InstructionResult {
    let level = match config.level {
        NotificationLevel::Info => "info",
        NotificationLevel::Warning => "warning",
        NotificationLevel::Error => "error",
        NotificationLevel::Success => "success",
    };

    tracing::info!(
        "[{}] {}: {}",
        level.to_uppercase(),
        config.title,
        config.message
    );

    if let Err(e) = ctx
        .device_ops
        .send_notification(
            level,
            &config.title,
            &config.message,
            config.explicit_transports.as_deref(),
        )
        .await
    {
        tracing::warn!("Failed to send notification: {}", e);
    }

    InstructionResult::success()
}
