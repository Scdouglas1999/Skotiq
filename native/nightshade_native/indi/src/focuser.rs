//! INDI Focuser wrapper
//!
//! Provides high-level focuser control via INDI protocol.

use crate::client::IndiClient;
use crate::error::IndiResult;
use crate::protocol::standard_properties::*;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// INDI Focuser device wrapper
pub struct IndiFocuser {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiFocuser {
    /// Create a new INDI focuser wrapper
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

    /// Connect to the focuser
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the focuser
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    /// Move to absolute position
    ///
    /// Returns once the driver has answered the move, not merely once it was
    /// sent: see [`Self::wait_for_move_answer`].
    pub async fn move_to(&self, position: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        let updated_before = client
            .get_property_last_update_ms(&self.device_name, ABS_FOCUS_POSITION)
            .await;
        let answer_timeout =
            Duration::from_secs(client.timeout_config().property_timeout_secs.max(1));
        client
            .set_number(
                &self.device_name,
                ABS_FOCUS_POSITION,
                "FOCUS_ABSOLUTE_POSITION",
                // Why: i32 focuser position -> f64 (INDI wire); lossless.
                f64::from(position),
            )
            .await?;
        drop(client);

        self.wait_for_move_answer(
            ABS_FOCUS_POSITION,
            updated_before,
            Some(position),
            answer_timeout,
        )
        .await
    }

    /// Wait for the driver's answer to a move.
    ///
    /// Sending the target only queues it; the cached property still says Ok at
    /// the old position until the driver's Busy comes back. The sequencer polls
    /// `is_moving` the moment the move returns and takes the first "not
    /// moving" as arrival, so a move that returned on send read as a move that
    /// had already ended where it started, and the next autofocus frame was
    /// exposed while the focuser was still travelling.
    ///
    /// Busy is the answer. Alert is the driver refusing the move and is
    /// returned as an error. An Ok update already at `target` (or any Ok update
    /// for a relative move, which has no position to compare) is a move that
    /// finished before the first poll. A driver that never answers within
    /// `timeout` is logged and let through, which is what this did before.
    async fn wait_for_move_answer(
        &self,
        property: &str,
        updated_before: Option<u64>,
        target: Option<i32>,
        timeout: Duration,
    ) -> IndiResult<()> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            {
                let client = self.client.read().await;
                let updated = client
                    .get_property_last_update_ms(&self.device_name, property)
                    .await;
                if updated > updated_before {
                    match client.get_property_state(&self.device_name, property).await {
                        Some(crate::IndiPropertyState::Busy) => return Ok(()),
                        Some(crate::IndiPropertyState::Alert) => {
                            return Err(crate::error::IndiError::DeviceAlert(format!(
                                "{} refused the focuser move ({} went to Alert)",
                                self.device_name, property
                            )));
                        }
                        _ => match target {
                            None => return Ok(()),
                            Some(target) => {
                                let position = client
                                    .get_number(
                                        &self.device_name,
                                        ABS_FOCUS_POSITION,
                                        "FOCUS_ABSOLUTE_POSITION",
                                    )
                                    .await;
                                if position.is_some_and(|p| (p - f64::from(target)).abs() < 0.5) {
                                    return Ok(());
                                }
                            }
                        },
                    }
                }
            }
            if tokio::time::Instant::now() >= deadline {
                tracing::warn!(
                    "{} did not answer the focuser move within {:?}; move completion may read \
                     the old position",
                    self.device_name,
                    timeout
                );
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Move to absolute position with timeout
    pub async fn move_to_with_timeout(
        &self,
        position: i32,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            Duration::from_secs(client.timeout_config().focuser_move_timeout_secs)
        };

        // Start the move, and wait for the driver to take it up: until then
        // the property still reads not-Busy from the last move.
        self.move_to(position).await?;

        // Wait for move to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, ABS_FOCUS_POSITION, timeout_duration)
            .await
            .map_err(|e| format!("Focuser move to position {} failed: {}", position, e))
    }

    /// Move relative (inward/outward)
    pub async fn move_relative(&self, steps: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;

        // Determine direction
        let direction = if steps > 0 { "FOCUS_IN" } else { "FOCUS_OUT" };
        let abs_steps = steps.abs();

        // Set direction switch
        client
            .set_switch(&self.device_name, FOCUS_MOTION, direction, true)
            .await?;

        let updated_before = client
            .get_property_last_update_ms(&self.device_name, REL_FOCUS_POSITION)
            .await;
        let answer_timeout =
            Duration::from_secs(client.timeout_config().property_timeout_secs.max(1));

        // Set relative steps
        client
            .set_number(
                &self.device_name,
                REL_FOCUS_POSITION,
                "FOCUS_RELATIVE_POSITION",
                // Why: i32 steps -> f64 (INDI wire); lossless.
                f64::from(abs_steps),
            )
            .await?;
        drop(client);

        self.wait_for_move_answer(REL_FOCUS_POSITION, updated_before, None, answer_timeout)
            .await
    }

