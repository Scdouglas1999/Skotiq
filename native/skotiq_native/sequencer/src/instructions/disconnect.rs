//! Handing a failure that a lost device caused to the run's recovery.

use super::*;

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
