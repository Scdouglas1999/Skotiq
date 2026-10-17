//! INDI Safety Monitor wrapper
//!
//! Provides safety monitoring via INDI protocol.
//!
//! INDI doesn't have a dedicated "SafetyMonitor" device type like ASCOM/Alpaca.
//! Instead, safety monitoring is typically implemented via:
//! - Weather devices (Weather interface with safety states)
//! - Watchdog devices (custom safety implementations)
//! - AUX devices with safety switches
//!
//! This wrapper provides a unified interface that can work with any of these.
//!
//! # `unwrap_or(false)` policy — fail-CLOSED
//!
//! Every `unwrap_or(false)` in this module evaluates a per-parameter weather
//! alert probe (`get_light_state(...).map(|s| s == 3)`). `Err`/`None` means
//! the INDI driver has not declared / has not yet streamed that specific
//! parameter (e.g. an indoor weather station with no rain sensor will not
//! publish `WEATHER_RAIN`). Treating "alert absent" as `false` for the
//! `has_*_alert` aggregate is **safe by construction** because the caller
//! `is_safe()` (line 124) **fails CLOSED with `Ok(false)`** when no
//! safety indicators resolve at all — i.e. an entirely-silent driver
//! produces *unsafe*, never *safe*. This matches the
//! `bridge/src/dispatch/alpaca.rs` `IsSafe` propagation precedent.
//!
//! Current aggregate behavior is stricter: `is_safe()` returns `Err` when no
//! safety indicator resolves at all, so the sequencer's `SafetyFailMode` makes
//! the only fail-open / fail-closed decision.

use crate::client::IndiClient;
use crate::error::IndiResult;
use std::sync::Arc;
use tokio::sync::RwLock;

/// INDI Safety Monitor device wrapper
pub struct IndiSafetyMonitor {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiSafetyMonitor {
    /// Create a new INDI safety monitor wrapper
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

    /// Connect to the safety monitor
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the safety monitor
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    // Safety status

    /// Check if conditions are safe for observing
    ///
    /// This checks multiple possible safety indicators:
    /// 1. WEATHER_STATUS property (for Weather devices)
    /// 2. SAFETY_STATUS property (for dedicated safety monitors)
    /// 3. Individual weather parameters (cloud, rain, wind)
    pub async fn is_safe(&self) -> Result<bool, String> {
        let client = self.client.read().await;

        // First, try the standard WEATHER_STATUS property
        // This is the most common way INDI weather devices report safety
        if let Some(state) = client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_SAFE")
            .await
        {
            // INDI light states: Idle (0), Ok (1), Busy (2), Alert (3)
            // "Ok" or "Idle" means safe
            return Ok(state == 0 || state == 1);
        }

        // Try a generic SAFETY_STATUS property
        if let Some(is_safe) = client
            .get_switch(&self.device_name, "SAFETY_STATUS", "SAFE")
            .await
        {
            return Ok(is_safe);
        }

        // Try AUX_SAFETY property (common for custom safety devices)
        if let Some(is_safe) = client
            .get_switch(&self.device_name, "AUX_SAFETY", "ENABLED")
            .await
        {
            return Ok(is_safe);
        }

        // Check individual weather alerts if available
        // If any critical parameter is in alert state, consider unsafe
        let has_rain_alert = client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_RAIN")
            .await
            .map(|s| s == 3) // Alert state
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false);

        let has_wind_alert = client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_WIND")
            .await
            .map(|s| s == 3)
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false);

