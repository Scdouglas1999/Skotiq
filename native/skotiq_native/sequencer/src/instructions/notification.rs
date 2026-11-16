//! Sending a notification from a sequence.

use super::*;

// Notification instruction

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
        .run
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
