//! INDI Weather device wrapper
//!
//! Provides weather monitoring via INDI protocol.
//!
//! INDI weather devices expose standard properties:
//! - WEATHER_PARAMETERS: Number vector with individual sensor readings
//! - WEATHER_STATUS: Light vector with per-sensor alert states
//!
//! Standard element names under WEATHER_PARAMETERS:
//! WEATHER_TEMPERATURE, WEATHER_HUMIDITY, WEATHER_PRESSURE,
//! WEATHER_WIND_SPEED, WEATHER_WIND_GUST, WEATHER_WIND_DIRECTION,
//! WEATHER_CLOUD_COVER, WEATHER_RAIN_RATE, WEATHER_DEWPOINT,
//! WEATHER_SKY_QUALITY, WEATHER_SKY_TEMPERATURE, WEATHER_SKY_BRIGHTNESS
//!
//! # `unwrap_or(false)` policy
//!
//! Each `has_*_alert` probe (`get_light_state(...).map(|s| s == 3)`) returns
//! `false` when the INDI driver does not publish that specific weather
//! parameter — e.g. a temperature/humidity-only station omits
//! `WEATHER_RAIN`. The aggregate caller does NOT use these directly to gate
//! exposure starts; safety-gating goes through the
//! `IndiSafetyMonitor::is_safe` path (see `safetymonitor.rs`), which fails
//! CLOSED on the empty-indicator case. These probes are observability /
//! UI signals only and "alert absent" is the correct default.

use crate::client::{current_time_ms, IndiClient};
use crate::error::IndiResult;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// Default maximum age for `WEATHER_PARAMETERS` before readings are treated as stale.
pub const DEFAULT_WEATHER_STALE_MS: u64 = 120_000;

/// Overall weather status derived from INDI light states
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiWeatherStatus {
    /// All parameters OK
    Ok,
    /// Some parameters in warning range
    Warning,
    /// One or more parameters in alert range -- unsafe
    Alert,
    /// Status unknown or device not reporting
    Unknown,
}