        let has_cloud_alert = client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_CLOUDS")
            .await
            .map(|s| s == 3)
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false);

        if has_rain_alert || has_wind_alert || has_cloud_alert {
            return Ok(false);
        }

        Err(format!(
            "No INDI safety indicators resolved for device '{}' (checked \
             WEATHER_STATUS/WEATHER_SAFE, SAFETY_STATUS/SAFE, AUX_SAFETY/ENABLED, \
             and rain/wind/cloud alerts)",
            self.device_name
        ))
    }

    /// Check if any safety monitoring is available
    pub async fn is_monitoring_available(&self) -> bool {
        let client = self.client.read().await;

        // Check for various safety-related properties
        client
            .has_property(&self.device_name, "WEATHER_STATUS")
            .await
            || client
                .has_property(&self.device_name, "SAFETY_STATUS")
                .await
            || client.has_property(&self.device_name, "AUX_SAFETY").await
    }

    // Weather parameters (if available)

    /// Get temperature in Celsius (if available)
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

    /// Get humidity percentage (if available)
    pub async fn get_humidity(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_HUMIDITY")
            .await
    }

    /// Get wind speed in m/s (if available)
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

    /// Get cloud cover percentage (if available)
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

    /// Get rain rate (if available)
    pub async fn get_rain_rate(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_RAIN_RATE")
            .await
    }

    /// Get dew point in Celsius (if available)
    pub async fn get_dew_point(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_DEWPOINT")
            .await
    }

    /// Get sky quality in mag/arcsec^2 (if available)
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

    /// Get sky temperature in Celsius (if available)
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

    /// Get barometric pressure in hPa (if available)
    pub async fn get_pressure(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "WEATHER_PARAMETERS", "WEATHER_PRESSURE")
            .await
    }

    // Alert states

    /// Check if there's a rain alert
    pub async fn has_rain_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_RAIN")
            .await
            .map(|s| s == 3) // Alert state
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false)
    }

    /// Check if there's a wind alert
    pub async fn has_wind_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_WIND")
            .await
            .map(|s| s == 3)
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false)
    }

    /// Check if there's a cloud alert
    pub async fn has_cloud_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_CLOUDS")
            .await
            .map(|s| s == 3)
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false)
    }

    /// Check if there's a humidity alert
    pub async fn has_humidity_alert(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_light_state(&self.device_name, "WEATHER_STATUS", "WEATHER_HUMIDITY")
            .await
            .map(|s| s == 3)
            // Why: see the module's fail-CLOSED `unwrap_or(false)` policy — parameter not streamed → no alert; outer `is_safe()` fails CLOSED.
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn monitor_from_fake_server(
        payload: &'static [u8],
        marker_property: &str,
    ) -> (IndiSafetyMonitor, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI safety server");
        let port = listener.local_addr().expect("read listener address").port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = [0_u8; 2048];
            let _ = socket
                .read(&mut buf)
                .await
                .expect("read initial getProperties");
            socket
                .write_all(payload)
                .await
                .expect("write fake INDI safety payload");
            let _ = socket.read(&mut buf).await;
        });

        let timeout_config = crate::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            ..Default::default()
        };
        let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");

        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        while client
            .get_property("Safety", marker_property)
            .await
            .is_none()
        {
            assert!(
                tokio::time::Instant::now() < deadline,
                "fake INDI property '{}' was not parsed in time",
                marker_property
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        (
            IndiSafetyMonitor::new(Arc::new(RwLock::new(client)), "Safety"),
            server,
        )
    }

    #[tokio::test]
    async fn is_safe_errors_when_no_safety_indicators_resolve() {
        let (monitor, server) = monitor_from_fake_server(
            br#"
<defTextVector device="Safety" name="UNRELATED" state="Idle" perm="ro">
  <defText name="VALUE">present</defText>
</defTextVector>
"#,
            "UNRELATED",
        )
        .await;

        let err = monitor
            .is_safe()
            .await
            .expect_err("missing INDI safety indicators must be an error");
        assert!(
            err.contains("No INDI safety indicators resolved"),
            "error should identify the missing safety telemetry: {}",
            err
        );

        drop(monitor);
        server.await.expect("fake server should finish");
    }

    #[tokio::test]
    async fn is_safe_uses_standard_weather_safe_light_state() {
        let (monitor, server) = monitor_from_fake_server(
            br#"
<defLightVector device="Safety" name="WEATHER_STATUS" state="Idle">
  <defLight name="WEATHER_SAFE">Ok</defLight>
</defLightVector>
"#,
            "WEATHER_STATUS",
        )
        .await;

        assert!(
            monitor
                .is_safe()
                .await
                .expect("WEATHER_SAFE should resolve"),
            "WEATHER_SAFE=Ok should report safe"
        );

        drop(monitor);
        server.await.expect("fake server should finish");
    }

    #[tokio::test]
    async fn silent_driver_returns_error_not_synthetic_unsafe() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let safety = IndiSafetyMonitor::new(client, "SilentSafety");

        let err = safety
            .is_safe()
            .await
            .expect_err("silent safety monitor must surface an error");

        assert!(err.contains("No INDI safety indicators resolved"));
        assert!(err.contains("SilentSafety"));
    }
}
