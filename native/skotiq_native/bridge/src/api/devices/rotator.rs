//! Rotator control exposed to Dart.

use crate::api::diagnostics::api_get_rotator_capabilities;
use crate::device::RotatorStatus;
use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;

/// Get rotator status
pub async fn api_get_rotator_status(device_id: String) -> Result<RotatorStatus, SkotiqError> {
    let mgr = get_device_manager();

    let position = mgr
        .rotator_get_position(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let is_moving = mgr
        .rotator_is_moving(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let mechanical_position = match mgr.rotator_get_mechanical_position(&device_id).await {
        Ok(angle) => angle,
        Err(e) => {
            tracing::warn!(
                "Failed to read the mechanical angle of rotator {}: {}. Showing the sky angle.",
                device_id,
                e
            );
            position
        }
    };
    let can_reverse = match api_get_rotator_capabilities(device_id.clone()).await {
        Ok(caps) => caps.can_reverse,
        Err(e) => {
            tracing::warn!(
                "Failed to query rotator capabilities for {}: {:?}. Treating reverse as unsupported.",
                device_id,
                e
            );
            false
        }
    };

    Ok(RotatorStatus {
        connected: true,
        position,
        moving: is_moving,
        mechanical_position,
        is_moving,
        can_reverse,
    })
}

/// Move rotator to angle
pub async fn api_rotator_move_to(device_id: String, angle: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.rotator_move_absolute(&device_id, angle)
        .await
        .map_err(SkotiqError::from)
}

/// Move rotator relative
pub async fn api_rotator_move_relative(device_id: String, delta: f64) -> Result<(), SkotiqError> {
    get_device_manager()
        .rotator_move_relative(&device_id, delta)
        .await
        .map_err(SkotiqError::from)
}

/// Set the rotator's reverse-direction flag (IRotatorV3 `Reverse`, Alpaca
/// `reverse`, INDI `ROTATOR_REVERSE`).
pub async fn api_rotator_set_reverse(device_id: String, reverse: bool) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.rotator_set_reverse(&device_id, reverse)
        .await
        .map_err(SkotiqError::from)
}

/// Halt rotator
pub async fn api_rotator_halt(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.rotator_halt(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Sync rotator's reported sky angle to the supplied position angle without
/// moving the hardware. Used by the "Sync to image PA" workflow after a plate
/// solve: the solver returns the astrometric PA of the captured frame and
/// this call aligns the rotator's reported PA so subsequent absolute moves
/// land at the correct sky angle.
pub async fn api_rotator_sync_to_pa(device_id: String, pa: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.rotator_sync(&device_id, pa)
        .await
        .map_err(SkotiqError::from)
}
