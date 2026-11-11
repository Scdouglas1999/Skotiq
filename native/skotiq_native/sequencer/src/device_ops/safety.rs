//! What a run asks of the safety monitor and weather station.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait SafetyOps: Send + Sync {
    /// Check if conditions are safe for observing
    /// Returns true if safe, false if unsafe.
    /// Returns Err when safety status cannot be determined (missing device, driver error, etc.).
    async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool>;

    /// Read humidity percentage (0-100) from the weather/observatory device.
    ///
    /// Returns `Ok(Some(value))` when the device reports humidity, `Ok(None)`
    /// when humidity is genuinely not supported by the connected weather
    /// device, and `Err(_)` when the query failed (driver error, no device
    /// configured, etc.). The trigger monitor uses this to feed the
    /// `HumidityThreshold` trigger; an `Err` result is logged and the trigger
    /// state is left unchanged so a stale-but-known reading does not get
    /// overwritten by a transient driver hiccup.
    ///
    /// The default reports no humidity; the real device layer overrides it.
    async fn weather_get_humidity(&self, weather_id: Option<&str>) -> DeviceResult<Option<f64>> {
        let _ = weather_id;
        Ok(None)
    }
}
