//! `disconnect.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

pub(crate) fn is_device_disconnected_message(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    if lower.contains("please reconnect") {
        return true;
    }
    if lower.contains("device") && lower.contains("not connected") {
        return true;
    }

    const DEVICE_PREFIXES: &[&str] = &[
        "camera",
        "mount",
        "focuser",
        "filter wheel",
        "filterwheel",
        "rotator",
        "dome",
        "cover calibrator",
        "flat panel",
    ];
    DEVICE_PREFIXES.iter().any(|prefix| {
        lower.contains(&format!("no {prefix} connected"))
            || lower.contains(&format!("{prefix} is not connected"))
            || lower.contains(&format!("{prefix} not connected"))
    })
}

pub(crate) fn request_device_disconnected_recovery(
    node_name: &str,
    message: &str,
    recovery_request_tx: Option<&mpsc::Sender<crate::recovery::RecoveryCause>>,
) {
    let Some(tx) = recovery_request_tx else {
        tracing::warn!(
            "[RECOVERY] {} detected a device disconnect but no recovery channel is installed: {}",
            node_name,
            message
        );
        return;
    };

    match tx.try_send(crate::recovery::RecoveryCause::DeviceDisconnected) {
        Ok(()) => tracing::warn!(
            "[RECOVERY] {} promoted device disconnect to recovery: {}",
            node_name,
            message
        ),
        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => tracing::warn!(
            "[RECOVERY] Recovery channel full; dropping duplicate device-disconnect request from {}: {}",
            node_name,
            message
        ),
        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => tracing::warn!(
            "[RECOVERY] Recovery channel closed; {} device-disconnect failure cannot enter recovery: {}",
            node_name,
            message
        ),
    }
}