/// INDI Weather device wrapper
pub struct IndiWeather {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiWeather {
    /// Create a new INDI weather device wrapper
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
        }
    }

    /// Get the device name
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    // Connection

    /// Connect to the weather device
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the weather device
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    // Weather measurements

    /// Age of the last `WEATHER_PARAMETERS` update in milliseconds, if known.
    pub async fn parameters_age_ms(&self) -> Option<u64> {
        let client = self.client.read().await;
        let now = current_time_ms();
        client
            .get_property_last_update_ms(&self.device_name, "WEATHER_PARAMETERS")
            .await
            .map(|ts| now.saturating_sub(ts))
    }

    /// Returns true when weather readings are older than `max_age` or never received.
    pub async fn is_parameters_stale(&self, max_age: Duration) -> bool {
        let limit_ms = max_age.as_millis() as u64;
        match self.parameters_age_ms().await {
            Some(age) => age > limit_ms,
            None => true,
        }
    }

    /// Temperature in Celsius when `WEATHER_PARAMETERS` was updated within `max_age`.
    pub async fn get_temperature_if_fresh(&self, max_age: Duration) -> Option<f64> {
        if self.is_parameters_stale(max_age).await {
            return None;
        }
        self.get_temperature().await
    }

    /// Get temperature in Celsius
    pub async fn get_temperature(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_TEMPERATURE",
            )
            .await
    }

    /// Get humidity percentage (0-100)
    pub async fn get_humidity(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_HUMIDITY")
            .await
    }

    /// Get barometric pressure in hPa
    pub async fn get_pressure(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_PRESSURE")
            .await
    }

    /// Get wind speed in m/s
    pub async fn get_wind_speed(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_WIND_SPEED",
            )
            .await
    }

    /// Get wind gust speed in m/s
    pub async fn get_wind_gust(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_WIND_GUST")
            .await
    }

    /// Get wind direction in degrees (0-360)
    pub async fn get_wind_direction(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_WIND_DIRECTION",
            )
            .await
    }

    /// Get cloud cover percentage (0-100)
    pub async fn get_cloud_cover(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_CLOUD_COVER",
            )
            .await
    }

    /// Get rain rate in mm/hr
    pub async fn get_rain_rate(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_RAIN_RATE")
            .await
    }

    /// Get dew point in Celsius
    pub async fn get_dew_point(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_DEWPOINT")
            .await
    }

    /// Get sky quality in mag/arcsec^2
    pub async fn get_sky_quality(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_SKY_QUALITY",
            )
            .await
    }

    /// Get sky temperature in Celsius
    pub async fn get_sky_temperature(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_SKY_TEMPERATURE",
            )
            .await
    }

    /// Get sky brightness in lux
    pub async fn get_sky_brightness(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "WEATHER_PARAMETERS",
                "WEATHER_SKY_BRIGHTNESS",
            )
            .await
    }

    // Overall status

    /// Get overall weather status from WEATHER_STATUS light property
    ///
    /// INDI light states: Idle (0), Ok (1), Busy (2), Alert (3)
    /// The overall status is determined by the worst individual sensor state.
    pub async fn get_overall_status(&self) -> IndiWeatherStatus {
        let client = self.client.read().await;

        // Check overall WEATHER_SAFE element first
        if let Some(state) = client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_SAFE")
            .await
        {
            return match state {
                0 | 1 => IndiWeatherStatus::Ok,
                2 => IndiWeatherStatus::Warning,
                3 => IndiWeatherStatus::Alert,
                _ => IndiWeatherStatus::Unknown,
            };
        }

        // Fall back to checking individual weather status elements
        let elements = [
            "WEATHER_RAIN",
            "WEATHER_WIND",
            "WEATHER_CLOUDS",
            "WEATHER_HUMIDITY",
            "WEATHER_TEMPERATURE",
        ];

        let mut worst_state = 0i32;
        let mut found_any = false;

        for element in &elements {
            if let Some(state) = client
                .get_light_state(&self.device_name, "WEATHER_STATUS", element)
                .await
            {
                found_any = true;
                if state > worst_state {
                    worst_state = state;
                }
            }
        }

        if !found_any {
            return IndiWeatherStatus::Unknown;
        }

        match worst_state {
            0 | 1 => IndiWeatherStatus::Ok,
            2 => IndiWeatherStatus::Warning,
            3 => IndiWeatherStatus::Alert,
            _ => IndiWeatherStatus::Unknown,
        }
    }

    /// Check if conditions are safe for observing
    pub async fn is_safe(&self) -> bool {
        match self.get_overall_status().await {
            IndiWeatherStatus::Ok => true,
            IndiWeatherStatus::Warning => true,
            IndiWeatherStatus::Alert => false,
            IndiWeatherStatus::Unknown => false, // Fail-closed: unknown status is treated as unsafe
        }
    }

    // Alert states

    /// Check if there's a rain alert
    pub async fn has_rain_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_RAIN")
            .await
            .map(|s| s == 3)
            // Why: see the module's `unwrap_or(false)` policy — parameter not published → no alert (observability only).
            .unwrap_or(false)
    }

    /// Check if there's a wind alert
    pub async fn has_wind_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_WIND")
            .await
            .map(|s| s == 3)
            // Why: see the module's `unwrap_or(false)` policy — parameter not published → no alert (observability only).
            .unwrap_or(false)
    }

    /// Check if there's a cloud alert
    pub async fn has_cloud_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_CLOUDS")
            .await
            .map(|s| s == 3)
            // Why: see the module's `unwrap_or(false)` policy — parameter not published → no alert (observability only).
            .unwrap_or(false)
    }

    /// Check if there's a humidity alert
    pub async fn has_humidity_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_HUMIDITY")
            .await
            .map(|s| s == 3)
            // Why: see the module's `unwrap_or(false)` policy — parameter not published → no alert (observability only).
            .unwrap_or(false)
    }

    // Sensor availability

    /// Check if WEATHER_STATUS property is available (device reports weather states)
    pub async fn has_weather_status(&self) -> bool {
        let client = self.client.read().await;
        client
            .has_property(&self.device_name, "WEATHER_STATUS")
            .await
    }

    /// Check if WEATHER_PARAMETERS property is available (device reports readings)
    pub async fn has_weather_parameters(&self) -> bool {
        let client = self.client.read().await;
        client
            .has_property(&self.device_name, "WEATHER_PARAMETERS")
            .await
    }

    /// Check if temperature sensor is available
    pub async fn has_temperature(&self) -> bool {
        self.get_temperature().await.is_some()
    }

    /// Check if humidity sensor is available
    pub async fn has_humidity(&self) -> bool {
        self.get_humidity().await.is_some()
    }

    /// Check if pressure sensor is available
    pub async fn has_pressure(&self) -> bool {
        self.get_pressure().await.is_some()
    }

    /// Check if wind speed sensor is available
    pub async fn has_wind_speed(&self) -> bool {
        self.get_wind_speed().await.is_some()
    }

    /// Check if cloud cover sensor is available
    pub async fn has_cloud_cover(&self) -> bool {
        self.get_cloud_cover().await.is_some()
    }

    /// Check if rain rate sensor is available
    pub async fn has_rain_rate(&self) -> bool {
        self.get_rain_rate().await.is_some()
    }

    /// Check if sky quality sensor is available
    pub async fn has_sky_quality(&self) -> bool {
        self.get_sky_quality().await.is_some()
    }

    /// Check if sky temperature sensor is available
    pub async fn has_sky_temperature(&self) -> bool {
        self.get_sky_temperature().await.is_some()
    }

    /// Check if sky brightness sensor is available
    pub async fn has_sky_brightness(&self) -> bool {
        self.get_sky_brightness().await.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn parameters_stale_when_never_updated() {
        let client = Arc::new(tokio::sync::RwLock::new(IndiClient::new(
            "localhost",
            Some(7624),
        )));
        let weather = IndiWeather::new(client, "WX");
        assert!(weather.is_parameters_stale(Duration::from_millis(1)).await);
    }
}
