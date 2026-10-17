//! Weather and safety-monitor status reads exposed to Dart.

use crate::api::get_device_manager;
use crate::device::{SafetyStatus, WeatherConditions};
use crate::error::SkotiqError;

/// Read the latest observing-conditions values from a connected device.
pub async fn api_get_weather_conditions(
    device_id: String,
) -> Result<WeatherConditions, SkotiqError> {
    get_device_manager()
        .weather_get_conditions(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Read a connected safety monitor directly. This deliberately does not use a
/// cached Dart provider value: safety checks must fail closed when the driver
/// read fails.
pub async fn api_get_safety_monitor_status(device_id: String) -> Result<SafetyStatus, SkotiqError> {
    let is_safe = get_device_manager()
        .safety_is_safe(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    Ok(SafetyStatus {
        connected: true,
        is_safe,
    })
}