    /// Move relative with timeout (inward/outward)
    pub async fn move_relative_with_timeout(
        &self,
        steps: i32,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            Duration::from_secs(client.timeout_config().focuser_move_timeout_secs)
        };

        // Start the move, and wait for the driver to take it up.
        self.move_relative(steps).await?;

        // Wait for move to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, REL_FOCUS_POSITION, timeout_duration)
            .await
            .map_err(|e| format!("Focuser relative move by {} steps failed: {}", steps, e))
    }

    /// Abort motion
    pub async fn abort_motion(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, FOCUS_ABORT_MOTION, "ABORT", true)
            .await
    }

    /// Get current position
    pub async fn get_position(&self) -> Result<i32, String> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                ABS_FOCUS_POSITION,
                "FOCUS_ABSOLUTE_POSITION",
            )
            .await
            // Why: INDI wire f64 -> i32 focuser position; bounded by focuser
            // max (typically <2^31). f64 -> i32 saturates per Rust 1.45 spec.
            .map(|p| p as i32)
            .ok_or_else(|| "Position not available".to_string())
    }

    /// Check if moving
    pub async fn is_moving(&self) -> bool {
        let client = self.client.read().await;
        for property in [ABS_FOCUS_POSITION, REL_FOCUS_POSITION, FOCUS_MOTION] {
            if let Some(state) = client.get_property_state(&self.device_name, property).await {
                if state == crate::IndiPropertyState::Busy {
                    return true;
                }
            }
        }
        false
    }

    /// Get temperature
    pub async fn get_temperature(&self) -> Result<f64, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, FOCUS_TEMPERATURE, "TEMPERATURE")
            .await
            .ok_or_else(|| "Temperature not available".to_string())
    }

    /// Maximum focuser travel in steps (`FOCUS_MAX` / `FOCUS_MAX_VALUE`).
    pub async fn get_max_step(&self) -> Option<i32> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, FOCUS_MAX, "FOCUS_MAX_VALUE")
            .await
            .map(|v| v as i32)
    }

    /// Focuser step size (`FOCUS_STEP` / `FOCUS_STEP_VALUE`), when advertised.
    pub async fn get_step_size(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, FOCUS_STEP, "FOCUS_STEP_VALUE")
            .await
    }

    /// Whether temperature compensation is enabled.
    pub async fn is_temp_comp_enabled(&self) -> Option<bool> {
        let client = self.client.read().await;
        for property in [FOCUS_TEMPERATURE_COMP, FOCUS_TEMP_COMP] {
            if client
                .get_switch(&self.device_name, property, "INDI_ENABLED")
                .await
                .is_some()
            {
                return client
                    .get_switch(&self.device_name, property, "INDI_ENABLED")
                    .await;
            }
        }
        None
    }

    /// Enable or disable temperature compensation when the driver supports it.
    pub async fn set_temp_comp_enabled(&self, enabled: bool) -> IndiResult<()> {
        let client = self.client.read().await;
        let property = if client
            .has_property(&self.device_name, FOCUS_TEMPERATURE_COMP)
            .await
        {
            FOCUS_TEMPERATURE_COMP
        } else {
            FOCUS_TEMP_COMP
        };
        let mut client = self.client.write().await;
        let element = if enabled {
            "INDI_ENABLED"
        } else {
            "INDI_DISABLED"
        };
        client
            .set_switch_exclusive(&self.device_name, property, element)
            .await
    }

    /// Backlash compensation step count (`FOCUS_BACKLASH_STEPS`).
    pub async fn get_backlash(&self) -> Option<i32> {
        let client = self.client.read().await;
        client
            .get_number(
                &self.device_name,
                FOCUS_BACKLASH_STEPS,
                "FOCUS_BACKLASH_VALUE",
            )
            .await
            .map(|v| v as i32)
    }

    /// Set backlash steps when supported.
    pub async fn set_backlash(&self, steps: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(
                &self.device_name,
                FOCUS_BACKLASH_STEPS,
                "FOCUS_BACKLASH_VALUE",
                f64::from(steps),
            )
            .await
    }

    /// Whether backlash compensation is enabled (`FOCUS_BACKLASH_TOGGLE`).
    pub async fn is_backlash_enabled(&self) -> Option<bool> {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, FOCUS_BACKLASH_TOGGLE, "INDI_ENABLED")
            .await
    }

    /// Enable or disable backlash compensation.
    pub async fn set_backlash_enabled(&self, enabled: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        let element = if enabled {
            "INDI_ENABLED"
        } else {
            "INDI_DISABLED"
        };
        client
            .set_switch_exclusive(&self.device_name, FOCUS_BACKLASH_TOGGLE, element)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::IndiClient;

    #[tokio::test]
    async fn test_focuser_creation() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let focuser = IndiFocuser::new(client, "TestFocuser");
        assert_eq!(focuser.device_name(), "TestFocuser");
    }

    #[tokio::test]
    async fn test_move_to_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let focuser = IndiFocuser::new(client, "TestFocuser");

        // This will fail since we're not connected
        let result = focuser
            .move_to_with_timeout(5000, Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention either the position or that we're not connected
            assert!(e.contains("position 5000") || e.to_lowercase().contains("not connected"));
        }
    }

    #[tokio::test]
    async fn test_move_relative_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let focuser = IndiFocuser::new(client, "TestFocuser");

        // This will fail since we're not connected
        let result = focuser
            .move_relative_with_timeout(100, Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention either the steps or that we're not connected
            assert!(e.contains("100 steps") || e.to_lowercase().contains("not connected"));
        }
    }

    #[tokio::test]
    async fn test_focuser_timeout_uses_config() {
        let config = crate::IndiTimeoutConfig {
            focuser_move_timeout_secs: 240, // Custom timeout
            ..Default::default()
        };

        let client = Arc::new(RwLock::new(IndiClient::with_timeout_config(
            "localhost",
            Some(7624),
            config,
        )));
        let _focuser = IndiFocuser::new(client.clone(), "TestFocuser");

        // Verify the timeout config is accessible
        let timeout_secs = {
            let c = client.read().await;
            c.timeout_config().focuser_move_timeout_secs
        };
        assert_eq!(timeout_secs, 240);
    }

    /// A fake server whose focuser, sitting idle at 5000, answers the first
    /// move command `reply_delay` after it arrives with `reply`.
    async fn focuser_with_delayed_move_reply(
        reply: &'static str,
        reply_delay: Duration,
    ) -> (IndiFocuser, tokio::task::JoinHandle<()>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let payload = r#"
<defSwitchVector device="Focuser" name="CONNECTION" state="Ok" perm="rw">
  <defSwitch name="CONNECT">On</defSwitch>
  <defSwitch name="DISCONNECT">Off</defSwitch>
</defSwitchVector>
<defNumberVector device="Focuser" name="ABS_FOCUS_POSITION" state="Ok" perm="rw">
  <defNumber name="FOCUS_ABSOLUTE_POSITION" min="0" max="50000">5000</defNumber>
</defNumberVector>
"#;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI focuser server");
        let port = listener.local_addr().expect("read listener address").port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = [0_u8; 8192];
            let _ = socket.read(&mut buf).await;
            socket
                .write_all(payload.as_bytes())
                .await
                .expect("write fake focuser payload");
            let mut received = String::new();
            let mut replied = false;
            loop {
                match socket.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        received.push_str(&String::from_utf8_lossy(&buf[..n]));
                        if !replied && received.contains("newNumberVector") {
                            replied = true;
                            tokio::time::sleep(reply_delay).await;
                            let _ = socket.write_all(reply.as_bytes()).await;
                        }
                    }
                }
            }
        });

        let timeout_config = crate::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            ..Default::default()
        };
        let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while client
            .get_property("Focuser", ABS_FOCUS_POSITION)
            .await
            .is_none()
        {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        (
            IndiFocuser::new(Arc::new(RwLock::new(client)), "Focuser"),
            server,
        )
    }

    /// The sequencer waits out a focuser move by polling `is_moving` the
    /// moment the move call returns. A move that returns before the driver
    /// has said Busy reads the cached Ok from the last move as "arrived", so
    /// an autofocus point was exposed while the focuser was still travelling
    /// to it.
    #[tokio::test]
    async fn a_move_returns_only_once_the_driver_reports_it() {
        let (focuser, server) = focuser_with_delayed_move_reply(
            "<setNumberVector device=\"Focuser\" name=\"ABS_FOCUS_POSITION\" state=\"Busy\">\
               <oneNumber name=\"FOCUS_ABSOLUTE_POSITION\">5040</oneNumber>\
             </setNumberVector>",
            Duration::from_millis(300),
        )
        .await;

        focuser.move_to(6000).await.expect("move on fake server");

        assert!(
            focuser.is_moving().await,
            "the move returned while the focuser still read as idle at its old position"
        );

        drop(focuser);
        server.abort();
    }

    /// A driver that refuses a move (past a limit, a stalled motor) answers
    /// Alert. That is the move failing, not a move that finished.
    #[tokio::test]
    async fn a_move_the_driver_refuses_is_an_error() {
        let (focuser, server) = focuser_with_delayed_move_reply(
            "<setNumberVector device=\"Focuser\" name=\"ABS_FOCUS_POSITION\" state=\"Alert\" \
               message=\"Target is out of range\">\
               <oneNumber name=\"FOCUS_ABSOLUTE_POSITION\">5000</oneNumber>\
             </setNumberVector>",
            Duration::from_millis(100),
        )
        .await;

        let result = focuser.move_to(6000).await;
        assert!(result.is_err(), "a refused move returned {:?}", result);

        drop(focuser);
        server.abort();
    }
}
