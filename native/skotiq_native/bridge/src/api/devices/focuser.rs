use crate::device::FocuserStatus;
use crate::device_manager::get_device_manager;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;

/// What focuser drivers say when they refuse a move because the focuser is
/// already moving (ASCOM drivers answer "Move Failure"), lowercased.
const BUSY_ANSWERS: [&str; 4] = [
    "move failure",
    "already moving",
    "device busy",
    "focuser is busy",
];

/// A move the driver refused because the focuser is moving is a busy
/// device (`DeviceBusy` over the FFI, 409 on the host), not a fault. Only
/// the app's moves: the run's own moves keep the driver's failure, which its
/// device retry takes as transient (the focuser stops moving).
fn refused_while_moving(device_id: &str, error: DeviceOpError) -> DeviceOpError {
    if matches!(error, DeviceOpError::InvalidState { .. }) {
        return error;
    }
    let words = error.to_string().to_lowercase();
    if BUSY_ANSWERS.iter().any(|answer| words.contains(answer)) {
        DeviceOpError::InvalidState {
            device_id: device_id.to_string(),
            detail: error.to_string(),
        }
    } else {
        error
    }
}

// Focuser control

/// Get focuser status
pub async fn api_get_focuser_status(device_id: String) -> Result<FocuserStatus, SkotiqError> {
    let mgr = get_device_manager();

    let position = mgr
        .focuser_get_position(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let moving = mgr
        .focuser_is_moving(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let temperature = mgr.focuser_get_temp(&device_id).await.unwrap_or(None);
    let (max_position, step_size) = match mgr.focuser_get_details(&device_id).await {
        Ok(details) => details,
        Err(e) => {
            tracing::warn!(
                "Failed to get focuser details for {}: {:?}. Returning unknown max/step values.",
                device_id,
                e
            );
            (0, 0.0)
        }
    };
    let is_absolute = mgr
        .focuser_is_absolute(&device_id)
        .await
        .map_err(SkotiqError::from)?;

    Ok(FocuserStatus {
        connected: true,
        position,
        moving,
        temperature,
        max_position,
        step_size,
        is_absolute,
        has_temperature: temperature.is_some(),
    })
}

/// Move focuser to position
pub async fn api_focuser_move_to(device_id: String, position: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_move_abs(&device_id, position)
        .await
        .map_err(|e| SkotiqError::from(refused_while_moving(&device_id, e)))
}

/// Move focuser by relative amount
pub async fn api_focuser_move_relative(device_id: String, delta: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_move_rel(&device_id, delta)
        .await
        .map_err(|e| SkotiqError::from(refused_while_moving(&device_id, e)))
}

/// Halt focuser
pub async fn api_focuser_halt(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_halt(&device_id)
        .await
        .map_err(SkotiqError::from)
}
