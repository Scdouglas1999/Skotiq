//! INDI Dome wrapper
//!
//! Provides high-level dome control via INDI protocol.
//!
//! # `unwrap_or(false)` policy
//!
//! `IndiClient::get_switch` returns `Result<Option<bool>, IndiError>`. An
//! `Err`/`None` here means the INDI driver has not yet streamed the
//! property/element pair — e.g. `DOME_AUTOSYNC` is optional and many
//! observatory domes do not support it. The caller (`get_shutter_status`,
//! `at_home`, `is_parked`, `is_slaved`) treats absent property as the
//! "false/Unknown" sentinel, which is the semantically-correct mapping for
//! these read-side observers. Hardware *commands* are issued through
//! `set_switch` / `set_number`, which return `IndiResult` and propagate
//! errors normally — silent fallback here applies only to status probes.

use crate::client::IndiClient;
use crate::error::IndiResult;
use crate::IndiPropertyState;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// Shutter status for INDI domes
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiShutterStatus {
    Open,
    Closed,
    Opening,
    Closing,
    Error,
    Unknown,
}

/// INDI Dome device wrapper
pub struct IndiDome {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
    last_shutter_command: Arc<RwLock<Option<IndiShutterStatus>>>,
}

impl IndiDome {
    /// Create a new INDI dome wrapper
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
            last_shutter_command: Arc::new(RwLock::new(None)),
        }
    }

    /// Get the device name
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    // Connection

    /// Connect to the dome
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the dome
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    // Position

    /// Get the current dome azimuth position in degrees (0-360)
    pub async fn get_azimuth(&self) -> Result<f64, String> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                "ABS_DOME_POSITION",
                "DOME_ABSOLUTE_POSITION",
            )
            .await
            .ok_or_else(|| "Azimuth not available".to_string())
    }

    /// Slew dome to specific azimuth
    pub async fn slew_to_azimuth(&self, azimuth: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(
                &self.device_name,
                "ABS_DOME_POSITION",
                "DOME_ABSOLUTE_POSITION",
                azimuth,
            )
            .await
    }

    /// Slew dome to specific azimuth with timeout
    pub async fn slew_to_azimuth_with_timeout(
        &self,
        azimuth: f64,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            Duration::from_secs(client.timeout_config().dome_slew_timeout_secs)
        };

        // Start the slew
        {
            let mut client = self.client.write().await;
            client
                .set_number(
                    &self.device_name,
                    "ABS_DOME_POSITION",
                    "DOME_ABSOLUTE_POSITION",
                    azimuth,
                )
                .await?;
        }

        // Wait for slew to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, "ABS_DOME_POSITION", timeout_duration)
            .await
            .map_err(|e| format!("Dome slew to azimuth {:.1} degrees failed: {}", azimuth, e))
    }

    /// Sync dome to current azimuth
    pub async fn sync_to_azimuth(&self, azimuth: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, "DOME_SYNC", "DOME_SYNC_VALUE", azimuth)
            .await
    }

    // Shutter control

    /// Open the dome shutter
    pub async fn open_shutter(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_SHUTTER", "SHUTTER_OPEN", true)
            .await?;
        *self.last_shutter_command.write().await = Some(IndiShutterStatus::Opening);
        Ok(())
    }

    /// Close the dome shutter
    pub async fn close_shutter(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_SHUTTER", "SHUTTER_CLOSE", true)
            .await?;
        *self.last_shutter_command.write().await = Some(IndiShutterStatus::Closing);
        Ok(())
    }

    /// Open the dome shutter with timeout
    pub async fn open_shutter_with_timeout(&self, timeout: Option<Duration>) -> Result<(), String> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            // Use dome slew timeout for shutter operations (they can be slow)
            Duration::from_secs(client.timeout_config().dome_slew_timeout_secs)
        };

        // Start shutter operation
        {
            let mut client = self.client.write().await;
            client
                .set_switch(&self.device_name, "DOME_SHUTTER", "SHUTTER_OPEN", true)
                .await?;
        }
        *self.last_shutter_command.write().await = Some(IndiShutterStatus::Opening);

        // Wait for shutter operation to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, "DOME_SHUTTER", timeout_duration)
            .await
            .map_err(|e| format!("Dome shutter open operation failed: {}", e))
    }

    /// Close the dome shutter with timeout
    pub async fn close_shutter_with_timeout(
        &self,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            // Use dome slew timeout for shutter operations (they can be slow)
            Duration::from_secs(client.timeout_config().dome_slew_timeout_secs)
        };

        // Start shutter operation
        {
            let mut client = self.client.write().await;
            client
                .set_switch(&self.device_name, "DOME_SHUTTER", "SHUTTER_CLOSE", true)
                .await?;
        }
        *self.last_shutter_command.write().await = Some(IndiShutterStatus::Closing);

        // Wait for shutter operation to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, "DOME_SHUTTER", timeout_duration)
            .await
            .map_err(|e| format!("Dome shutter close operation failed: {}", e))
    }

    /// Get shutter status by checking switch states
    pub async fn get_shutter_status(&self) -> IndiShutterStatus {
        let client = self.client.read().await;

        // Check if shutter is open
        let is_open = client
            .get_switch(&self.device_name, "DOME_SHUTTER", "SHUTTER_OPEN")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns Unknown.
            .unwrap_or(false);

        // Check if shutter is closed
        let is_closed = client
            .get_switch(&self.device_name, "DOME_SHUTTER", "SHUTTER_CLOSE")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns Unknown.
            .unwrap_or(false);

        let shutter_state = client
            .get_property_state(&self.device_name, "DOME_SHUTTER")
            .await;
        let shutter_busy = shutter_state == Some(IndiPropertyState::Busy);

        if shutter_state == Some(IndiPropertyState::Alert) {
            IndiShutterStatus::Error
        } else if shutter_busy && is_open && !is_closed {
            IndiShutterStatus::Opening
        } else if shutter_busy && is_closed && !is_open {
            IndiShutterStatus::Closing
        } else if shutter_busy {
            self.last_shutter_command
                .read()
                .await
                .filter(|status| {
                    matches!(
                        status,
                        IndiShutterStatus::Opening | IndiShutterStatus::Closing
                    )
                })
                .unwrap_or(IndiShutterStatus::Unknown)
        } else if is_open && !is_closed {
            IndiShutterStatus::Open
        } else if is_closed && !is_open {
            IndiShutterStatus::Closed
        } else {
            // Check if we're in motion by looking at property state
            // If both are false or property is busy, we're in transition
            IndiShutterStatus::Unknown
        }
    }

    // Motion control

    /// Check if dome is currently slewing
    pub async fn is_slewing(&self) -> bool {
        let client = self.client.read().await;
        // Check if the dome position property is in "Busy" state
        client
            .is_property_busy(&self.device_name, "ABS_DOME_POSITION")
            .await
    }

    /// Abort all dome motion
    pub async fn abort_slew(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_ABORT_MOTION", "ABORT", true)
            .await
    }

    /// Move dome clockwise (manual jog)
    pub async fn move_clockwise(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_MOTION", "DOME_CW", true)
            .await
    }

    /// Move dome counter-clockwise (manual jog)
    pub async fn move_counter_clockwise(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_MOTION", "DOME_CCW", true)
            .await
    }

    // Home & Park

    /// Go to home position
    pub async fn find_home(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_GOTO", "DOME_HOME", true)
            .await
    }

    /// Park the dome
    pub async fn park(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "DOME_GOTO", "DOME_PARK", true)
            .await
    }

    /// Unpark the dome
    pub async fn unpark(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        // INDI uses DOME_PARK property with UNPARK element
        client
            .set_switch(&self.device_name, "DOME_PARK", "UNPARK", true)
            .await
    }

    /// Check if dome is at home position
    pub async fn at_home(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, "DOME_GOTO", "DOME_HOME")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false.
            .unwrap_or(false)
    }

    /// Check if dome is parked
    pub async fn is_parked(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, "DOME_PARK", "PARK")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false.
            .unwrap_or(false)
    }

    // Slaving

    /// Enable/disable mount slaving
    pub async fn set_slaved(&self, slaved: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        if slaved {
            client
                .set_switch(
                    &self.device_name,
                    "DOME_AUTOSYNC",
                    "DOME_AUTOSYNC_ENABLE",
                    true,
                )
                .await
        } else {
            client
                .set_switch(
                    &self.device_name,
                    "DOME_AUTOSYNC",
                    "DOME_AUTOSYNC_DISABLE",
                    true,
                )
                .await
        }
    }

    /// Check if dome is slaved to mount
    pub async fn is_slaved(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, "DOME_AUTOSYNC", "DOME_AUTOSYNC_ENABLE")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false.
            .unwrap_or(false)
    }

    // Configuration

    /// Set home position
    pub async fn set_home_position(&self, azimuth: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, "DOME_PARAMS", "HOME_POSITION", azimuth)
            .await
    }

    /// Set park position
    pub async fn set_park_position(&self, azimuth: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, "DOME_PARAMS", "PARK_POSITION", azimuth)
            .await
    }

    /// Get home position
    pub async fn get_home_position(&self) -> Result<f64, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "DOME_PARAMS", "HOME_POSITION")
            .await
            .ok_or_else(|| "Home position not available".to_string())
    }

    /// Get park position
    pub async fn get_park_position(&self) -> Result<f64, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "DOME_PARAMS", "PARK_POSITION")
            .await
            .ok_or_else(|| "Park position not available".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::IndiClient;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn dome_from_fake_server(
        payload: &'static [u8],
    ) -> (IndiDome, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI dome server");
        let port = listener.local_addr().expect("read listener address").port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = [0_u8; 4096];
            let _ = socket
                .read(&mut buf)
                .await
                .expect("read initial getProperties");
            socket
                .write_all(payload)
                .await
                .expect("write fake dome payload");
            loop {
                match socket.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
        });

        let timeout_config = crate::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            ..Default::default()
        };
        let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");

        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        while client.get_property("Dome", "DOME_SHUTTER").await.is_none() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "fake INDI DOME_SHUTTER property was not parsed in time"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        (IndiDome::new(Arc::new(RwLock::new(client)), "Dome"), server)
    }

    #[tokio::test]
    async fn test_dome_creation() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let dome = IndiDome::new(client, "TestDome");
        assert_eq!(dome.device_name(), "TestDome");
    }

    #[tokio::test]
    async fn test_slew_to_azimuth_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let dome = IndiDome::new(client, "TestDome");

        // This will fail since we're not connected
        let result = dome
            .slew_to_azimuth_with_timeout(180.0, Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention the azimuth or that we're not connected
            assert!(e.contains("180") || e.to_lowercase().contains("not connected"));
        }
    }

    #[tokio::test]
    async fn test_open_shutter_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let dome = IndiDome::new(client, "TestDome");

        // This will fail since we're not connected
        let result = dome
            .open_shutter_with_timeout(Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention shutter or connection
            assert!(e.contains("shutter") || e.to_lowercase().contains("not connected"));
        }
    }

    #[tokio::test]
    async fn test_dome_timeout_uses_config() {
        let config = crate::IndiTimeoutConfig {
            dome_slew_timeout_secs: 600, // Custom timeout
            ..Default::default()
        };

        let client = Arc::new(RwLock::new(IndiClient::with_timeout_config(
            "localhost",
            Some(7624),
            config,
        )));
        let _dome = IndiDome::new(client.clone(), "TestDome");

        // Verify the timeout config is accessible
        let timeout_secs = {
            let c = client.read().await;
            c.timeout_config().dome_slew_timeout_secs
        };
        assert_eq!(timeout_secs, 600);
    }

    #[tokio::test]
    async fn shutter_status_reports_opening_when_shutter_property_busy_open_switch_active() {
        let (dome, server) = dome_from_fake_server(
            br#"
<defSwitchVector device="Dome" name="DOME_SHUTTER" state="Idle" perm="rw">
  <defSwitch name="SHUTTER_OPEN">Off</defSwitch>
  <defSwitch name="SHUTTER_CLOSE">Off</defSwitch>
</defSwitchVector>
<setSwitchVector device="Dome" name="DOME_SHUTTER" state="Busy">
  <oneSwitch name="SHUTTER_OPEN">On</oneSwitch>
  <oneSwitch name="SHUTTER_CLOSE">Off</oneSwitch>
</setSwitchVector>
"#,
        )
        .await;

        assert_eq!(dome.get_shutter_status().await, IndiShutterStatus::Opening);

        drop(dome);
        server.await.expect("fake server should finish");
    }

    #[tokio::test]
    async fn shutter_status_uses_last_successful_command_when_busy_switches_are_clear() {
        let (dome, server) = dome_from_fake_server(
            br#"
<defSwitchVector device="Dome" name="DOME_SHUTTER" state="Busy" perm="rw">
  <defSwitch name="SHUTTER_OPEN">Off</defSwitch>
  <defSwitch name="SHUTTER_CLOSE">Off</defSwitch>
</defSwitchVector>
"#,
        )
        .await;

        assert_eq!(dome.get_shutter_status().await, IndiShutterStatus::Unknown);

        dome.close_shutter()
            .await
            .expect("close_shutter command should be sent to fake server");
        assert_eq!(dome.get_shutter_status().await, IndiShutterStatus::Closing);

        drop(dome);
        server.await.expect("fake server should finish");
    }
}
