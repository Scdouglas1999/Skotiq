use super::*;

#[async_trait]
impl SafetyOps for UnifiedDeviceOps {
    async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool> {
        // Prefer a connected SafetyMonitor device. Equipment profiles still
        // only store weather_id, so weather remains a fallback rather than the
        // primary safety source.
        let device_id = self.resolve_safety_device_id(safety_id).await?;

        tracing::debug!("Checking safety status for device: {}", device_id);

        // Use DeviceManager which handles all driver types (ASCOM, Alpaca, INDI, Native)
        match get_device_manager().safety_is_safe(&device_id).await {
            Ok(is_safe) => {
                tracing::info!(
                    "Safety monitor {} reports: {}",
                    device_id,
                    if is_safe { "SAFE" } else { "UNSAFE" }
                );
                Ok(is_safe)
            }

            Err(e) => {
                tracing::error!("Failed to check safety monitor {}: {} - returning error for fail-mode handling", device_id, e);
                Err(format!("Safety check failed for {}: {}", device_id, e).into())
            }
        }
    }

    /// Feed HumidityThreshold triggers from the configured weather device.
    /// See the trait rustdoc for `Ok(None)` vs `Err` semantics.
    async fn weather_get_humidity(&self, weather_id: Option<&str>) -> DeviceResult<Option<f64>> {
        let device_id = match weather_id {
            Some(id) => id.to_string(),
            None => {
                let profile = self.app_state.get_profile().await;
                match profile.and_then(|p| p.weather_id) {
                    Some(id) => id,
                    None => return Ok(None),
                }
            }
        };

        match get_device_manager()
            .weather_get_conditions(&device_id)
            .await
        {
            Ok(conditions) => Ok(conditions.humidity),
            Err(e) => Err(format!("Humidity poll failed for {}: {}", device_id, e).into()),
        }
    }
}
